import Foundation
import Security

/// Senhas dos perfis "usuário e senha" ficam no Keychain do usuário, nunca no JSON.
enum Keychain {
    private static let service = "io.github.tools4us.geleit"
    /// Serviço usado quando o projeto se chamava "Split VPN".
    private static let legacyService = "dev.zeniel.splitvpn"

    private static func query(_ id: UUID, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func password(for id: UUID) -> String? {
        if let current = read(query(id)) { return current }
        guard let legacy = read(query(id, service: legacyService)) else { return nil }
        setPassword(legacy, for: id)
        SecItemDelete(query(id, service: legacyService) as CFDictionary)
        return legacy
    }

    private static func read(_ base: [String: Any]) -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for id: UUID) {
        deletePassword(for: id)
        var q = query(id)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
