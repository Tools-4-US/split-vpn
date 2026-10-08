#if DEBUG
import AppKit
import SwiftUI

/// Só no build de debug: GELEIT_DEMO=connected|idle|failed preenche dados fictícios e
/// GELEIT_SNAPSHOT=<arquivo.png> salva a janela do console (sem precisar de Gravação de Tela).
enum DebugSnapshot {
    static var demo: String? { ProcessInfo.processInfo.environment["GELEIT_DEMO"] }

    static let demoProfiles: [VPNProfile] = {
        var a = VPNProfile()
        a.name = "Trabalho"; a.gateway = "vpn.exemplo.com.br"; a.port = 10443
        a.routes = ["10.0.0.0/8", "172.16.0.0/12", "203.0.113.0/24"]; a.dnsDomains = ["exemplo.com.br"]
        var b = VPNProfile()
        b.name = "Laboratório"; b.gateway = "lab.exemplo.org"; b.authMode = .password; b.username = "maria"
        b.routingMode = .full
        return [a, b]
    }()

    @MainActor
    static func apply(store: ProfileStore, tunnel: TunnelController) {
        guard let demo else { return }
        store.replaceForDemo(demoProfiles)
        tunnel.loadDemo(profile: demoProfiles[0], mode: demo)
        if let path = ProcessInfo.processInfo.environment["GELEIT_RENDER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                render(profile: demoProfiles[0], tunnel: tunnel, to: path)
            }
            return
        }
        if let path = ProcessInfo.processInfo.environment["GELEIT_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // Janela encoberta não é desenhada pelo macOS; traz para a frente antes de capturar.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.filter { $0.frame.width > 400 }.forEach { $0.orderFrontRegardless() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { snapshot(to: path) }
        }
    }

    /// Renderiza o painel fora da tela (ImageRenderer): não depende de janela visível
    /// nem de tela desbloqueada — serve para gerar as imagens do README, inclusive no CI.
    @MainActor
    static func render(profile: VPNProfile, tunnel: TunnelController, to path: String) {
        let live = tunnel.phase == .connected
        let content = VStack(spacing: 18) {
            HeroCard(profile: profile, phase: tunnel.phase, onEdit: {})
            if live {
                StatsRow(traffic: tunnel.traffic)
                TrafficChartCard(traffic: tunnel.traffic)
            }
            DetailsCard(profile: profile, live: live)
        }
        .padding(28)
        .frame(width: 1000)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(tunnel)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let cg = renderer.cgImage {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    @MainActor
    static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }
}

extension ProfileStore {
    func replaceForDemo(_ list: [VPNProfile]) { setProfilesInMemory(list) }
}

extension TrafficMonitor {
    func loadDemo() {
        let now = Date()
        let s = (0..<Self.window).map { i -> TrafficSample in
            let t = Double(i)
            let rx = max(0, 180_000 + 140_000 * sin(t / 9) + Double((i * 7919) % 90_000) + (i > 80 && i < 95 ? 900_000 : 0))
            let tx = max(0, 40_000 + 25_000 * cos(t / 7) + Double((i * 104729) % 20_000))
            return TrafficSample(time: now.addingTimeInterval(t - Double(Self.window)), rxPerSec: rx, txPerSec: tx)
        }
        setDemo(samples: s, rxTotal: 1_874_329_600, txTotal: 241_172_480)
    }
}
#endif
