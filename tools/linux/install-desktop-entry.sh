#!/bin/sh
# Adds PaperShelf to the application menu (for the current user only).
# Run it from the PaperShelf folder after unpacking: ./install-desktop-entry.sh
# Run it again if you move the folder.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
cat > "$APPS/papershelf.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PaperShelf
Comment=Read papers one sentence at a time
Exec="$DIR/PaperShelf.x86_64"
Icon=$DIR/icon.svg
Terminal=false
Categories=Office;Education;Viewer;
MimeType=application/pdf;
EOF
chmod +x "$DIR/PaperShelf.x86_64" "$DIR/runtime/bin/java"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" || true
echo "Added PaperShelf to the application menu ($APPS/papershelf.desktop)."
