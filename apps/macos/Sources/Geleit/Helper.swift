import Foundation

/// Ponte para o geleit-helper (root via sudoers NOPASSWD restrito ao helper).
enum Helper {
    static let path = "/usr/local/libexec/geleit-helper"
    static let sudo = "/usr/bin/sudo"

    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Executa um subcomando curto e espera terminar.
    @discardableResult
    static func run(_ args: [String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(args))
            }
        }
    }

    /// Versão síncrona — usada no encerramento do app, quando não dá para esperar o run loop.
    @discardableResult
    static func runSync(_ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sudo)
        p.arguments = ["-n", path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func isInstalled() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return await run(["ping"]).output.contains("ok")
    }

    /// Inicia o túnel (processo longo). O segredo vai pelo stdin, nunca pela linha de comando.
    static func startTunnel(args: [String], secret: String, onLine: @escaping (String) -> Void,
                            onExit: @escaping (Int32) -> Void) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sudo)
        p.arguments = ["-n", path, "up"] + args
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output

        let buffer = LineBuffer(onLine: onLine)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                buffer.flush()
            } else {
                buffer.append(data)
            }
        }
        p.terminationHandler = { proc in
            output.fileHandleForReading.readabilityHandler = nil
            buffer.flush()
            onExit(proc.terminationStatus)
        }
        try p.run()
        input.fileHandleForWriting.write(Data((secret + "\n").utf8))
        try? input.fileHandleForWriting.close()
        return p
    }

    /// O instalador viaja dentro do .app (Contents/Resources), então funciona sem o repositório.
    static var installCommand: String {
        let script = Bundle.main.url(forResource: "install-helper", withExtension: "sh")?.path
            ?? "/Applications/Geleit.app/Contents/Resources/install-helper.sh"
        return "sudo \"\(script)\""
    }
}

/// Junta pedaços de saída em linhas completas.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}
