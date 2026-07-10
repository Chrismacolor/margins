import Foundation

// Theme-independent Markdown model and parser. Deliberately free of SwiftUI/
// AppKit so it can be compiled and unit-tested on its own (see scripts/test.sh).
// Colors and fonts are applied later, in the views.

enum HAlign {
    case left
    case center
    case right
}

enum CalloutKind {
    case note
    case tip
    case important
    case warning
    case caution
    case plain

    init(tag: String) {
        switch tag.uppercased() {
        case "NOTE": self = .note
        case "TIP", "HINT": self = .tip
        case "IMPORTANT": self = .important
        case "WARNING": self = .warning
        case "CAUTION", "DANGER": self = .caution
        default: self = .plain
        }
    }

    var title: String? {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        case .plain: return nil
        }
    }
}

/// A list item with its inline text already parsed (theme-independent).
struct ListItem: Identifiable {
    let id = UUID()
    let indent: Int
    let marker: String
    let inline: AttributedString
    /// GFM task-list state: nil for a normal item, true/false for `[x]`/`[ ]`.
    let checkbox: Bool?
}

/// A single `key: value` pair from a YAML frontmatter block (value flattened
/// to a display string — lists are comma-joined; deeper YAML is not parsed).
struct FrontmatterField: Equatable {
    let key: String
    let value: String
}

/// Theme-independent structural blocks. Inline `AttributedString`s carry
/// presentation intents and links but NO colors/fonts — applied in the views.
enum MarkdownBlock {
    case frontmatter([FrontmatterField])
    case heading(level: Int, inline: AttributedString)
    case paragraph(inline: AttributedString)
    case list([ListItem])
    case code(language: String, rawLines: [String])
    case table(header: [AttributedString], rows: [[AttributedString]], alignments: [HAlign])
    case callout(kind: CalloutKind, inline: AttributedString)
    case rule
}

struct RenderedBlock: Identifiable {
    let id: Int
    let block: MarkdownBlock
}

struct MarkdownRenderer {
    static func parse(_ markdown: String) -> [RenderedBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var index = 0
        var blocks: [MarkdownBlock] = []

        // A leading `---` line begins YAML frontmatter (only at the very top of
        // the document, which disambiguates it from a horizontal rule).
        if let (fields, next) = parseFrontmatter(from: lines) {
            if !fields.isEmpty { blocks.append(.frontmatter(fields)) }
            index = next
        }

        while index < lines.count {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            if index >= lines.count { break }

            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let (block, next) = parseCodeBlock(from: lines, start: index)
                blocks.append(block); index = next; continue
            }
            if let (level, text) = parseHeader(trimmed) {
                blocks.append(.heading(level: level, inline: parseInline(text)))
                index += 1; continue
            }
            if isHorizontalRule(trimmed) {
                blocks.append(.rule); index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                let (block, next) = parseBlockquote(from: lines, start: index)
                blocks.append(block); index = next; continue
            }
            if let (block, next) = parseTableBlock(from: lines, start: index) {
                blocks.append(block); index = next; continue
            }
            if parseListItem(lines[index]) != nil {
                let (block, next) = parseListBlock(from: lines, start: index)
                blocks.append(block); index = next; continue
            }
            let (block, next) = parseParagraph(from: lines, start: index)
            blocks.append(block); index = next
        }

        return blocks.enumerated().map { RenderedBlock(id: $0.offset, block: $0.element) }
    }

    // MARK: Frontmatter

    /// Parse a leading YAML frontmatter block (`---` … `---`/`...`) into flattened
    /// key/value fields. Returns nil when the document doesn't open with one.
    /// Only top-level scalars, inline `[a, b]` lists, and `- item` block lists
    /// are recognized; deeper YAML is skipped (kept minimal, no YAML dependency).
    private static func parseFrontmatter(from lines: [String]) -> (fields: [FrontmatterField], end: Int)? {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        var close = -1
        var i = 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { close = i; break }
            i += 1
        }
        guard close != -1 else { return nil }  // no close → treat as a normal rule

        var fields: [FrontmatterField] = []
        var j = 1
        while j < close {
            let raw = lines[j]
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Only non-indented `key: value` lines are fields (skip nested maps).
            if !raw.hasPrefix(" "), !raw.hasPrefix("\t"), let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    if rest.isEmpty {
                        // An empty value may be followed by a `- item` block list.
                        var items: [String] = []
                        var k = j + 1
                        while k < close {
                            let it = lines[k].trimmingCharacters(in: .whitespaces)
                            if it.hasPrefix("- ") {
                                items.append(cleanScalar(String(it.dropFirst(2))))
                                k += 1
                            } else if it.isEmpty {
                                k += 1
                            } else {
                                break
                            }
                        }
                        if !items.isEmpty {
                            fields.append(FrontmatterField(key: key, value: items.joined(separator: ", ")))
                            j = k
                            continue
                        }
                        // empty value, no list (e.g. a nested-map parent) → skip
                    } else {
                        fields.append(FrontmatterField(key: key, value: cleanScalar(rest)))
                    }
                }
            }
            j += 1
        }
        return (fields, close + 1)
    }

    /// Strip surrounding quotes and flatten an inline `[a, b]` list to a string.
    private static func cleanScalar(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        v = unquoted(v)
        if v.hasPrefix("["), v.hasSuffix("]") {
            let inner = v.dropFirst().dropLast()
            v = inner.split(separator: ",")
                .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
        }
        return v
    }

    private static func unquoted(_ s: String) -> String {
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: Cached regexes (compiled once, not per line)

    private static let hrRegex = try! NSRegularExpression(pattern: #"^(-{3,}|\*{3,}|_{3,})$"#)
    private static let tableSepCellRegex = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Headers

    private static func parseHeader(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first == " " else { return nil }
        return (level, String(remainder.trimmingCharacters(in: .whitespaces)))
    }

    // MARK: Horizontal rule

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard !trimmed.contains("|") else { return false }
        return matches(hrRegex, trimmed)
    }

    // MARK: Code blocks

    private static func parseCodeBlock(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        let openingFence = lines[index].trimmingCharacters(in: .whitespaces)
        let language = String(openingFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1

        var codeLines: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }

        return (.code(language: language, rawLines: codeLines), index)
    }

    // MARK: Blockquotes / callouts

    private static func parseBlockquote(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var contentLines: [String] = []

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var stripped = String(trimmed.dropFirst())
            if stripped.hasPrefix(" ") { stripped.removeFirst() }
            contentLines.append(stripped)
            index += 1
        }

        var kind = CalloutKind.plain
        // Runs once per blockquote (not a per-line hot path), so range(of:) is fine.
        if
            let first = contentLines.first,
            let match = first.range(of: #"^\[!\w+\]"#, options: .regularExpression)
        {
            let tag = String(first[match]).dropFirst(2).dropLast()
            kind = CalloutKind(tag: String(tag))
            // Drop the marker line; remaining lines form the body.
            let remainder = String(first[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            contentLines.removeFirst()
            if !remainder.isEmpty { contentLines.insert(remainder, at: 0) }
        }

        let bodyText = contentLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.callout(kind: kind, inline: parseInline(bodyText)), index)
    }

    // MARK: Tables

    private static func parseTableBlock(from lines: [String], start: Int) -> (MarkdownBlock, Int)? {
        guard start + 1 < lines.count else { return nil }
        guard
            let headerCells = splitTableRow(lines[start]),
            let alignments = parseTableSeparatorRow(lines[start + 1])
        else {
            return nil
        }

        let columnCount = max(headerCells.count, alignments.count)
        guard columnCount > 0 else { return nil }

        var resolvedAlignments = alignments
        if resolvedAlignments.count < columnCount {
            resolvedAlignments.append(contentsOf: Array(repeating: .left, count: columnCount - resolvedAlignments.count))
        }

        let header = normalizeCells(headerCells, toCount: columnCount).map { parseInline($0.uppercased()) }

        var rows: [[AttributedString]] = []
        var index = start + 2
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let row = splitTableRow(lines[index]) else { break }
            rows.append(normalizeCells(row, toCount: columnCount).map { parseInline($0) })
            index += 1
        }

        return (.table(header: header, rows: rows, alignments: resolvedAlignments), index)
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableSeparatorRow(_ line: String) -> [HAlign]? {
        guard let cells = splitTableRow(line), !cells.isEmpty else { return nil }
        var alignments: [HAlign] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard matches(tableSepCellRegex, trimmed) else { return nil }
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right {
                alignments.append(.center)
            } else if right {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }

    private static func normalizeCells(_ cells: [String], toCount count: Int) -> [String] {
        var normalized = Array(cells.prefix(count))
        if normalized.count < count {
            normalized.append(contentsOf: Array(repeating: "", count: count - normalized.count))
        }
        return normalized
    }

    // MARK: Lists

    private enum ListKind {
        case unordered(indent: Int, text: String)
        case ordered(indent: Int, number: String, text: String)
    }

    private static func parseListBlock(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var rows: [ListItem] = []

        while index < lines.count {
            guard let item = parseListItem(lines[index]) else { break }
            switch item {
            case let .unordered(indent, text):
                if let task = taskCheckbox(text) {
                    rows.append(ListItem(indent: indent, marker: "•", inline: parseInline(task.remainder), checkbox: task.checked))
                } else {
                    rows.append(ListItem(indent: indent, marker: "•", inline: parseInline(text), checkbox: nil))
                }
            case let .ordered(indent, number, text):
                rows.append(ListItem(indent: indent, marker: "\(number).", inline: parseInline(text), checkbox: nil))
            }
            index += 1
        }

        return (.list(rows), index)
    }

    private static func parseListItem(_ line: String) -> ListKind? {
        let indentWidth = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let indent = max(0, indentWidth / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return .unordered(indent: indent, text: text)
        }

        guard
            let match = orderedListRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let range = Range(match.range, in: trimmed)
        else { return nil }
        let prefix = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        let number = prefix.split(separator: ".").first.map(String.init) ?? "1"
        let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .ordered(indent: indent, number: number, text: text)
    }

    /// Detects a GFM task-list prefix on an unordered item's text. Returns the
    /// checked state plus the text with the `[ ] `/`[x] ` marker stripped, or
    /// nil when the item is not a task (GFM requires whitespace after `]`).
    private static func taskCheckbox(_ text: String) -> (checked: Bool, remainder: String)? {
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
            if text == prefix {
                return (checked, "")
            }
            if text.hasPrefix(prefix + " ") {
                return (checked, String(text.dropFirst(prefix.count + 1)))
            }
        }
        return nil
    }

    // MARK: Paragraphs

    private static func parseParagraph(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var parts: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if
                trimmed.isEmpty ||
                trimmed.hasPrefix("```") ||
                trimmed.hasPrefix(">") ||
                parseHeader(trimmed) != nil ||
                isHorizontalRule(trimmed) ||
                parseListItem(line) != nil ||
                looksLikeTableStart(lines, index)
            {
                break
            }

            parts.append(trimmed)
            index += 1
        }

        return (.paragraph(inline: parseInline(parts.joined(separator: " "))), index)
    }

    /// Cheap check to end a paragraph at a table without building the whole table
    /// on every line (avoids the previous O(n^2) look-ahead).
    private static func looksLikeTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|") else { return false }
        return parseTableSeparatorRow(lines[i + 1]) != nil
    }

    // MARK: Inline parse (theme-independent)

    /// Parses inline markdown (bold/italic/code/links) into an AttributedString
    /// carrying presentation intents and links but no colors/fonts. Done once
    /// per content change; the views apply theme styling cheaply at render time.
    private static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
