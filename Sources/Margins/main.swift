import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme

/// Color palette ported verbatim from md-viewer-py's CSS custom properties
/// (`01-base.css` dark `:root` and `07-theme.css` `body.light`).
struct Theme {
    let bg: Color
    let surface: Color
    let card: Color
    let hover: Color
    let border: Color
    let text: Color
    let textMuted: Color
    let textHeading: Color
    let accent: Color
    let green: Color
    let amber: Color
    let red: Color
    let cyan: Color

    static let dark = Theme(
        bg: Color(hex: 0x0f1117),
        surface: Color(hex: 0x161922),
        card: Color(hex: 0x1c1f2e),
        hover: Color(hex: 0x242838),
        border: Color(hex: 0x2a2e3f),
        text: Color(hex: 0xe1e4ed),
        textMuted: Color(hex: 0x8b90a5),
        textHeading: Color(hex: 0xf5f7fb),
        accent: Color(hex: 0x7c8aff),
        green: Color(hex: 0x4ade80),
        amber: Color(hex: 0xfbbf24),
        red: Color(hex: 0xf87171),
        cyan: Color(hex: 0x22d3ee)
    )

    static let light = Theme(
        bg: Color(hex: 0xffffff),
        surface: Color(hex: 0xf6f8fa),
        card: Color(hex: 0xf0f2f5),
        hover: Color(hex: 0xe8eaed),
        border: Color(hex: 0xd0d7de),
        text: Color(hex: 0x24292f),
        textMuted: Color(hex: 0x57606a),
        textHeading: Color(hex: 0x1c2128),
        accent: Color(hex: 0x0969da),
        green: Color(hex: 0x1a7f37),
        amber: Color(hex: 0x9a6700),
        red: Color(hex: 0xcf222e),
        cyan: Color(hex: 0x0550ae)
    )
}

extension Color {
    init(hex: UInt) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Model

/// Watches a single file for on-disk changes and reports them after a short
/// debounce. Re-establishes the watch when the file is replaced via an atomic
/// save (editors that write-then-rename invalidate the original descriptor).
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.disanto.margins.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingNotify: DispatchWorkItem?

    init?(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        guard start() else { return nil }
    }

    deinit { stop() }

    @discardableResult
    private func start() -> Bool {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.restart()
            }
            self.scheduleNotify()
        }

        // Capture the descriptor by value: the handler runs asynchronously
        // after cancel(), by which point a deinit-triggered cancel has already
        // deallocated self — a weak capture would silently leak the fd.
        let fd = fileDescriptor
        source.setCancelHandler { close(fd) }

        self.source = source
        source.resume()
        return true
    }

    /// An atomic save replaced the file at this path; rebuild the watch on it.
    private func restart() {
        source?.cancel()
        source = nil
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.start()
        }
    }

    /// Coalesce bursts of write events into a single reload.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingNotify = item
        queue.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func stop() {
        pendingNotify?.cancel()
        pendingNotify = nil
        source?.cancel()
        source = nil
    }
}

/// Watches a directory tree recursively via FSEvents and reports each
/// coalesced batch of changed paths. It only observes — deciding *which*
/// Markdown file to show stays with ViewerModel + FolderScan, and reloading
/// the shown file's content stays with FileWatcher.
///
/// FSEvents rather than a DispatchSource because a dispatch source on a
/// directory descriptor only reports direct children, and agents write into
/// subdirectories. The stream's latency doubles as the change debounce.
final class DirectoryWatcher {
    /// The stream context points at this box, retained by the stream itself,
    /// instead of at the watcher. A callback racing deinit then reads a zeroed
    /// weak reference rather than a dangling pointer.
    private final class Box {
        weak var owner: DirectoryWatcher?
    }

    private let onEvents: ([String]) -> Void
    private let queue = DispatchQueue(label: "com.disanto.margins.dirwatcher")
    private var stream: FSEventStreamRef?

    init?(directory: URL, onEvents: @escaping ([String]) -> Void) {
        self.onEvents = onEvents

        let box = Box()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            guard let owner = box.owner,
                  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]
            else { return }
            owner.onEvents(paths)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // seconds FSEvents coalesces before calling back
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            // Creation failed, so the stream will never run the release
            // callback; balance the passRetained ourselves.
            Unmanaged.passUnretained(box).release()
            return nil
        }
        box.owner = self
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream) // releases the context's Box
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var markdownSource = "" {
        didSet { reparse() }
    }
    /// Theme-independent parsed blocks. Colors/fonts are applied later in the
    /// views, so a theme switch never triggers a re-parse.
    @Published var blocks: [RenderedBlock] = [] {
        didSet { parseTick += 1 }
    }
    /// Bumped on every `blocks` assignment (sync and async parse paths alike).
    /// Follow mode keys off this rather than `blocks.count`, which misses the
    /// "last block grew" case while a stream appends to one paragraph.
    @Published private(set) var parseTick = 0
    /// Non-blocking banner message (large/truncated file, file removed, etc.).
    @Published var notice: String?
    /// Non-nil while watch mode is active: the folder whose newest Markdown
    /// file the viewer keeps showing.
    @Published private(set) var watchedFolder: URL?

    private var watcher: FileWatcher?
    private var folderWatcher: DirectoryWatcher?
    private var liveReloadEnabled = true
    private var parseGeneration = 0

    /// Hard cap on how much of a file we load, to keep memory bounded. Files
    /// above this are truncated with a notice — protecting the "low resource"
    /// promise against pathologically large inputs.
    private static let maxBytes = 20_000_000

    /// Re-parse markdown into theme-independent blocks. Small documents parse
    /// synchronously (instant); large ones parse on a background task so the UI
    /// never blocks. Stale async results are discarded via a generation token.
    private func reparse() {
        parseGeneration += 1
        let gen = parseGeneration
        let src = markdownSource
        if src.utf8.count < 100_000 {
            blocks = MarkdownRenderer.parse(src)
            return
        }
        Task.detached(priority: .userInitiated) {
            let parsed = MarkdownRenderer.parse(src)
            await MainActor.run { [weak self] in
                guard let self, gen == self.parseGeneration else { return }
                self.blocks = parsed
            }
        }
    }

    /// Routes any incoming URL (Finder, CLI, drop, URL scheme): a directory
    /// enters watch mode, a file opens directly.
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            watchFolder(url)
        } else {
            openFile(url)
        }
    }

    /// Opening a specific file is an explicit choice to leave watch mode.
    func openFile(_ url: URL) {
        stopWatchingFolder()
        display(url)
    }

    private func display(_ url: URL) {
        do {
            let (text, banner) = try loadContents(of: url)
            notice = banner
            markdownSource = text
            fileURL = url
            if liveReloadEnabled { startWatching(url) }
        } catch {
            notice = nil
            markdownSource = "Could not open \(url.lastPathComponent).\n\n\(error.localizedDescription)"
            fileURL = nil
            watcher = nil
        }
    }

    /// Reads a file with a size guard and an encoding fallback chain. Returns the
    /// text plus an optional banner (e.g. when the file was truncated).
    private func loadContents(of url: URL) throws -> (String, String?) {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = handle.readData(ofLength: Self.maxBytes)
            let mb = size / 1_000_000
            return (decodeText(data),
                    "Large file (\(mb) MB) — showing the first \(Self.maxBytes / 1_000_000) MB for performance.")
        }
        return (decodeText(try Data(contentsOf: url)), nil)
    }

    /// Decodes bytes as UTF-8, then (only if a UTF-16 BOM is present) UTF-16,
    /// then the common single-byte encodings. UTF-16 is gated on a BOM because
    /// it "succeeds" on arbitrary byte pairs and would otherwise yield mojibake.
    private func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return s
        }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Turns live reload on or off, tearing down or rebuilding the watcher for
    /// the open file. Re-enabling catches up on any change missed while paused.
    func setLiveReload(_ enabled: Bool) {
        liveReloadEnabled = enabled
        if enabled {
            if let url = fileURL { startWatching(url) }
            reloadFromDisk()
        } else {
            watcher = nil
            // Watch mode without live reload would silently show stale
            // content while claiming to track the folder.
            stopWatchingFolder()
        }
    }

    /// Enters watch mode: shows the newest Markdown file under `folder` and
    /// keeps switching to whichever eligible file was written most recently.
    func watchFolder(_ folder: URL) {
        stopWatchingFolder()
        folderWatcher = DirectoryWatcher(directory: folder) { [weak self] paths in
            Task { @MainActor in self?.watchedFolderDidChange(paths) }
        }
        guard folderWatcher != nil else {
            notice = "Can’t watch \(folder.lastPathComponent) — the folder may not be accessible."
            return
        }
        watchedFolder = folder
        if let newest = FolderScan.newestMarkdown(under: folder) {
            display(newest.url)
        } else {
            // Nothing to show yet — stay in watch mode; the first Markdown
            // file written under the folder will appear on its own.
            fileURL = nil
            markdownSource = ""
            watcher = nil
            notice = "Watching \(folder.lastPathComponent) — no Markdown files yet."
        }
    }

    func stopWatchingFolder() {
        folderWatcher = nil
        watchedFolder = nil
    }

    /// A coalesced FSEvents batch arrived for the watched folder. Ignore it
    /// unless it plausibly changes which file is newest, then rescan and apply
    /// the switch policy.
    private func watchedFolderDidChange(_ paths: [String]) {
        guard let root = watchedFolder else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            stopWatchingFolder()
            notice = "\(root.lastPathComponent) is no longer available — stopped watching."
            return
        }
        // A directory rename/removal reports the directory's path, not each
        // file inside it, so "current file vanished" is its own trigger.
        let currentGone = fileURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard currentGone || paths.contains(where: { FolderScan.isEligibleEventPath($0, root: root.path) })
        else { return }

        guard let newest = FolderScan.newestMarkdown(under: root) else {
            // No Markdown left; reloadFromDisk's banner already covers a
            // deleted current file. Keep watching for the next one.
            return
        }
        if newest.url == fileURL { return } // content reloads are FileWatcher's job
        let current = fileURL.flatMap(modificationDate(of:))
        if FolderScan.shouldSwitch(currentModified: current, candidateModified: newest.modified) {
            display(newest.url)
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func startWatching(_ url: URL) {
        // Reassigning releases the previous watcher, which cancels its source.
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
    }

    /// Re-reads the open file after a live change; no-op if the content matches.
    /// Surfaces a banner (instead of silently showing stale content) when the
    /// file has been deleted or can no longer be read.
    func reloadFromDisk() {
        guard let url = fileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            notice = "\(url.lastPathComponent) is no longer available on disk."
            return
        }
        do {
            let (text, banner) = try loadContents(of: url)
            notice = banner
            if text != markdownSource { markdownSource = text }
        } catch {
            notice = "Can’t read \(url.lastPathComponent) — it may have moved or its permissions changed."
        }
    }

    func pickFileFromDisk() {
        let panel = NSOpenPanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType, .plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    /// Registers this app as the system-default opener for Markdown files —
    /// the in-app replacement for Finder's Get Info → Change All ritual.
    /// The three extensions usually collapse to one UTType
    /// (net.daringfireball.markdown), so the Set keeps it to a single
    /// LaunchServices call; macOS may show its own confirmation dialog.
    func makeDefaultMarkdownApp() {
        let types = Set(["md", "markdown", "mdown"].compactMap { UTType(filenameExtension: $0) })
        guard !types.isEmpty else { return }

        let group = DispatchGroup()
        var failure: Error?
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { error in
                // Completions arrive on an arbitrary queue; funnel through
                // main so the error write and the notify below are ordered.
                DispatchQueue.main.async {
                    if let error { failure = error }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.notice = failure == nil
                ? "Margins is now the default app for Markdown files."
                : "Margins wasn’t made the default — the change may have been declined."
        }
    }

    func pickFolderToWatch() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Margins will keep showing the newest Markdown file under the chosen folder."

        if panel.runModal() == .OK, let url = panel.url {
            watchFolder(url)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenFiles: (([URL]) -> Void)?

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        onOpenFiles?(urls)
        application.reply(toOpenOrPrint: .success)
    }
}

// MARK: - Renderer styling
//
// The Markdown model and parser live in MarkdownRenderer.swift (SwiftUI-free so
// it can be unit-tested standalone). The view-facing color mapping lives here.

/// Maps callout kinds to theme colors.
extension CalloutKind {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .note: return theme.accent
        case .tip: return theme.green
        case .important: return theme.accent
        case .warning: return theme.amber
        case .caution: return theme.red
        case .plain: return theme.textMuted
        }
    }
}

/// Font sizes ported from md-viewer-py's `05-content.css`.
private enum FontSize {
    static let body: Double = 14
    static let h1: Double = 30
    static let h2: Double = 21
    static let h3: Double = 16
    static let h4: Double = 13.5
    static let h5: Double = 13
    static let h6: Double = 12.5
    static let inlineCode: Double = 12.5
    static let codeBlock: Double = 12.5
    static let tableHeader: Double = 11
    static let tableCell: Double = 13.5

    static func heading(_ level: Int) -> Double {
        switch level {
        case 1: return h1
        case 2: return h2
        case 3: return h3
        case 4: return h4
        case 5: return h5
        default: return h6
        }
    }
}

// MARK: - Block views

private func readingLineSpacing(for size: Double) -> Double {
    // Approximates the reference's `line-height: 1.65` on top of the default leading.
    max(3, size * 0.45)
}

/// Applies theme colors and fonts to parsed (theme-independent) inline text.
/// Cheap — runs at view time, so a theme switch restyles without re-parsing.
private func styledInline(
    _ raw: AttributedString,
    size: Double,
    weight: Font.Weight = .regular,
    baseColor: Color,
    theme: Theme
) -> AttributedString {
    var inline = raw
    inline.font = .system(size: size, weight: weight)
    inline.foregroundColor = baseColor

    for run in inline.runs {
        // Links render in the accent color (the reference uses `color: var(--accent)`).
        if run.link != nil {
            inline[run.range].foregroundColor = theme.accent
        }
        guard let intent = run.inlinePresentationIntent else { continue }
        if intent.contains(.code) {
            inline[run.range].font = .system(size: FontSize.inlineCode, weight: .regular, design: .monospaced)
            inline[run.range].foregroundColor = theme.cyan
            inline[run.range].backgroundColor = theme.card
        } else if intent.contains(.stronglyEmphasized) {
            inline[run.range].font = .system(size: size, weight: .bold)
        } else if intent.contains(.emphasized) {
            inline[run.range].font = .system(size: size, weight: weight).italic()
        }
    }
    return inline
}

private struct DashedRule: View {
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let y = lineWidth / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: [4, 3]))
        }
        .frame(height: lineWidth)
    }
}

private struct FrontmatterView: View {
    let fields: [FrontmatterField]
    let theme: Theme
    var blockID: Int = 0
    var find: FindHighlight = .inactive(.dark)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(field.key.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                        .frame(width: 92, alignment: .leading)
                    Text(preparedForDisplay(styledValue(field.value), segmentID: "\(blockID)#F\(index)", find: find))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func styledValue(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.font = .system(size: FontSize.body)
        a.foregroundColor = theme.text
        return a
    }
}

private struct HeadingView: View {
    let level: Int
    let inline: AttributedString
    let theme: Theme
    var segmentID: String = ""
    var find: FindHighlight = .inactive(.dark)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preparedForDisplay(styled, segmentID: segmentID, find: find))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if level == 1 {
                DashedRule(color: theme.border, lineWidth: 2)
            } else if level == 2 {
                DashedRule(color: theme.border, lineWidth: 1)
            }
        }
        .padding(.top, topPadding)
    }

    private var styled: AttributedString {
        // h4+ render in the accent color per the reference CSS; rest use heading color.
        let weight: Font.Weight = level == 1 ? .heavy : (level == 2 ? .bold : .semibold)
        let color = level >= 4 ? theme.accent : theme.textHeading
        return styledInline(inline, size: FontSize.heading(level), weight: weight, baseColor: color, theme: theme)
    }

    private var topPadding: CGFloat {
        switch level {
        case 1: return 8
        case 2: return 28
        case 3: return 16
        default: return 12
        }
    }
}

private struct ListView: View {
    let rows: [ListItem]
    let theme: Theme
    var blockID: Int = 0
    var find: FindHighlight = .inactive(.dark)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    markerView(for: row)
                        .font(.system(size: FontSize.body))
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(preparedForDisplay(
                        styledInline(row.inline, size: FontSize.body, baseColor: theme.text, theme: theme),
                        segmentID: "\(blockID)#L\(index)", find: find))
                        .lineSpacing(readingLineSpacing(for: FontSize.body))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(row.indent) * 18)
            }
        }
    }

    /// Bullet/number text, or a checkbox symbol for task items. Wrapping the
    /// Image in Text keeps a real baseline for the .firstTextBaseline HStack.
    private func markerView(for row: ListItem) -> Text {
        if let checked = row.checkbox {
            return Text(Image(systemName: checked ? "checkmark.square.fill" : "square"))
                .foregroundColor(checked ? theme.accent : theme.textMuted)
        }
        return Text(row.marker).foregroundColor(theme.textMuted)
    }
}

private struct CalloutView: View {
    let kind: CalloutKind
    let inline: AttributedString
    let theme: Theme
    var segmentID: String = ""
    var find: FindHighlight = .inactive(.dark)

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(kind.color(theme))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if let title = kind.title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind.color(theme))
                }
                Text(preparedForDisplay(
                    styledInline(inline, size: FontSize.body, baseColor: theme.text, theme: theme),
                    segmentID: segmentID, find: find))
                    .lineSpacing(readingLineSpacing(for: FontSize.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Spacer(minLength: 0)
        }
        .background(kind.color(theme).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MarkdownTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [HAlign]
    let theme: Theme
    var blockID: Int = 0
    var find: FindHighlight = .inactive(.dark)

    private var columnCount: Int { header.count }

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                    cellView(cell, column: index, isHeader: true, segmentID: "\(blockID)#H\(index)")
                        .background(theme.card)
                }
            }
            rowDivider
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cellView(column < row.count ? row[column] : AttributedString(""),
                                 column: column, isHeader: false,
                                 segmentID: "\(blockID)#R\(rowIndex)C\(column)")
                    }
                }
                if rowIndex < rows.count - 1 {
                    rowDivider
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
            .gridCellColumns(max(1, columnCount))
    }

    private func cellView(_ raw: AttributedString, column: Int, isHeader: Bool, segmentID: String) -> some View {
        let styled = isHeader
            ? styledInline(raw, size: FontSize.tableHeader, weight: .semibold, baseColor: theme.textMuted, theme: theme)
            : styledInline(raw, size: FontSize.tableCell, baseColor: theme.text, theme: theme)
        return Text(preparedForDisplay(styled, segmentID: segmentID, find: find))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: alignment(for: column))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    private func alignment(for column: Int) -> Alignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let rawLines: [String]
    let theme: Theme
    var segmentID: String = ""
    var find: FindHighlight = .inactive(.dark)

    @State private var isHovering = false
    @State private var copied = false

    private var display: AttributedString {
        var s = AttributedString(rawLines.joined(separator: "\n"))
        s.font = .system(size: FontSize.codeBlock, weight: .regular, design: .monospaced)
        s.foregroundColor = theme.text
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textMuted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(preparedForDisplay(display, segmentID: segmentID, find: find))
                    .lineSpacing(readingLineSpacing(for: FontSize.codeBlock))
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    setPasteboard(rawLines.joined(separator: "\n"))
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? theme.green : theme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(copied ? theme.green : theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity)
                .accessibilityLabel("Copy code")
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

// MARK: - Copy support

/// Replace the general pasteboard with `string`.
private func setPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// A small "Copy" chip that fades in at the top-trailing corner on hover,
/// mirroring the affordance built into `CodeBlockView`.
private struct HoverCopyButton: ViewModifier {
    let text: String
    let theme: Theme

    @State private var isHovering = false
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isHovering && !text.isEmpty {
                    Button {
                        setPasteboard(text)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? theme.green : theme.textMuted)
                            .padding(5)
                            .background(theme.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(copied ? theme.green : theme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help(copied ? "Copied" : "Copy this block")
                    .accessibilityLabel("Copy this block")
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            }
    }
}

private extension View {
    /// Adds a hover-to-copy chip carrying `text`.
    func copyableOnHover(_ text: String, theme: Theme) -> some View {
        modifier(HoverCopyButton(text: text, theme: theme))
    }
}

// MARK: - Find

// `FindMatch`, `collectMatches`, and `plainText(of:)` live in the SwiftUI-free
// MarkdownSearch.swift so they can be unit-tested standalone.

/// The bits a leaf view needs to highlight its own text. Value-typed so it
/// flows through the existing per-block views alongside `theme`.
struct FindHighlight {
    let query: String
    let currentSegmentID: String
    let currentStart: Int
    let theme: Theme

    static func inactive(_ theme: Theme) -> FindHighlight {
        FindHighlight(query: "", currentSegmentID: "", currentStart: -1, theme: theme)
    }
}

/// Search state for the active window. App-scoped (like `ViewerModel`) so the
/// Find menu commands can reach it.
final class FindModel: ObservableObject {
    @Published var isActive = false
    @Published var query = ""
    @Published private(set) var matches: [FindMatch] = []
    @Published var currentIndex = 0

    var current: FindMatch? {
        matches.indices.contains(currentIndex) ? matches[currentIndex] : nil
    }

    func setMatches(_ m: [FindMatch]) {
        matches = m
        currentIndex = 0
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    func close() {
        isActive = false
        query = ""
        matches = []
        currentIndex = 0
    }

    func highlight(theme: Theme) -> FindHighlight {
        guard isActive else { return .inactive(theme) }
        return FindHighlight(
            query: query,
            currentSegmentID: current?.segmentID ?? "",
            currentStart: current?.start ?? -1,
            theme: theme
        )
    }
}

/// Final display-preparation for a leaf `Text`: paints search-match backgrounds
/// (the current match solid with inverted text, the rest a translucent amber
/// wash) and then pads inline-code spans. Called just before every leaf Text.
private func preparedForDisplay(
    _ styled: AttributedString,
    segmentID: String,
    find: FindHighlight
) -> AttributedString {
    var result = styled
    if !find.query.isEmpty {
        let plain = String(styled.characters)
        var searchRange = plain.startIndex..<plain.endIndex
        while let r = plain.range(of: find.query, options: .caseInsensitive, range: searchRange) {
            let startOff = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let length = plain.distance(from: r.lowerBound, to: r.upperBound)
            let lo = result.index(result.startIndex, offsetByCharacters: startOff)
            let hi = result.index(lo, offsetByCharacters: length)
            let isCurrent = segmentID == find.currentSegmentID && startOff == find.currentStart
            if isCurrent {
                result[lo..<hi].backgroundColor = find.theme.amber
                result[lo..<hi].foregroundColor = find.theme.bg
            } else {
                result[lo..<hi].backgroundColor = find.theme.amber.opacity(0.32)
            }
            searchRange = r.upperBound..<plain.endIndex
        }
    }
    return paddedInlineCode(result, theme: find.theme)
}

/// Pads each inline-code span with a narrow no-break space on both sides, styled
/// with the code background + monospaced font so the card visually extends past
/// the glyphs (SwiftUI `Text` can't pad a run directly). Runs last, after find
/// highlights, so match offsets stay in sync with the unpadded parse text. Fenced
/// code blocks carry no `.code` intent, so this leaves them untouched.
private func paddedInlineCode(_ styled: AttributedString, theme: Theme) -> AttributedString {
    // Coalesce adjacent `.code` runs into character-offset spans: a find
    // highlight inside a code span splits it into several runs that all keep the
    // `.code` intent, and we must pad only the merged span's edges, not mid-span.
    var spans: [(lower: Int, upper: Int)] = []
    var current: (lower: Int, upper: Int)?
    for run in styled.runs {
        let lo = styled.characters.distance(from: styled.startIndex, to: run.range.lowerBound)
        let hi = styled.characters.distance(from: styled.startIndex, to: run.range.upperBound)
        if run.inlinePresentationIntent?.contains(.code) ?? false {
            current = (current?.lower ?? lo, hi)
        } else if let c = current {
            spans.append(c); current = nil
        }
    }
    if let c = current { spans.append(c) }
    guard !spans.isEmpty else { return styled }

    var pad = AttributedString("\u{202F}")  // U+202F narrow no-break space
    pad.font = .system(size: FontSize.inlineCode, weight: .regular, design: .monospaced)
    pad.backgroundColor = theme.card

    // Insert back-to-front so the lower spans' offsets stay valid as we go.
    var result = styled
    for span in spans.reversed() {
        result.insert(pad, at: result.index(result.startIndex, offsetByCharacters: span.upper))
        result.insert(pad, at: result.index(result.startIndex, offsetByCharacters: span.lower))
    }
    return result
}

// MARK: - Content

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var find: FindModel
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("liveReload") private var liveReload = true
    @AppStorage("followTail") private var followTail = false
    @Environment(\.colorScheme) private var systemScheme
    @State private var docCopied = false
    @State private var findDebounce: Task<Void, Never>?
    @FocusState private var findFieldFocused: Bool

    private let contentWidth: CGFloat = 860

    private var activeScheme: ColorScheme {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return systemScheme
        }
    }

    private var theme: Theme {
        activeScheme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
            if let notice = model.notice {
                noticeBar(notice)
            }
            documentArea
        }
        .background(theme.bg)
        .frame(minWidth: 680, minHeight: 480)
        .preferredColorScheme(preferredScheme)
        .onAppear {
            model.setLiveReload(liveReload)
        }
        .onChange(of: liveReload) { enabled in
            model.setLiveReload(enabled)
            if !enabled { followTail = false }
        }
        .onChange(of: model.watchedFolder) { folder in
            // Watch mode exists to see an agent write: reload live and keep
            // the tail in view without requiring two more clicks.
            if folder != nil {
                liveReload = true
                followTail = true
            }
        }
        .onChange(of: find.query) { _ in scheduleRecompute() }
        .onChange(of: model.markdownSource) { _ in scheduleRecompute() }
        .onChange(of: find.isActive) { active in
            if active {
                findFieldFocused = true
                recomputeMatches()
            } else {
                findDebounce?.cancel()
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard
                    let data = data as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button { model.notice = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notice")
        }
        .foregroundStyle(theme.amber)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.amber.opacity(0.12))
    }

    private var preferredScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.pickFileFromDisk()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text("Open")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)

            if let fileURL = model.fileURL {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !model.markdownSource.isEmpty {
                copyDocButton
            }
            if model.watchedFolder != nil {
                watchToggle
            }
            if model.fileURL != nil {
                liveToggle
                followToggle
            }
            themeToggle
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(theme.surface)
    }

    private var copyDocButton: some View {
        Button {
            copyDocument()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: docCopied ? "checkmark" : "doc.on.doc")
                Text(docCopied ? "Copied" : "Copy")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(docCopied ? theme.green : theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(docCopied ? theme.green.opacity(0.5) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy the whole document as Markdown (⇧⌘C)")
        .accessibilityLabel("Copy document as Markdown")
    }

    private func copyDocument() {
        setPasteboard(model.markdownSource)
        withAnimation { docCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { docCopied = false }
        }
    }

    private var liveToggle: some View {
        Button {
            liveReload.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: liveReload ? "bolt.fill" : "bolt.slash")
                Text("Live")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(liveReload ? theme.accent : theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(liveReload ? theme.accent.opacity(0.5) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(liveReload ? "Live reload on — preview updates when the file changes" : "Live reload off — click to resume")
        .accessibilityLabel("Live reload")
        .accessibilityValue(liveReload ? "On" : "Off")
    }

    // Note: on multi-MB documents a sustained fast writer can postpone visible
    // updates until it pauses (trailing watcher debounce + parse-generation
    // drops) — pre-existing reload behavior, not a follow-mode bug.
    private var followToggle: some View {
        Button {
            followTail.toggle()
            // Following a file that never reloads is useless.
            if followTail { liveReload = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.to.line")
                Text("Follow")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(followTail ? theme.accent : theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(followTail ? theme.accent.opacity(0.5) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(followTail ? "Following — scrolls to the end as the file grows; scroll up to stop"
                         : "Follow off — click to keep the end of a growing file in view")
        .accessibilityLabel("Follow tail")
        .accessibilityValue(followTail ? "On" : "Off")
    }

    // Watch mode has no "off but visible" state like Live/Follow: the pill
    // only exists while watching, and clicking it stops the watch.
    private var watchToggle: some View {
        Button {
            model.stopWatchingFolder()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye")
                Text("Watching \(model.watchedFolder?.lastPathComponent ?? "")")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 220)
        .help("Watching \(model.watchedFolder?.path ?? "") — shows its newest Markdown file as it's written; click to stop")
        .accessibilityLabel("Stop watching folder")
    }

    private var themeToggle: some View {
        Menu {
            Button { appTheme = "system" } label: { Label("System", systemImage: "circle.lefthalf.filled") }
            Button { appTheme = "light" } label: { Label("Light", systemImage: "sun.max") }
            Button { appTheme = "dark" } label: { Label("Dark", systemImage: "moon") }
        } label: {
            Image(systemName: themeIcon)
                .foregroundStyle(theme.textMuted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Theme")
        .accessibilityLabel("Theme")
    }

    private var themeIcon: String {
        switch appTheme {
        case "light": return "sun.max"
        case "dark": return "moon"
        default: return "circle.lefthalf.filled"
        }
    }

    @ViewBuilder
    private var documentArea: some View {
        if model.fileURL == nil && model.markdownSource.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.blocks) { rendered in
                            blockView(rendered)
                                .padding(.bottom, bottomSpacing(rendered.block))
                                .id(rendered.id)
                        }
                    }
                    .frame(maxWidth: contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
                // Switching documents (watch mode, hooks) must rebuild scroll
                // state: a long document followed to its bottom leaves an
                // offset past a shorter successor's end, where the LazyVStack
                // realizes no rows and scrollTo has no anchor — blank window.
                // Same-file reloads keep their identity, and their position.
                .id(model.fileURL)
                .onChange(of: model.fileURL) { _ in
                    // The fresh scroll view starts at the top; re-assert
                    // follow once the new layout exists.
                    if followTail { DispatchQueue.main.async { scrollToBottom(proxy) } }
                }
                .onChange(of: find.currentIndex) { _ in scrollToCurrentMatch(proxy) }
                .onChange(of: find.matches) { _ in scrollToCurrentMatch(proxy) }
                .onChange(of: model.parseTick) { _ in
                    if followTail { scrollToBottom(proxy) }
                }
                .onChange(of: followTail) { on in
                    if on { scrollToBottom(proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSScrollView.didLiveScrollNotification)) { note in
                    // User-initiated scroll away from the bottom detaches follow
                    // (terminal semantics). The at-bottom gate keeps horizontal
                    // code-block scrollers — which post the same notification —
                    // from detaching it, and deliberately ignores which window
                    // the event came from (settings and model are app-global).
                    guard followTail,
                          let scrollView = note.object as? NSScrollView,
                          let document = scrollView.documentView else { return }
                    if scrollView.documentVisibleRect.maxY < document.frame.height - 4 {
                        followTail = false
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if find.isActive {
                    findBar
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                }
            }
        }
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let match = find.current else { return }
        // Jumping to a match while follow keeps yanking to the bottom would be
        // a tug-of-war; finding something implies the user wants to stay there.
        followTail = false
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(match.blockID, anchor: .center)
        }
    }

    /// Unanimated on purpose: during streaming this fires on every parse tick,
    /// and overlapping animated scrolls fight each other.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.blocks.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    // Small documents recompute instantly for snappy highlighting; large ones
    // debounce so typing in Find doesn't trigger a full re-scan per keystroke.
    private func scheduleRecompute() {
        findDebounce?.cancel()
        if model.blocks.count < 2000 {
            recomputeMatches()
            return
        }
        findDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            recomputeMatches()
        }
    }

    private func recomputeMatches() {
        guard find.isActive, !find.query.isEmpty else {
            find.setMatches([])
            return
        }
        var result: [FindMatch] = []
        for rendered in model.blocks {
            let id = rendered.id
            switch rendered.block {
            case let .frontmatter(fields):
                for (i, field) in fields.enumerated() {
                    collectMatches(into: &result, blockID: id, segmentID: "\(id)#F\(i)", text: field.value, query: find.query)
                }
            case let .heading(_, inline):
                collectMatches(into: &result, blockID: id, segmentID: "\(id)", text: String(inline.characters), query: find.query)
            case let .paragraph(inline):
                collectMatches(into: &result, blockID: id, segmentID: "\(id)", text: String(inline.characters), query: find.query)
            case let .callout(_, inline):
                collectMatches(into: &result, blockID: id, segmentID: "\(id)", text: String(inline.characters), query: find.query)
            case let .code(_, rawLines):
                collectMatches(into: &result, blockID: id, segmentID: "\(id)", text: rawLines.joined(separator: "\n"), query: find.query)
            case let .list(items):
                for (i, item) in items.enumerated() {
                    collectMatches(into: &result, blockID: id, segmentID: "\(id)#L\(i)", text: String(item.inline.characters), query: find.query)
                }
            case let .table(header, rows, _):
                for (c, cell) in header.enumerated() {
                    collectMatches(into: &result, blockID: id, segmentID: "\(id)#H\(c)", text: String(cell.characters), query: find.query)
                }
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        collectMatches(into: &result, blockID: id, segmentID: "\(id)#R\(r)C\(c)", text: String(cell.characters), query: find.query)
                    }
                }
            case .rule:
                break
            }
        }
        find.setMatches(result)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
                .accessibilityHidden(true)
            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($findFieldFocused)
                .onSubmit { find.next() }
                .accessibilityLabel("Find in document")
            if !find.query.isEmpty {
                Text(find.matches.isEmpty ? "Not found" : "\(find.currentIndex + 1) of \(find.matches.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted)
                    .accessibilityLabel(find.matches.isEmpty
                        ? "No matches"
                        : "Match \(find.currentIndex + 1) of \(find.matches.count)")
            }
            Divider().frame(height: 16)
            Button { find.previous() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(find.matches.isEmpty)
                .help("Previous match (⇧⌘G)")
                .accessibilityLabel("Previous match")
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(find.matches.isEmpty)
                .help("Next match (⌘G)")
                .accessibilityLabel("Next match")
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel("Close find")
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .onExitCommand { closeFind() }
    }

    private func closeFind() {
        find.close()
        findFieldFocused = false
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(theme.textMuted)
            Text("Open a Markdown file to preview it")
                .font(.system(size: 15))
                .foregroundStyle(theme.textMuted)
            Button("Open Markdown File") { model.pickFileFromDisk() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    @ViewBuilder
    private func blockView(_ rendered: RenderedBlock) -> some View {
        let block = rendered.block
        let id = rendered.id
        let hl = find.highlight(theme: theme)
        switch block {
        case let .frontmatter(fields):
            FrontmatterView(fields: fields, theme: theme, blockID: id, find: hl)
                .copyableOnHover(plainText(of: block), theme: theme)
        case let .heading(level, inline):
            HeadingView(level: level, inline: inline, theme: theme, segmentID: "\(id)", find: hl)
                .copyableOnHover(plainText(of: block), theme: theme)
        case let .paragraph(inline):
            Text(preparedForDisplay(
                styledInline(inline, size: FontSize.body, baseColor: theme.text, theme: theme),
                segmentID: "\(id)", find: hl))
                .lineSpacing(readingLineSpacing(for: FontSize.body))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .copyableOnHover(plainText(of: block), theme: theme)
        case let .list(rows):
            ListView(rows: rows, theme: theme, blockID: id, find: hl)
                .copyableOnHover(plainText(of: block), theme: theme)
        case let .code(language, rawLines):
            CodeBlockView(language: language, rawLines: rawLines, theme: theme, segmentID: "\(id)", find: hl)
        case let .table(header, rows, alignments):
            MarkdownTableView(header: header, rows: rows, alignments: alignments, theme: theme, blockID: id, find: hl)
                .copyableOnHover(plainText(of: block), theme: theme)
        case let .callout(kind, inline):
            CalloutView(kind: kind, inline: inline, theme: theme, segmentID: "\(id)", find: hl)
                .copyableOnHover(plainText(of: block), theme: theme)
        case .rule:
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
                .padding(.vertical, 18)
        }
    }

    private func bottomSpacing(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .frontmatter: return 20
        case .heading(let level, _): return level <= 2 ? 10 : 8
        case .paragraph: return 14
        case .list: return 14
        case .code: return 16
        case .table: return 18
        case .callout: return 16
        case .rule: return 0
        }
    }
}

@main
struct MarginsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewerModel()
    @StateObject private var find = FindModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // A single Window scene, not a WindowGroup: every window shares the
        // one ViewerModel, so a second window could only ever be a clone of
        // the first. WindowGroup + handlesExternalEvents reused an existing
        // window for later opens, but lost the race at cold launch — opening
        // a document from Finder created the default window AND an
        // event-spawned duplicate. A unique Window makes that impossible and
        // drops the pointless New Window menu item.
        Window("Margins", id: "main") {
            ContentView(model: model, find: find)
                .onAppear {
                    appDelegate.onOpenFiles = { urls in
                        if let firstURL = urls.first {
                            model.open(firstURL)
                            // Re-surface the window if it was closed when the
                            // open event arrived (app kept running).
                            openWindow(id: "main")
                        }
                    }
                }
                .onOpenURL { url in
                    model.open(url)
                    openWindow(id: "main")
                }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Make Default for Markdown") { model.makeDefaultMarkdownApp() }
            }
            CommandGroup(after: .newItem) {
                Button("Watch Folder…") { model.pickFolderToWatch() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Document as Markdown") {
                    setPasteboard(model.markdownSource)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.markdownSource.isEmpty)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { find.isActive = true }
                    .keyboardShortcut("f")
                    .disabled(model.markdownSource.isEmpty)
                Button("Find Next") { find.next() }
                    .keyboardShortcut("g")
                    .disabled(find.matches.isEmpty)
                Button("Find Previous") { find.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(find.matches.isEmpty)
            }
        }
    }
}
