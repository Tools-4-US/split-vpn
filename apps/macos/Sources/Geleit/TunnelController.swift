import AppKit
import Foundation

@MainActor
final class TunnelController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case authenticating
        case connecting
        case connected
        case reconnecting(attempt: Int, nextAt: Date)
        case disconnecting
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .authenticating, .connecting, .connected, .reconnecting, .disconnecting: return true
            case .idle, .failed: return false
            }
        }
    }

    /// Janela máxima de tentativas após uma queda (pedido: "em até 10 minutos").
    static let reconnectWindow: TimeInterval = 600
    static let reconnectBaseDelay: TimeInterval = 5
    static let tunnelUpTimeout: TimeInterval = 45

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var connectedAt: Date?
    @Published private(set) var localIP: String?
    @Published private(set) var interface: String?
    @Published private(set) var dnsServers: [String] = []
    @Published private(set) var appliedRoutes: [String] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var helperInstalled: Bool?

    let traffic = TrafficMonitor()
    let notifier = Notifier()
    var profileLookup: (UUID) -> VPNProfile? = { _ in nil }

    private var activeProfile: VPNProfile?
    private var process: Process?
    private var saml: SAMLAuth?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var upTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var secret: String?
    private var gatewayIP: String?
    private var tunnelUp = false
    private var authRejected = false
    private var userStopping = false
    private var dropStartedAt: Date?
    private var attempt = 0
    /// openfortivpn conseguiu fazer logout no gateway ao encerrar: o cookie SSO morreu junto.
    private var loggedOut = false
    /// Modo de demonstração (só debug): nada pode chegar ao helper.
    private var demoMode = false

    init() {
        notifier.onAction = { [weak self] id in
            guard let self, let p = self.profileLookup(id) else { return }
            self.connect(p)
        }
    }

    // MARK: - API pública

    func refreshHelperStatus() {
        #if DEBUG
        if DebugSnapshot.demo != nil { helperInstalled = true; return }
        #endif
        Task { helperInstalled = await Helper.isInstalled() }
    }

    func isActive(_ profile: VPNProfile) -> Bool {
        activeProfileID == profile.id && phase.isBusy
    }

    func connect(_ profile: VPNProfile) {
        if let current = activeProfileID, current != profile.id, phase.isBusy {
            disconnect()
        }
        reconnectTask?.cancel()
        connectTask?.cancel()
        activeProfile = profile
        activeProfileID = profile.id
        secret = nil
        dropStartedAt = nil
        attempt = 0
        log = []
        connectTask = Task { await establish(profile, fresh: true) }
    }

    func disconnect() {
        guard !demoMode else { return }
        reconnectTask?.cancel()
        connectTask?.cancel()
        saml?.cancel()
        upTimeoutTask?.cancel()
        dropStartedAt = nil
        secret = nil
        if process != nil {
            userStopping = true
            phase = .disconnecting
            append("Desconectando…")
            Task { await Helper.run(["down"]) }
        } else {
            let profile = activeProfile
            let gw = gatewayIP
            phase = .idle
            Task { await cleanupNetwork(profile: profile, gatewayIP: gw) }
        }
    }

    /// Chamado no encerramento do app: precisa ser síncrono.
    func shutdownSync() {
        guard !demoMode else { return }
        reconnectTask?.cancel()
        connectTask?.cancel()
        saml?.cancel()
        guard process != nil || activeProfile != nil else { return }
        userStopping = true
        Helper.runSync(["down"])
        if let p = activeProfile {
            for d in p.dnsDomains { Helper.runSync(["dns-clear", d]) }
            if p.routingMode == .split, let gw = gatewayIP { Helper.runSync(["route-del-host", gw]) }
        }
    }

    #if DEBUG
    func loadDemo(profile: VPNProfile, mode: String) {
        demoMode = true
        helperInstalled = true
        activeProfile = profile
        activeProfileID = profile.id
        switch mode {
        case "failed": phase = .failed("A sessão SSO expirou ou foi recusada. Entre novamente.")
        case "reconnecting": phase = .reconnecting(attempt: 3, nextAt: Date().addingTimeInterval(17))
        case "idle": phase = .idle
        default:
            phase = .connected
            connectedAt = Date().addingTimeInterval(-4_871)
            localIP = "10.100.8.2"; interface = "ppp0"; dnsServers = ["10.20.3.97", "10.20.3.100"]
            appliedRoutes = profile.routes
            traffic.loadDemo()
            log = ["01:12:31  Login SSO concluído.", "01:12:35  Using interface ppp0",
                   "01:12:38  INFO:   Tunnel is up and running.", "01:12:39  Conectado."]
        }
    }
    #endif

    // MARK: - Conexão

    private func establish(_ profile: VPNProfile, fresh: Bool) async {
        guard !demoMode else { return }
        if helperInstalled != true {
            helperInstalled = await Helper.isInstalled()
            guard helperInstalled == true else {
                phase = .failed("Componente de sistema não instalado. Veja as instruções no console.")
                return
            }
        }

        let reconnecting = dropStartedAt != nil

        // Durante a reconexão, só tenta (e só abre o navegador) se o gateway responder.
        if reconnecting {
            guard await RawHTTPS.canReach(host: profile.gateway, port: profile.port) else {
                append("Gateway inacessível; nova tentativa mais tarde.")
                scheduleReconnect(profile)
                return
            }
        }

        // Credencial
        if secret == nil {
            switch profile.authMode {
            case .sso:
                if !reconnecting { phase = .authenticating }
                append(reconnecting ? "Sessão SSO encerrada pelo gateway; reautenticando no navegador…"
                                    : "Abrindo o login SSO no navegador…")
                let auth = SAMLAuth()
                auth.diagnostic = { [weak self] line in Task { @MainActor in self?.append(line) } }
                saml = auth
                do {
                    // Com a sessão do provedor de identidade ainda válida, o login conclui sozinho
                    // em poucos segundos; na reconexão não vale esperar os 5 minutos do primeiro login.
                    secret = try await auth.authenticate(profile: profile, timeout: reconnecting ? 90 : 300)
                    append("Login SSO concluído.")
                } catch {
                    saml = nil
                    if Task.isCancelled || (error as? SAMLError).map({ if case .cancelled = $0 { return true }; return false }) == true {
                        if activeProfileID == profile.id, !phase.isConnectedLike { phase = .idle }
                    } else if reconnecting {
                        append(error.localizedDescription)
                        scheduleReconnect(profile)
                    } else {
                        fail(error.localizedDescription, profile: profile, offerRetry: true)
                    }
                    return
                }
                saml = nil
            case .password:
                let stored = profile.savePassword ? Keychain.password(for: profile.id) : nil
                guard let pw = stored ?? PasswordPrompt.ask(profile: profile) else {
                    phase = .idle
                    return
                }
                secret = pw
            }
        }
        guard !Task.isCancelled, let secret else { return }

        if dropStartedAt == nil { phase = .connecting }
        append("Conectando a \(profile.endpoint)…")

        // Rota de host para o gateway pela internet normal: o gateway costuma ficar
        // dentro das redes enviadas ao túnel, e sem isso o próprio túnel entraria em loop.
        gatewayIP = await NetUtil.resolveIPv4(profile.gateway)
        if profile.routingMode == .split, let gw = gatewayIP, let def = await NetUtil.defaultGateway() {
            let r = await Helper.run(["route-host", gw, def])
            if !r.ok { append("Aviso: rota do gateway não aplicada: \(r.output)") }
        }

        var args = ["--host", profile.gateway, "--port", String(profile.port),
                    "--auth", profile.authMode == .sso ? "cookie" : "password",
                    "--set-routes", profile.routingMode == .full ? "1" : "0"]
        if profile.authMode == .password { args += ["--user", profile.username] }
        if !profile.realm.isEmpty { args += ["--realm", profile.realm] }
        if !profile.trustedCert.isEmpty { args += ["--trusted-cert", profile.trustedCert.lowercased()] }

        generation += 1
        let gen = generation
        tunnelUp = false
        authRejected = false
        loggedOut = false
        userStopping = false
        localIP = nil; interface = nil; dnsServers = []; appliedRoutes = []

        do {
            process = try Helper.startTunnel(
                args: args, secret: secret,
                onLine: { [weak self] line in Task { @MainActor in self?.handleLine(line, gen: gen) } },
                onExit: { [weak self] code in Task { @MainActor in self?.handleExit(code, gen: gen) } })
        } catch {
            fail("Não foi possível iniciar o túnel: \(error.localizedDescription)", profile: profile, offerRetry: true)
            return
        }

        upTimeoutTask?.cancel()
        upTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.tunnelUpTimeout))
            guard let self, !Task.isCancelled, gen == self.generation, !self.tunnelUp, self.process != nil else { return }
            self.append("O túnel não subiu em \(Int(Self.tunnelUpTimeout))s; abortando a tentativa.")
            await Helper.run(["down"])
        }
    }

    private func handleLine(_ raw: String, gen: Int) {
        guard gen == generation else { return }
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        append(line)
        let lower = line.lowercased()

        if line.contains("Got addresses:") {
            if let ip = line.firstMatch(of: #/Got addresses: \[([0-9.]+)\]/#)?.1 { localIP = String(ip) }
            if let ns = line.firstMatch(of: #/ns \[([^\]]*)\]/#)?.1 {
                dnsServers = ns.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { Validators.isIPv4($0) && $0 != "0.0.0.0" }
            }
        }
        if let m = line.firstMatch(of: #/Interface (\S+) is UP/#) { interface = String(m.1) }
        if lower.contains("could not authenticate") || lower.contains("invalid cookie")
            || lower.contains("permission denied") || lower.contains("login failed")
            || (lower.contains("cookie") && lower.contains("expired"))
            || lower.contains("vpn configuration") {
            authRejected = true
        }
        if lower.hasSuffix("logged out.") { loggedOut = true }
        if line.contains("Tunnel is up and running") {
            Task { await onTunnelUp(gen: gen) }
        }
    }

    private func onTunnelUp(gen: Int) async {
        guard gen == generation, let profile = activeProfile else { return }
        tunnelUp = true
        upTimeoutTask?.cancel()
        let iface = interface ?? NetUtil.firstPPPInterface()
        interface = iface

        if profile.routingMode == .split, let iface {
            for cidr in profile.routes {
                let r = await Helper.run(["route-add", cidr, iface])
                if r.ok { appliedRoutes.append(cidr) } else { append("Falha na rota \(cidr): \(r.output)") }
            }
        }
        if !profile.dnsDomains.isEmpty {
            if dnsServers.isEmpty {
                append("Aviso: o servidor não informou DNS; domínios internos podem não resolver.")
            } else {
                for d in profile.dnsDomains {
                    let r = await Helper.run(["dns-set", d] + dnsServers)
                    if !r.ok { append("Falha no DNS de \(d): \(r.output)") }
                }
            }
        }
        guard gen == generation else { return }
        let wasReconnecting = dropStartedAt != nil
        dropStartedAt = nil
        attempt = 0
        connectedAt = Date()
        phase = .connected
        if let iface { traffic.start(interface: iface) }
        append("Conectado.")
        notifier.post(title: wasReconnecting ? "Reconectado" : "Conectado",
                      body: "\(profile.displayName) · IP \(localIP ?? "—")")
    }

    private func handleExit(_ code: Int32, gen: Int) {
        guard gen == generation else { return }
        process = nil
        upTimeoutTask?.cancel()
        traffic.stop()
        let profile = activeProfile
        let gw = gatewayIP
        Task { await cleanupNetwork(profile: profile, gatewayIP: gw) }
        append("Túnel encerrado (código \(code)).")
        connectedAt = nil

        guard let profile else { phase = .idle; return }

        if userStopping {
            userStopping = false
            phase = .idle
            return
        }

        if tunnelUp {
            // Caiu depois de conectado. Se o openfortivpn conseguiu fazer logout, o cookie
            // SSO foi invalidado no gateway; a próxima tentativa precisa de novo login.
            if loggedOut && profile.authMode == .sso { secret = nil }
            if profile.autoReconnect {
                notifier.post(title: "Conexão caiu", body: "\(profile.displayName): tentando reconectar…")
                scheduleReconnect(profile)
            } else {
                fail("A conexão caiu.", profile: profile, offerRetry: true)
            }
            return
        }

        // Não chegou a subir.
        if authRejected && profile.authMode == .sso && dropStartedAt != nil {
            secret = nil
            append("Sessão recusada pelo gateway; a próxima tentativa fará novo login SSO.")
            scheduleReconnect(profile)
            return
        }
        if authRejected {
            secret = nil
            dropStartedAt = nil
            let msg = profile.authMode == .sso
                ? "A sessão SSO expirou ou foi recusada. Entre novamente."
                : "Usuário ou senha recusados pelo gateway."
            fail(msg, profile: profile, offerRetry: true)
            return
        }
        if dropStartedAt != nil {
            scheduleReconnect(profile)
            return
        }
        fail("Não foi possível conectar (código \(code)). Detalhes no log.", profile: profile, offerRetry: true)
    }

    // MARK: - Reconexão exponencial (5s, 10s, 20s, … até 10 min desde a queda)

    private func scheduleReconnect(_ profile: VPNProfile) {
        if dropStartedAt == nil {
            dropStartedAt = Date()
            attempt = 0
        }
        attempt += 1
        let delay = Self.reconnectBaseDelay * pow(2, Double(attempt - 1))
        let elapsed = Date().timeIntervalSince(dropStartedAt!)
        guard elapsed + delay <= Self.reconnectWindow else {
            dropStartedAt = nil
            secret = profile.authMode == .sso ? nil : secret
            fail("Não foi possível reconectar em 10 minutos.", profile: profile, offerRetry: true)
            return
        }
        let nextAt = Date().addingTimeInterval(delay)
        phase = .reconnecting(attempt: attempt, nextAt: nextAt)
        append("Tentativa \(attempt) de reconexão em \(Int(delay))s.")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.establish(profile, fresh: false)
        }
    }

    // MARK: - Utilidades

    private func fail(_ message: String, profile: VPNProfile, offerRetry: Bool) {
        phase = .failed(message)
        append(message)
        notifier.post(title: "\(profile.displayName): falha na VPN", body: message,
                      actionProfileID: offerRetry ? profile.id : nil)
    }

    private func cleanupNetwork(profile: VPNProfile?, gatewayIP: String?) async {
        guard !demoMode, let profile else { return }
        for d in profile.dnsDomains { await Helper.run(["dns-clear", d]) }
        if profile.routingMode == .split, let gatewayIP { await Helper.run(["route-del-host", gatewayIP]) }
    }

    private func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }
}

extension TunnelController.Phase {
    var isConnectedLike: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum NetUtil {
    static func resolveIPv4(_ host: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(res) }
                var addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                cont.resume(returning: String(cString: buf))
            }
        }
    }

    /// Gateway da rota padrão atual (ex.: o roteador do Wi-Fi).
    static func defaultGateway() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/sbin/route")
                p.arguments = ["-n", "get", "default"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                let gw = out.split(separator: "\n")
                    .first { $0.contains("gateway:") }?
                    .split(separator: ":").last?
                    .trimmingCharacters(in: .whitespaces)
                cont.resume(returning: gw.flatMap { Validators.isIPv4($0) ? $0 : nil })
            }
        }
    }

    static func firstPPPInterface() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("ppp") { return name }
            p = cur.pointee.ifa_next
        }
        return nil
    }
}

/// Pede a senha quando o perfil não a guarda no Keychain.
enum PasswordPrompt {
    @MainActor
    static func ask(profile: VPNProfile) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Senha para \(profile.displayName)"
        alert.informativeText = "Usuário: \(profile.username)"
        alert.addButton(withTitle: "Conectar")
        alert.addButton(withTitle: "Cancelar")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }
}
