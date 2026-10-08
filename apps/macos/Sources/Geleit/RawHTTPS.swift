import CryptoKit
import Foundation
import Network

/// Cliente HTTPS mínimo (uma requisição, HTTP/1.1 forçado via ALPN) sobre Network.framework.
enum RawHTTPS {
    struct Response {
        var status: Int
        var headers: [(name: String, value: String)]
    }

    static func send(_ request: String, host: String, port: Int, pinnedSHA256: String,
                     timeout: TimeInterval = 20) async throws -> Data {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        sec_protocol_options_set_tls_server_name(sec, host)
        if !pinnedSHA256.isEmpty {
            sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
                    complete(false); return
                }
                let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
                complete(digest == pinnedSHA256)
            }, DispatchQueue.global())
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw SAMLError.network("porta inválida") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tls))
        let queue = DispatchQueue(label: "geleit.rawhttps")
        let box = ResultBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                box.set(cont)
                var received = Data()

                func receive() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let data { received.append(data) }
                        // Só os cabeçalhos interessam (o cookie vem no Set-Cookie). Não dá para esperar
                        // o fechamento: em respostas 200 o FortiGate mantém a conexão aberta.
                        let headersDone = received.range(of: Data("\r\n\r\n".utf8)) != nil
                        if headersDone || isComplete || received.count > 1_048_576 {
                            conn.cancel(); box.finish(.success(received))
                        } else if let error {
                            conn.cancel()
                            received.isEmpty ? box.finish(.failure(SAMLError.network(error.localizedDescription)))
                                             : box.finish(.success(received))
                        } else {
                            receive()
                        }
                    }
                }

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: Data(request.utf8), completion: .contentProcessed { err in
                            if let err { conn.cancel(); box.finish(.failure(SAMLError.network(err.localizedDescription))) }
                        })
                        receive()
                    case .failed(let err), .waiting(let err):
                        conn.cancel(); box.finish(.failure(SAMLError.network(err.localizedDescription)))
                    default: break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    conn.cancel(); box.finish(.failure(SAMLError.network("tempo esgotado")))
                }
            }
        } onCancel: {
            conn.cancel(); box.finish(.failure(SAMLError.cancelled))
        }
    }

    /// O gateway aceita conexão TCP? Evita abrir o navegador (ou gastar tentativa) sem rede.
    static func canReach(host: String, port: Int, timeout: TimeInterval = 5) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "geleit.reach")
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .waiting: if once.take() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.take() { conn.cancel(); cont.resume(returning: false) }
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    static func parse(_ data: Data) -> Response {
        let text = String(decoding: data, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n").first ?? text
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.isEmpty ? "" : lines.removeFirst()
        let status = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return Response(status: status, headers: headers)
    }

    /// Garante que a continuation é retomada uma única vez.
    private final class ResultBox: @unchecked Sendable {
        private var cont: CheckedContinuation<Data, Error>?
        private var pending: Result<Data, Error>?
        private let lock = NSLock()

        func set(_ c: CheckedContinuation<Data, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let pending { c.resume(with: pending); self.pending = nil } else { cont = c }
        }

        func finish(_ r: Result<Data, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let c = cont { cont = nil; c.resume(with: r) } else if pending == nil { pending = r }
        }
    }
}
