import AppKit
import SwiftUI

enum Theme {
    // Marinho profundo + azul cobalto: sóbrio, institucional, legível nos dois modos.
    static let navyTop = Color(red: 0.055, green: 0.098, blue: 0.200)      // #0E1933
    static let navyBottom = Color(red: 0.090, green: 0.165, blue: 0.318)   // #172A51
    static let accent = Color(red: 0.231, green: 0.510, blue: 0.965)       // #3B82F6
    static let rx = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let tx = Color(red: 0.078, green: 0.722, blue: 0.651)           // #14B8A6

    static let connected = Color(red: 0.133, green: 0.773, blue: 0.369)    // #22C55E
    static let busy = Color(red: 0.961, green: 0.620, blue: 0.043)         // #F59E0B
    static let failed = Color(red: 0.937, green: 0.267, blue: 0.267)       // #EF4444
    static let idle = Color(red: 0.580, green: 0.639, blue: 0.722)         // #94A3B8

    static let heroGradient = LinearGradient(colors: [navyTop, navyBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardRadius: CGFloat = 14
}

extension TunnelController.Phase {
    var color: Color {
        switch self {
        case .connected: return Theme.connected
        case .authenticating, .connecting, .reconnecting, .disconnecting: return Theme.busy
        case .failed: return Theme.failed
        case .idle: return Theme.idle
        }
    }

    var title: String {
        switch self {
        case .idle: return "Desconectado"
        case .authenticating: return "Aguardando login no navegador"
        case .connecting: return "Conectando"
        case .connected: return "Conectado"
        case .reconnecting(let n, _): return "Reconectando (tentativa \(n))"
        case .disconnecting: return "Desconectando"
        case .failed: return "Falha"
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "checkmark.shield.fill"
        case .authenticating, .connecting, .reconnecting, .disconnecting: return "shield.lefthalf.filled"
        case .failed: return "exclamationmark.shield.fill"
        case .idle: return "shield"
        }
    }
}

/// Ícone da barra de menus. Usa os PDFs/PNGs de Resources quando existirem:
///   MenuBarIcon            — desconectado
///   MenuBarIconConnecting  — conectando / reconectando
///   MenuBarIconConnected   — conectado
///   MenuBarIconError       — falha
/// Sem eles, cai nos SF Symbols equivalentes.
enum MenuBarIcon {
    static func image(for phase: TunnelController.Phase) -> NSImage {
        let name: String
        switch phase {
        case .connected: name = "MenuBarIconConnected"
        case .authenticating, .connecting, .reconnecting, .disconnecting: name = "MenuBarIconConnecting"
        case .failed: name = "MenuBarIconError"
        case .idle: name = "MenuBarIcon"
        }
        if let img = load(name) ?? (name == "MenuBarIcon" ? nil : load("MenuBarIcon")) {
            return img
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let img = NSImage(systemSymbolName: phase.symbol, accessibilityDescription: phase.title)?
            .withSymbolConfiguration(config) ?? NSImage()
        img.isTemplate = true
        return img
    }

    private static func load(_ name: String) -> NSImage? {
        for ext in ["pdf", "svg", "png"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext), let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}

struct Card<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .labelStyle(TitleAndIconOrTitle(showIcon: systemImage != nil))
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct TitleAndIconOrTitle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if showIcon { configuration.icon }
            configuration.title
        }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3))
    }
}
