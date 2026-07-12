# Changelog

All notable changes to Margins are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Watch mode**: point Margins at a folder — `margins -w .`, **File → Watch
  Folder…** (⇧⌘O), or drop/open a folder — and it keeps showing the most
  recently written Markdown file under it, switching automatically as your
  agent moves between files. Hidden folders and `node_modules` are ignored,
  a file must be meaningfully newer to steal the view (no flapping when two
  files are written in alternation), and watching an empty folder waits for
  the first Markdown file to appear. Watching turns Live and Follow on;
  opening a file explicitly (or turning Live off) stops the watch.

### Fixed
- Switching to a much shorter document (watch mode auto-switch, or a hook
  opening a different file) no longer shows a blank window when the previous
  document had been scrolled or followed past the shorter one's end.

## [1.1.2] - 2026-07-11

### Fixed
- Hard-wrapped list items (a bullet continued on indented lines) render as a
  single item again instead of a one-line bullet followed by a stray
  full-width paragraph. Ordered and task-list items included.
- Inline code spans get a little horizontal padding, so the card background
  no longer sits flush against the first and last glyph.
- Opening a file that's already showing (e.g. an agent hook firing
  `margins -g` on every save) reuses the existing window instead of stacking
  up duplicate windows — one per open event.
- The file watcher no longer leaks a file descriptor each time the watched
  file changes identity (new file opened, or an atomic save replacing it).
  Under a rapid save loop the leak could eventually exhaust descriptors and
  silently stop live reload.

## [1.1.1] - 2026-07-10

### Added
- `margins -g` opens in the background without stealing focus — built for
  editor and agent hooks (the README shows a Claude Code auto-open recipe).
- `margins <dir>` (so `margins .` works) opens the newest Markdown file under
  a directory, skipping hidden folders and `node_modules`.

### Internal
- The CLI shim now has tests: `scripts/test_cli.sh` exercises it in a dry-run
  mode (`MARGINS_DRY_RUN=1`) and runs as part of `scripts/test.sh`.

## [1.1.0] - 2026-07-09

### Added
- **Follow mode**: a Follow pill in the header keeps the end of the document
  in view as the file grows — made for watching AI tools stream output into a
  file. Scrolling up detaches; the pill re-attaches. Follow implies Live.
- **`margins` CLI**: a small launcher shipped inside the app bundle (linked
  into PATH by the Homebrew cask). `margins file.md` opens files;
  `some-cmd | margins -` renders piped Markdown, streaming live as it arrives.
- **Task lists**: `- [ ]` / `- [x]` items render with read-only checkboxes;
  the per-block copy button preserves the `[x]` state.

## [1.0.4] - 2026-07-09

### Added
- YAML frontmatter: a leading `---` block is rendered as a metadata panel
  (key/value pairs) instead of leaking in as a rule + paragraph. Simple
  scalars, inline `[a, b]` lists, and `- item` block lists are recognized.

## [1.0.3] - 2026-06-21

### Added
- VoiceOver accessibility: labels on the toolbar and Find controls, and
  headings exposed as headers so the document is navigable by the rotor.

### Changed
- Find recompute is debounced on large documents so typing stays smooth.

### Internal
- Extracted the SwiftUI-free search core into `MarkdownSearch.swift` and added
  unit tests for it; bumped CI `actions/checkout` to v5.

## [1.0.2] - 2026-06-21

### Added
- In-document **Find** (⌘F): live, case-insensitive search across every block
  type, with match highlighting, keyboard navigation (⌘G / ⇧⌘G), and
  scroll-to-match.

### Fixed
- The Live and Copy toolbar pills are now clickable across their whole area,
  not just the icon/text.

## [1.0.1] - 2026-06-21

### Added
- Copy affordances: a "Copy document as Markdown" button + ⇧⌘C, and a per-block
  hover **Copy** on prose, lists, tables, callouts, and code blocks.

## [1.0.0] - 2026-06-21

### Added
- Initial release: a native, zero-dependency macOS Markdown reader with live
  reload, light/dark themes, robust file handling, and a signed + notarized DMG
  plus a Homebrew cask.

[Unreleased]: https://github.com/Chrismacolor/margins/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/Chrismacolor/margins/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/Chrismacolor/margins/compare/v1.0.4...v1.1.0
[1.0.4]: https://github.com/Chrismacolor/margins/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/Chrismacolor/margins/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/Chrismacolor/margins/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Chrismacolor/margins/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Chrismacolor/margins/releases/tag/v1.0.0
