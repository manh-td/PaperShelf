# PaperShelf

Desktop app (Godot 4.7 + a Java helper process) for reading papers one sentence or line at a
time, like HighReader, with a small Zotero-style library (collections, tags). Mainly used
on Linux; developed on Windows.

## Layout

```
app/                         Godot project (GL Compatibility renderer, user dir "PaperShelf")
  scripts/pdf_bridge.gd      Autoload "Pdf": starts the helper and talks to it over a pipe
  scripts/library.gd         Autoload "Library": papers, collections, tags in library.json
  scripts/library_view.gd    Library screen: collections + tags | paper list | details
  scripts/main.gd            Shell: library <-> reader, opening (analysis) and theme
  scripts/reader_view.gd     Reader: modes, framing/zoom, async page textures, keyboard and mouse
  scripts/steps_builder.gd   Copied unchanged from HighReader: lines -> sentence/line/float steps
  scripts/settings_panel.gd  Settings overlay (fit, scrolling, colors, style, dim, skip side columns)
  scripts/contents_panel.gd  Contents drawer (left, keyboard-driven ItemList)
  scripts/comment_editor.gd  Comment editor (points, category list); cards are built in reader_view.gd
  scripts/review_view.gd     Review screen (merit + sections, saved as you type, export Markdown)
  scripts/review_builder.gd  Comments -> review sections; review -> Markdown
  helper/paperhelper.jar     Built helper (copied by Gradle; .gdignore keeps Godot out)
  tests/bridge_test.gd       Headless end-to-end check of the bridge and helper
  tests/reader_shots.gd      Windowed run: opens a PDF, presses reader keys, saves screenshots
  tests/panel_scroll_test.gd Windowed: wheel/touchpad over open Contents/Settings must not move the page
  tests/details_shot.gd      Windowed: screenshot of the details pane for a paper with no tags/collections
  tests/comment_test.gd      Windowed: commenting by typing, categories, points, edit, delete, re-attach
  tests/zoom_test.gd         Windowed: zoom (Ctrl+wheel, keys, top-bar control) survives the next sentence
  tests/selection_test.gd    Windowed: Free-mode drag selection, comment on it, click/Esc, categories
  tests/review_test.gd       Windowed: comments in each category -> locations -> review screen -> Markdown
  tests/locations_test.gd    Windowed: locations in front matter (title, abstract, CCS) and sections
  tests/library_test.gd      Headless library model checks (scratch folder)
  tests/library_shots.gd     Windowed library run: import, collections, tags, open, trash (scratch folder)
  tests/sentences_sample.gd, mode_switch_drift.gd   From HighReader; run on a cache JSON
pdf_helper/                  Kotlin/JVM Gradle project for the helper
  src/main/kotlin/com/papershelf/helper/
    Main.kt                  JSON-lines protocol on stdin/stdout: ping, open, render, close, info, analyze, quit
    TitleGuesser.kt          Title for new papers: PDF Title field if it looks real, else largest text on page 1
    PaperAnalyzer.kt         Copy of HighReader's analyzer (only PdfBox imports changed)
tools/make_test_pdf.ps1      Generates a synthetic two-column test paper
```

## Build and test (this machine)

Godot: `D:\Godot\Godot_v4.7.2-stable_win64_console.exe`. JDK 17: `C:\Program Files\Eclipse Adoptium\jdk-17.0.21.9-hotspot`.

1. Build the helper (JAVA_HOME = JDK 17): `pdf_helper\gradlew.bat -p pdf_helper copyJarToGodot`
2. Test: `Godot --headless --path app --script res://tests/bridge_test.gd -- <file.pdf> [--fresh]`
   (`--fresh` drops the cached analysis first).
3. Check scripts compile: `Godot --headless --path app --quit-after 30`.

## Linux package

`powershell -ExecutionPolicy Bypass -File tools\build_linux.ps1` builds
`build/PaperShelf-linux-x86_64.tar.gz` (~78 MB): helper jar, Godot export (preset "Linux",
pck embedded), and the Adoptium JRE 17 from `build/downloads/` as `PaperShelf/runtime/`.
- Needs Godot 4.7.2 export templates in `%APPDATA%\Godot\export_templates\4.7.2.stable`.
- Packing is the Gradle `packageLinux` task: it sets Unix modes (0755 for the app and the
  script, JRE modes kept from its tarball) and LF line endings, so it works from Windows.
- `tools/linux/`: README.txt and install-desktop-entry.sh (adds a menu entry) go into the package.
- Windows: `tools\build_windows.ps1` builds `build/PaperShelf-windows-x86_64.zip` (~84 MB) the same
  way (Gradle `packageWindows`, JRE zip from `build/downloads/`, README from `tools/windows/`).
  On Windows the bridge runs `javaw.exe` so no console window opens.
- `--verbose` prints "PDF helper ready: ... java=..., jar=..." to check which runtime was used.

## CI: building the packages on GitHub

`.github/workflows/build.yml` (manual trigger: Actions > "Build packages" > Run workflow).
On ubuntu-latest: JDK 17, Godot 4.7.2 editor + export templates (SHA-512 checked, cached),
Adoptium JRE 17 for Linux and Windows (SHA-256 checked), builds the helper jar, exports
both presets, runs `packageLinux packageWindows`, checks permissions and the bundled
runtime, then smoke-tests the Linux package (helper ping with the bundled Java, and the app
started headless must log "PDF helper ready"). Uploads both packages as artifacts and,
optionally, publishes a Release tagged `v<version>`.
- Inputs: `version_name` (file names; empty = `0.0-build<run number>`), `publish_release`.
- No secrets needed. Android is not built: PaperShelf has no Android backend yet.

## How the helper works

- `pdf_bridge.gd` runs `java -jar helper/paperhelper.jar` once. Java is looked up as
  `<app dir>/runtime/bin/java` (bundled runtime, for the Linux export), then `$JAVA_HOME/bin/java`, then `java` on PATH.
  The jar is looked up in `<app dir>/helper/`, then (editor only) `res://helper/`.
- open/render/close wait for their reply. Analysis runs on a helper thread and is polled
  (`analysis_state()`, `analysis_progress()`, `analysis_result()`), same API as HighReader's plugin.
- Rendering writes raw RGBA8 to `user://tmp/` and the bridge loads it into an Image.
- Analysis is cached in `user://cache/<file>_<size>_v<VERSION>.json` (same format as HighReader).
- The helper exits when its stdin closes, so it never outlives the app.
- `PaperAnalyzer.kt` started as HighReader's; bump `VERSION` when output changes. Changes since
  (v18, not yet in HighReader): bold also from TeX font names (Libertine/Biolinum `…TB`, `-Medi`,
  `Demi`, `Bd`), declared weight/ForceBold, or a thick stemV; unnumbered bold headings must look
  like titles (capital first, 3+ letters, no trailing ':'); a numbered section title ends a
  table/figure region. Found on ACM review-format papers (headings same size as body, bold
  only in "LinBiolinumTB"). Check Contents before/after on several papers when changing this.

## Reader (reader_view.gd)

- Same modes and steps as HighReader. Zoom is `view_scale` (px per page width); fits:
  `column` (default: the column fills READ_WIDTH * zoom), `text` (the highlight does), `width`, `page`.
  The zoom level (`zoom`, and `float_zoom` for Figures mode) is kept across steps and saved: Ctrl+wheel,
  pinch, Ctrl+=/−/0 and the top-bar `− 100% +` control all change it. Figures always fit their region
  (times `float_zoom`). `follow`: `center` keeps the highlight at 40% height, `minimal` scrolls only near the edges.
- Keys: →/↓/Space/Enter next, ←/↑/Shift+Space/Backspace back, PgDn/PgUp page, Home/End,
  Ctrl+1-4 mode, Ctrl+=/−/0 zoom, Tab contents, Ctrl+, settings, Ctrl+↓/↑ next/previous comment,
  Esc back. Any other printable key starts a comment, so plain letters/digits must never be shortcuts. Wheel steps (scrolls in Free), Ctrl+wheel zooms,
  click a word to jump, drag (or middle-drag) to look around. F11 fullscreen (main.gd).
- Bar buttons use FOCUS_NONE so arrow keys never move GUI focus; keys are read in `_unhandled_key_input`.
- Pages render asynchronously (`Pdf.request_render` / `take_render`), at most 2 at a time.
- Reading positions live in `<library root>/progress.cfg`, keyed by paper id. Reader settings are in
  `<library root>/settings.cfg` too, so tests with a scratch library never touch the real settings.

## Comments (comment_editor.gd, reader_view.gd, library.gd)

- Typing a character on a highlighted step opens the editor beside it (whole sentence, also
  when split across columns; or the line; or the figure). In Free mode a left drag that starts
  on text selects words (any line, captions too; `_flat_key_at`), typing comments on the
  selection, a click on commented text selects it, Esc clears; a drag from a blank area pans.
  Categories and colors: `comment_editor.gd` CATEGORIES / CATEGORY_COLORS. Enter adds a point (one level only),
  Tab opens the category list (type to filter, Enter/Tab picks), Ctrl+Enter saves, Esc discards,
  Backspace in an empty point removes it. Click a comment card to edit; empty + Ctrl+Enter deletes.
- Stored per paper in library.json: {id, kind (text|float), s, e (keys), quote, category, text,
  subs[], created, updated}. On open, a comment whose s..e text no longer equals its quote
  (e.g. after an analyzer VERSION bump) is re-attached to the same words nearest its old place.
- Commented text is underlined in the category color; Ctrl+↓/↑ jumps between comments.
  Cards start minimized (one line); Ctrl+M or a click on one shows them in full
  (`comments_expanded` in settings, kept until toggled); a click on a full card edits it.
  Library search also matches comment text.

## Reviews (review_view.gd, review_builder.gd)

- Per paper in library.json: `review` = {merit, sections{key: text}, included[comment ids], quotes}.
  Opened with Ctrl+R / the Review button (reader) or Write review (library); main.gd swaps screens.
- First open collects all comments; categories map to sections (`CATEGORY_SECTION`): list sections
  (Strengths, Weaknesses, Questions) get "- text (where: “quote”)" with points as sub-bullets,
  detail parts get "> where: “quote”" then the text and points, the summary is prose.
  "Add new comments" appends comments not in `included`; "Rebuild" refills those sections but
  keeps merit, intro and references. Export Markdown follows the usual review-form layout.
- Each comment's `where` comes from the reader (`_location_of`): numbered headings (Section /
  Subsection / Subsubsection) plus common unnumbered ones (Abstract, References, ...), the sentence
  number counted from the heading, and the page; figures/tables by their label. Updated on save
  and whenever the paper opens (`set_comment_quiet`). Before the first heading: "Abstract, sentence N" when
  `_find_abstract` finds an abstract without a heading (first run of 3 full-width text lines, up to
  CCS Concepts / Keywords / Index Terms ...), "Title and authors" above it, "Front matter" after it.
- Quotes never include "small" lines (margin line numbers are left out of the word index), and
  `pretty_quote` joins words split at a line end ("compre- hension" -> "compre-hension").

## Library (library.gd, library_view.gd)

- Storage (`user://`, i.e. `~/.local/share/PaperShelf` on Linux, `%APPDATA%\PaperShelf` on Windows):
  `library.json`, `papers/<id>.pdf` (copies), `cache/` (analysis), `progress.cfg`, `settings.cfg`.
- Zotero-like: a paper can be in several collections; collections nest at most
  `Library.MAX_NESTING` (2) levels below a top-level one (add, menu and drag-drop all check
  `can_add_subcollection` / `can_move_collection`); deleting a collection
  keeps its papers; Trash, then Delete permanently (removes the copy, cache and progress).
- Import copies the file, skips duplicates by MD5, and asks the helper (`info`) for a title.
- Clear cache (toolbar; paper menu for selected papers): `clear_cache(ids)` removes cache/*.json
  (and tmp/ when clearing all, incl. leftovers of deleted papers); nothing else is touched.
- Views: "all", "unfiled", "trash", "c:<id>"; tag filter is AND; search matches title, tags, file name.
- Keys: Enter open, Delete trash, F2 rename, Ctrl+O / Ctrl+Shift+O import, Ctrl+F search, Ctrl+N new collection.
- Tests use `Library.load_from(<scratch dir>)` so the real library is never touched.

## Conventions

- GDScript: explicit types where inference fails. UI is built in code.
