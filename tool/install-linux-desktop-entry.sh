#!/usr/bin/env bash
# Installs the TryCatch .desktop entry + hicolor icons into ~/.local/share so
# Wayland compositors (e.g. KWin on KDE Plasma) can match running windows
# (app_id com.krychlic.trycatch) to the app name and icon — including windows
# started via `flutter run`, which otherwise show a generic Wayland icon.
#
# NOTE: gtk_window_set_icon() is X11-only; on Wayland the icon ALWAYS comes
# from the icon theme via this desktop entry. Re-run after icon changes.
# The menu launcher Exec=trycatch assumes the release binary is on PATH
# (AppImage/tarball install); icon association for already-running windows
# works regardless of Exec.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_ID="com.krychlic.trycatch"
DEST_APPS="$HOME/.local/share/applications"
DEST_ICONS="$HOME/.local/share/icons"

mkdir -p "$DEST_APPS"
cp "packaging/linux/${APP_ID}.desktop" "$DEST_APPS/"

# hicolor/<size>/apps/<app-id>.png -> ~/.local/share/icons/…
cp -a packaging/linux/icons/hicolor/. "$DEST_ICONS/hicolor/"
# gtk-update-icon-cache needs the stock hicolor index.theme; seed it from
# the system copy if the user theme dir doesn't have one yet.
if [ ! -f "$DEST_ICONS/hicolor/index.theme" ] && [ -f /usr/share/icons/hicolor/index.theme ]; then
  cp /usr/share/icons/hicolor/index.theme "$DEST_ICONS/hicolor/index.theme"
fi

command -v gtk-update-icon-cache >/dev/null &&
  gtk-update-icon-cache -f -t "$DEST_ICONS/hicolor" || true
command -v update-desktop-database >/dev/null &&
  update-desktop-database "$DEST_APPS" || true

echo "Installed ${APP_ID}.desktop + icons to ~/.local/share."
echo "Restart the app (flutter run) — the task manager should show the TryCatch icon."
