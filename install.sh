#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: запускай через sudo: sudo ./install.sh"
    exit 1
fi

USERNAME="${SUDO_USER:-$USER}"
HOME_DIR="/home/$USERNAME"
GDRIVE_MOUNT="$HOME_DIR/GoogleDrive"
RCLONE_REMOTE="bogdan.lavreniuk"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running as: $USERNAME, home: $HOME_DIR"

apt_install() {
    sudo apt-get install -y "$@"
}

# ── 0. Passwordless sudo ──────────────────────────────────────────────────────

SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}-nopasswd"
if [ ! -f "$SUDOERS_FILE" ]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    echo "==> Passwordless sudo налаштовано для $USERNAME"
else
    echo "==> Passwordless sudo вже є"
fi

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

RCLONE_CONF="$HOME_DIR/.config/rclone/rclone.conf"
if ! grep -q "^\[${RCLONE_REMOTE}\]" "$RCLONE_CONF" 2>/dev/null; then
    echo ""
    echo "==> rclone не налаштований."
    echo "    Зараз відкриється rclone config."
    echo "    Створи новий remote:"
    echo "      - name:  ${RCLONE_REMOTE}"
    echo "      - type:  Google Drive"
    echo "      - scope: drive (повний доступ)"
    echo ""
    read -rp "    Натисни Enter щоб продовжити..."
    sudo -u "$USERNAME" HOME="$HOME_DIR" rclone config
fi

if grep -qs "$GDRIVE_MOUNT" /proc/mounts; then
    echo "==> Google Drive вже змонтований → $GDRIVE_MOUNT"
else
    echo "==> Монтування Google Drive → $GDRIVE_MOUNT"
    sudo -u "$USERNAME" HOME="$HOME_DIR" rclone mount "${RCLONE_REMOTE}:" "$GDRIVE_MOUNT" \
        --vfs-cache-mode writes \
        --vfs-cache-max-size 1G \
        --dir-cache-time 72h \
        --allow-other \
        --daemon

    # Чекаємо поки змонтується (до 30 сек)
    echo -n "    Чекаємо монтування"
    for i in $(seq 1 30); do
        if grep -qs "$GDRIVE_MOUNT" /proc/mounts; then
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
fi

# ── 4. Розшифрування секретів (SSH ключі + WireGuard) ────────────────────────

SECRETS_DIR="$GDRIVE_MOUNT/secrets"
SSH_DIR="$HOME_DIR/.ssh"

if [ -f "$SECRETS_DIR/secrets.tar.gz.gpg" ]; then
    echo ""
    echo "==> Знайдено secrets.tar.gz.gpg. Розшифровуємо..."

    read -s -rp "Введи ключ-фразу: " PASSPHRASE; echo

    RESTORE_TMP="$(mktemp -d)"
    trap 'rm -rf "$RESTORE_TMP"' EXIT

    if ! gpg --decrypt --batch --passphrase "$PASSPHRASE" \
             "$SECRETS_DIR/secrets.tar.gz.gpg" \
         | tar xzf - -C "$RESTORE_TMP"; then
        echo "ERROR: Невірна ключ-фраза або пошкоджений файл."
        exit 1
    fi

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

        systemctl enable wg-quick@devadmin
        if ip link show devadmin &>/dev/null; then
            echo "    WireGuard tunnel devadmin вже активний."
        else
            echo "    Піднімаємо WireGuard tunnel devadmin..."
            wg-quick up devadmin
            echo "    Tunnel devadmin активний."
        fi
    fi
else
    echo "==> $SECRETS_DIR/secrets.tar.gz.gpg не знайдено, пропускаємо"
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

VSCODE_SETTINGS_SRC="$SCRIPT_DIR/vscode/settings.json"
if [ -f "$VSCODE_SETTINGS_SRC" ]; then
    sudo -u "$USERNAME" mkdir -p "$HOME_DIR/.config/Code/User"
    cp "$VSCODE_SETTINGS_SRC" "$HOME_DIR/.config/Code/User/settings.json"
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.config/Code/User/settings.json"
    echo "VS Code settings відновлено → $HOME_DIR/.config/Code/User/settings.json"
else
    echo "WARNING: $VSCODE_SETTINGS_SRC not found, skipping"
fi

VSCODE_EXTENSIONS_SRC="$SCRIPT_DIR/vscode/extensions.txt"
if [ -f "$VSCODE_EXTENSIONS_SRC" ]; then
    echo "==> Встановлення VS Code екстеншенів..."
    while IFS= read -r ext; do
        [ -z "$ext" ] && continue
        sudo -u "$USERNAME" code --install-extension "$ext" --force
    done < "$VSCODE_EXTENSIONS_SRC"
    echo "==> VS Code екстеншени встановлено."
else
    echo "WARNING: $VSCODE_EXTENSIONS_SRC not found, skipping"
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

# ── 10. kubectl + kubectx ────────────────────────────────────────────────────

if ! command -v kubectl &>/dev/null; then
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -q
    apt_install kubectl
else
    echo "kubectl already installed"
fi

if ! command -v kubectx &>/dev/null; then
    apt_install kubectx
else
    echo "kubectx already installed"
fi

# ── 11. KeePassXC ─────────────────────────────────────────────────────────────

apt_install keepassxc

# ── 12. Starship ──────────────────────────────────────────────────────────────

if ! command -v starship &>/dev/null; then
    curl -sS https://starship.rs/install.sh | sudo sh -s -- --yes
else
    echo "Starship already installed"
fi

# ── 13. Default shell → zsh ───────────────────────────────────────────────────

apt_install zsh
ZSH_PATH="$(which zsh)"
if [ "$(getent passwd "$USERNAME" | cut -d: -f7)" != "$ZSH_PATH" ]; then
    sudo chsh -s "$ZSH_PATH" "$USERNAME"
    echo "Default shell set to zsh for $USERNAME"
else
    echo "zsh already default shell"
fi

# ── 14. Copy zshrc ────────────────────────────────────────────────────────────

if [ -f "$SCRIPT_DIR/zshrc" ]; then
    cp "$SCRIPT_DIR/zshrc" "$HOME_DIR/.zshrc"
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.zshrc"
    echo "Copied zshrc → $HOME_DIR/.zshrc"
else
    echo "WARNING: $SCRIPT_DIR/zshrc not found, skipping"
fi

# ── 15. zsh плагіни ──────────────────────────────────────────────────────────

ZSH_CUSTOM_DIR="${HOME_DIR}/.oh-my-zsh/custom"

if [ ! -d "${ZSH_CUSTOM_DIR}/plugins/zsh-autosuggestions" ]; then
    sudo -u "$USERNAME" git clone https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_CUSTOM_DIR}/plugins/zsh-autosuggestions"
    echo "zsh-autosuggestions встановлено"
else
    echo "zsh-autosuggestions вже є"
fi

if [ ! -d "${ZSH_CUSTOM_DIR}/plugins/zsh-syntax-highlighting" ]; then
    sudo -u "$USERNAME" git clone https://github.com/zsh-users/zsh-syntax-highlighting \
        "${ZSH_CUSTOM_DIR}/plugins/zsh-syntax-highlighting"
    echo "zsh-syntax-highlighting встановлено"
else
    echo "zsh-syntax-highlighting вже є"
fi

# ── 16. WezTerm конфіг ───────────────────────────────────────────────────────

if [ -f "$SCRIPT_DIR/wezterm.lua" ]; then
    sudo -u "$USERNAME" mkdir -p "$HOME_DIR/.config/wezterm"
    cp "$SCRIPT_DIR/wezterm.lua" "$HOME_DIR/.config/wezterm/wezterm.lua"
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.config/wezterm/wezterm.lua"
    echo "Copied wezterm.lua → $HOME_DIR/.config/wezterm/wezterm.lua"
else
    echo "WARNING: $SCRIPT_DIR/wezterm.lua not found, skipping"
fi

# ── 17. tfenv + Terraform ─────────────────────────────────────────────────────

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
if ! sudo -u "$USERNAME" "$TFENV" list 2>/dev/null | grep -q "^[^n]"; then
    sudo -u "$USERNAME" "$TFENV" install latest
    sudo -u "$USERNAME" "$TFENV" use latest
else
    echo "terraform версія вже встановлена, пропускаємо tfenv install"
fi

# ── 18. systemd user-сервіс для автомонтування GDrive ────────────────────────

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

# ── 19. KeePassXC → автовідкриття Passwords.kdbx ─────────────────────────────

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
