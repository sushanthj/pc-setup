## Debugging flaky GNOME extension

### Workspace Matrix Non-Responsive Key-Bindings

```bash
mkdir -p ~/.config/autostart
nano ~/.config/autostart/restart-gnome-shell.desktop
```

```bash
[Desktop Entry]
Type=Application
Exec=bash -c "sleep 5 && gnome-extensions list | grep -q wsmatrix@ && gnome-extensions enable wsmatrix@"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Ensure Workspace Matrix Loaded
```