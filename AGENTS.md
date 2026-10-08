# Geleit — guia para agentes e mantenedores

Contexto necessário para trabalhar neste repositório sem o histórico das conversas que o criaram.
Leia antes de mudar código. Se uma decisão daqui mudar, atualize este arquivo no mesmo commit.

## O que é

Cliente de VPN **split tunnel** para gateways **Fortinet SSL-VPN (FortiGate)**, construído sobre o
[openfortivpn](https://github.com/adrienverge/openfortivpn). Nasceu para substituir o FortiClient, que manda
todo o tráfego pela VPN: no Geleit só passam pelo túnel as redes e os domínios que o usuário listar.

- Nome: *Geleit* (alemão, "salvo-conduto": a escolta que garantia a passagem segura numa estrada).
- Repositório: <https://github.com/Tools-4-US/split-vpn> (público, MIT). O projeto se chamava "Split VPN" antes.
- Monorepo: um cliente por plataforma em `apps/`. Hoje só existe `apps/macos`; Windows e Linux estão planejados.

## Regras que não podem ser quebradas

1. **Genérico.** Nada fixo de uma organização específica (gateway, faixas de IP, domínios, nomes) em código,
   docs, exemplos, capturas ou commits. Tudo é configurável pelo usuário. Exemplos usam
   `vpn.exemplo.com.br`, `exemplo.com.br` e faixas de documentação (`203.0.113.0/24`).
2. **O helper é a fronteira de segurança.** `apps/macos/helper/geleit-helper` roda como root via sudoers
   `NOPASSWD` e pode ser chamado por qualquer processo do usuário. Todo argumento novo precisa de validação
   por regex. Nunca repasse opções livres ao openfortivpn (`pppd-plugin` e afins dariam root arbitrário).
   Segredos (cookie SSO, senha) só via stdin, nunca na linha de comando. Arquivos em `/etc/resolver` só são
   sobrescritos ou removidos se tiverem o marcador do Geleit (ou o legado `# gerenciado por splitvpn`).
3. **Modo de demonstração nunca toca no sistema.** `GELEIT_DEMO` (só em build debug) não pode chegar ao helper.
   Já aconteceu: encerrar uma execução de demonstração chamou `shutdownSync()` → `geleit-helper down` e
   derrubou o túnel real do usuário. Os guards `demoMode` em `TunnelController` existem por isso.
4. **Exclusão é decisão do usuário.** Não remova dados do usuário (perfis, Keychain, `~/Library/Application
   Support/...`) sem pedido explícito.
5. **Não publique o que não leu.** `brand/concepts/` é exploração local da marca e fica fora do git
   (`.gitignore`); só os artefatos finais vão para `brand/`.

## Arquitetura (macOS)

| Arquivo | Responsabilidade |
|---|---|
| `App.swift` | `@main`: janela do console (primeira cena, abre ao iniciar) + `MenuBarExtra`; `LSUIElement` (sem Dock) |
| `MenuContent.swift` | Menu da barra: "Conectar a <nome>" por perfil (um clique inicia o login), status, abrir console, encerrar |
| `ConsoleView.swift` | Console: lista de perfis, painel (`HeroCard`), estatísticas, gráfico, detalhes, log, aviso de helper ausente |
| `ProfileEditor.swift` | Editor de perfil com campos abertos (estilo FortiClient) |
| `Models.swift` | `VPNProfile`, validação, `ProfileStore` (JSON em `~/Library/Application Support/Geleit/profiles.json`) |
| `Keychain.swift` | Senhas (serviço `io.github.tools4us.geleit`; migra do legado `dev.zeniel.splitvpn`) |
| `TunnelController.swift` | Ciclo de vida da conexão, rotas/DNS via helper, reconexão exponencial, parsing do log do openfortivpn |
| `SAMLAuth.swift` + `RawHTTPS.swift` | SSO no navegador e troca do id de sessão pelo cookie `SVPNCOOKIE`; sonda TCP do gateway |
| `Helper.swift` | Chama `sudo -n /usr/local/libexec/geleit-helper …`; inicia o túnel com segredo no stdin |
| `TrafficMonitor.swift` | Contadores de 64 bits da interface do túnel via `sysctl(NET_RT_IFLIST2)`, 1×/s, janela de 120 s |
| `Notifier.swift` | Notificações; falhas trazem ação "Conectar" |
| `PennantMark.swift` | Emblema interno: estandarte vetorial; a faixa segue a cor do estado e a bandeira tremula ao conectar |
| `Theme.swift` | Cores (marinho `#0E1933`→`#172A51`, cobalto `#3B82F6`), ícone da barra por estado, componentes base |
| `DebugSnapshot.swift` | Só debug: dados fictícios e geração de imagens (ver "Testes") |

Fluxo de conexão: SSO (ou senha) → rota de host do gateway pela internet normal (o gateway costuma cair dentro
das redes roteadas para o túnel) → `geleit-helper up` (openfortivpn com `set-routes=0`, `set-dns=0`) → ao ver
`Tunnel is up and running`, aplica as rotas do perfil e `/etc/resolver/<domínio>` com o DNS informado pelo
gateway → monitor de tráfego. Ao desconectar ou encerrar, desfaz rotas e DNS.

## Lições aprendidas com um gateway real (não regredir)

Detalhes em [`spec/fortigate-ssl-vpn.md`](spec/fortigate-ssl-vpn.md). Em resumo:

- **Cookie SSO**: a requisição a `/remote/saml/auth_id?id=…` precisa imitar o openfortivpn byte a byte
  (HTTP/1.1 via ALPN, `User-Agent: Mozilla/5.0 SV1`). Com `URLSession` (HTTP/2, outro user agent) o cookie
  era recusado depois, em `Could not get VPN configuration`.
- O gateway manda um `Set-Cookie: SVPNCOOKIE=` **vazio** junto com o real: ler cada cabeçalho separado e
  pegar o primeiro não vazio. Nunca juntar cabeçalhos.
- Em respostas 200 o gateway **não fecha a conexão**: parar de ler no fim dos cabeçalhos (`\r\n\r\n`).
- O openfortivpn não valida o cookie em "Authenticated"; cookie inválido só aparece como
  `Could not get VPN configuration`.
- **O openfortivpn sempre faz logout ao encerrar** (`Logged out.`), o que invalida o cookie. Ele só sobrevive
  quando o logout falha (`Could not log out.`, queda real de rede). Por isso a reconexão SSO refaz o login
  no navegador quando houve logout ou o cookie é recusado; com a sessão do provedor de identidade ativa,
  isso conclui sozinho em segundos.
- `stdout`/`stderr` do openfortivpn e do pppd se embaralham (`INFO: erface ppp0 is UP.`, `ERROR:ld not get…`):
  o parsing precisa tolerar linhas cortadas e ter plano B (descobrir a interface `ppp*` via `getifaddrs`).

## Comportamento definido com o usuário

- **Reconexão**: opção por perfil (ligada por padrão). Espera 5 s, 10 s, 20 s… dobrando, e desiste quando a
  próxima tentativa passaria de **10 minutos** desde a queda; então notifica com ação "Conectar". Antes de cada
  tentativa, sonda TCP do gateway: inacessível → pula sem abrir navegador. Timeout do SSO na reconexão: 90 s
  (primeiro login: 300 s).
- **Não abre com o login do macOS.** O usuário abre pelo Spotlight/Launchpad quando precisa.
- **Menu da barra** igual ao do FortiClient: clicar na configuração salva inicia o login.
- **Visual**: moderno, sério e robusto. Painel em degradê marinho, cartões discretos, números em fonte
  arredondada monoespaçada, estado sempre por cor **e** símbolo (acessibilidade).
- **Ícones**: o ícone do app e os da barra de menus seguem a ideia do **corredor protegido**
  (`apps/macos/Resources`, `brand/menubar`); o emblema **dentro** do app é o **estandarte**
  (`brand/pennant-concept.png`, desenhado em vetor em `PennantMark.swift`).
- **Idiomas**: interface e comentários de código em português do Brasil; README, SECURITY e `spec/` em inglês
  (repositório público); mensagens de commit em inglês.

## Build, testes e release

```bash
cd apps/macos
./build.sh                      # build/Geleit.app — universal (arm64 + x86_64), assinatura ad hoc
./build.sh --zip                # + build/Geleit-macOS.zip e .sha256
./build.sh --install            # + copia para /Applications
VERSION=0.2.0 ./build.sh --zip  # versão exibida no app (padrão 0.0.0-dev)
```

- O build compila uma arquitetura por vez e junta com `lipo`: `swift build --arch arm64 --arch x86_64` falha
  com "duplicate output file" no Xcode dos runners do GitHub.
- Requer `brew install openfortivpn` para rodar; versão testada em `apps/macos/OPENFORTIVPN_VERSION`.
- **Testes**: não há suíte automatizada ainda. O que dá para verificar sem o usuário:
  - `shellcheck -S warning -e SC2024` nos scripts (o CI roda);
  - validação do helper com entradas maliciosas, executando-o **sem root** (falha antes de agir). Use `bash`
    para dividir os argumentos; no zsh uma variável não é dividida e o teste dá falso resultado;
  - imagens do console: `GELEIT_DEMO=connected|reconnecting|failed|idle GELEIT_RENDER=/tmp/x.png .build/debug/Geleit`
    renderiza fora da tela (funciona com a tela bloqueada). `GELEIT_SNAPSHOT` captura a janela real, mas sai
    em branco com a tela bloqueada e não desenha a barra lateral translúcida.
  - **Conexão real exige o usuário** (login SSO e `sudo` para instalar o helper). Nunca afirme que conexão,
    reconexão ou migração funcionam sem esse teste; diga o que foi e o que não foi verificado.
- **Release**: `git tag vX.Y.Z && git push origin vX.Y.Z` → `release-macos.yml` publica o zip e o checksum.
  Link estável: `https://github.com/Tools-4-US/split-vpn/releases/latest/download/Geleit-macOS.zip`.
  O app não é notarizado: quem baixa precisa de "Abrir Mesmo Assim" ou `xattr -dr com.apple.quarantine`.
- **Dependências**: Dependabot (Swift em `/apps/macos` e GitHub Actions). O openfortivpn vem do Homebrew; o
  workflow `openfortivpn-upstream.yml` abre issue quando sai versão nova (compara tags com
  `OPENFORTIVPN_VERSION`). Ao criar um cliente novo, adicione o ecossistema dele no `dependabot.yml`.

## Instalação local do helper

```bash
sudo "/Applications/Geleit.app/Contents/Resources/install-helper.sh"            # instala
sudo "/Applications/Geleit.app/Contents/Resources/install-helper.sh" --uninstall
```

Instala `/usr/local/libexec/geleit-helper` (root:wheel 0755) e `/etc/sudoers.d/geleit` só para esse arquivo;
remove a instalação legada `splitvpn`. O app mostra esse comando num aviso enquanto o helper não existir.

## Pendências conhecidas

- Reconexão SSO revisada (sonda + novo login após logout) ainda **não testada numa queda real**.
- Migração Split VPN → Geleit (perfis e Keychain) implementada, mas não confirmada com dados reais.
- Sem notarização (requer conta Apple Developer; dá para adicionar ao `release-macos.yml`).
- Sem testes automatizados de Swift (bons candidatos: `Validators`, `RawHTTPS.parse`,
  `SAMLAuth.sessionID(fromRequest:)`, cálculo do backoff).
- Clientes Windows e Linux: reaproveitar `spec/profile.schema.json` e `spec/fortigate-ssl-vpn.md`.
- Repositório ainda se chama `split-vpn`; renomear para `geleit` é opcional (o GitHub redireciona).
