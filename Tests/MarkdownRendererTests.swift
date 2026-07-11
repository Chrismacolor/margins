import Foundation

// Standalone test + benchmark runner for the Markdown parser. Compiled with
// Sources/Margins/MarkdownRenderer.swift by scripts/test.sh (no SwiftPM,
// no SwiftUI). Exits non-zero on any failure.

private func plain(_ a: AttributedString) -> String { String(a.characters) }

private func blockKind(_ b: MarkdownBlock) -> String {
    switch b {
    case .frontmatter: return "frontmatter"
    case .heading: return "heading"
    case .paragraph: return "paragraph"
    case .list: return "list"
    case .code: return "code"
    case .table: return "table"
    case .callout: return "callout"
    case .rule: return "rule"
    }
}

@main
struct TestRunner {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok  \(message)")
        } else {
            print("  FAIL  \(message)")
            failures += 1
        }
    }

    static func main() {
        testHeadings()
        testParagraphInline()
        testCodeBlock()
        testTable()
        testCallout()
        testLists()
        testTaskLists()
        testListContinuation()
        testHorizontalRule()
        testParagraphTableBoundary()
        testEmpty()
        testFindMatches()
        testPlainText()
        testFrontmatter()
        benchmark()

        if failures > 0 {
            print("\n\(failures) test(s) FAILED")
            exit(1)
        }
        print("\nAll tests passed")
    }

    static func testHeadings() {
        print("Headings")
        let blocks = MarkdownRenderer.parse("# Hello World\n\n### Sub")
        check(blocks.count == 2, "two heading blocks")
        if case let .heading(level, inline) = blocks[0].block {
            check(level == 1, "first is h1")
            check(plain(inline) == "Hello World", "h1 text")
        } else { check(false, "block 0 is a heading") }
        if case let .heading(level, _) = blocks[1].block {
            check(level == 3, "second is h3")
        } else { check(false, "block 1 is a heading") }
    }

    static func testParagraphInline() {
        print("Paragraph inline")
        let blocks = MarkdownRenderer.parse("Some **bold** and `code` text.")
        check(blocks.count == 1 && blockKind(blocks[0].block) == "paragraph", "single paragraph")
        if case let .paragraph(inline) = blocks[0].block {
            check(plain(inline) == "Some bold and code text.", "inline markers stripped to text")
        }
    }

    static func testCodeBlock() {
        print("Code block")
        let blocks = MarkdownRenderer.parse("```swift\nlet x = 1\nlet y = 2\n```")
        check(blocks.count == 1, "one block")
        if case let .code(language, rawLines) = blocks[0].block {
            check(language == "swift", "language captured")
            check(rawLines == ["let x = 1", "let y = 2"], "raw lines preserved")
        } else { check(false, "block is code") }
    }

    static func testTable() {
        print("Table")
        // Note: the parser requires 3+ dashes in the separator row.
        let md = "| A | B |\n|:---|---:|\n| 1 | 2 |\n| 3 | 4 |"
        let blocks = MarkdownRenderer.parse(md)
        check(blocks.count == 1, "one block")
        if case let .table(header, rows, alignments) = blocks[0].block {
            check(header.count == 2, "two header cells")
            check(rows.count == 2, "two body rows")
            check(alignments.count == 2, "two alignments")
            check(plain(header[0]) == "A", "header uppercased text retained")
        } else { check(false, "block is table") }
    }

    static func testCallout() {
        print("Callout")
        let blocks = MarkdownRenderer.parse("> [!WARNING]\n> Be careful.")
        check(blocks.count == 1, "one block")
        if case let .callout(kind, inline) = blocks[0].block {
            check(kind.title == "Warning", "warning kind")
            check(plain(inline) == "Be careful.", "callout body")
        } else { check(false, "block is callout") }
    }

    static func testLists() {
        print("Lists")
        let unordered = MarkdownRenderer.parse("- a\n- b\n- c")
        if case let .list(items) = unordered[0].block {
            check(items.count == 3, "three bullets")
            check(items.allSatisfy { $0.marker == "•" }, "bullet markers")
        } else { check(false, "unordered list block") }

        let ordered = MarkdownRenderer.parse("1. first\n2. second")
        if case let .list(items) = ordered[0].block {
            check(items.map(\.marker) == ["1.", "2."], "ordered markers")
        } else { check(false, "ordered list block") }
    }

    static func testTaskLists() {
        print("Task lists")
        let doc = "- [ ] open\n- [x] done\n- [X] DONE\n- plain\n- [ ]\n  - [ ] child"
        if case let .list(items) = MarkdownRenderer.parse(doc)[0].block {
            check(items.count == 6, "one block of six items")
            check(items.map(\.checkbox) == [false, true, true, nil, false, false], "checkbox states")
            check(plain(items[0].inline) == "open", "unchecked prefix stripped")
            check(plain(items[1].inline) == "done", "checked prefix stripped")
            check(plain(items[3].inline) == "plain", "plain sibling untouched")
            check(plain(items[4].inline).isEmpty, "empty task item allowed")
            check(items[5].indent == 1, "nested task keeps indent")
            check(items.allSatisfy { $0.marker == "•" }, "markers stay bullets")
        } else { check(false, "task list block") }

        let notTasks = MarkdownRenderer.parse("- [y] nope\n- [ ]tight\n1. [ ] ordered")
        if case let .list(items) = notTasks[0].block {
            check(items.map(\.checkbox) == [nil, nil, nil], "near-misses are not tasks")
            check(plain(items[0].inline) == "[y] nope", "unknown bracket kept literal")
            check(plain(items[1].inline) == "[ ]tight", "missing space kept literal")
            check(plain(items[2].inline) == "[ ] ordered", "ordered item keeps brackets")
        } else { check(false, "near-miss list block") }
    }

    static func testListContinuation() {
        print("List continuation (hard-wrapped items)")

        // (a) A hard-wrapped unordered item folds into one item, single-spaced.
        let unordered = MarkdownRenderer.parse("- first line\n  second line\n- next item")
        check(unordered.count == 1 && blockKind(unordered[0].block) == "list", "no stray paragraph after the list")
        if case let .list(items) = unordered[0].block {
            check(items.count == 2, "two items despite the wrap")
            check(plain(items[0].inline) == "first line second line", "wrapped lines join with a space")
            check(plain(items[1].inline) == "next item", "sibling item intact")
        } else { check(false, "wrapped unordered list block") }

        // (b) A hard-wrapped ordered item folds too, markers preserved.
        let ordered = MarkdownRenderer.parse("1. do a thing\n   across lines\n2. and another")
        if case let .list(items) = ordered[0].block {
            check(items.count == 2, "two ordered items")
            check(plain(items[0].inline) == "do a thing across lines", "wrapped ordered item joins")
            check(items.map(\.marker) == ["1.", "2."], "ordered markers preserved")
        } else { check(false, "wrapped ordered list block") }

        // (c) A wrapped task item keeps its checkbox state.
        let task = MarkdownRenderer.parse("- [x] finish the thing\n  even after wrapping")
        if case let .list(items) = task[0].block {
            check(items.count == 1, "one task item")
            check(items[0].checkbox == true, "checkbox state survives continuation")
            check(plain(items[0].inline) == "finish the thing even after wrapping", "task text joins with continuation")
        } else { check(false, "wrapped task list block") }

        // (d) A blank line ends the list; the following paragraph stays separate.
        let blank = MarkdownRenderer.parse("- item\n\nA following paragraph.")
        check(blank.map { blockKind($0.block) } == ["list", "paragraph"],
              "blank line after an item ends the list")

        // (e) A header right after an item is not swallowed as a continuation.
        let header = MarkdownRenderer.parse("- item\n# Heading")
        check(header.map { blockKind($0.block) } == ["list", "heading"],
              "header right after an item is not swallowed")
    }

    static func testHorizontalRule() {
        print("Horizontal rule")
        let blocks = MarkdownRenderer.parse("above\n\n---\n\nbelow")
        check(blocks.map { blockKind($0.block) } == ["paragraph", "rule", "paragraph"],
              "paragraph, rule, paragraph")
    }

    static func testParagraphTableBoundary() {
        print("Paragraph/table boundary (O(n^2) fix regression)")
        let md = "intro text\n| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownRenderer.parse(md)
        check(blocks.map { blockKind($0.block) } == ["paragraph", "table"],
              "paragraph ends at table start")
    }

    static func testEmpty() {
        print("Empty input")
        check(MarkdownRenderer.parse("").isEmpty, "no blocks for empty string")
        check(MarkdownRenderer.parse("\n\n   \n").isEmpty, "no blocks for whitespace only")
    }

    static func testFindMatches() {
        print("Find — collectMatches")
        var r: [FindMatch] = []
        // Two case-insensitive, non-overlapping occurrences with correct offsets.
        collectMatches(into: &r, blockID: 3, segmentID: "3", text: "The cat and the CAT.", query: "cat")
        check(r.count == 2, "two case-insensitive matches")
        check(r.first?.blockID == 3 && r.first?.segmentID == "3", "match carries block/segment id")
        check(r.map(\.start) == [4, 16], "match start offsets")

        // Empty query / empty text / no match → nothing appended.
        var empty: [FindMatch] = []
        collectMatches(into: &empty, blockID: 0, segmentID: "0", text: "hello", query: "")
        collectMatches(into: &empty, blockID: 0, segmentID: "0", text: "", query: "x")
        collectMatches(into: &empty, blockID: 0, segmentID: "0", text: "hello", query: "z")
        check(empty.isEmpty, "no matches for empty/absent query")

        // Adjacent matches don't overlap-double-count.
        var adj: [FindMatch] = []
        collectMatches(into: &adj, blockID: 1, segmentID: "1", text: "aaaa", query: "aa")
        check(adj.map(\.start) == [0, 2], "adjacent matches step past the previous one")
    }

    static func testPlainText() {
        print("Find — plainText(of:)")
        let doc = """
        # Title

        A **bold** paragraph.

        - one
        - two

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let blocks = MarkdownRenderer.parse(doc)
        let heading = blocks.first { blockKind($0.block) == "heading" }!.block
        check(plainText(of: heading) == "Title", "heading plain text strips markup")

        let para = blocks.first { blockKind($0.block) == "paragraph" }!.block
        check(plainText(of: para) == "A bold paragraph.", "paragraph drops emphasis markers")

        let list = blocks.first { blockKind($0.block) == "list" }!.block
        check(plainText(of: list).contains("one") && plainText(of: list).contains("two"),
              "list plain text includes each item")

        let tasks = MarkdownRenderer.parse("- [x] done\n- [ ] open")[0].block
        check(plainText(of: tasks) == "• [x] done\n• [ ] open",
              "task list copies with checkbox state")

        let table = blocks.first { blockKind($0.block) == "table" }!.block
        check(plainText(of: table).contains("\t"), "table cells are tab-separated")
        check(plainText(of: table).contains("1") && plainText(of: table).contains("2"),
              "table plain text includes body cells")
    }

    static func testFrontmatter() {
        print("Frontmatter")
        let doc = """
        ---
        title: "My Note"
        date: 2026-06-21
        tags: [reading, ideas]
        authors:
          - Jane
          - John
        nested:
          a: 1
        ---
        # Heading

        Body.
        """
        let blocks = MarkdownRenderer.parse(doc)
        guard case let .frontmatter(fields) = blocks.first?.block else {
            check(false, "first block is frontmatter"); return
        }
        check(true, "first block is frontmatter")
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        check(map["title"] == "My Note", "quotes stripped from scalar")
        check(map["date"] == "2026-06-21", "plain scalar")
        check(map["tags"] == "reading, ideas", "inline list flattened")
        check(map["authors"] == "Jane, John", "block list flattened")
        check(map["nested"] == nil, "nested map skipped (no YAML dependency)")
        // The body still parses, and the closing --- is not a stray rule.
        check(blocks.contains { blockKind($0.block) == "heading" }, "body heading parsed after frontmatter")
        check(!blocks.contains { blockKind($0.block) == "rule" }, "delimiters did not become rules")

        // A mid-document --- is still a horizontal rule, not frontmatter.
        let hr = MarkdownRenderer.parse("Para\n\n---\n\nMore")
        check(hr.contains { blockKind($0.block) == "rule" }, "mid-document --- stays a rule")
        check(!hr.contains { blockKind($0.block) == "frontmatter" }, "no frontmatter when --- isn't first")

        // No closing delimiter → leading --- is treated as a normal rule.
        let unclosed = MarkdownRenderer.parse("---\ntitle: x\nstill going")
        check(!unclosed.contains { blockKind($0.block) == "frontmatter" }, "unterminated block is not frontmatter")
    }

    static func benchmark() {
        print("\nBenchmark (parse time)")
        let chunk = """
        # Section

        Some **bold** paragraph with `inline code` and a [link](https://example.com)
        spanning a couple of lines of prose to be representative.

        - bullet one
        - bullet two

        | Col A | Col B |
        |:------|------:|
        | one   | two   |

        > [!NOTE]
        > A callout.

        ```swift
        let x = 42
        ```

        """
        for targetMB in [0.1, 1.0, 10.0] {
            let targetBytes = Int(targetMB * 1_000_000)
            var doc = ""
            doc.reserveCapacity(targetBytes + chunk.count)
            while doc.utf8.count < targetBytes { doc += chunk }
            let start = Date()
            let blocks = MarkdownRenderer.parse(doc)
            let ms = Date().timeIntervalSince(start) * 1000
            let label = targetMB < 1 ? "100 KB" : "\(Int(targetMB)) MB"
            print(String(format: "  %-7@  %7.1f ms  (%d blocks)", label as NSString, ms, blocks.count))
        }
    }
}
