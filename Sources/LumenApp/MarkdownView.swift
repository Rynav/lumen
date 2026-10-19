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
                }
            }
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

    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
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
