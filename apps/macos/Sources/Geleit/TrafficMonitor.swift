import Darwin
import Foundation

struct TrafficSample: Identifiable {
    let id = UUID()
    let time: Date
    let rxPerSec: Double
    let txPerSec: Double
}

/// Contadores de bytes da interface do túnel (ppp0, utun…), lidos 1x/s via sysctl NET_RT_IFLIST2
/// (contadores de 64 bits — o if_data de getifaddrs é de 32 bits e dá a volta em 4 GB).
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var rxTotal: UInt64 = 0
    @Published private(set) var txTotal: UInt64 = 0
    @Published private(set) var rxRate: Double = 0
    @Published private(set) var txRate: Double = 0
    @Published private(set) var samples: [TrafficSample] = []

    static let window = 120

    private var iface: String?
    private var baseline: (rx: UInt64, tx: UInt64)?
    private var last: (rx: UInt64, tx: UInt64, at: Date)?
    private var timer: Timer?

    func start(interface: String) {
        stop()
        iface = interface
        rxTotal = 0; txTotal = 0; rxRate = 0; txRate = 0
        samples = (0..<Self.window).map { i in
            TrafficSample(time: Date().addingTimeInterval(Double(i - Self.window)), rxPerSec: 0, txPerSec: 0)
        }
        if let c = Self.counters(for: interface) {
            baseline = c
            last = (c.rx, c.tx, Date())
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        iface = nil
        baseline = nil
        last = nil
        rxRate = 0; txRate = 0
    }

    private func tick() {
        guard let iface, let c = Self.counters(for: iface) else { return }
        let now = Date()
        if baseline == nil { baseline = c }
        if let last {
            let dt = max(now.timeIntervalSince(last.at), 0.001)
            rxRate = Double(c.rx &- last.rx) / dt
            txRate = Double(c.tx &- last.tx) / dt
        }
        last = (c.rx, c.tx, now)
        if let b = baseline {
            rxTotal = c.rx &- b.rx
            txTotal = c.tx &- b.tx
        }
        samples.append(TrafficSample(time: now, rxPerSec: rxRate, txPerSec: txRate))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    #if DEBUG
    func setDemo(samples: [TrafficSample], rxTotal: UInt64, txTotal: UInt64) {
        self.samples = samples
        self.rxTotal = rxTotal
        self.txTotal = txTotal
        rxRate = samples.last?.rxPerSec ?? 0
        txRate = samples.last?.txPerSec ?? 0
    }
    #endif

    nonisolated static func counters(for name: String) -> (rx: UInt64, tx: UInt64)? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }

        return buf.withUnsafeBytes { raw -> (UInt64, UInt64)? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2, UInt32(hdr.ifm_index) == index {
                    let m2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    return (m2.ifm_data.ifi_ibytes, m2.ifm_data.ifi_obytes)
                }
                guard hdr.ifm_msglen > 0 else { break }
                offset += Int(hdr.ifm_msglen)
            }
            return nil
        }
    }
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ v: UInt64) -> String {
        v == 0 ? "0 B" : byteFormatter.string(fromByteCount: Int64(clamping: v))
    }

    static func rate(_ v: Double) -> String {
        bytes(UInt64(max(v, 0))) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
