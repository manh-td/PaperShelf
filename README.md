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
| Ctrl+Shift+O | import a folder | Ctrl+wheel, Ctrl+= / Ctrl+− / Ctrl+0 | zoom (kept as you read on) |
| Ctrl+F | search | Tab | contents |
| Ctrl+N | new collection | Ctrl+, | settings |
| F11 | fullscreen | Ctrl+↓ / Ctrl+↑ | next / previous comment |
| | | Ctrl+M | minimize / expand comment cards |
| | | Ctrl+R | review (put the comments together) |
| | | Esc | back to the library |

Drag papers onto a collection to file them; drop PDFs or folders on the window to import.

**Clear cache…** (library toolbar) removes the cached page analysis; papers, comments, reviews,
tags and reading positions are kept, and each paper is analyzed again when next opened.
Right-click papers > **Clear cached analysis** does it for just those papers.

## Comments

While reading, just start typing: the comment goes on the highlighted sentence (or line,
or figure). In Free mode, first drag across the text you want, then type. Enter adds a
point under the comment (one level), Tab picks a category (Paper summary, Strength,
Weakness, Question, Presentation, Rigor/Soundness, Verifiability, Novelty, Significance,
Others; type `pre` to pick Presentation, `we` for Weakness), Ctrl+Enter saves, Esc discards. Commented sentences are underlined
in their category's color and their comments show beside the highlight, minimized to one
line each (Ctrl+M or a click shows them in full; click a full card to edit
it (empty it and press Ctrl+Enter to delete it). Comments stay in the library, never in the PDF.

## Reviews

When you have commented a paper, press **Ctrl+R** in the reader (or **Write review** in the
library). The Review screen puts your comments together like a conference review:
Overall merit, Paper summary, Strengths, Weaknesses, Detailed comments for authors
(Originality/Novelty, Significance, Soundness, Verifiability, Presentation, Other),
Questions for authors' response and References. Each item quotes the commented text and
where it is, e.g. *Section 2 (Methodology), Subsection 2.1 (Study Setup), sentence 2, p. 4*.
Edit everything there (it is saved as you type). Sections you have not edited follow your
comments automatically: new comments, edited ones and changed categories show up each time
the review opens. A section you edited is kept; when its comments change, a note offers
**Update from comments**. **Rebuild…** refreshes every section, and **Export Markdown…** saves
the review as a `.md` file.

## Building locally (Windows)

Needs Godot 4.7.2 with export templates, and JDK 17.

```
pdf_helper\gradlew.bat -p pdf_helper copyJarToGodot     # build the PDF helper
powershell -ExecutionPolicy Bypass -File tools\build_linux.ps1
powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1
```

The packaging scripts expect the Adoptium JRE 17 archives (Linux `.tar.gz`, Windows `.zip`)
in `build/downloads/`. See [CLAUDE.md](CLAUDE.md) for the architecture and tests.
