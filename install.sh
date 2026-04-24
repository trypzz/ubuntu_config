#!/bin/bash
set -e

USERNAME="${SUDO_USER:-$USER}"
HOME_DIR="/home/$USERNAME"
GDRIVE_MOUNT="$HOME_DIR/GoogleDrive"
RCLONE_REMOTE="gdrive"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running as: $USERNAME, home: $HOME_DIR"

apt_install() {
    sudo apt-get install -y "$@"
}

# ── 1. Мінімальні залежності для старту ───────────────────────────────────────

sudo apt-get update -q
apt_install curl wget gpg apt-transport-https software-properties-common \
            git fuse3 age

# Allow user_allow_other (потрібно для rclone mount)
if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" | sudo tee -a /etc/fuse.conf > /dev/null
fi

# ── 2. rclone ─────────────────────────────────────────────────────────────────

if ! command -v rclone &>/dev/null; then
    curl -s https://rclone.org/install.sh | sudo bash
else
    echo "rclone already installed"
fi

# ── 3. Google Drive mount (інтерактивний OAuth якщо перший раз) ───────────────

sudo -u "$USERNAME" mkdir -p "$GDRIVE_MOUNT"

if ! sudo -u "$USERNAME" rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
    echo ""
    echo "==> rclone не налаштований."
    echo "    Зараз відкриється rclone config."
    echo "    Створи новий remote:"
    echo "      - name:  ${RCLONE_REMOTE}"
    echo "      - type:  Google Drive"
    echo "      - scope: drive (повний доступ)"
    echo ""
    read -rp "    Натисни Enter щоб продовжити..."
    sudo -u "$USERNAME" rclone config
fi

echo "==> Монтування Google Drive → $GDRIVE_MOUNT"
sudo -u "$USERNAME" rclone mount "${RCLONE_REMOTE}:" "$GDRIVE_MOUNT" \
    --vfs-cache-mode writes \
    --vfs-cache-max-size 1G \
    --dir-cache-time 72h \
    --allow-other \
    --daemon

# Чекаємо поки смонтується (до 30 сек)
echo -n "    Чекаємо монтування"
for i in $(seq 1 30); do
    if mountpoint -q "$GDRIVE_MOUNT" 2>/dev/null; then
        echo " OK"
        break
    fi
    echo -n "."
    sleep 1
    if [ "$i" -eq 30 ]; then
        echo ""
        echo "ERROR: Google Drive не змонтувався за 30 сек. Перевір rclone config."
        exit 1
    fi
done

# ── 4. Розшифрування секретів (SSH ключі + WireGuard) ────────────────────────

SECRETS_DIR="$GDRIVE_MOUNT/secrets"
SSH_DIR="$HOME_DIR/.ssh"

if [ -f "$SECRETS_DIR/secrets.tar.gz.age" ]; then
    echo ""
    echo "==> Знайдено secrets.tar.gz.age. Розшифровуємо..."
    echo "    (age запитає ключ-фразу один раз)"

    RESTORE_TMP="$(mktemp -d)"
    trap 'rm -rf "$RESTORE_TMP"' EXIT

    sudo -u "$USERNAME" age -d "$SECRETS_DIR/secrets.tar.gz.age" \
        | tar xzf - -C "$RESTORE_TMP"

    # SSH ключі
    if [ -d "$RESTORE_TMP/ssh" ] && [ -n "$(ls -A "$RESTORE_TMP/ssh")" ]; then
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        cp "$RESTORE_TMP/ssh/"* "$SSH_DIR/"
        chmod 600 "$SSH_DIR"/*
        chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
        echo "    SSH ключі відновлено → $SSH_DIR"
    fi

    # WireGuard конфіг
    if [ -f "$RESTORE_TMP/wireguard/devadmin.conf" ]; then
        apt_install wireguard-tools
        mkdir -p /etc/wireguard
        cp "$RESTORE_TMP/wireguard/devadmin.conf" /etc/wireguard/devadmin.conf
        chmod 600 /etc/wireguard/devadmin.conf
        echo "    WireGuard конфіг відновлено → /etc/wireguard/devadmin.conf"

        echo "    Піднімаємо WireGuard tunnel devadmin..."
        wg-quick up devadmin
        systemctl enable wg-quick@devadmin
        echo "    Tunnel devadmin активний і додано в автозапуск."
    fi
else
    echo "==> $SECRETS_DIR/secrets.tar.gz.age не знайдено, пропускаємо"
fi

# ── 5. SSH config ─────────────────────────────────────────────────────────────

SSH_CONFIG="$SSH_DIR/config"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

add_ssh_host() {
    local host_name="$1"
    local block="$2"
    if ! grep -qF "Host $host_name" "$SSH_CONFIG" 2>/dev/null; then
        echo "" >> "$SSH_CONFIG"
        echo "$block" >> "$SSH_CONFIG"
        echo "Added SSH host: $host_name"
    else
        echo "SSH host already present: $host_name"
    fi
}

add_ssh_host "github-69centr" "Host github-69centr
  User git
  Port 22
  Hostname github.com
  ServerAliveInterval 120
  IdentityFile /home/bohdan/.ssh/santa_git"

add_ssh_host "github-personal" "Host github-personal
  User git
  Port 22
  Hostname github.com
  ServerAliveInterval 120
  IdentityFile /home/bohdan/.ssh/id_rsa"

chmod 600 "$SSH_CONFIG"
chown "$USERNAME:$USERNAME" "$SSH_CONFIG"

# ── 6. Visual Studio Code ─────────────────────────────────────────────────────

if ! command -v code &>/dev/null; then
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor \
        | sudo tee /usr/share/keyrings/microsoft.gpg > /dev/null
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list
    sudo apt-get update -q
    apt_install code
else
    echo "VS Code already installed"
fi

# ── 7. Google Chrome ──────────────────────────────────────────────────────────

if ! command -v google-chrome &>/dev/null; then
    wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt-get install -y /tmp/chrome.deb
    rm /tmp/chrome.deb
else
    echo "Google Chrome already installed"
fi

# ── 8. Ansible core 2.18.11 (via pipx) ───────────────────────────────────────

apt_install python3-pip python3-venv pipx
sudo -u "$USERNAME" pipx ensurepath
if ! sudo -u "$USERNAME" pipx list 2>/dev/null | grep -q "ansible-core 2.18.11"; then
    sudo -u "$USERNAME" pipx install "ansible-core==2.18.11"
else
    echo "Ansible core 2.18.11 already installed via pipx"
fi

# ── 9. Signal Desktop ────────────────────────────────────────────────────────

if ! command -v signal-desktop &>/dev/null; then
    wget -qO- https://updates.signal.org/desktop/apt/keys.asc \
        | gpg --dearmor \
        | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg > /dev/null
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] \
https://updates.signal.org/desktop/apt xenial main" \
        | sudo tee /etc/apt/sources.list.d/signal-xenial.list
    sudo apt-get update -q
    apt_install signal-desktop
else
    echo "Signal Desktop already installed"
fi

# ── 10. KeePassXC ─────────────────────────────────────────────────────────────

apt_install keepassxc

# ── 11. Starship ──────────────────────────────────────────────────────────────

if ! command -v starship &>/dev/null; then
    curl -sS https://starship.rs/install.sh | sudo sh -s -- --yes
else
    echo "Starship already installed"
fi

# ── 12. Default shell → zsh ───────────────────────────────────────────────────

apt_install zsh
ZSH_PATH="$(which zsh)"
if [ "$(getent passwd "$USERNAME" | cut -d: -f7)" != "$ZSH_PATH" ]; then
    sudo chsh -s "$ZSH_PATH" "$USERNAME"
    echo "Default shell set to zsh for $USERNAME"
else
    echo "zsh already default shell"
fi

# ── 13. Copy zshrc ────────────────────────────────────────────────────────────

if [ -f "$SCRIPT_DIR/zshrc" ]; then
    cp "$SCRIPT_DIR/zshrc" "$HOME_DIR/.zshrc"
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.zshrc"
    echo "Copied zshrc → $HOME_DIR/.zshrc"
else
    echo "WARNING: $SCRIPT_DIR/zshrc not found, skipping"
fi

# ── 14. tfenv + Terraform ─────────────────────────────────────────────────────

TFENV_DIR="$HOME_DIR/.tfenv"

if [ ! -d "$TFENV_DIR" ]; then
    sudo -u "$USERNAME" git clone --depth=1 https://github.com/tfutils/tfenv.git "$TFENV_DIR"
    echo "tfenv cloned → $TFENV_DIR"
else
    echo "tfenv already installed"
fi

ZSHRC="$HOME_DIR/.zshrc"
if ! grep -q "tfenv/bin" "$ZSHRC" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.tfenv/bin:$PATH"\n' >> "$ZSHRC"
fi

TFENV="$TFENV_DIR/bin/tfenv"
sudo -u "$USERNAME" "$TFENV" install latest
sudo -u "$USERNAME" "$TFENV" use latest

# ── 15. systemd user-сервіс для автомонтування GDrive ────────────────────────

SYSTEMD_USER_DIR="$HOME_DIR/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/rclone-gdrive.service" <<EOF
[Unit]
Description=Google Drive via rclone
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p %h/GoogleDrive
ExecStart=/usr/bin/rclone mount ${RCLONE_REMOTE}: %h/GoogleDrive \\
    --vfs-cache-mode writes \\
    --vfs-cache-max-size 1G \\
    --dir-cache-time 72h \\
    --allow-other \\
    --log-level INFO
ExecStop=/bin/fusermount3 -u %h/GoogleDrive
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

chown -R "$USERNAME:$USERNAME" "$SYSTEMD_USER_DIR"

sudo loginctl enable-linger "$USERNAME"
XDG_RT="/run/user/$(id -u "$USERNAME")"
sudo -u "$USERNAME" XDG_RUNTIME_DIR="$XDG_RT" systemctl --user daemon-reload
sudo -u "$USERNAME" XDG_RUNTIME_DIR="$XDG_RT" systemctl --user enable rclone-gdrive.service

# ── 16. KeePassXC → автовідкриття Passwords.kdbx ─────────────────────────────

KEEPASSXC_CONFIG_DIR="$HOME_DIR/.config/keepassxc"
KEEPASSXC_INI="$KEEPASSXC_CONFIG_DIR/keepassxc.ini"
KDBX_PATH="$HOME_DIR/GoogleDrive/Passwords.kdbx"

mkdir -p "$KEEPASSXC_CONFIG_DIR"

if [ ! -f "$KEEPASSXC_INI" ]; then
    cat > "$KEEPASSXC_INI" <<EOF
[General]
LastActiveDatabase=$KDBX_PATH
OpenPreviousDatabasesOnStartup=true
RememberLastDatabases=true
RememberLastKeyFiles=true

[RecentDatabases]
1\Path=$KDBX_PATH
EOF
    chown -R "$USERNAME:$USERNAME" "$KEEPASSXC_CONFIG_DIR"
    echo "KeePassXC config created → $KDBX_PATH"
else
    python3 - "$KEEPASSXC_INI" "$KDBX_PATH" <<'PYEOF'
import sys, re

ini_path, kdbx_path = sys.argv[1], sys.argv[2]
with open(ini_path, "r") as f:
    content = f.read()

def set_key(text, section, key, value):
    pattern = re.compile(
        rf"(\[{re.escape(section)}\][^\[]*?){re.escape(key)}\s*=\s*[^\n]*",
        re.DOTALL,
    )
    if pattern.search(text):
        return pattern.sub(lambda m: m.group(1) + f"{key}={value}", text)
    sec_pattern = re.compile(rf"\[{re.escape(section)}\]")
    m = sec_pattern.search(text)
    if m:
        insert_at = text.find("\n[", m.end())
        line = f"\n{key}={value}"
        if insert_at == -1:
            return text + line
        return text[:insert_at] + line + text[insert_at:]
    return text + f"\n[{section}]\n{key}={value}\n"

for key, value in [
    ("LastActiveDatabase", kdbx_path),
    ("OpenPreviousDatabasesOnStartup", "true"),
    ("RememberLastDatabases", "true"),
]:
    content = set_key(content, "General", key, value)

if "RecentDatabases" not in content:
    content += f"\n[RecentDatabases]\n1\\Path={kdbx_path}\n"
elif kdbx_path not in content:
    content = re.sub(
        r"(\[RecentDatabases\]\n)",
        rf"\g<1>1\\Path={kdbx_path}\n",
        content,
    )

with open(ini_path, "w") as f:
    f.write(content)
print(f"KeePassXC config patched → {kdbx_path}")
PYEOF
    chown -R "$USERNAME:$USERNAME" "$KEEPASSXC_CONFIG_DIR"
fi

echo ""
echo "==> Done. Log out and back in for zsh to take effect."
