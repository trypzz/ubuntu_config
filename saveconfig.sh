#!/bin/bash
set -e

GDRIVE_MOUNT="$HOME/GoogleDrive"
SECRETS_DIR="$GDRIVE_MOUNT/secrets"
SSH_DIR="$HOME/.ssh"
WG_CONF="/etc/wireguard/devadmin.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── gpg: встановити якщо нема ─────────────────────────────────────────────────

if ! command -v gpg &>/dev/null; then
    echo "==> Встановлення gpg..."
    sudo apt-get install -y gnupg
fi

# ── Перевірки ─────────────────────────────────────────────────────────────────

if ! mountpoint -q "$GDRIVE_MOUNT" 2>/dev/null; then
    echo "ERROR: Google Drive не змонтований ($GDRIVE_MOUNT)."
    exit 1
fi

# ── zshrc → репозиторій ───────────────────────────────────────────────────────

cp "$HOME/.zshrc" "$SCRIPT_DIR/zshrc"
echo "==> Збережено .zshrc → ./zshrc"

# ── VS Code settings + extensions → репозиторій ─────────────────────────────

VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
if [ -f "$VSCODE_SETTINGS" ]; then
    mkdir -p "$SCRIPT_DIR/vscode"
    cp "$VSCODE_SETTINGS" "$SCRIPT_DIR/vscode/settings.json"
    echo "==> Збережено VS Code settings → ./vscode/settings.json"
else
    echo "УВАГА: $VSCODE_SETTINGS не знайдено, пропускаємо."
fi

if command -v code &>/dev/null; then
    mkdir -p "$SCRIPT_DIR/vscode"
    code --list-extensions > "$SCRIPT_DIR/vscode/extensions.txt"
    echo "==> Збережено список екстеншенів → ./vscode/extensions.txt"
else
    echo "УВАГА: code не знайдено, список екстеншенів не збережено."
fi

# ── wezterm.lua → репозиторій ─────────────────────────────────────────────────

if [ -f "$HOME/.config/wezterm/wezterm.lua" ]; then
    cp "$HOME/.config/wezterm/wezterm.lua" "$SCRIPT_DIR/wezterm.lua"
    echo "==> Збережено wezterm.lua → ./wezterm.lua"
else
    echo "УВАГА: ~/.config/wezterm/wezterm.lua не знайдено, пропускаємо."
fi

# ── Збираємо секрети в тимчасову директорію ───────────────────────────────────

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/ssh" "$TMPDIR/wireguard"

# SSH приватні ключі
KEYS=()
for f in "$SSH_DIR"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        *.pub|config|known_hosts|known_hosts.old|authorized_keys) continue ;;
    esac
    cp "$f" "$TMPDIR/ssh/"
    KEYS+=("$(basename "$f")")
done

if [ ${#KEYS[@]} -eq 0 ]; then
    echo "УВАГА: Приватних ключів у $SSH_DIR не знайдено."
else
    echo "==> SSH ключі: ${KEYS[*]}"
fi

# WireGuard конфіг
if sudo test -f "$WG_CONF"; then
    sudo cp "$WG_CONF" "$TMPDIR/wireguard/devadmin.conf"
    sudo chown "$USER:$USER" "$TMPDIR/wireguard/devadmin.conf"
    echo "==> WireGuard: devadmin.conf"
else
    echo "УВАГА: $WG_CONF не знайдено, пропускаємо."
fi

# ── Шифрування → ~/GoogleDrive/secrets/ ──────────────────────────────────────

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -f "$SECRETS_DIR/secrets.tar.gz.gpg" ]; then
    echo ""
    echo "УВАГА: $SECRETS_DIR/secrets.tar.gz.gpg буде перезаписаний."
    read -rp "Продовжити? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }
fi

# ── Пароль з підтвердженням ───────────────────────────────────────────────────

while true; do
    read -s -rp "Введи ключ-фразу: " PASSPHRASE; echo
    read -s -rp "Підтвердь ключ-фразу: " PASSPHRASE2; echo
    if [ "$PASSPHRASE" = "$PASSPHRASE2" ]; then
        break
    fi
    echo "Ключ-фрази не збігаються, спробуй ще раз."
done

# ── Шифрування ────────────────────────────────────────────────────────────────

echo "==> Шифрування..."
tar czf - -C "$TMPDIR" . \
    | gpg --symmetric --cipher-algo AES256 --batch --yes --passphrase "$PASSPHRASE" \
          --output "$SECRETS_DIR/secrets.tar.gz.gpg"

echo "==> Збережено → $SECRETS_DIR/secrets.tar.gz.gpg"

# ── Git commit & push ─────────────────────────────────────────────────────────

SAVE_DATE=$(date +%s)
cd "$SCRIPT_DIR"
git add .
git commit -m "save config $SAVE_DATE"
git push origin main

echo ""
echo "==> Готово."
