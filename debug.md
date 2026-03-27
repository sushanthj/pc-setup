## Debugging flaky GNOME extension

### Workspace Matrix Non-Responsive Key-Bindings

The most probable cause is Ubuntu tiling assistant and workspace matrix extensions both fighting for key-bindings.

Save and Run the below shell script to uninstall both extensions and cleanly install workspace matrix

```bash
#!/usr/bin/env bash

set -e

WSMATRIX_UUID="wsmatrix@martin.zurowietz.de"
WSMATRIX_DIR="$HOME/.local/share/gnome-shell/extensions/$WSMATRIX_UUID"
REPO_URL="https://github.com/mzur/gnome-shell-wsmatrix.git"

echo "===> STEP 1: Removing Workspace Matrix (if exists)..."
gnome-extensions disable "$WSMATRIX_UUID" 2>/dev/null || true
gnome-extensions uninstall "$WSMATRIX_UUID" 2>/dev/null || true
rm -rf "$WSMATRIX_DIR"

echo "===> STEP 2: Removing Ubuntu Tiling Assistant (if installed)..."
if dpkg -l | grep -q gnome-shell-extension-ubuntu-tiling-assistant; then
    sudo apt purge -y gnome-shell-extension-ubuntu-tiling-assistant
else
    echo "Tiling Assistant not installed via APT"
fi

echo "===> STEP 3: Cleaning GNOME extension cache..."
rm -rf ~/.cache/gnome-shell

echo "===> STEP 4: Cloning fresh Workspace Matrix..."
TMP_DIR=$(mktemp -d)
git clone "$REPO_URL" "$TMP_DIR"

echo "===> STEP 5: Installing Workspace Matrix..."
cd "$TMP_DIR"
make install

echo "===> STEP 6: Enabling Workspace Matrix..."
gnome-extensions enable "$WSMATRIX_UUID"

echo "===> STEP 7: Cleaning up temp files..."
rm -rf "$TMP_DIR"

echo "===> DONE."

echo ""
echo "======================================"
echo "👉 Restarting GNOME Shell..."
echo "======================================"

# Try to restart GNOME Shell (works on X11)
if [[ "$XDG_SESSION_TYPE" == "x11" ]]; then
    echo "Restarting GNOME (X11 detected)..."
    busctl call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'Meta.restart("reexec")' || true
else
    echo "⚠️ Wayland detected → cannot auto-restart GNOME"
    echo "👉 Please log out and log back in manually"
fi

echo ""
echo "✅ All done!"
```