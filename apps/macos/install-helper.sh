#!/bin/bash
# Instala o componente com privilégios do Geleit. Rodar UMA vez:
#   sudo "/Applications/Geleit.app/Contents/Resources/install-helper.sh"
#   (ou, a partir do repositório: sudo apps/macos/install-helper.sh)
# Remover:
#   sudo "/Applications/Geleit.app/Contents/Resources/install-helper.sh" --uninstall
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }

TARGET=/usr/local/libexec/geleit-helper
SUDOERS=/etc/sudoers.d/geleit
USER_NAME="${SUDO_USER:?rode via sudo a partir do seu usuario}"

# Instalação anterior, de quando o projeto se chamava Split VPN.
rm -f /etc/sudoers.d/splitvpn /usr/local/libexec/splitvpn-helper

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$SUDOERS" "$TARGET"
  echo "Removido."
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/geleit-helper"
[[ -f "$SRC" ]] || SRC="$HERE/helper/geleit-helper"
[[ -f "$SRC" ]] || { echo "geleit-helper nao encontrado ao lado deste script."; exit 1; }
mkdir -p /usr/local/libexec
install -o root -g wheel -m 0755 "$SRC" "$TARGET"

tmp=$(mktemp)
echo "$USER_NAME ALL=(root) NOPASSWD: $TARGET" > "$tmp"
visudo -cf "$tmp" >/dev/null
install -o root -g wheel -m 0440 "$tmp" "$SUDOERS"
rm -f "$tmp"

sudo -u "$USER_NAME" sudo -n "$TARGET" ping >/dev/null && echo "OK: helper instalado e liberado para $USER_NAME."
