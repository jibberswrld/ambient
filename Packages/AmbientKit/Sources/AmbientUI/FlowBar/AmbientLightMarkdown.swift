import SwiftUI

/// A block of light markdown: the subset a spoken assistant actually uses.
enum AmbientMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    /// `marker` is "•" for bullets or "3." for numbered items.
    case listItem(marker: String, text: String)
    case codeBlock(String)
}

enum AmbientLightMarkdownParser {
    /// Splits text into blocks. Tolerates text that is still streaming: an unclosed code fence is shown as code.
    static func blocks(from markdownText: String) -> [AmbientMarkdownBlock] {
        var parsedBlocks: [AmbientMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false

        func flushParagraph() {
            let paragraphText = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !paragraphText.isEmpty { parsedBlocks.append(.paragraph(paragraphText)) }
            paragraphLines = []
        }

        for rawLine in markdownText.components(separatedBy: "\n") {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                if isInsideCodeFence {
                    parsedBlocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                    codeLines = []
                } else {
                    flushParagraph()
                }
                isInsideCodeFence.toggle()
                continue
            }
            if isInsideCodeFence {
                codeLines.append(rawLine)
                continue
            }
            if trimmedLine.isEmpty {
                flushParagraph()
                continue
            }
            if let headingText = headingText(in: trimmedLine) {
                flushParagraph()
                parsedBlocks.append(.heading(headingText))
            } else if let bulletText = bulletText(in: trimmedLine) {
                flushParagraph()
                parsedBlocks.append(.listItem(marker: "•", text: bulletText))
            } else if let numbered = numberedItem(in: trimmedLine) {
                flushParagraph()
                parsedBlocks.append(.listItem(marker: numbered.marker, text: numbered.text))
            } else {
                paragraphLines.append(trimmedLine)
            }
        }
        if isInsideCodeFence, !codeLines.isEmpty { parsedBlocks.append(.codeBlock(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return parsedBlocks
    }

    private static func headingText(in line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let withoutHashes = line.drop(while: { $0 == "#" })
        guard withoutHashes.first == " " else { return nil }
        return withoutHashes.trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(in line: String) -> String? {
        for bulletPrefix in ["- ", "* ", "• "] where line.hasPrefix(bulletPrefix) {
            return String(line.dropFirst(bulletPrefix.count))
        }
        return nil
    }

    private static func numberedItem(in line: String) -> (marker: String, text: String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let remainder = line.dropFirst(digits.count)
        guard remainder.hasPrefix(". ") || remainder.hasPrefix(") ") else { return nil }
        return (marker: "\(digits).", text: String(remainder.dropFirst(2)))
    }

    /// Emphasis, inline code and links inside one block, styled for smoked glass.
    static func inlineAttributedText(_ text: String, surface: AmbientCapsuleButton.Surface = .smokedGlass) -> AttributedString {
        let parseOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var attributedText = (try? AttributedString(markdown: text, options: parseOptions)) ?? AttributedString(text)
        for run in attributedText.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributedText[run.range].font = .system(size: 12.5, weight: .medium, design: .monospaced)
                attributedText[run.range].foregroundColor = surface == .window ? AmbientDesign.Palette.accentText : AmbientDesign.Palette.emberCore
            }
            if run.link != nil {
                attributedText[run.range].foregroundColor = surface == .window ? AmbientDesign.Palette.accentText : AmbientDesign.Palette.ember
                attributedText[run.range].underlineStyle = .single
            }
        }
        return attributedText
    }
}

/// Renders light markdown on smoked glass, or on a window surface for long reports.
struct AmbientLightMarkdownView: View {
    var markdownText: String
    var surface: AmbientCapsuleButton.Surface = .smokedGlass

    private var textColor: Color { surface == .window ? AmbientDesign.Palette.primaryText : AmbientDesign.Palette.onSmokePrimary }
    private var markerColor: Color { surface == .window ? AmbientDesign.Palette.accentText : AmbientDesign.Palette.ember.opacity(0.9) }
    private var codeBlockFill: Color { surface == .window ? AmbientDesign.Palette.quietFill : Color.black.opacity(0.28) }

    var body: some View {
        let parsedBlocks = AmbientLightMarkdownParser.blocks(from: markdownText)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AmbientMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let paragraphText):
            Text(AmbientLightMarkdownParser.inlineAttributedText(paragraphText, surface: surface))
                .font(AmbientDesign.Typeface.replyBody)
                .lineSpacing(AmbientDesign.Typeface.replyBodyLineSpacing)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let headingText):
            Text(AmbientLightMarkdownParser.inlineAttributedText(headingText, surface: surface))
                .font(.system(size: surface == .window ? 15 : 13.5, weight: .semibold))
                .padding(.top, surface == .window ? 6 : 0)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let itemText):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(markerColor)
                    .frame(minWidth: 10, alignment: .trailing)
                Text(AmbientLightMarkdownParser.inlineAttributedText(itemText, surface: surface))
                    .font(AmbientDesign.Typeface.replyBody)
                    .lineSpacing(AmbientDesign.Typeface.replyBodyLineSpacing)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(let codeText):
            Text(codeText)
                .font(AmbientDesign.Typeface.monospacedDetail)
                .foregroundStyle(textColor)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).fill(codeBlockFill))
        }
    }
}
