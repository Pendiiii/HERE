import Foundation
import Security

struct SupabaseAuthSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var needsRefresh: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}

struct SecureSessionStore: Sendable {
    private let service = "de.cealum.here.supabase-auth"
    private let account = "anonymous-session"

    func load() throws -> SupabaseAuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureSessionError.keychain(status) }
        guard let data = result as? Data,
              let authSession = try? JSONDecoder().decode(SupabaseAuthSession.self, from: data) else {
            throw SecureSessionError.corruptSession
        }
        return authSession
    }

    func save(_ session: SupabaseAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = lookup
            attributes.forEach { insert[$0.key] = $0.value }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw SecureSessionError.keychain(insertStatus) }
        } else if status != errSecSuccess {
            throw SecureSessionError.keychain(status)
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SecureSessionError: LocalizedError {
    case keychain(OSStatus), corruptSession
    var errorDescription: String? { "Die sichere Sitzung konnte nicht gelesen oder gespeichert werden." }
}
