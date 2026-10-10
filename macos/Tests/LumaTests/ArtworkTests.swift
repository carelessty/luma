import AppKit
import Testing
@testable import Luma

private final class ArtworkMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var firstStatus = 200
    private static var imageData = Data()
    private static var slowPaths: Set<String> = []
    private let stateLock = NSLock()
    private var stopped = false

    static func install(data: Data, firstStatus: Int = 200, slowPaths: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        count = 0
        imageData = data
        self.firstStatus = firstStatus
        self.slowPaths = slowPaths
    }
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let status = Self.count == 1 ? Self.firstStatus : 200
        let data = Self.imageData
        let delay = Self.slowPaths.contains(request.url!.path) ? 1.0 : 0.05
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            stateLock.lock()
            let shouldDeliver = !stopped
            stateLock.unlock()
            guard shouldDeliver else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status == 200 { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        stateLock.lock(); defer { stateLock.unlock() }
        stopped = true
    }
}

@Suite(.serialized)
struct ArtworkTests {
    @Test
    func sameOriginArtworkRedirectUsesServerImageRoute() throws {
        let original = try #require(URL(string: "https://media.example/emby/Items/movie1/Images/Primary?api_key=fixture-token&maxWidth=600"))
        let target = try #require(URL(string: "https://media.example/img/i/poster/movie1.jpg"))
        let result = ArtworkRedirectDelegate.redirect(URLRequest(url: target), from: original, originalURL: original)
        #expect(result?.url == target)
        #expect(result?.url?.query == nil)
    }

    @Test
    func cdnRedirectKeepsImageSignatureWithoutEmbyCredentials() throws {
        let original = try #require(URL(string: "https://media.example/emby/Items/movie1/Images/Primary?api_key=fixture-token"))
        let target = try #require(URL(string: "https://cdn.example/poster.jpg?signature=cdn-signature&api_key=fixture-token&copied=fixture-token&width=600"))
        var request = URLRequest(url: target)
        for field in ["Authorization", "X-Emby-Authorization", "X-Emby-Token", "Cookie"] {
            request.setValue("fixture-token", forHTTPHeaderField: field)
        }
        let result = try #require(ArtworkRedirectDelegate.redirect(request, from: original, originalURL: original))
        let query = URLComponents(url: try #require(result.url), resolvingAgainstBaseURL: true)?.queryItems
        #expect(query == [URLQueryItem(name: "signature", value: "cdn-signature"), URLQueryItem(name: "width", value: "600")])
        #expect(result.allHTTPHeaderFields?.values.contains("fixture-token") != true)
    }

    @Test
    func artworkRedirectRejectsTransportDowngradeAndEmbeddedCredentials() throws {
        let original = try #require(URL(string: "https://media.example/poster"))
        for target in ["http://media.example/poster.jpg", "file:///tmp/poster.jpg", "https://viewer:password@cdn.example/poster.jpg"] {
            let request = URLRequest(url: try #require(URL(string: target)))
            #expect(ArtworkRedirectDelegate.redirect(request, from: original, originalURL: original) == nil)
        }
    }

    private func pipeline(firstStatus: Int = 200, slowPaths: Set<String> = []) throws -> ImagePipeline {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        ArtworkMockProtocol.install(data: data, firstStatus: firstStatus, slowPaths: slowPaths)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkMockProtocol.self]
        return ImagePipeline(urlSession: URLSession(configuration: config))
    }

    private func waitForDownload() async throws {
        for _ in 0..<500 {
            if ArtworkMockProtocol.requestCount > 0 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Artwork request did not start")
    }

    @Test
    func cancelledCellDoesNotPoisonFailedImageRetry() async throws {
        let pipeline = try pipeline(firstStatus: 503)
        let url = try #require(URL(string: "https://media.example/poster.jpg"))
        let cell = Task { await pipeline.image(for: url, maxPixelSize: 100) != nil }
        try await waitForDownload()
        cell.cancel()
        #expect(await cell.value == false)
        let retried = await pipeline.image(for: url, maxPixelSize: 100)
        #expect(retried != nil)
        #expect(ArtworkMockProtocol.requestCount == 2)
        #expect(retried?.size == NSSize(width: 100, height: 50))
    }

    @Test
    func cancelledCellDoesNotBreakReplacementOrImageCache() async throws {
        let pipeline = try pipeline()
        let url = try #require(URL(string: "https://media.example/poster.jpg"))
        let firstCell = Task { await pipeline.image(for: url, maxPixelSize: 100) != nil }
        try await waitForDownload()
        let secondCell = Task { await pipeline.image(for: url, maxPixelSize: 100) != nil }
        firstCell.cancel()
        #expect(await firstCell.value == false)
        #expect(await secondCell.value == true)
        // Starting a Task does not guarantee that it has subscribed to the
        // actor yet. Cancelling the sole existing subscriber may legitimately
        // cancel the first request before the replacement joins.
        let completedRequests = ArtworkMockProtocol.requestCount
        #expect((1...2).contains(completedRequests))
        #expect(await pipeline.image(for: url, maxPixelSize: 100) != nil)
        #expect(ArtworkMockProtocol.requestCount == completedRequests)
        await pipeline.removeAll()
        #expect(await pipeline.image(for: url, maxPixelSize: 100) != nil)
        #expect(ArtworkMockProtocol.requestCount == completedRequests + 1)
    }

    @Test
    func concurrentCellsShareOneArtworkDownload() async throws {
        let pipeline = try pipeline()
        let url = try #require(URL(string: "https://media.example/poster.jpg"))
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask { await pipeline.image(for: url, maxPixelSize: 100) != nil }
            }
            for await available in group { #expect(available) }
        }
        #expect(ArtworkMockProtocol.requestCount == 1)
    }

    @Test
    func scrollingPastArtworkReleasesDownloadSlotsForVisibleCells() async throws {
        let pipeline = try pipeline(slowPaths: Set((0..<6).map { "/old-\($0).jpg" }))
        let oldCells = (0..<6).map { index in
            Task { await pipeline.image(for: URL(string: "https://media.example/old-\(index).jpg")!) != nil }
        }
        for _ in 0..<500 {
            if ArtworkMockProtocol.requestCount == 6 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(ArtworkMockProtocol.requestCount == 6)
        let queuedCells = (0..<8).map { index in
            Task { await pipeline.image(for: URL(string: "https://media.example/queued-\(index).jpg")!) != nil }
        }
        for cell in queuedCells { cell.cancel() }
        for cell in queuedCells { #expect(await cell.value == false) }
        for cell in oldCells { cell.cancel() }
        let visibleCell = Task { await pipeline.image(for: URL(string: "https://media.example/visible.jpg")!) != nil }
        for _ in 0..<300 {
            if ArtworkMockProtocol.requestCount == 7 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(ArtworkMockProtocol.requestCount == 7, "Visible artwork must start before obsolete downloads finish")
        #expect(await visibleCell.value)
        for cell in oldCells { #expect(await cell.value == false) }
        #expect(ArtworkMockProtocol.requestCount == 7, "Cancelled queued artwork must not reach the server")
    }
}
