# Fix: Workspace Matrix + Ctrl+Alt+Arrow Keybindings (2026-08-24)

## What was broken

- The cleanup script in `debug.md` uninstalled Workspace Matrix, but its
  reinstall step (git clone + `make install`) never landed —
  `~/.local/share/gnome-shell/extensions/` was empty.
- The Ctrl+Alt+Arrow bindings were still set in gsettings the whole time.
  They appeared dead because without the grid extension GNOME 46 only has a
  single horizontal row of workspaces (Up/Down had nothing to switch to).
- Old Workspace Matrix settings were gone from dconf (likely from the
  `dconf reset -f /org/gnome/` suggested in `debug.md`), so the extension
  starts with its default 2×2 grid.

## The fix

Install the official build for the running GNOME Shell version from
extensions.gnome.org instead of building from git master:

```bash
# 1. Find the right version for your shell (check "shell_version_map")
gnome-shell --version
curl -s "https://extensions.gnome.org/extension-info/?uuid=wsmatrix@martin.zurowietz.de&shell_version=46"

# 2. Download + install (version_tag 62683 = v50, the GNOME 46 build)
curl -sL -o wsmatrix.zip "https://extensions.gnome.org/download-extension/wsmatrix@martin.zurowietz.de.shell-extension.zip?version_tag=62683"
gnome-extensions install --force wsmatrix.zip

# 3. Enable. The running shell only rescans extensions at startup, so
#    `gnome-extensions enable` fails with "does not exist" — write the
#    gsettings key directly instead:
gsettings set org.gnome.shell enabled-extensions "['wsmatrix@martin.zurowietz.de']"

# 4. On Wayland the shell can't be restarted in place: log out and back in.
```

Grid size (rows/columns) can be changed afterwards in
Extension Manager → Workspace Matrix → settings.

## Follow-up (same day): still dead after logout

The step-3 gsettings write set `enabled-extensions`, but the earlier
`gnome-extensions disable` had left the UUID in
`org.gnome.shell disabled-extensions` — and the disabled list **overrides**
the enabled list, so the extension stayed off across logins
(`State: INITIALIZED`, `Enabled: No`).

Fix (immediate, no logout needed once the shell has rescanned the files):

```bash
gsettings set org.gnome.shell disabled-extensions "[]"
gnome-extensions enable wsmatrix@martin.zurowietz.de
```

`install_gnome_extension.sh` now clears the UUID from `disabled-extensions`
as part of its enable step.

## Follow-up 2 (same day): config proven correct, fault is in the input path

After clearing `disabled-extensions` the arrows were still reported dead, so
the desktop side was verified exhaustively rather than guessed at:

| Check | Result |
|---|---|
| Extension state | `ACTIVE`, version 50, matches GNOME Shell 46.0 |
| `disabled-extensions` / `disable-user-extensions` | empty / false |
| Grid + workspaces | 2×2, `num-workspaces=4`, `dynamic-workspaces=false` |
| All four `switch-to-workspace-*` bindings | bound to Ctrl+Alt+Arrows |
| Conflicting extensions | none (only ding, appindicators, dock) |
| Key remapper daemons | none running |
| Shell JS errors | none in the journal |
| Monitors | 1 (so `workspaces-only-on-primary` is irrelevant) |
| Mutter holds the Ctrl+Alt+Up grab | yes — a competing `gsd-media-keys` grab was refused |
| Switching works when driven programmatically | yes — EWMH `_NET_CURRENT_DESKTOP` moved 0→3→0 |
| **Extension responds live** | **yes — `num-rows` 2→3 moved workspaces 4→6, and back** |

That last row is the decisive one and is now automated as layer 2 of
`verify_workspace_grid.sh`. Workspace Matrix forces
`workspaces = rows × columns`, so if the workspace count tracks a `num-rows`
change, `_overrideLayout()` is demonstrably running and the grid is real.
`ACTIVE` alone does not prove this — it only means the extension object was
constructed.

Also observed: `xprop -root -spy _NET_CURRENT_DESKTOP` recorded a genuine
0 → 1 transition during a user key test, i.e. horizontal navigation fired at
least once.

**Conclusion at the time:** layers 1 and 2 are green, so the remaining fault
is layer 3 — the Ctrl+Alt+Arrow combo not reaching the compositor as that
combo. See `debug.md` Step 5. Prime suspects were an Fn-layer arrow cluster
and AltGr being pressed instead of the left Alt, since AltGr does not satisfy
`<Alt>` in GNOME keybindings.

**This layer-3 conclusion was never confirmed.** See Resolution below.

### Gotchas worth remembering

- `libinput debug-events` fails with *"No such file or directory"* on stock
  Ubuntu — `libinput-tools` is not installed. Use `evtest` (which is), or
  `sudo apt install libinput-tools`.
- Reading the extension's own settings needs
  `gsettings --schemadir <ext>/schemas ...`; without it you get
  *"No such schema org.gnome.shell.extensions.wsmatrix-settings"*.
- Stock GNOME's `_showWorkspaceSwitcher` **ignores up/down by design**.
  Up/Down working at all depends on Workspace Matrix replacing that handler,
  which is why "Left/Right work, Up/Down don't" is a distinct diagnosis from
  "nothing works".

## Resolution (2026-08-24): working — root cause NOT identified

The grid and all four Ctrl+Alt+Arrow directions now work. Recording this
honestly, because the cause was never pinned down and a confident-but-wrong
note here would cost time later.

What is known:

- Every layer-1/2 check was re-run independently and was green.
- A sweep of **every** keybinding schema (`keybind|media-keys|shell|mutter|wm`)
  found **zero** conflicts on `<Control><Alt>Up` / `<Control><Alt>Down`.
  `custom-keybindings` is empty.
- The live probe passed again: `num-rows` 2→3 moved workspaces 4→6 and back,
  so `_overrideLayout()` is demonstrably running.
- **No config changed between the "broken" and "working" snapshots.** Grid,
  bindings and `wraparound-mode` were byte-identical before and after. The
  kernel-injection test (below) was never run — `uinput` was never loaded.

So there is no evidence of a fix; the desktop side was already correct once
`disabled-extensions` was cleared (Follow-up 1). The most likely benign
explanation, **unconfirmed**:

> Testing was being done from workspace 1 — the **top-right** cell of the 2×2
> grid. With `wraparound-mode 'none'`, Ctrl+Alt+**Up** and Ctrl+Alt+**Right**
> from that corner have no neighbour to move to and are *correct* no-ops.
> "Two of the four arrows do nothing" is expected from any edge cell, and is
> not a fault. Always test from workspace 0 (top-left), where Right and Down
> must both move.

### Hypothesis tested and DISPROVED — don't re-chase it

Workspace Matrix patches the up/down handler by looping over gnome-shell's
*private* `Main.wm._allowedKeybindings` (`workspaceManagerOverride.js`,
`_overrideKeybindingHandlers`). If GNOME 46 had renamed or removed that field,
the loop would iterate nothing and silently no-op — while `_overrideLayout()`
kept working. That would produce *exactly* the reported symptom: grid live,
up/down dead.

It is not the cause. Verified by extracting the shell's own source:

```bash
# The GNOME 46 shell JS is a gresource inside libshell-14.so —
# NOT in /usr/share/gnome-shell, and NOT in the gnome-shell binary.
gresource extract /usr/lib/gnome-shell/libshell-14.so \
    /org/gnome/shell/ui/windowManager.js > wm.js
grep -n "_allowedKeybindings" wm.js          # exists: assigned at init
grep -n "setCustomKeybindingHandler(" wm.js  # registers switch-to-workspace-up/down
```

Both are present in 46.0, so the extension's override loop does see the
workspace bindings.

### `test_workspace_keys.py` — the test to run FIRST next time

If this recurs, stop guessing at the input layer and measure it.
`test_workspace_keys.py` creates a virtual keyboard via `/dev/uinput` and
injects Ctrl+Alt+<arrow> *below* the physical keyboard, then watches
`_NET_CURRENT_DESKTOP`:

```bash
sudo python3 test_workspace_keys.py    # needs root for /dev/uinput
```

- workspaces move → GNOME/mutter/wsmatrix are fine, the **keyboard** is the
  fault (Fn layer, or AltGr instead of left Alt)
- horizontal moves but vertical does not → the grid override is not driving
  the up/down handler
- nothing moves → the compositor is not acting on the bindings at all

It tests all four directions and reports each separately, which also sidesteps
the corner/wraparound trap described above.

## Open, unrelated issue: Fn+F7 / Fn+F8

Separate from the workspace grid and **still unresolved**: on this ASUS
laptop `Fn+F7` and `Fn+F8` do nothing, while other Fn combos (e.g. `Fn+F3`)
work fine. This is a keyboard/firmware-level issue, not a GNOME workspace one
— do not conflate the two. Starting point:

```bash
sudo evtest /dev/input/event3     # internal keyboard
sudo evtest /dev/input/event12    # ASUS WMI hotkeys
```

Press Fn+F3 (known working) and Fn+F7 (broken) and compare what, if anything,
each emits and on which device.

## Side notes

- The Ubuntu Tiling Assistant conflict from `debug.md` is resolved — the
  package is no longer installed.
- Fn key "not working" in evtest is a red herring: Fn is handled by the
  keyboard firmware and never emits a keycode on its own; only Fn combos do.
  With ~20 `/dev/input/event*` devices on this machine, test with
  `sudo libinput debug-events --show-keycodes` (listens to all devices) —
  the internal keyboard is `event3`, ASUS WMI hotkeys arrive on `event12`.
