#!/bin/bash
set -e

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
GDRIVE_MOUNT="$HOME_DIR/GoogleDrive"
SECRETS_DIR="$GDRIVE_MOUNT/secrets"
SSH_DIR="$HOME_DIR/.ssh"
WG_CONF="/etc/wireguard/devadmin.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── gpg: встановити якщо нема ─────────────────────────────────────────────────

if ! command -v gpg &>/dev/null; then
    echo "==> Встановлення gpg..."
    sudo apt-get install -y gnupg
fi

# ── Перевірки ─────────────────────────────────────────────────────────────────

if ! grep -qs "$GDRIVE_MOUNT" /proc/mounts; then
    echo "ERROR: Google Drive не змонтований ($GDRIVE_MOUNT)."
    exit 1
fi

# ── zshrc → репозиторій ───────────────────────────────────────────────────────

cp "$HOME_DIR/.zshrc" "$SCRIPT_DIR/zshrc"
echo "==> Збережено .zshrc → ./zshrc"

# ── MC config → репозиторій ──────────────────────────────────────────────────

if [ -f "$HOME_DIR/.config/mc/ini" ]; then
    cp "$HOME_DIR/.config/mc/ini" "$SCRIPT_DIR/mc.ini"
    echo "==> Збережено MC config → ./mc.ini"
else
    echo "УВАГА: ~/.config/mc/ini не знайдено, пропускаємо."
fi

# ── VS Code settings + extensions → репозиторій ─────────────────────────────

VSCODE_SETTINGS="$HOME_DIR/.config/Code/User/settings.json"
if [ -f "$VSCODE_SETTINGS" ]; then
    mkdir -p "$SCRIPT_DIR/vscode"
    cp "$VSCODE_SETTINGS" "$SCRIPT_DIR/vscode/settings.json"
    echo "==> Збережено VS Code settings → ./vscode/settings.json"
else
    echo "УВАГА: $VSCODE_SETTINGS не знайдено, пропускаємо."
fi

if command -v code &>/dev/null; then
    mkdir -p "$SCRIPT_DIR/vscode"
    sudo -u "$REAL_USER" code --list-extensions > "$SCRIPT_DIR/vscode/extensions.txt"
    echo "==> Збережено список екстеншенів → ./vscode/extensions.txt"
else
    echo "УВАГА: code не знайдено, список екстеншенів не збережено."
fi

# ── wezterm.lua → репозиторій ─────────────────────────────────────────────────

if [ -f "$HOME_DIR/.config/wezterm/wezterm.lua" ]; then
    cp "$HOME_DIR/.config/wezterm/wezterm.lua" "$SCRIPT_DIR/wezterm.lua"
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

sudo -u "$REAL_USER" mkdir -p "$SECRETS_DIR"
sudo -u "$REAL_USER" chmod 700 "$SECRETS_DIR"

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
    | sudo -u "$REAL_USER" gpg --symmetric --cipher-algo AES256 --batch --yes --passphrase "$PASSPHRASE" \
          --output "$SECRETS_DIR/secrets.tar.gz.gpg"

echo "==> Збережено → $SECRETS_DIR/secrets.tar.gz.gpg"

# ── Git commit & push ─────────────────────────────────────────────────────────

SAVE_DATE=$(date +%s)
cd "$SCRIPT_DIR"
chown -R "$REAL_USER:$REAL_USER" "$SCRIPT_DIR"
sudo -u "$REAL_USER" git add .
sudo -u "$REAL_USER" git commit -m "save config $SAVE_DATE"
sudo -u "$REAL_USER" git push origin main

echo ""
echo "==> Готово."
