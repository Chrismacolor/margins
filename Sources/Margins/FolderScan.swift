import Foundation

// SwiftUI-free core of watch mode: which Markdown file under a watched folder
// is "current", and when the viewer should switch to a different one. Kept
// free of AppKit/SwiftUI so scripts/test.sh can unit-test it standalone.
// The traversal rules mirror the CLI shim's newest_md() (Resources/margins-cli):
// hidden files/directories and node_modules are never considered.

enum FolderScan {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    /// Path components pruned from every scan, in addition to dotfiles.
    private static let excludedDirNames: Set<String> = ["node_modules"]

    private static func isExcludedComponent(_ name: String) -> Bool {
        name.hasPrefix(".") || excludedDirNames.contains(name)
    }

    private static func isMarkdownName(_ name: String) -> Bool {
        markdownExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether a path relative to the watched root names a Markdown file the
    /// scan would consider: Markdown extension, no hidden or excluded ancestors.
    static func isEligible(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last, isMarkdownName(name) else { return false }
        return !components.contains(where: isExcludedComponent)
    }

    /// Whether an absolute event path (as reported by FSEvents) is a Markdown
    /// file inside `root` that watch mode cares about.
    static func isEligibleEventPath(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        return isEligible(relativePath: String(path.dropFirst(prefix.count)))
    }

    /// The most recently modified eligible Markdown file under `root`, with
    /// its modification date. Excluded directories are pruned from traversal
    /// (not just filtered), so a large node_modules costs nothing.
    static func newestMarkdown(under root: URL) -> (url: URL, modified: Date)? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: []
        ) else { return nil }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            let name = values?.name ?? url.lastPathComponent
            if isExcludedComponent(name) {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values?.isDirectory != true,
                  isMarkdownName(name),
                  let modified = values?.contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest
    }

    /// Whether the viewer should leave the file it is showing for a newer one.
    /// The hysteresis keeps an agent that alternates writes between two files
    /// (streaming into plan.md while touching README.md) from flapping the
    /// view: the candidate must be meaningfully newer, not just newer.
    static func shouldSwitch(
        currentModified: Date?,
        candidateModified: Date,
        hysteresis: TimeInterval = 1.0
    ) -> Bool {
        guard let current = currentModified else { return true }
        return candidateModified.timeIntervalSince(current) > hysteresis
    }
}
