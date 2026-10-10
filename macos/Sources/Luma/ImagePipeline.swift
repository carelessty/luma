import AppKit
import ImageIO

/// Memory-only, downsampled images. Work is deduplicated and downloads are bounded.
actor ImagePipeline {
    static let shared = ImagePipeline()
    private let cache = NSCache<NSString, NSImage>()
    private struct Request {
        let id = UUID()
        let task: Task<DecodedImage?, Never>
        var waiters: Set<UUID> = []
    }
    private var requests: [String: Request] = [:]
    private var generation = 0
    private let permits = ImagePermits(limit: 6)
    private let session: URLSession

    init(urlSession: URLSession? = nil) {
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 160
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        session = urlSession ?? URLSession(configuration: config, delegate: ArtworkRedirectDelegate(), delegateQueue: nil)
    }

    func image(for url: URL, maxPixelSize: Int = 1000) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let pixels = min(2560, max(64, maxPixelSize))
        let key = "\(pixels):\(url.absoluteString)"
        if let image = cache.object(forKey: key as NSString) { return image }
        let requestGeneration = generation
        let waiter = UUID()
        var request: Request
        if let pending = requests[key] {
            request = pending
        } else {
            request = Request(task: download(url: url, pixels: pixels))
        }
        request.waiters.insert(waiter)
        requests[key] = request
        let requestID = request.id
        let task = request.task
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.cancelWaiter(waiter, key: key, requestID: requestID) }
        }
        guard requestGeneration == generation else { return nil }
        // A reused cell may cancel its waiter while another cell still needs
        // this download. Always retire the shared request, including failures.
        if requests[key]?.id == request.id { requests[key] = nil }
        guard let decoded else { return nil }
        let image: NSImage
        if let cached = cache.object(forKey: key as NSString) { image = cached }
        else {
            image = NSImage(cgImage: decoded.image, size: decoded.size)
            cache.setObject(image, forKey: key as NSString, cost: decoded.image.bytesPerRow * decoded.image.height)
        }
        return Task.isCancelled ? nil : image
    }

    private func cancelWaiter(_ waiter: UUID, key: String, requestID: UUID) {
        guard var request = requests[key], request.id == requestID else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty {
            requests[key] = nil
            request.task.cancel()
        } else {
            requests[key] = request
        }
    }

    private func download(url: URL, pixels: Int) -> Task<DecodedImage?, Never> {
        let session = session
        let permits = permits
        return Task.detached(priority: .utility) { () -> DecodedImage? in
            guard await permits.acquire() else { return nil }
            if Task.isCancelled { await permits.release(); return nil }
            let data: Data?
            if url.isFileURL { data = try? Data(contentsOf: url, options: .mappedIfSafe) }
            else {
                do {
                    let (download, response) = try await session.data(from: url)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) { data = download }
                    else { data = nil }
                } catch { data = nil }
            }
            await permits.release()
            guard !Task.isCancelled, let data, data.count <= 32 * 1024 * 1024 else { return nil }
            return autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels
                      ] as CFDictionary) else { return nil }
                return DecodedImage(image: cgImage)
            }
        }
    }

    func removeAll() {
        generation += 1
        cache.removeAllObjects()
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
    }
}

/// Emby may serve artwork from a separate image route or CDN. Unlike API
/// calls, these reads can follow redirects without forwarding Emby credentials.
final class ArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = response.url else { completionHandler(nil); return }
        completionHandler(Self.redirect(request, from: source, originalURL: task.originalRequest?.url))
    }

    static func redirect(_ request: URLRequest, from source: URL, originalURL: URL?) -> URLRequest? {
        guard let target = request.url,
              var parts = URLComponents(url: target, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil,
              !(source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http") else { return nil }
        var redirected = request
        if !sameOrigin(target, originalURL ?? source) {
            for header in ["Authorization", "Proxy-Authorization", "X-Emby-Authorization", "X-Emby-Token", "Cookie"] {
                redirected.setValue(nil, forHTTPHeaderField: header)
            }
            // Preserve CDN signatures provided by Location, but never pass
            // the Emby session token embedded in our original image URL.
            let originalToken = URLComponents(url: originalURL ?? source, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name.lowercased() == "api_key" }?.value
            parts.queryItems = parts.queryItems?.filter {
                !["api_key", "x-emby-token", "x-emby-authorization"].contains($0.name.lowercased()) &&
                (originalToken == nil || $0.value != originalToken)
            }
            if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
            redirected.url = parts.url
        }
        return redirected
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
        lhs.host?.lowercased() == rhs.host?.lowercased() &&
        (lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80))
    }
}

/// CGImage is immutable; this box permits transfer on macOS 13 without relying
/// on AppKit's NSImage Sendable conformance introduced in macOS 14.
private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
    var size: NSSize { NSSize(width: image.width, height: image.height) }
}

private actor ImagePermits {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var available: Int
    private var waiters: [Waiter] = []
    init(limit: Int) { available = limit }
    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if available > 0 { available -= 1; continuation.resume(returning: true) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().continuation.resume(returning: true) }
    }
}
