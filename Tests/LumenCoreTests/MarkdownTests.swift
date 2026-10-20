import Testing
@testable import LumenCore

@Suite struct MarkdownTests {
    @Test func blocksPreserveStructureAndCodeDuringStreaming() {
        let source = "# Summary\n\nA **clear** answer.\n\n- First item\n2. Second item\n> A quote\n\n```swift\nlet value = 1\n\n# Not a heading\n```\n\nNext paragraph"
        let blocks = MarkdownBlock.parse(source)
        #expect(blocks.map(\.kind) == [.heading(1), .paragraph, .listItem("•"), .listItem("2."), .quote, .code("swift"), .paragraph])
        #expect(blocks[5].text == "let value = 1\n\n# Not a heading")
        #expect(MarkdownBlock.parse("```\npartial code").first?.kind == .code(""))
        #expect(MarkdownBlock.parse("```\npartial code").first?.text == "partial code")
        #expect(MarkdownBlock.parse("a\nb").first?.text == "a\nb")
        #expect(MarkdownBlock.parse("#tag").first?.kind == .paragraph)
        #expect(MarkdownBlock.parse("\n\n").isEmpty)
    }

    @Test func parsesTablesWithAlignmentEscapedPipesAndShortRows() {
        let source = """
        Before

        | Name | Value | Notes |
        | :--- | ---: | :---: |
        | alpha | 1 | has \\| pipe |
        | beta |
        | gamma | 3 | extra | ignored |

        After
        """
        let blocks = MarkdownBlock.parse(source)
        #expect(blocks.map(\.kind) == [
            .paragraph,
            .table(header: ["Name", "Value", "Notes"],
                   rows: [["alpha", "1", "has \\| pipe"], ["beta", "", ""], ["gamma", "3", "extra"]]),
            .paragraph
        ])
        #expect(blocks.first?.text == "Before")
        #expect(blocks.last?.text == "After")
    }

    @Test func tableSyntaxWithoutADelimiterRowStaysParagraphText() {
        #expect(MarkdownBlock.parse("a | b\nnot a table").first?.kind == .paragraph)
        #expect(MarkdownBlock.parse("```\na | b\n--- | ---\n```").first?.kind == .code(""))
        #expect(MarkdownBlock.parse("a | b\n--- | ---").first?.kind == .table(header: ["a", "b"], rows: []))
    }
}
