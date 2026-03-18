#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Config
########################################
LOG_FILE="$HOME/ubuntu_setup.log"
UBUNTU_REQUIRED="24.04"
SCRIPT_USER="${SUDO_USER:-$USER}"

########################################
# Logging
########################################
log() { printf '[INFO] %s\n' "$1" | tee -a "$LOG_FILE"; }
warn() { printf '[WARN] %s\n' "$1" | tee -a "$LOG_FILE"; }
error() { printf '[ERROR] %s\n' "$1" | tee -a "$LOG_FILE" >&2; }

########################################
# Root helper
########################################
run_root() {
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

########################################
# Retry helper
########################################
retry() {
    local retries=5 delay=3 count=0
    until "$@"; do
        local exit_code=$?
        ((count++))
        if [[ $count -ge $retries ]]; then
            error "Failed after $retries attempts: $*"
            return $exit_code
        fi
        warn "Retry $count/$retries: $*"
        sleep $delay
    done
}

########################################
# Apt helpers
########################################
apt_update() { retry run_root apt update; }
apt_upgrade() { retry run_root apt upgrade -y; }
apt_install() { retry run_root apt install -y "$@"; }

########################################
# Pre-check
########################################
log "Starting setup..."
. /etc/os-release

[[ "$ID" == "ubuntu" && "$VERSION_ID" == "$UBUNTU_REQUIRED" ]] || {
    error "Ubuntu $UBUNTU_REQUIRED required"
    exit 1
}

########################################
# Clean broken NVIDIA repo
########################################
BROKEN="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
if [[ -f "$BROKEN" ]] && grep -q "<!doctype" "$BROKEN"; then
    warn "Removing broken NVIDIA repo"
    run_root rm -f "$BROKEN"
fi

########################################
# System update
########################################
apt_update
apt_upgrade

########################################
# GNOME Extension Manager
########################################
apt_install chrome-gnome-shell || true
log "NOTE: replace chrome-gnome-shell with gnome-browser-connector for Ubuntu 26.04+"
apt_install gnome-shell-extension-manager || true

########################################
# Docker
########################################
log "Installing Docker..."

run_root apt remove -y docker docker-engine docker.io containerd runc || true
apt_install ca-certificates curl gnupg

run_root install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    retry curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        run_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi

run_root chmod a+r /etc/apt/keyrings/docker.gpg

if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | \
    run_root tee /etc/apt/sources.list.d/docker.list > /dev/null
fi

apt_update
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

run_root usermod -aG docker "$SCRIPT_USER" || true

########################################
# NVIDIA + GPU VALIDATION
########################################
if command -v nvidia-smi &> /dev/null; then
    log "Validating NVIDIA driver..."

    if nvidia-smi &> /dev/null; then
        DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
        log "Driver version: $DRIVER"

        KEY="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
        LIST="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

        if [[ ! -f "$KEY" ]]; then
            retry curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
                run_root gpg --dearmor -o "$KEY"
        fi

        if [[ ! -f "$LIST" ]]; then
            TMP=$(mktemp)
            retry curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o "$TMP"
            sed "s#deb https://#deb [signed-by=$KEY] https://#g" "$TMP" | run_root tee "$LIST" > /dev/null
            rm -f "$TMP"
        fi

        apt_update
        apt_install nvidia-container-toolkit

        run_root nvidia-ctk runtime configure --runtime=docker
        run_root systemctl restart docker

        ########################################
        # GPU TEST (robust)
        ########################################
        log "Testing GPU in Docker..."

        if docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
            log "GPU container runtime OK ✅"
        else
            warn "Docker not accessible as user, retrying with sudo..."

            if run_root docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
                log "GPU container works (sudo) ✅"
                warn "Log out and log back in for non-sudo docker usage"
            else
                warn "GPU container test failed ❌"
            fi
        fi

    else
        warn "nvidia-smi broken; skipping toolkit"
    fi
else
    warn "No NVIDIA GPU"
fi

########################################
# VS Code (FULL CLEAN incl .sources)
########################################
log "Installing VS Code..."

KEY="/etc/apt/keyrings/microsoft.gpg"
LIST="/etc/apt/sources.list.d/vscode.list"

run_root install -m 0755 -d /etc/apt/keyrings

warn "Cleaning all VS Code repo entries..."

run_root rm -f /etc/apt/sources.list.d/vscode.list
run_root rm -f /etc/apt/sources.list.d/vscode.sources

run_root sed -i '/packages.microsoft.com\/repos\/code/d' /etc/apt/sources.list || true
run_root find /etc/apt/sources.list.d -type f -exec sed -i '/packages.microsoft.com\/repos\/code/d' {} \; || true

if [[ ! -f "$KEY" ]]; then
    retry curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor | run_root tee "$KEY" > /dev/null
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEY] \
https://packages.microsoft.com/repos/code stable main" | \
run_root tee "$LIST" > /dev/null

apt_update
apt_install code

########################################
# Python (PEP 668 safe)
########################################
apt_install python3 python3-venv python3-pip pipx
pipx ensurepath || true

PYTHON_BIN=$(command -v python3)

########################################
# Workspace
########################################
mkdir -p ~/sush/virtual_envs

if [[ ! -d ~/sush/virtual_envs/play_env ]]; then
    $PYTHON_BIN -m venv ~/sush/virtual_envs/play_env
fi

########################################
# Alias
########################################
ALIAS="alias tenv='source ~/sush/virtual_envs/play_env/bin/activate'"
touch ~/.bash_aliases

grep -Fxq "$ALIAS" ~/.bash_aliases || {
    echo "# alias for virtualenvs" >> ~/.bash_aliases
    echo "$ALIAS" >> ~/.bash_aliases
}

########################################
# Done
########################################
log "Setup complete!"

echo ""
echo "================ NEXT STEPS ================"
echo "1. Reboot your system"
echo "2. docker run hello-world"
echo "3. Run 'tenv'"
echo "Manually Install Workspace Matrix using Firefox (not Chrome!)"
echo "https://extensions.gnome.org/extension/1485/workspace-matrix/"
echo "==========================================="
