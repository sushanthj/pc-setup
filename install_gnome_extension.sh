#!/usr/bin/env bash
#
# Install one or more GNOME Shell extensions from extensions.gnome.org,
# matched to the *running* GNOME Shell version (never build from git master —
# it may target a different shell version than the one running).
#
# Guarantees:
#   - fails fast if a required tool is missing
#   - fails if extensions.gnome.org has no build for this GNOME Shell version
#   - verifies the extension actually landed on disk after install
#   - enables without clobbering other enabled extensions
#   - tells you exactly what restart step is still needed (X11 vs Wayland)
#
# Usage:   ./install_gnome_extension.sh <extension-uuid> [more-uuids...]
# Example: ./install_gnome_extension.sh wsmatrix@martin.zurowietz.de

set -Eeuo pipefail

EGO="https://extensions.gnome.org"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"

log()  { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || fail "Usage: $0 <extension-uuid> [more-uuids...]"

for cmd in curl python3 gnome-shell gnome-extensions gsettings; do
    command -v "$cmd" &> /dev/null || fail "Required command not found: $cmd"
done

# GNOME >= 40 is versioned by major only ("46"); GNOME 3.x by major.minor ("3.38").
FULL_VER=$(gnome-shell --version | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1)
MAJOR=${FULL_VER%%.*}
if (( MAJOR >= 40 )); then
    SHELL_VER=$MAJOR
else
    SHELL_VER=$(cut -d. -f1,2 <<< "$FULL_VER")
fi
log "Running GNOME Shell $FULL_VER (extensions.gnome.org shell_version: $SHELL_VER)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Append a UUID to org.gnome.shell enabled-extensions without clobbering the
# list, and drop it from disabled-extensions — a leftover disabled entry (e.g.
# from `gnome-extensions disable` before an uninstall) overrides the enabled
# list, leaving the extension permanently off across logins.
enable_extension() {
    local uuid=$1
    # The running shell only rescans for new extensions at startup, so
    # `gnome-extensions enable` fails for freshly installed ones ("does not
    # exist"). Fall back to editing the gsettings lists directly.
    gnome-extensions enable "$uuid" 2>/dev/null && return 0
    python3 - "$uuid" <<'PY'
import ast, subprocess, sys
uuid = sys.argv[1]

def get_list(key):
    cur = subprocess.run(
        ["gsettings", "get", "org.gnome.shell", key],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return [] if cur in ("@as []", "[]") else ast.literal_eval(cur)

def set_list(key, lst):
    subprocess.run(
        ["gsettings", "set", "org.gnome.shell", key, str(lst)],
        check=True,
    )

enabled = get_list("enabled-extensions")
if uuid not in enabled:
    set_list("enabled-extensions", enabled + [uuid])

disabled = get_list("disabled-extensions")
if uuid in disabled:
    set_list("disabled-extensions", [u for u in disabled if u != uuid])
PY
}

NEEDS_RESTART=0

for UUID in "$@"; do
    log "Looking up $UUID for GNOME $SHELL_VER..."
    INFO_JSON=$(curl -fsSL "$EGO/extension-info/?uuid=$UUID&shell_version=$SHELL_VER") \
        || fail "Extension not found on extensions.gnome.org: $UUID"

    TAG=$(printf '%s' "$INFO_JSON" | python3 -c '
import json, sys
info = json.load(sys.stdin)
build = info.get("shell_version_map", {}).get(sys.argv[1])
print(build["pk"] if build else "")
' "$SHELL_VER")
    [[ -n "$TAG" ]] || fail "$UUID has no build for GNOME Shell $SHELL_VER"

    log "Downloading $UUID (version_tag=$TAG)..."
    ZIP="$TMP/$UUID.zip"
    curl -fsSL -o "$ZIP" \
        "$EGO/download-extension/$UUID.shell-extension.zip?version_tag=$TAG" \
        || fail "Download failed for $UUID"

    gnome-extensions install --force "$ZIP" || fail "Install failed for $UUID"

    # Verify it actually landed on disk.
    [[ -f "$EXT_DIR/$UUID/metadata.json" ]] \
        || fail "$UUID did not appear in $EXT_DIR after install"

    enable_extension "$UUID"

    if gnome-extensions info "$UUID" &> /dev/null; then
        log "$UUID installed and enabled ✅"
    else
        log "$UUID installed and marked enabled ✅ (needs a shell restart to load)"
        NEEDS_RESTART=1
    fi
done

if [[ $NEEDS_RESTART -eq 1 ]]; then
    echo ""
    if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        echo "👉 Restart GNOME Shell to load it: press Alt+F2, type 'r', press Enter."
    else
        echo "👉 Wayland session: log out and log back in to load the extension."
    fi
fi
