import Foundation

enum AuthMode: String, Codable, CaseIterable, Identifiable {
    case sso
    case password
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sso: return "SSO (SAML) no navegador"
        case .password: return "Usuário e senha"
        }
    }
}

enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case split
    case full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .split: return "Somente as redes listadas"
        case .full: return "Todo o tráfego (rotas do servidor)"
        }
    }
}

struct VPNProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var notes = ""
    var gateway = ""
    var port = 443
    var authMode: AuthMode = .sso
    var username = ""
    var savePassword = false
    var realm = ""
    var trustedCert = ""
    var samlPort = 8020
    var routingMode: RoutingMode = .split
    var routes: [String] = []
    var dnsDomains: [String] = []
    var autoReconnect = true

    var displayName: String { name.isEmpty ? gateway : name }
    var endpoint: String { port == 443 ? gateway : "\(gateway):\(port)" }

    /// Lista de erros que impedem salvar o perfil.
    func validationErrors() -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Informe um nome.") }
        if !Validators.isHost(gateway) { errors.append("Gateway inválido.") }
        if !(1...65535).contains(port) { errors.append("Porta inválida.") }
        if authMode == .password && !Validators.isUser(username) { errors.append("Informe o usuário.") }
        if !realm.isEmpty && !Validators.isRealm(realm) { errors.append("Realm inválido.") }
        if !trustedCert.isEmpty && !Validators.isSHA256(trustedCert) { errors.append("Certificado: use o SHA-256 em hexadecimal (64 caracteres).") }
        if authMode == .sso && !(1024...65535).contains(samlPort) { errors.append("Porta local do SSO deve estar entre 1024 e 65535.") }
        if routingMode == .split {
            if routes.isEmpty { errors.append("Liste ao menos uma rede para o modo dividido.") }
            for r in routes where !Validators.isCIDR(r) { errors.append("Rede inválida: \(r)") }
        }
        for d in dnsDomains where !Validators.isHost(d) { errors.append("Domínio inválido: \(d)") }
        return errors
    }
}

enum Validators {
    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
    static func isHost(_ s: String) -> Bool { matches(s, #"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$"#) }
    static func isUser(_ s: String) -> Bool { matches(s, #"^[A-Za-z0-9._@+\-]{1,128}$"#) }
    static func isRealm(_ s: String) -> Bool { matches(s, #"^[A-Za-z0-9._-]{1,64}$"#) }
    static func isSHA256(_ s: String) -> Bool { matches(s, #"^[0-9a-fA-F]{64}$"#) }
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in Int(p).map { (0...255).contains($0) && String($0) == p } ?? false }
    }
    static func isCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        guard parts.count == 2, isIPv4(String(parts[0])), let len = Int(parts[1]) else { return false }
        return (0...32).contains(len)
    }

    /// Converte o texto livre do editor (uma entrada por linha, # comenta) em lista.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { line in
                let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                return noComment.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [VPNProfile] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Geleit", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json")
    }()

    init() {
        migrateFromSplitVPN()
        load()
    }

    /// O projeto se chamava "Split VPN"; traz as conexões salvas na primeira execução do Geleit.
    private func migrateFromSplitVPN() {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SplitVPN/profiles.json")
        guard !fm.fileExists(atPath: fileURL.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.copyItem(at: legacy, to: fileURL)
    }

    func profile(id: UUID?) -> VPNProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func upsert(_ profile: VPNProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        save()
    }

    #if DEBUG
    func setProfilesInMemory(_ list: [VPNProfile]) { profiles = list }
    #endif

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        profiles = (try? JSONDecoder().decode([VPNProfile].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        #if DEBUG
        if DebugSnapshot.demo != nil { return }
        #endif
        guard let data = try? enc.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
