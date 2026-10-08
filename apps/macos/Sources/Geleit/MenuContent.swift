import SwiftUI

/// Menu da barra superior — mesmo modelo do FortiClient: um clique na configuração salva inicia o login.
struct MenuContent: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("VPN") {
            if store.profiles.isEmpty {
                Button("Adicionar configuração…") { showConsole(openWindow) }
            }
            ForEach(store.profiles) { profile in
                if tunnel.isActive(profile) {
                    Button {
                        tunnel.disconnect()
                    } label: {
                        Label("Desconectar de \(profile.displayName)", systemImage: "laptopcomputer.slash")
                    }
                    Text(statusLine)
                } else {
                    Button {
                        tunnel.connect(profile)
                    } label: {
                        Label("Conectar a \(profile.displayName)", systemImage: "lock.laptopcomputer")
                    }
                }
            }
        }
        Divider()
        Button("Abrir console do Geleit") { showConsole(openWindow) }
        Button("Encerrar Geleit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch tunnel.phase {
        case .connected:
            let since = tunnel.connectedAt.map { Format.duration(Date().timeIntervalSince($0)) } ?? "—"
            return "Conectado · \(since) · ↓ \(Format.bytes(tunnel.traffic.rxTotal))  ↑ \(Format.bytes(tunnel.traffic.txTotal))"
        default:
            return tunnel.phase.title
        }
    }
}
