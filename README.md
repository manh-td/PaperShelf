# PaperShelf

A desktop app for reading research papers and books one sentence (or line) at a time: the
current sentence is highlighted and the rest of the page is dimmed, and the arrow keys move
through the text. A small Zotero-style library keeps papers in collections with tags.

Built with Godot 4.7 and a Java PDF helper (Apache PDFBox) that analyzes page layout:
columns, reading order, headings, figures and tables. Based on the reader of HighReader.

## Download

GitHub > Actions > **Build packages** > Run workflow builds both packages (and, if ticked,
publishes them as a Release). Each includes its own Java runtime.

- **Linux (x86_64):** `tar -xzf PaperShelf-*-linux-x86_64.tar.gz`, run `PaperShelf/PaperShelf.x86_64`.
  `./install-desktop-entry.sh` adds it to the application menu.
- **Windows (x64):** unzip, run `PaperShelf\PaperShelf.exe`.

The library lives in `~/.local/share/PaperShelf` (Linux) or `%APPDATA%\PaperShelf` (Windows),
outside the app folder, so updating is just unpacking the new version.

## Keys

| Library | | Reader | |
|---|---|---|---|
| Enter | open | → / Space / Enter | next sentence |
| Delete | move to Trash | ← / Shift+Space | back |
| F2 | rename | PageDown / PageUp | next / previous page |
| Ctrl+O | import PDFs | Ctrl+1 2 3 4 | Sentence / Line / Figures / Free |
| Ctrl+Shift+O | import a folder | Ctrl+= / Ctrl+− / Ctrl+0 | zoom |
| Ctrl+F | search | Tab | contents |
| Ctrl+N | new collection | Ctrl+, | settings |
| F11 | fullscreen | Ctrl+↓ / Ctrl+↑ | next / previous comment |
| | | Esc | back to the library |

Drag papers onto a collection to file them; drop PDFs or folders on the window to import.

## Comments

While reading, just start typing: the comment goes on the highlighted sentence (or line,
or figure). Enter adds a point under the comment (one level), Tab picks a category
(Presentation, Rigor/Soundness, Verifiability, Novelty, Significance, Others; type `pre`
to pick Presentation), Ctrl+Enter saves, Esc discards. Commented sentences are underlined
in their category's color and their comments show beside the highlight: click one to edit
it (empty it and press Ctrl+Enter to delete it). Comments stay in the library, never in the PDF.

## Building locally (Windows)

Needs Godot 4.7.2 with export templates, and JDK 17.

```
pdf_helper\gradlew.bat -p pdf_helper copyJarToGodot     # build the PDF helper
powershell -ExecutionPolicy Bypass -File tools\build_linux.ps1
powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1
```

The packaging scripts expect the Adoptium JRE 17 archives (Linux `.tar.gz`, Windows `.zip`)
in `build/downloads/`. See [CLAUDE.md](CLAUDE.md) for the architecture and tests.
