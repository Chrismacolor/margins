import Foundation

// SwiftUI-free search/plain-text core, kept separate from the views so it can be
// unit-tested standalone (like MarkdownRenderer).

/// One occurrence of the search query within the document.
struct FindMatch: Equatable {
    let blockID: Int       // RenderedBlock.id — the scroll target
    let segmentID: String  // identifies the specific leaf Text holding the match
    let start: Int         // character offset of the match within that segment
}

/// Append a `FindMatch` for every case-insensitive occurrence of `query` in `text`.
func collectMatches(
    into result: inout [FindMatch],
    blockID: Int,
    segmentID: String,
    text: String,
    query: String
) {
    guard !query.isEmpty, !text.isEmpty else { return }
    var searchRange = text.startIndex..<text.endIndex
    while let r = text.range(of: query, options: .caseInsensitive, range: searchRange) {
        let start = text.distance(from: text.startIndex, to: r.lowerBound)
        result.append(FindMatch(blockID: blockID, segmentID: segmentID, start: start))
        searchRange = r.upperBound..<text.endIndex
    }
}

/// Clean, plain-text rendering of a single block (markup markers stripped).
/// Used by the per-block hover copy button.
func plainText(of block: MarkdownBlock) -> String {
    switch block {
    case let .frontmatter(fields):
        return fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    case let .heading(_, inline):
        return String(inline.characters)
    case let .paragraph(inline):
        return String(inline.characters)
    case let .callout(_, inline):
        return String(inline.characters)
    case let .list(items):
        return items.map { item in
            let task = item.checkbox.map { $0 ? "[x] " : "[ ] " } ?? ""
            return String(repeating: "    ", count: max(0, item.indent))
                + item.marker + " " + task + String(item.inline.characters)
        }.joined(separator: "\n")
    case let .code(_, rawLines):
        return rawLines.joined(separator: "\n")
    case let .table(header, rows, _):
        let lines = [header] + rows
        return lines.map { row in
            row.map { String($0.characters) }.joined(separator: "\t")
        }.joined(separator: "\n")
    case .rule:
        return ""
    }
}
