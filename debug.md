# Debugging GNOME extension issues

## Workspace Matrix: grid missing / Ctrl+Alt+Arrow keys not working

> Verified fix from 2026-08-24 — incident write-up in
> [workspace_matrix_fix.md](workspace_matrix_fix.md).

### Step 0 — Run the verifier first

`./verify_workspace_grid.sh` automates everything in Steps 1–3 and, crucially,
tells you **which of three layers** is at fault. Start there; the manual steps
below are for when you want to understand what it checked.

| Layer | What it covers | How the script proves it |
|---|---|---|
| 1. Config | installed, enabled, grid size, workspace count, keybindings | reads gsettings/dconf |
| 2. Compositor | mutter really applied the 2-D grid | live probe (see below) |
| 3. Input | the key combo actually reaches the compositor | manual, instructions printed |

**The layer-2 probe is the one that settles arguments.** `gnome-extensions info`
saying `ACTIVE` only means the extension object was constructed — it does *not*
mean the grid override took effect. To prove it did, the script bumps
`num-rows` by one and watches `_NET_NUMBER_OF_DESKTOPS`: Workspace Matrix forces
`workspaces = rows × columns`, so a live extension makes the count jump (4 → 6)
and back when the setting is restored. No reaction means the extension is
loaded but inert, and only a logout fixes that.

### Step 1 — Diagnose before changing anything

```bash
gnome-shell --version
gnome-extensions info wsmatrix@martin.zurowietz.de
ls ~/.local/share/gnome-shell/extensions/

# An extension listed in BOTH of these stays off — disabled wins.
# (A leftover disabled entry survives reinstalls and logins.)
gsettings get org.gnome.shell enabled-extensions
gsettings get org.gnome.shell disabled-extensions
gsettings get org.gnome.shell disable-user-extensions   # must be false

# The Ctrl+Alt+Arrow bindings live in GNOME itself, not in the extension —
# they usually survive extension trouble:
gsettings get org.gnome.desktop.wm.keybindings switch-to-workspace-left
gsettings get org.gnome.desktop.wm.keybindings switch-to-workspace-up
```

How to read the results:

| Observation | Meaning | Go to |
|---|---|---|
| `info` says the extension doesn't exist / dir missing | Not installed | Step 3 |
| State is `ERROR` or `OUT OF DATE` | Build doesn't match this GNOME Shell version | Step 3 |
| State is `INACTIVE` or `INITIALIZED` with `Enabled: No` | Installed but disabled — often a stale entry in `disabled-extensions` | `gsettings set org.gnome.shell disabled-extensions "[]"` then `gnome-extensions enable wsmatrix@martin.zurowietz.de` (takes effect immediately, no logout) |
| State is `ACTIVE` but keys are dead | Grid may still be inert, or the keys never arrive | Step 0's layer-2 probe, then Step 2 |

Reading the extension's own settings needs `--schemadir` — its schemas are not
installed system-wide, so a plain `gsettings get` fails with *"No such schema"*:

```bash
SD=~/.local/share/gnome-shell/extensions/wsmatrix@martin.zurowietz.de/schemas
gsettings --schemadir "$SD" get org.gnome.shell.extensions.wsmatrix-settings num-rows
```

#### Why Up/Down are special

This is the single most useful fact for triaging this bug. Stock GNOME's
`_showWorkspaceSwitcher` handler **deliberately ignores the up and down
directions** — with one horizontal row there is no "above". Workspace Matrix
makes them work by *replacing that handler* (see the comment above
`_showWorkspaceSwitcher` in `workspacePopup/workspaceManagerOverride.js`).

So the symptom splits cleanly:

| Symptom | Meaning |
|---|---|
| Left/Right work, Up/Down dead | The extension's handler override is **not** live → layer 2 |
| All four dead | The keys aren't reaching the compositor at all → layer 3 |
| All four work | Fixed |

Distinguish them by running `xprop -root -spy _NET_CURRENT_DESKTOP` and
pressing each combo — it prints a line only when a switch actually happens.

### Step 2 — Remove conflicting tiling extensions

Tiling extensions fight over the same keybindings. Find whatever variant is
present (don't assume a specific package name — it differs across releases):

```bash
gnome-extensions list | grep -i -E 'tiling|tile'
dpkg -l | grep -i tiling
```

Then disable/purge exactly what you found:

```bash
gnome-extensions disable <uuid-from-above>
sudo apt purge -y <package-from-above>
```

### Step 3 — Clean reinstall, matched to your GNOME version

Do **not** build from git master — its supported shell version may not match
the one you are running, and a `make install` that half-fails leaves you with
no extension at all. Use the installer script in this repo instead: it
auto-detects your GNOME Shell version, downloads the matching build from
extensions.gnome.org, verifies it landed on disk, and enables it without
clobbering other extensions:

```bash
# Optional: clean out any broken copy first
gnome-extensions disable wsmatrix@martin.zurowietz.de 2>/dev/null || true
rm -rf ~/.local/share/gnome-shell/extensions/wsmatrix@martin.zurowietz.de

./install_gnome_extension.sh wsmatrix@martin.zurowietz.de
```

The script fails loudly (non-zero exit) if there is no build for your GNOME
version or the install didn't land — if it prints ✅, the files are in place.

### Step 4 — Restart the shell so it picks the extension up

The running shell only rescans extensions at startup:

- **X11**: press `Alt+F2`, type `r`, press Enter.
- **Wayland** (Ubuntu default): log out and log back in — the shell cannot be
  restarted in place. (Check with `echo $XDG_SESSION_TYPE`.)

### Step 5 — When config is green but the keys still do nothing (layer 3)

If `verify_workspace_grid.sh` reports layers 1–2 all green, stop editing
gsettings — the desktop side is provably correct and the fault is in the input
path.

**First, rule out the false alarm.** With `wraparound-mode 'none'`, an edge
cell of the grid has no neighbour in some directions, so those arrows are
*correct* no-ops. Layer 2b of the verifier tells you which directions should
work from where you are. Two dead arrows in a corner is expected behaviour.

**Then measure the input path instead of guessing at it:**

```bash
sudo python3 test_workspace_keys.py
```

That injects Ctrl+Alt+<arrow> through `/dev/uinput`, below the physical
keyboard, and reports each direction separately — so it separates "GNOME is
broken" from "this keyboard never sends the combo" in one run. Only if that
points at the keyboard, work down this list:

```bash
# 1. Which device is the keyboard? (internal keyboard is usually event3)
cat /proc/bus/input/devices

# 2. Watch the raw scancodes. Use evtest — libinput-tools is NOT installed
#    by default on Ubuntu, which is why `libinput debug-events` errors with
#    "No such file or directory".
sudo evtest /dev/input/event3
```

Press Ctrl+Alt+Up and check you see all three of `KEY_LEFTCTRL`, `KEY_LEFTALT`
and `KEY_UP` with `value 1`. Common causes when you don't:

- **`KEY_UP` never appears** — the arrows sit on an Fn layer and the firmware
  is emitting something else. Toggle Fn-Lock (often `Fn+Esc` on ASUS). This is
  a keyboard/firmware issue, not a GNOME one.
- **`KEY_RIGHTALT` instead of `KEY_LEFTALT`** — AltGr does *not* satisfy
  `<Alt>` in GNOME keybindings. Use the **left** Alt key.
- **Nothing at all on any device** — a remapper is swallowing events. Check for
  one: `ps aux | grep -iE 'keyd|xremap|kmonad|input-remapper|kanata'`.

Note that on Wayland the compositor matches keybindings *before* forwarding
events to the focused window, so a focused app (VS Code, a browser, a terminal)
cannot steal Ctrl+Alt+Arrow. Which window has focus is not a useful variable
here — don't waste time on it.

### Last resort — targeted resets only

⚠️ **Never run `dconf reset -f /org/gnome/`** — that wipes your *entire*
desktop configuration (themes, fonts, custom shortcuts, every extension's
settings), not just the broken part. Reset only what's relevant:

```bash
# Workspace Matrix's own settings and keybindings back to defaults
dconf reset -f /org/gnome/shell/extensions/wsmatrix-settings/
dconf reset -f /org/gnome/shell/extensions/wsmatrix-keybindings/

# Workspace-switching keybindings (Ctrl+Alt+Arrows etc.) back to defaults
gsettings reset-recursively org.gnome.desktop.wm.keybindings

# Fixed 4 workspaces (Workspace Matrix manages the grid shape itself)
gsettings reset org.gnome.mutter dynamic-workspaces
```

Then log out and back in.
