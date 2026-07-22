import AppKit

// AppKit rendering for the Quick Look preview. Ports the app's Theme palette,
// FontSize ladder, encoding fallback, and inline-styling rules (main.swift's
// styledInline) into NSAttributedString terms. Deliberately a SEPARATE render
// path from the SwiftUI app — kept visually in sync by hand — because the
// block views in main.swift are entangled with SwiftUI. Shares only the
// SwiftUI-free MarkdownRenderer parser.

// MARK: - Theme (NSColor port of main.swift's Theme, same hex values)

struct QLTheme {
    let bg, surface, card, hover, border: NSColor
    let text, textMuted, textHeading: NSColor
    let accent, green, amber, red, cyan: NSColor

    static let dark = QLTheme(
        bg: NSColor(hex: 0x0f1117), surface: NSColor(hex: 0x161922),
        card: NSColor(hex: 0x1c1f2e), hover: NSColor(hex: 0x242838),
        border: NSColor(hex: 0x2a2e3f),
        text: NSColor(hex: 0xe1e4ed), textMuted: NSColor(hex: 0x8b90a5),
        textHeading: NSColor(hex: 0xf5f7fb),
        accent: NSColor(hex: 0x7c8aff), green: NSColor(hex: 0x4ade80),
        amber: NSColor(hex: 0xfbbf24), red: NSColor(hex: 0xf87171),
        cyan: NSColor(hex: 0x22d3ee)
    )

    static let light = QLTheme(
        bg: NSColor(hex: 0xffffff), surface: NSColor(hex: 0xf6f8fa),
        card: NSColor(hex: 0xf0f2f5), hover: NSColor(hex: 0xe8eaed),
        border: NSColor(hex: 0xd0d7de),
        text: NSColor(hex: 0x24292f), textMuted: NSColor(hex: 0x57606a),
        textHeading: NSColor(hex: 0x1c2128),
        accent: NSColor(hex: 0x0969da), green: NSColor(hex: 0x1a7f37),
        amber: NSColor(hex: 0x9a6700), red: NSColor(hex: 0xcf222e),
        cyan: NSColor(hex: 0x0550ae)
    )

    static func forAppearance(_ appearance: NSAppearance) -> QLTheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension NSColor {
    convenience init(hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

// MARK: - Font ladder (verbatim from main.swift's FontSize)

private enum FontSize {
    static let body: CGFloat = 14
    static let h1: CGFloat = 30
    static let h2: CGFloat = 21
    static let h3: CGFloat = 16
    static let h4: CGFloat = 13.5
    static let h5: CGFloat = 13
    static let h6: CGFloat = 12.5
    static let inlineCode: CGFloat = 12.5
    static let codeBlock: CGFloat = 12.5
    static let tableHeader: CGFloat = 11
    static let tableCell: CGFloat = 13.5

    static func heading(_ level: Int) -> CGFloat {
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

// MARK: - Renderer

enum PreviewRenderer {
    /// Far below the app's 20 MB guard: quicklookd kills slow/hungry previews
    /// (they fail silently to a generic icon), so cap hard and note truncation.
    static let maxBytes = 2 * 1024 * 1024

    static func render(fileURL: URL, theme: QLTheme) -> NSAttributedString {
        let (text, truncated) = readCapped(fileURL)
        let out = NSMutableAttributedString()
        for rendered in MarkdownRenderer.parse(text) {
            append(rendered.block, to: out, theme: theme)
        }
        if truncated {
            appendLine(
                "… preview truncated (file exceeds \(maxBytes / (1024 * 1024)) MB) — open in Margins for the full document",
                to: out, font: .systemFont(ofSize: FontSize.body, weight: .regular),
                color: theme.textMuted, spacingBefore: 16, spacing: 0
            )
        }
        return out
    }

    // MARK: File reading (size cap + encoding fallback, ported from ViewerModel)

    private static func readCapped(_ url: URL) -> (text: String, truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        let truncated = data.count > maxBytes
        let capped = truncated ? data.prefix(maxBytes) : data
        return (decodeText(Data(capped)), truncated)
    }

    /// UTF-8, then UTF-16 (only with a BOM), then the common single-byte
    /// encodings — identical chain to the app's ViewerModel.decodeText.
    private static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return s
        }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Inline styling (NSAttributedString port of styledInline)

    private static func inlineToNS(
        _ inline: AttributedString, size: CGFloat, weight: NSFont.Weight,
        baseColor: NSColor, theme: QLTheme
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in inline.runs {
            let piece = NSMutableAttributedString(string: String(inline[run.range].characters))
            let range = NSRange(location: 0, length: piece.length)

            var font = NSFont.systemFont(ofSize: size, weight: weight)
            var color = baseColor
            var background: NSColor?

            if run.link != nil { color = theme.accent }

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: FontSize.inlineCode, weight: .regular)
                    color = theme.cyan
                    background = theme.card
                } else if intent.contains(.stronglyEmphasized) {
                    font = .systemFont(ofSize: size, weight: .bold)
                } else if intent.contains(.emphasized) {
                    font = italic(size: size, weight: weight)
                }
            }

            piece.addAttribute(.font, value: font, range: range)
            piece.addAttribute(.foregroundColor, value: color, range: range)
            if let background { piece.addAttribute(.backgroundColor, value: background, range: range) }
            result.append(piece)
        }
        return result
    }

    private static func italic(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    // MARK: Block rendering

    private static func append(_ block: MarkdownBlock, to out: NSMutableAttributedString, theme: QLTheme) {
        switch block {
        case let .frontmatter(fields):
            for field in fields {
                let line = NSMutableAttributedString(
                    string: field.key.uppercased() + "  ",
                    attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                 .foregroundColor: theme.textMuted]
                )
                line.append(NSAttributedString(
                    string: field.value,
                    attributes: [.font: NSFont.systemFont(ofSize: FontSize.body, weight: .regular),
                                 .foregroundColor: theme.text]
                ))
                appendBlockLine(line, to: out, style: paragraph(spacing: 3), tint: theme.card)
            }
            addSpacing(6, to: out)

        case let .heading(level, inline):
            let weight: NSFont.Weight = level == 1 ? .heavy : (level == 2 ? .bold : .semibold)
            let color: NSColor = level >= 4 ? theme.accent : theme.textHeading
            let line = inlineToNS(inline, size: FontSize.heading(level), weight: weight, baseColor: color, theme: theme)
            appendBlockLine(line, to: out, style: paragraph(spacingBefore: headingTop(level), spacing: 6))

        case let .paragraph(inline):
            let line = inlineToNS(inline, size: FontSize.body, weight: .regular, baseColor: theme.text, theme: theme)
            appendBlockLine(line, to: out, style: paragraph(spacing: 10, lineSpacing: 3))

        case let .list(items):
            for item in items {
                let indent = CGFloat(item.indent) * 18 + 2
                let style = paragraph(spacing: 4, lineSpacing: 3)
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 16

                let markerText: String
                let markerColor: NSColor
                if let checked = item.checkbox {
                    markerText = (checked ? "☑︎" : "☐") + "  "
                    markerColor = checked ? theme.accent : theme.textMuted
                } else {
                    markerText = item.marker + "  "
                    markerColor = theme.textMuted
                }
                let line = NSMutableAttributedString(
                    string: markerText,
                    attributes: [.font: NSFont.systemFont(ofSize: FontSize.body), .foregroundColor: markerColor]
                )
                line.append(inlineToNS(item.inline, size: FontSize.body, weight: .regular, baseColor: theme.text, theme: theme))
                appendBlockLine(line, to: out, style: style)
            }
            addSpacing(6, to: out)

        case let .code(_, rawLines):
            let style = paragraph(spacingBefore: 4, spacing: 10, lineSpacing: 2)
            style.firstLineHeadIndent = 10
            style.headIndent = 10
            let line = NSMutableAttributedString(
                string: rawLines.joined(separator: "\n"),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: FontSize.codeBlock, weight: .regular),
                             .foregroundColor: theme.text,
                             .backgroundColor: theme.card]
            )
            appendBlockLine(line, to: out, style: style)

        case let .table(header, rows, alignments):
            appendTable(header: header, rows: rows, alignments: alignments, to: out, theme: theme)

        case let .callout(kind, inline):
            let color = calloutColor(kind, theme)
            let style = paragraph(spacingBefore: 4, spacing: 10, lineSpacing: 3)
            style.firstLineHeadIndent = 8
            style.headIndent = 18
            let line = NSMutableAttributedString(
                string: "▌ ",
                attributes: [.font: NSFont.systemFont(ofSize: FontSize.body, weight: .bold), .foregroundColor: color]
            )
            if let title = kind.title {
                line.append(NSAttributedString(
                    string: title + "   ",
                    attributes: [.font: NSFont.systemFont(ofSize: FontSize.body, weight: .semibold), .foregroundColor: color]
                ))
            }
            line.append(inlineToNS(inline, size: FontSize.body, weight: .regular, baseColor: theme.text, theme: theme))
            appendBlockLine(line, to: out, style: style, tint: color.withAlphaComponent(0.1))

        case .rule:
            appendLine(
                String(repeating: "—", count: 48), to: out,
                font: .systemFont(ofSize: FontSize.body), color: theme.border,
                spacingBefore: 8, spacing: 8
            )
        }
    }

    private static func appendTable(
        header: [AttributedString], rows: [[AttributedString]], alignments: [HAlign],
        to out: NSMutableAttributedString, theme: QLTheme
    ) {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }

        let style = paragraph(spacing: 3, lineSpacing: 2)
        // Tab stops approximate columns (no true column layout in a text run).
        style.tabStops = (1...columns).map { i in
            NSTextTab(textAlignment: .left, location: CGFloat(i) * 150)
        }

        func rowLine(_ cells: [AttributedString], size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSMutableAttributedString {
            let line = NSMutableAttributedString()
            for (i, cell) in cells.enumerated() {
                line.append(inlineToNS(cell, size: size, weight: weight, baseColor: color, theme: theme))
                if i < cells.count - 1 {
                    line.append(NSAttributedString(string: "\t"))
                }
            }
            return line
        }

        appendBlockLine(
            rowLine(header, size: FontSize.tableHeader, weight: .semibold, color: theme.textMuted),
            to: out, style: style
        )
        for row in rows {
            appendBlockLine(
                rowLine(row, size: FontSize.tableCell, weight: .regular, color: theme.text),
                to: out, style: style
            )
        }
        addSpacing(6, to: out)
    }

    private static func calloutColor(_ kind: CalloutKind, _ theme: QLTheme) -> NSColor {
        switch kind {
        case .note, .important: return theme.accent
        case .tip: return theme.green
        case .warning: return theme.amber
        case .caution: return theme.red
        case .plain: return theme.textMuted
        }
    }

    // MARK: Layout helpers

    private static func headingTop(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 8
        case 2: return 28
        case 3: return 16
        default: return 12
        }
    }

    private static func paragraph(
        spacingBefore: CGFloat = 0, spacing: CGFloat = 0, lineSpacing: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        style.lineSpacing = lineSpacing
        return style
    }

    /// Append one logical block line (may itself contain wrapped text), applying
    /// a paragraph style over the whole thing plus an optional background tint,
    /// terminated by a newline so the next block starts fresh.
    private static func appendBlockLine(
        _ line: NSMutableAttributedString, to out: NSMutableAttributedString,
        style: NSMutableParagraphStyle, tint: NSColor? = nil
    ) {
        line.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: 0, length: line.length)
        line.addAttribute(.paragraphStyle, value: style, range: range)
        if let tint { line.addAttribute(.backgroundColor, value: tint, range: range) }
        out.append(line)
    }

    private static func appendLine(
        _ string: String, to out: NSMutableAttributedString,
        font: NSFont, color: NSColor, spacingBefore: CGFloat, spacing: CGFloat
    ) {
        let line = NSMutableAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: color]
        )
        appendBlockLine(line, to: out, style: paragraph(spacingBefore: spacingBefore, spacing: spacing))
    }

    private static func addSpacing(_ points: CGFloat, to out: NSMutableAttributedString) {
        let style = paragraph(spacing: points)
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 2), .paragraphStyle: style,
        ]))
    }
}
