import AppKit
import LumenCore
import SwiftUI

/// Renders the block structure of a message with inline Markdown styling.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .code(let language):
                    codeBlock(block.text, language: language)
                case .heading(let level):
                    inline(block.text)
                        .font(.system(size: level == 1 ? 21 : level == 2 ? 17 : 15, weight: .semibold))
                        .padding(.top, LumenStyle.space1)
                case .listItem(let marker):
                    HStack(alignment: .top, spacing: LumenStyle.space2) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                        inline(block.text)
                    }
                    .accessibilityElement(children: .combine)
                case .quote:
                    HStack(spacing: LumenStyle.space2) {
                        Rectangle().fill(.tertiary).frame(width: 2)
                        inline(block.text).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .paragraph:
                    inline(block.text)
                case .table(let header, let rows):
                    table(header: header, rows: rows)
                }
            }
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        MarkdownTableLayout(columns: header.count, rows: rows.count + 1) {
            ForEach(header.indices, id: \.self) { index in
                tableCell(header[index], header: true, last: index == header.count - 1)
            }
            ForEach(rows.indices, id: \.self) { row in
                ForEach(header.indices, id: \.self) { index in
                    tableCell(rows[row].indices.contains(index) ? rows[row][index] : "",
                              header: false, last: index == header.count - 1)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous)
            .strokeBorder(LumenStyle.separator))
    }

    private func tableCell(_ text: String, header: Bool, last: Bool) -> some View {
        inlineText(text)
            .font(.callout.weight(header ? .semibold : .regular))
            .textSelection(.enabled)
            .padding(.horizontal, LumenStyle.space3)
            .padding(.vertical, LumenStyle.space2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(header ? Color.primary.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LumenStyle.separator).frame(height: 1)
            }
            .overlay(alignment: .trailing) {
                if !last { Rectangle().fill(LumenStyle.separator).frame(width: 1) }
            }
    }

    private func codeBlock(_ code: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }.buttonStyle(.borderless).accessibilityLabel("Copy code block")
            }
            .padding(.horizontal, LumenStyle.space3).padding(.vertical, LumenStyle.space2)
            Divider()
            ScrollView(.horizontal) {
                Text(highlight(code)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(LumenStyle.space3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous).strokeBorder(LumenStyle.separator))
    }

    private func inlineText(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    private func inline(_ text: String) -> some View {
        inlineText(text)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlight(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        // ponytail: lightweight language-neutral highlighting; use a grammar engine if richer language support is needed.
        let patterns: [(String, Color)] = [
            (#"\b(func|let|var|if|else|return|class|struct|enum|import|public|private|async|await|throw|throws|try|def|from|const|function|for|while|in|true|false|nil|null|None)\b"#, .purple),
            (#"\b[0-9]+(?:\.[0-9]+)?\b"#, .orange),
            (#"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'"#, .green),
            (#"(?m)//[^\n]*$|^[ \t]*#[^\n]*$"#, .secondary)
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range, in: source),
                      let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[lower..<upper].foregroundColor = color
            }
        }
        return result
    }
}

/// Fits a table to the transcript width: each column keeps its natural width
/// when it can, wide columns wrap, and the extra space goes to the last column.
private struct MarkdownTableLayout: Layout {
    let columns: Int
    let rows: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(subviews, available: proposal.width)
        let heights = rowHeights(subviews, widths: widths)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(subviews, available: bounds.width)
        let heights = rowHeights(subviews, widths: widths)
        var y = bounds.minY
        var index = 0
        for row in 0..<rows {
            var x = bounds.minX
            for column in 0..<columns {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: widths[column], height: heights[row]))
                x += widths[column]
                index += 1
            }
            y += heights[row]
        }
    }

    private func widths(_ subviews: Subviews, available: CGFloat?) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var ideals = Array(repeating: CGFloat(0), count: columns)
        for row in 0..<rows {
            for column in 0..<columns {
                ideals[column] = max(ideals[column],
                    subviews[row * columns + column].sizeThatFits(.unspecified).width)
            }
        }
        let available = available ?? ideals.reduce(0, +)
        guard available > 0 else { return ideals }
        // The smallest column still needs room for its padding and a word or two.
        let minimum = min(72, available / CGFloat(columns))
        let natural = ideals.map { max($0, minimum) }
        if natural.reduce(0, +) <= available {
            var result = natural
            result[result.count - 1] += available - result.reduce(0, +)
            return result
        }
        // Shrink only columns wider than the shared threshold, so short label
        // columns keep their text on one line while prose wraps.
        var low = minimum
        var high = max(ideals.max() ?? available, minimum)
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let total = ideals.reduce(0) { $0 + min(max($1, minimum), mid) }
            if total > available { high = mid } else { low = mid }
        }
        let threshold = (low + high) / 2
        return ideals.map { min(max($0, minimum), threshold) }
    }

    private func rowHeights(_ subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        (0..<rows).map { row in
            (0..<columns).reduce(CGFloat(0)) { height, column in
                let size = subviews[row * columns + column]
                    .sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                return max(height, size.height)
            }
        }
    }
}
