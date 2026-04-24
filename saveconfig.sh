#!/bin/bash
set -e

GDRIVE_MOUNT="$HOME/GoogleDrive"
SECRETS_DIR="$GDRIVE_MOUNT/secrets"
SSH_DIR="$HOME/.ssh"
WG_CONF="/etc/wireguard/devadmin.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── age: встановити якщо нема ──────────────────────────────────────────────────

if ! command -v age &>/dev/null; then
    echo "==> Встановлення age..."
    sudo apt-get install -y age
fi

# ── Перевірки ─────────────────────────────────────────────────────────────────

if ! mountpoint -q "$GDRIVE_MOUNT" 2>/dev/null; then
    echo "ERROR: Google Drive не змонтований ($GDRIVE_MOUNT)."
    exit 1
fi

# ── zshrc → репозиторій ───────────────────────────────────────────────────────

cp "$HOME/.zshrc" "$SCRIPT_DIR/zshrc"
echo "==> Збережено .zshrc → ./zshrc"

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
if [ -f "$WG_CONF" ]; then
    sudo cp "$WG_CONF" "$TMPDIR/wireguard/devadmin.conf"
    sudo chown "$USER:$USER" "$TMPDIR/wireguard/devadmin.conf"
    echo "==> WireGuard: devadmin.conf"
else
    echo "УВАГА: $WG_CONF не знайдено, пропускаємо."
fi

# ── Шифрування → ~/GoogleDrive/secrets/ ──────────────────────────────────────

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -f "$SECRETS_DIR/secrets.tar.gz.age" ]; then
    echo ""
    echo "УВАГА: $SECRETS_DIR/secrets.tar.gz.age буде перезаписаний."
    read -rp "Продовжити? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }
fi

echo ""
echo "==> Шифрування (age запитає ключ-фразу двічі)..."
tar czf - -C "$TMPDIR" . | age --passphrase --armor -o "$SECRETS_DIR/secrets.tar.gz.age"

echo "==> Збережено → $SECRETS_DIR/secrets.tar.gz.age"

# ── Git commit & push ─────────────────────────────────────────────────────────

SAVE_DATE=$(date +%s)
cd "$SCRIPT_DIR"
git add .
git commit -m "save config $SAVE_DATE"
git push origin main

echo ""
echo "==> Готово."
