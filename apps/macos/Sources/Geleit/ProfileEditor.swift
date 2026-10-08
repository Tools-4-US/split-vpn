import SwiftUI

/// Edição de uma conexão: campos abertos, sem nada fixo de um órgão específico.
struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VPNProfile
    @State private var routesText: String
    @State private var domainsText: String
    @State private var password = ""
    @State private var portText: String
    @State private var samlPortText: String
    @State private var errors: [String] = []
    let isNew: Bool
    let onSave: (VPNProfile) -> Void

    init(profile: VPNProfile, isNew: Bool, onSave: @escaping (VPNProfile) -> Void) {
        _draft = State(initialValue: profile)
        _routesText = State(initialValue: profile.routes.joined(separator: "\n"))
        _domainsText = State(initialValue: profile.dnsDomains.joined(separator: "\n"))
        _portText = State(initialValue: String(profile.port))
        _samlPortText = State(initialValue: String(profile.samlPort))
        _password = State(initialValue: profile.savePassword ? (Keychain.password(for: profile.id) ?? "") : "")
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "Nova conexão" : "Editar conexão").font(.title3.weight(.semibold))
                    Text("SSL-VPN compatível com FortiGate").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)

            Form {
                Section("Conexão") {
                    TextField("Nome", text: $draft.name, prompt: Text("Ex.: Trabalho"))
                    TextField("Descrição", text: $draft.notes, prompt: Text("Opcional"))
                    TextField("Gateway remoto", text: $draft.gateway, prompt: Text("vpn.exemplo.com.br"))
                    TextField("Porta", text: $portText, prompt: Text("443"))
                }

                Section("Autenticação") {
                    Picker("Método", selection: $draft.authMode) {
                        ForEach(AuthMode.allCases) { Text($0.label).tag($0) }
                    }
                    if draft.authMode == .sso {
                        TextField("Porta local de retorno do SSO", text: $samlPortText, prompt: Text("8020"))
                        Text("Após o login, o navegador volta para http://127.0.0.1:\(samlPortText). O gateway precisa redirecionar para essa porta (padrão 8020).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Usuário", text: $draft.username)
                        Toggle("Salvar senha no Keychain", isOn: $draft.savePassword)
                        if draft.savePassword {
                            SecureField("Senha", text: $password)
                        }
                    }
                    TextField("Realm", text: $draft.realm, prompt: Text("Opcional"))
                }

                Section {
                    Picker("Enviar pelo túnel", selection: $draft.routingMode) {
                        ForEach(RoutingMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if draft.routingMode == .split {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Redes (CIDR), uma por linha — # comenta").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $routesText)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 84)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                } header: {
                    Text("Roteamento")
                } footer: {
                    Text(draft.routingMode == .split
                         ? "Somente essas redes passam pela VPN; o restante segue pela internet normal."
                         : "Usa as rotas enviadas pelo gateway (em geral, todo o tráfego).")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Domínios, um por linha").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $domainsText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 52)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                } header: {
                    Text("DNS da VPN")
                } footer: {
                    Text("Nomes nesses domínios (e subdomínios) são resolvidos pelos servidores DNS informados pelo gateway. Os demais continuam no DNS da sua rede.")
                }

                Section("Segurança") {
                    TextField("SHA-256 do certificado do gateway", text: $draft.trustedCert, prompt: Text("Opcional — só para certificado não confiável"))
                        .font(.system(size: 12, design: .monospaced))
                }

                Section {
                    Toggle("Reconectar automaticamente se cair", isOn: $draft.autoReconnect)
                } header: {
                    Text("Comportamento")
                } footer: {
                    Text("Tentativas em intervalos crescentes (5s, 10s, 20s, 40s…) por até 10 minutos. Com SSO, reaproveita a sessão enquanto o gateway aceitar; se ela expirar, você recebe uma notificação para entrar de novo.")
                }

                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { e in
                            Label(e, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.failed)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 600, height: 720)
    }

    private func save() {
        var p = draft
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.gateway = p.gateway.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        p.username = p.username.trimmingCharacters(in: .whitespaces)
        p.realm = p.realm.trimmingCharacters(in: .whitespaces)
        p.trustedCert = p.trustedCert.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
        p.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? -1
        p.samlPort = Int(samlPortText.trimmingCharacters(in: .whitespaces)) ?? -1
        p.routes = Validators.lines(routesText)
        p.dnsDomains = Validators.lines(domainsText).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }

        errors = p.validationErrors()
        if p.authMode == .password && p.savePassword && password.isEmpty {
            errors.append("Informe a senha ou desmarque \"Salvar senha\".")
        }
        guard errors.isEmpty else { return }

        if p.authMode == .password && p.savePassword {
            Keychain.setPassword(password, for: p.id)
        } else {
            Keychain.deletePassword(for: p.id)
        }
        onSave(p)
        dismiss()
    }
}
