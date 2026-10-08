import AppKit
import CryptoKit
import Foundation
import Network

enum SAMLError: LocalizedError {
    case listen(String)
    case cancelled
    case timeout
    case noSessionID
    case noCookie(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .listen(let m): return "Não foi possível abrir a porta local do SSO: \(m)"
        case .cancelled: return "Login cancelado."
        case .timeout: return "Tempo de login esgotado."
        case .noSessionID: return "O gateway não devolveu o identificador de sessão."
        case .noCookie(let code): return "O gateway não entregou o cookie de sessão (HTTP \(code))."
        case .network(let m): return "Falha ao falar com o gateway: \(m)"
        }
    }
}

/// Fluxo SAML do FortiGate, o mesmo do `openfortivpn --saml-login`, mas dentro do app:
/// 1. escuta em 127.0.0.1:<samlPort>;
/// 2. abre `https://gw/remote/saml/start?redirect=1` no navegador;
/// 3. após o login, o gateway redireciona o navegador para `http://127.0.0.1:<porta>/?id=<sessão>`;
/// 4. troca o id pelo cookie SVPNCOOKIE em `/remote/saml/auth_id?id=<sessão>`.
/// Guardar o cookie permite reconectar sem novo login enquanto a sessão valer.
final class SAMLAuth: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private let queue = DispatchQueue(label: "geleit.saml")
    private var finished = false
    /// Linha de diagnóstico para o log da conexão (nunca inclui o valor do cookie).
    var diagnostic: ((String) -> Void)?

    func authenticate(profile: VPNProfile, timeout: TimeInterval = 300) async throws -> String {
        let sessionID = try await waitForSessionID(profile: profile, timeout: timeout)
        return try await fetchCookie(profile: profile, sessionID: sessionID)
    }

    func cancel() {
        queue.async { self.finish(.failure(SAMLError.cancelled)) }
    }

    // MARK: - Passos 1–3

    private func waitForSessionID(profile: VPNProfile, timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async {
                    self.finished = false
                    self.continuation = cont
                    do {
                        try self.startListener(port: profile.samlPort)
                    } catch {
                        self.finish(.failure(SAMLError.listen(error.localizedDescription)))
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(SAMLError.timeout)) }
                    var url = "https://\(profile.gateway):\(profile.port)/remote/saml/start?redirect=1"
                    if !profile.realm.isEmpty { url += "&realm=\(profile.realm)" }
                    DispatchQueue.main.async { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func startListener(port: Int) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { self?.finish(.failure(SAMLError.listen(err.localizedDescription))) }
        }
        l.start(queue: queue)
        listener = l
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let id = Self.sessionID(fromRequest: request)
            let body = id == nil
                ? Self.page(title: "Aguardando login", message: "Esta página é usada pelo Geleit para receber o login.")
                : Self.page(title: "Login concluído", message: "Pode fechar esta aba e voltar ao Geleit.")
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if let id { self.finish(.success(id)) }
        }
    }

    static func sessionID(fromRequest request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: "http://localhost" + parts[1]) else { return nil }
        guard let id = comps.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return id
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        let cont = continuation
        continuation = nil
        cont?.resume(with: result)
    }

    // MARK: - Passo 4

    /// Repete byte a byte a requisição do `openfortivpn --saml-login` (HTTP/1.1 puro,
    /// `User-Agent: Mozilla/5.0 SV1`, sem HTTP/2): o FortiGate pode recusar no túnel uma
    /// sessão criada por outro cliente HTTP.
    private func fetchCookie(profile: VPNProfile, sessionID: String) async throws -> String {
        let encodedID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionID
        let request = "GET /remote/saml/auth_id?id=\(encodedID) HTTP/1.1\r\n"
            + "Host: \(profile.gateway):\(profile.port)\r\n"
            + "User-Agent: Mozilla/5.0 SV1\r\n"
            + "Accept: */*\r\n"
            + "Accept-Encoding: identity\r\n"
            + "Pragma: no-cache\r\n"
            + "Cache-Control: no-store, no-cache, must-revalidate\r\n"
            + "If-Modified-Since: Sat, 1 Jan 2000 00:00:00 GMT\r\n"
            + "Content-Type: application/x-www-form-urlencoded\r\n"
            + "Cookie: \r\n"
            + "Content-Length: 0\r\n"
            + "Connection: close\r\n\r\n"

        let raw = try await RawHTTPS.send(request, host: profile.gateway, port: profile.port,
                                          pinnedSHA256: profile.trustedCert.lowercased())
        let parsed = RawHTTPS.parse(raw)
        let cookies = parsed.headers.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }.map(\.value)
        let svpn = cookies.compactMap { line -> String? in
            guard let r = line.range(of: "SVPNCOOKIE=") else { return nil }
            let value = line[r.upperBound...].prefix { $0 != ";" && $0 != "\r" && $0 != "\n" }
            return value.isEmpty ? nil : String(value)
        }
        let names = cookies.map { $0.prefix { $0 != "=" } }.joined(separator: ", ")
        diagnostic?("SSO: HTTP \(parsed.status), Set-Cookie [\(names)], SVPNCOOKIE \(svpn.first.map { "com \($0.count) caracteres" } ?? "ausente")")
        guard parsed.status == 200, let value = svpn.first else { throw SAMLError.noCookie(parsed.status) }
        return "SVPNCOOKIE=\(value)"
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="pt-br"><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font:16px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;
        background:#0f172a;color:#e2e8f0}div{text-align:center}h1{font-weight:600;font-size:22px}</style></head>
        <body><div><h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }
}

