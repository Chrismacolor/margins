import Foundation

// Tests for the watch-mode folder scan core (Sources/Margins/FolderScan.swift).
// Compiled into the same runner as the parser tests by scripts/test.sh.

extension TestRunner {
    static func testFolderScan() {
        print("Folder scan")
        testFolderScanEligibility()
        testFolderScanNewest()
        testFolderScanSwitchPolicy()
    }

    private static func testFolderScanEligibility() {
        check(FolderScan.isEligible(relativePath: "notes.md"), "top-level md is eligible")
        check(FolderScan.isEligible(relativePath: "docs/plan.markdown"), "nested .markdown is eligible")
        check(FolderScan.isEligible(relativePath: "A/B/README.MD"), "extension check is case-insensitive")
        check(!FolderScan.isEligible(relativePath: "notes.txt"), "non-markdown is not eligible")
        check(!FolderScan.isEligible(relativePath: "node_modules/pkg/README.md"), "node_modules is pruned")
        check(!FolderScan.isEligible(relativePath: ".git/COMMIT_EDITMSG.md"), "hidden dirs are pruned")
        check(!FolderScan.isEligible(relativePath: "docs/.draft.md"), "hidden files are pruned")
        check(!FolderScan.isEligible(relativePath: ""), "empty path is not eligible")

        check(FolderScan.isEligibleEventPath("/w/docs/a.md", root: "/w"), "event path inside root")
        check(FolderScan.isEligibleEventPath("/w/docs/a.md", root: "/w/"), "root with trailing slash")
        check(!FolderScan.isEligibleEventPath("/other/a.md", root: "/w"), "event path outside root")
        check(!FolderScan.isEligibleEventPath("/wider/a.md", root: "/w"), "prefix match is component-wise")
        check(!FolderScan.isEligibleEventPath("/w", root: "/w"), "root itself is not a candidate")
    }

    private static func testFolderScanNewest() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("folderscan-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? fm.removeItem(at: root) }

        func plant(_ relative: String, minutesAgo: Double) {
            let url = root.appendingPathComponent(relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data("x".utf8))
            try? fm.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)],
                ofItemAtPath: url.path
            )
        }

        check(FolderScan.newestMarkdown(under: root) == nil, "missing root yields nil")

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        check(FolderScan.newestMarkdown(under: root) == nil, "empty root yields nil")

        plant("old.md", minutesAgo: 60)
        plant("sub dir/new.mdown", minutesAgo: 10)
        plant("newest.txt", minutesAgo: 1)
        plant("node_modules/decoy.md", minutesAgo: 1)
        plant(".hidden/decoy.md", minutesAgo: 1)
        plant("sub dir/.decoy.md", minutesAgo: 1)

        let newest = FolderScan.newestMarkdown(under: root)
        check(newest?.url.lastPathComponent == "new.mdown",
              "newest eligible markdown wins (skips non-md, node_modules, hidden)")
        if let newest {
            check(abs(newest.modified.timeIntervalSinceNow + 10 * 60) < 5,
                  "reported modification date matches the file")
        }
    }

    private static func testFolderScanSwitchPolicy() {
        let now = Date()
        check(FolderScan.shouldSwitch(currentModified: nil, candidateModified: now),
              "no current file always switches")
        check(!FolderScan.shouldSwitch(currentModified: now, candidateModified: now.addingTimeInterval(-5)),
              "older candidate never switches")
        check(!FolderScan.shouldSwitch(currentModified: now, candidateModified: now.addingTimeInterval(0.5)),
              "barely-newer candidate stays put (hysteresis)")
        check(FolderScan.shouldSwitch(currentModified: now, candidateModified: now.addingTimeInterval(1.5)),
              "meaningfully newer candidate switches")
    }
}
