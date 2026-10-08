import Charts
import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var tunnel: TunnelController
    @State private var selection: UUID?
    @State private var editing: VPNProfile?
    @State private var confirmDelete: VPNProfile?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            if let profile = store.profile(id: selection) {
                ProfileDetailView(profile: profile, onEdit: { editing = profile })
                    .id(profile.id)
            } else {
                EmptyStateView { editing = VPNProfile() }
            }
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, isNew: store.profile(id: profile.id) == nil) { saved in
                store.upsert(saved)
                selection = saved.id
            }
        }
        .confirmationDialog("Excluir \(confirmDelete?.displayName ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                if let p = confirmDelete {
                    if tunnel.isActive(p) { tunnel.disconnect() }
                    store.delete(p.id)
                    if selection == p.id { selection = store.profiles.first?.id }
                }
                confirmDelete = nil
            }
        } message: {
            Text("A configuração e a senha salva serão removidas.")
        }
        .onAppear {
            if selection == nil { selection = tunnel.activeProfileID ?? store.profiles.first?.id }
            tunnel.refreshHelperStatus()
        }
        .onChange(of: store.profiles.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = tunnel.activeProfileID ?? ids.first }
        }
        .onChange(of: tunnel.activeProfileID) { _, id in
            if let id { selection = id }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Conexões") {
                ForEach(store.profiles) { profile in
                    ProfileRow(profile: profile)
                        .tag(profile.id)
                        .contextMenu {
                            Button("Editar…") { editing = profile }
                            Button("Duplicar") {
                                var copy = profile
                                copy.id = UUID()
                                copy.name += " (cópia)"
                                store.upsert(copy)
                            }
                            Divider()
                            Button("Excluir…", role: .destructive) { confirmDelete = profile }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button { editing = VPNProfile() } label: { Image(systemName: "plus") }
                    .help("Nova conexão")
                Button {
                    if let p = store.profile(id: selection) { confirmDelete = p }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Excluir conexão")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct ProfileRow: View {
    @EnvironmentObject private var tunnel: TunnelController
    let profile: VPNProfile

    var body: some View {
        let active = tunnel.activeProfileID == profile.id
        HStack(spacing: 10) {
            StatusDot(color: active ? tunnel.phase.color : Theme.idle.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.system(size: 13, weight: .medium))
                Text(active && tunnel.phase != .idle ? tunnel.phase.title : profile.endpoint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyStateView: View {
    let onCreate: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Nenhuma conexão configurada").font(.title2.weight(.semibold))
            Text("Adicione um gateway SSL-VPN (FortiGate) para começar.")
                .foregroundStyle(.secondary)
            Button("Nova conexão", action: onCreate)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detalhe

struct ProfileDetailView: View {
    @EnvironmentObject private var tunnel: TunnelController
    let profile: VPNProfile
    let onEdit: () -> Void

    private var isMine: Bool { tunnel.activeProfileID == profile.id }
    private var phase: TunnelController.Phase { isMine ? tunnel.phase : .idle }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if tunnel.helperInstalled == false { HelperBanner() }
                HeroCard(profile: profile, phase: phase, onEdit: onEdit)
                if isMine && phase == .connected {
                    StatsRow(traffic: tunnel.traffic)
                    TrafficChartCard(traffic: tunnel.traffic)
                }
                DetailsCard(profile: profile, live: isMine && phase == .connected)
                if isMine && !tunnel.log.isEmpty { LogCard() }
            }
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(profile.displayName)
        .toolbar {
            ToolbarItem {
                Button(action: onEdit) { Label("Editar", systemImage: "slider.horizontal.3") }
                    .help("Editar configuração")
            }
        }
    }
}

private struct HeroCard: View {
    @EnvironmentObject private var tunnel: TunnelController
    let profile: VPNProfile
    let phase: TunnelController.Phase
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            StatusEmblem(phase: phase)
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.displayName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                Text(profile.notes.isEmpty ? profile.endpoint : "\(profile.endpoint) · \(profile.notes)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    StatusDot(color: phase.color, size: 7)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(subtitle) }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
            }
            Spacer(minLength: 12)
            actionButton
        }
        .padding(26)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var subtitle: String {
        switch phase {
        case .failed(let msg): return msg
        case .reconnecting(let n, let at):
            let s = max(0, Int(at.timeIntervalSinceNow.rounded()))
            return "Reconectando — tentativa \(n), próxima em \(s)s"
        case .connected:
            let since = tunnel.connectedAt.map { Format.duration(Date().timeIntervalSince($0)) } ?? ""
            return "Conectado há \(since)"
        default: return phase.title
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch phase {
        case .idle, .failed:
            Button { tunnel.connect(profile) } label: {
                Label("Conectar", systemImage: "power").frame(minWidth: 120)
            }
            .buttonStyle(HeroButtonStyle(kind: .primary))
        case .connected:
            Button { tunnel.disconnect() } label: {
                Label("Desconectar", systemImage: "power").frame(minWidth: 120)
            }
            .buttonStyle(HeroButtonStyle(kind: .danger))
        case .disconnecting:
            ProgressView().controlSize(.small).tint(.white)
        default:
            Button { tunnel.disconnect() } label: { Text("Cancelar").frame(minWidth: 120) }
                .buttonStyle(HeroButtonStyle(kind: .secondary))
        }
    }
}

private struct HeroButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(kind == .primary ? Theme.navyTop : .white)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(kind == .secondary ? 0.35 : 0)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }

    private var background: Color {
        switch kind {
        case .primary: return .white
        case .danger: return Theme.failed.opacity(0.9)
        case .secondary: return .white.opacity(0.06)
        }
    }
}

private struct StatusEmblem: View {
    let phase: TunnelController.Phase
    @State private var pulse = false

    private var busy: Bool {
        switch phase {
        case .authenticating, .connecting, .reconnecting, .disconnecting: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.06)).frame(width: 92, height: 92)
            Circle()
                .stroke(phase.color.opacity(busy ? (pulse ? 0.15 : 0.7) : 0.85), lineWidth: 3)
                .frame(width: 92, height: 92)
                .scaleEffect(busy && pulse ? 1.08 : 1)
            Image(systemName: phase.symbol)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.white, phase.color)
                .symbolRenderingMode(.palette)
        }
        .onAppear { pulse = true }
        .animation(busy ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
        .animation(.default, value: phase)
    }
}

private struct StatsRow: View {
    @EnvironmentObject private var tunnel: TunnelController
    @ObservedObject var traffic: TrafficMonitor

    var body: some View {
        HStack(spacing: 14) {
            StatTile(title: "Recebido", value: Format.bytes(traffic.rxTotal), symbol: "arrow.down", tint: Theme.rx)
            StatTile(title: "Enviado", value: Format.bytes(traffic.txTotal), symbol: "arrow.up", tint: Theme.tx)
            StatTile(title: "Download", value: Format.rate(traffic.rxRate), symbol: "speedometer", tint: Theme.rx)
            StatTile(title: "Upload", value: Format.rate(traffic.txRate), symbol: "speedometer", tint: Theme.tx)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                StatTile(title: "Tempo", value: tunnel.connectedAt.map { Format.duration(Date().timeIntervalSince($0)) } ?? "—",
                         symbol: "clock", tint: Theme.idle)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct TrafficChartCard: View {
    @ObservedObject var traffic: TrafficMonitor

    var body: some View {
        Card("Tráfego no túnel — últimos 2 minutos", systemImage: "waveform.path.ecg") {
            Chart {
                ForEach(traffic.samples) { s in
                    AreaMark(x: .value("Hora", s.time), y: .value("Bytes/s", s.rxPerSec), series: .value("Sentido", "Download"))
                        .foregroundStyle(LinearGradient(colors: [Theme.rx.opacity(0.35), Theme.rx.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Hora", s.time), y: .value("Bytes/s", s.rxPerSec), series: .value("Sentido", "Download"))
                        .foregroundStyle(Theme.rx)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Hora", s.time), y: .value("Bytes/s", s.txPerSec), series: .value("Sentido", "Upload"))
                        .foregroundStyle(Theme.tx)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Format.rate(v)).font(.system(size: 10)) }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 190)

            HStack(spacing: 18) {
                LegendItem(color: Theme.rx, label: "Download", value: Format.rate(traffic.rxRate))
                LegendItem(color: Theme.tx, label: "Upload", value: Format.rate(traffic.txRate))
            }
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 3)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

private struct DetailsCard: View {
    @EnvironmentObject private var tunnel: TunnelController
    let profile: VPNProfile
    let live: Bool

    var body: some View {
        Card(live ? "Sessão" : "Configuração", systemImage: live ? "network" : "doc.text") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                row("Gateway", profile.endpoint)
                if live {
                    row("IP na VPN", tunnel.localIP ?? "—")
                    row("Interface", tunnel.interface ?? "—")
                    row("Servidores DNS", tunnel.dnsServers.isEmpty ? "Não informado" : tunnel.dnsServers.joined(separator: ", "))
                }
                row("Autenticação", profile.authMode == .sso ? "SSO (SAML)" : "Usuário e senha · \(profile.username)")
                row("Roteamento", profile.routingMode == .split
                    ? (live ? tunnel.appliedRoutes : profile.routes).joined(separator: "   ")
                    : "Todo o tráfego pelo túnel")
                row("DNS da VPN para", profile.dnsDomains.isEmpty ? "Nenhum domínio" : profile.dnsDomains.joined(separator: ", "))
                row("Realm", profile.realm.isEmpty ? "Não informado" : profile.realm)
                row("Certificado fixado", profile.trustedCert.isEmpty ? "Não (validação padrão do sistema)" : String(profile.trustedCert.prefix(16)) + "…")
                row("Reconexão automática", profile.autoReconnect ? "Ligada (até 10 min, intervalos crescentes)" : "Desligada")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).monospacedDigit()
        }
        .font(.system(size: 13))
    }
}

private struct LogCard: View {
    @EnvironmentObject private var tunnel: TunnelController
    @State private var expanded = false

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(tunnel.log.enumerated()), id: \.offset) { i, line in
                                Text(line).id(i)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    .onChange(of: tunnel.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                HStack {
                    Spacer()
                    Button("Copiar log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tunnel.log.joined(separator: "\n"), forType: .string)
                    }
                    .controlSize(.small)
                }
            } label: {
                Label("Log da conexão", systemImage: "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
    }
}

private struct HelperBanner: View {
    @EnvironmentObject private var tunnel: TunnelController
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 22))
                .foregroundStyle(Theme.busy)
            VStack(alignment: .leading, spacing: 6) {
                Text("Instale o componente de sistema").font(.headline)
                Text("Rotas, DNS e o túnel exigem privilégios de administrador. Rode uma vez no Terminal:")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(Helper.installCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Helper.installCommand, forType: .string)
                    }
                    Button("Verificar de novo") { tunnel.refreshHelperStatus() }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.busy.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.busy.opacity(0.35)))
    }
}
