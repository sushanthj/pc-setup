#!/usr/bin/env bash
#
# Verify the Workspace Matrix grid is actually live, and localise a
# "Ctrl+Alt+Arrow does nothing" fault to one of three layers:
#
#   layer 1  config      - extension installed/enabled, grid + workspace count
#   layer 2  compositor  - mutter really applied the grid and holds the grabs
#   layer 3  input       - the key combo actually reaches the compositor
#
# Layers 1 and 2 are checked automatically. Layer 3 needs your hands on the
# keyboard (and root for evtest), so it is printed as instructions at the end.
#
# Usage: ./verify_workspace_grid.sh

set -uo pipefail

UUID="wsmatrix@martin.zurowietz.de"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$UUID"
SCHEMADIR="$EXT_DIR/schemas"
SETTINGS="org.gnome.shell.extensions.wsmatrix-settings"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILED=1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

FAILED=0

# Extension schemas are NOT installed system-wide; gsettings needs --schemadir
# or it fails with "No such schema".
ext_get() { gsettings --schemadir "$SCHEMADIR" get "$SETTINGS" "$1" 2>/dev/null; }
ext_set() { gsettings --schemadir "$SCHEMADIR" set "$SETTINGS" "$1" "$2" 2>/dev/null; }

hdr "Layer 1 — configuration"

echo "  GNOME Shell $(gnome-shell --version | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1), session: ${XDG_SESSION_TYPE:-unknown}"

if [[ -f "$EXT_DIR/metadata.json" ]]; then
    pass "extension present ($EXT_DIR)"
else
    bad "extension not installed — run ./install_gnome_extension.sh $UUID"
fi

STATE=$(gnome-extensions info "$UUID" 2>/dev/null | sed -n 's/^ *State: *//p')
ENABLED=$(gnome-extensions info "$UUID" 2>/dev/null | sed -n 's/^ *Enabled: *//p')
if [[ "$STATE" == "ACTIVE" ]]; then
    pass "extension state: ACTIVE"
else
    bad "extension state: ${STATE:-unknown} (Enabled: ${ENABLED:-?}) — see disabled-extensions below"
fi

# A UUID present in BOTH lists stays off: disabled-extensions wins.
DIS=$(gsettings get org.gnome.shell disabled-extensions)
if [[ "$DIS" == *"$UUID"* ]]; then
    bad "$UUID is in disabled-extensions (this overrides enabled-extensions)"
    echo "      fix: gsettings set org.gnome.shell disabled-extensions \"[]\""
else
    pass "not in disabled-extensions"
fi

if [[ "$(gsettings get org.gnome.shell disable-user-extensions)" == "true" ]]; then
    bad "disable-user-extensions is true — all user extensions are off"
else
    pass "disable-user-extensions: false"
fi

ROWS=$(ext_get num-rows); COLS=$(ext_get num-columns)
if [[ -n "$ROWS" && -n "$COLS" ]]; then
    pass "grid: ${ROWS}x${COLS}"
else
    bad "cannot read grid settings (schemadir missing?)"
fi

if [[ "$(gsettings get org.gnome.mutter dynamic-workspaces)" == "false" ]]; then
    pass "dynamic-workspaces: false (required for a fixed grid)"
else
    warn "dynamic-workspaces is true — the extension forces this false at enable"
fi

hdr "Layer 1b — keybindings"
for dir in up down left right; do
    VAL=$(gsettings get org.gnome.desktop.wm.keybindings "switch-to-workspace-$dir")
    if [[ "$VAL" == *"Up'"* || "$VAL" == *"Down'"* || "$VAL" == *"Left'"* || "$VAL" == *"Right'"* ]]; then
        pass "switch-to-workspace-$dir = $VAL"
    else
        bad "switch-to-workspace-$dir is unbound: $VAL"
    fi
done
echo
echo "  NOTE: stock GNOME's own handler deliberately IGNORES up/down."
echo "  Ctrl+Alt+Up/Down only work because Workspace Matrix replaces that"
echo "  handler. Left/Right working while Up/Down do nothing == the grid"
echo "  override is not live. Layer 2 tests exactly that."

hdr "Layer 2 — is the grid actually live in the compositor?"

if ! command -v xprop &> /dev/null; then
    warn "xprop not available; skipping live probe (install x11-utils)"
else
    BEFORE=$(xprop -root _NET_NUMBER_OF_DESKTOPS 2>/dev/null | grep -oE '[0-9]+$')
    if [[ -z "$BEFORE" ]]; then
        warn "cannot read _NET_NUMBER_OF_DESKTOPS (no XWayland?); skipping probe"
    else
        echo "  workspaces now: $BEFORE"
        # If the extension is live, bumping num-rows must change the workspace
        # count within a moment, because it forces n = rows * columns.
        echo "  probing: temporarily setting rows=$((ROWS + 1))..."
        ext_set num-rows "$((ROWS + 1))"
        sleep 2
        DURING=$(xprop -root _NET_NUMBER_OF_DESKTOPS 2>/dev/null | grep -oE '[0-9]+$')
        ext_set num-rows "$ROWS"
        sleep 2
        AFTER=$(xprop -root _NET_NUMBER_OF_DESKTOPS 2>/dev/null | grep -oE '[0-9]+$')
        EXPECT=$(( (ROWS + 1) * COLS ))

        if [[ "$DURING" == "$EXPECT" ]]; then
            pass "extension is LIVE (workspaces $BEFORE -> $DURING -> $AFTER)"
            pass "the ${ROWS}x${COLS} grid override is genuinely applied"
            echo
            echo "  => Config and compositor are correct. If Ctrl+Alt+Arrow still"
            echo "     does nothing, the fault is layer 3 (input) — see below."
        else
            bad "extension did NOT react (expected $EXPECT workspaces, saw ${DURING:-?})"
            echo "      the extension reports ACTIVE but its settings handlers are dead."
            echo "      fix: log out and back in (Wayland cannot restart the shell in place)."
        fi
    fi
fi

hdr "Layer 2b — where are you in the grid? (the classic false alarm)"

# wraparound-mode 'none' means edge cells have no neighbour in some
# directions, so those arrows are CORRECT no-ops. Testing from a corner and
# concluding "the keys are dead" is the single most common false alarm here.
WRAP=$(ext_get wraparound-mode)
CUR=$(xprop -root _NET_CURRENT_DESKTOP 2>/dev/null | grep -oE '[0-9]+$')
if [[ -n "$CUR" && -n "$ROWS" && -n "$COLS" ]]; then
    R=$(( CUR / COLS )); C=$(( CUR % COLS ))
    echo "  on workspace $CUR = row $R, column $C of a ${ROWS}x${COLS} grid"
    echo "  wraparound-mode: $WRAP"
    if [[ "$WRAP" == "'none'" ]]; then
        DEAD=()
        (( R == 0 ))            && DEAD+=("Up")
        (( R == ROWS - 1 ))     && DEAD+=("Down")
        (( C == 0 ))            && DEAD+=("Left")
        (( C == COLS - 1 ))     && DEAD+=("Right")
        if (( ${#DEAD[@]} )); then
            LIVE=()
            for d in Up Down Left Right; do
                [[ " ${DEAD[*]} " == *" $d "* ]] || LIVE+=("$d")
            done
            warn "from here, Ctrl+Alt+${DEAD[*]} SHOULD do nothing (no neighbour)"
            echo "      this is correct behaviour, not a fault."
            echo "      test with Ctrl+Alt+${LIVE[*]} instead — those must move."
        else
            pass "not on an edge — all four directions should move from here"
        fi
    else
        pass "wraparound is on — all four directions should move from anywhere"
    fi
fi

hdr "Layer 3 — does the key combo reach the compositor?"
echo "  Best first move: measure it instead of guessing --"
echo "      sudo python3 test_workspace_keys.py"
echo "  That injects Ctrl+Alt+<arrow> via /dev/uinput, below the physical"
echo "  keyboard, and reports each direction separately."
echo
cat <<'EOF'
  To check by hand instead:

  1) Watch workspace changes live (leave this running in a terminal):

       xprop -root -spy _NET_CURRENT_DESKTOP

     Then press Ctrl+Alt+Right, Left, Up, Down.
       - all four change the number  -> navigation works
       - only Left/Right change it   -> grid override not live (rerun layer 2)
       - nothing changes             -> continue to step 2

  2) Watch the raw key events (needs root; evtest, not libinput-tools):

       sudo evtest /dev/input/event3      # "AT Translated Set 2 keyboard"

     Find your keyboard's node with:  cat /proc/bus/input/devices
     Press Ctrl+Alt+Up and confirm you see all three of:
       KEY_LEFTCTRL, KEY_LEFTALT, KEY_UP   (value 1 = press)

     If KEY_UP never appears, the arrows are on an Fn layer and the
     firmware is sending something else -- that is a keyboard/firmware
     issue, not a GNOME one. Check Fn-Lock (often Fn+Esc on ASUS).
     If you see KEY_RIGHTALT instead of KEY_LEFTALT, note that AltGr does
     not satisfy <Alt> in GNOME keybindings -- use the LEFT Alt key.
EOF

hdr "Result"
if [[ $FAILED -eq 0 ]]; then
    echo "  Layers 1-2 all green. Any remaining fault is in layer 3 (input)."
else
    echo "  Problems found above — fix those first, then re-run."
fi
exit $FAILED
