import Foundation
import Security

/// An Emby access token is sufficient to resume a connection; the password is
/// never retained. This value is stored only in the macOS login Keychain.
struct StoredSession: Codable, Sendable {
    let serverURL: String
    let userID: String
    let userName: String
    let serverName: String
    let deviceID: String
    let token: String

    init(session: Session, token: String) {
        serverURL = session.serverURL
        userID = session.userID
        userName = session.userName
        serverName = session.serverName
        deviceID = session.deviceID
        self.token = token
    }

    var session: Session {
        Session(serverURL: serverURL, userID: userID, userName: userName, serverName: serverName, deviceID: deviceID)
    }
}

/// Synchronous operations make a credential replacement and the actor's
/// in-memory commit indivisible with respect to cancellation and account changes.
protocol SessionStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ value: StoredSession) throws
    func clear() throws
}

struct KeychainSessionStore: SessionStore {
    private let service = "io.luma.emby.native.session.v1"
    private let account = "current-connection"

    private var query: [String: Any] {
        // The login Keychain supports a locally signed macOS app without access
        // group entitlements. Keep the default creating-app ACL intact.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> StoredSession? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status, operation: L10n.service("keychain.read")) }
        guard let data = result as? Data,
              let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            throw ServiceError(code: "SESSION_STORAGE", message: L10n.service("keychain.unreadable"))
        }
        return session
    }

    func save(_ value: StoredSession) throws {
        let data = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrLabel as String: L10n.service("keychain.label")]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            changes.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
            // Another instance may have saved between update and add.
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, changes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw failure(status, operation: L10n.service("keychain.save")) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, operation: L10n.service("keychain.delete")) }
    }

    private func failure(_ status: OSStatus, operation: String) -> ServiceError {
        let reason: String
        switch status {
        case errSecUserCanceled: reason = L10n.service("keychain.cancelled")
        case errSecAuthFailed, errSecInteractionNotAllowed: reason = L10n.service("keychain.locked")
        case errSecNotAvailable: reason = L10n.service("keychain.unavailable")
        default: reason = L10n.service("keychain.error", status)
        }
        return ServiceError(code: "SESSION_STORAGE", message: L10n.service("keychain.operationFailed", operation, reason))
    }
}
