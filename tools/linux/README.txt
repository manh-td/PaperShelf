PaperShelf for Linux (x86_64)
=============================

Run:      ./PaperShelf.x86_64
Menu:     ./install-desktop-entry.sh   (adds PaperShelf to the application menu)

Everything the app needs is in this folder:
  PaperShelf.x86_64     the app
  helper/               the PDF engine (Java)
  runtime/              a Java 17 runtime used only by PaperShelf (no system Java needed)

Your library (papers, analysis cache, reading positions, settings) is stored in
  ~/.local/share/PaperShelf
Back up that folder to keep your library. Deleting this app folder does not touch it.

Requirements: a desktop with OpenGL 3.3. For the system's own file dialogs,
xdg-desktop-portal should be installed (it is on most desktops); otherwise
PaperShelf shows its own file dialog.

Keys in the library: Enter open, Delete trash, F2 rename, Ctrl+O import PDFs,
Ctrl+Shift+O import a folder, Ctrl+F search, Ctrl+N new collection, F11 fullscreen.
Keys in the reader: Right/Space next, Left back, PageDown/PageUp page, 1-4 mode,
+/- zoom, C contents, S settings, Esc back to the library.

Troubleshooting: run ./PaperShelf.x86_64 --verbose from a terminal to see the
PDF helper's messages.
