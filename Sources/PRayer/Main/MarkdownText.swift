import SwiftUI
import PRayerCore

/// GitHub 마크다운을 읽기 좋게 그린다.
/// 블록(제목·목록·인용·코드펜스)은 직접 나누고, 줄 안의 서식(굵게·인라인 코드·링크)만 AttributedString 에 맡긴다.
struct MarkdownText: View {
    @Environment(AppModel.self) private var model
    @Environment(\.codeLinks) private var codeLinks
    let text: String
    /// 지정하지 않으면 설정의 코멘트 폰트를 쓴다.
    var baseFont: Font?
    var codeFont: Font?

    private var body_: Font { baseFont ?? model.fonts.comment() }
    /// 코멘트 안의 코드 블록·인라인 코드는 코드용 폰트를 따른다.
    private var code_: Font { codeFont ?? model.fonts.code() }

    /// 간격·제목 크기를 재는 기준 글자 크기. GitHub 마크다운 CSS(14px 기준)의 값을 이 크기에 맞춰 늘리고 줄인다.
    private var size: CGFloat { CGFloat(model.settings.commentFontSize) }

    /// GitHub 과 같은 모양(사용자 결정, 2026-10-28)의 수치. github-markdown-css 를 글자 크기 비율로 옮겼다.
    private enum GitHubStyle {
        /// 줄 높이 1.5 — SwiftUI 기본 줄 높이(약 1.2)에 0.3 을 더 띄운다.
        static let lineSpacing: CGFloat = 0.3
        /// 문단·목록·표·코드 블록 아래 16px, 제목 위 24px, 목록 항목 사이 0.25em.
        static let blockGap: CGFloat = 16.0 / 14
        static let headingGap: CGFloat = 24.0 / 14
        static let listItemGap: CGFloat = 0.25
        /// 한 줄이 너무 길면 읽기 힘들다. GitHub 대화 칸의 글 폭(약 820px)쯤에서 멈춘다.
        static let readableWidth: CGFloat = 60
        /// 목록 들여쓰기 2em — 글머리·번호는 그 안쪽 칸에 오른쪽 맞춤으로 단다.
        static let listIndent: CGFloat = 2
        static let border = Color.primary.opacity(0.16)
        static let mutedFill = Color.primary.opacity(0.04)
    }

    var body: some View {
        let blocks = MarkdownParser.blocks(from: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                view(for: blocks[index])
                    .padding(.top, index == 0 ? 0 : gap(after: blocks[index - 1].kind, before: blocks[index].kind))
            }
        }
        .lineSpacing(size * GitHubStyle.lineSpacing)
        .frame(maxWidth: size * GitHubStyle.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .task(id: codeLinks?.pr.id) {
            // 코드 표기를 diff 로 이으려면 diff 가 있어야 한다. 개요 탭만 연 채로는 아직 안 받았을 수 있다
            // (AI 리뷰·변경 파일 탭이 받는다). 코드 표기가 있는 글을 펼쳤을 때만 받는다 — 받은 diff 는 커밋별로 디스크에 남는다.
            guard let codeLinks, text.contains("`"), model.parsedDiff(for: codeLinks.pr) == nil else {
                return
            }
            await model.loadDiff(for: codeLinks.pr)
        }
    }

    /// 블록 사이 간격. GitHub 은 위아래 여백이 겹치면 큰 쪽만 남으므로 앞뒤 블록 종류로 한 값만 고른다.
    private func gap(after previous: MarkdownBlock.Kind, before next: MarkdownBlock.Kind) -> CGFloat {
        if case .heading = next {
            return size * GitHubStyle.headingGap
        }
        if previous.isListItem, next.isListItem {
            return size * GitHubStyle.listItemGap
        }
        return size * GitHubStyle.blockGap
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.text)
                .font(body_)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level):
            // h1·h2 는 GitHub 처럼 밑줄을 긋는다.
            VStack(alignment: .leading, spacing: size * 0.3) {
                inline(block.text)
                    .font(headingFont(level))
                    .foregroundStyle(level == 6 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 {
                    Rectangle().fill(GitHubStyle.border).frame(height: 1)
                }
            }

        case .bullet(let indent):
            listItem(indent: indent, text: block.text) {
                Text(indent > 0 ? "◦" : "•")
                    .font(body_)
            }

        case .task(let indent, let done):
            listItem(indent: indent, text: block.text) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(body_)
                    .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }

        case .ordered(let number, let indent):
            listItem(indent: indent, text: block.text) {
                Text("\(number).")
                    .font(body_.monospacedDigit())
            }

        case .quote:
            HStack(alignment: .top, spacing: size) {
                Rectangle().fill(GitHubStyle.border).frame(width: max(3, size * 0.25))
                inline(block.text)
                    .font(body_)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language):
            if CodeSyntax.profile(forLanguage: language)?.isDiff == true {
                DiffCodeBlock(code: block.text, font: code_, size: size)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let language, !language.isEmpty {
                        Text(language)
                            .font(model.fonts.ui(delta: -4))
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Group {
                            // 색은 변경 파일 탭 diff 와 같은 Xcode 풍(사용자 결정 — GitHub 색보다 낫다).
                            if let profile = CodeSyntax.profile(forLanguage: language) {
                                SwiftCodeText(code: block.text, profile: profile, font: code_)
                            } else {
                                Text(block.text).font(code_)
                            }
                        }
                        .lineSpacing(size * 0.2)
                    }
                }
                .padding(size * GitHubStyle.blockGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GitHubStyle.mutedFill, in: RoundedRectangle(cornerRadius: 6))
            }

        case .rule:
            Rectangle()
                .fill(GitHubStyle.border)
                .frame(height: max(2, size * 0.25))
                .padding(.vertical, size * 0.5)

        case .table(let table):
            tableView(table)

        case .images(let images):
            MarkdownImagesView(images: images)
        }
    }

    /// 목록 한 줄. 글머리·번호·체크 상자는 들여쓴 칸(2em) 안쪽에 오른쪽 맞춤으로 두어, 줄이 넘어가도 글이 한 줄에 선다.
    private func listItem<Marker: View>(indent: Int, text: String, @ViewBuilder marker: () -> Marker) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.4) {
            marker()
                .foregroundStyle(.secondary)
                .frame(width: size * (GitHubStyle.listIndent - 0.4), alignment: .trailing)
            inline(text)
                .font(body_)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indent) * size * GitHubStyle.listIndent)
    }

    /// GitHub 처럼 칸마다 선을 긋고 머리 줄은 굵게, 몸 줄은 둘째 줄부터 한 줄 걸러 옅게 깐다(모서리는 각지게).
    /// 칸 폭은 내용에 맞추고(TableLayout), 창보다 넓으면 넓은 열만 줄바꿈한다 — GitHub 은 옆으로 스크롤하지만
    /// 여기 칸은 좁아서 스크롤이 더 불편하다.
    private func tableView(_ table: MarkdownTable) -> some View {
        let columns = table.header.count
        let rows = [table.header] + table.rows
        return TableLayout(columns: columns) {
            ForEach(0..<(rows.count * columns), id: \.self) { index in
                let row = index / columns
                let column = index % columns
                tableCell(rows[row][column], alignment: table.alignments[column], row: row,
                          isLastRow: row == rows.count - 1, isLastColumn: column == columns - 1)
            }
        }
        .overlay(Rectangle().strokeBorder(GitHubStyle.border))
    }

    /// `row` 0 이 머리 줄이다.
    private func tableCell(_ text: String, alignment: MarkdownTable.Alignment, row: Int,
                           isLastRow: Bool, isLastColumn: Bool) -> some View {
        let (frame, textAlignment): (Alignment, TextAlignment) = switch alignment {
        case .leading: (.leading, .leading)
        case .center: (.center, .center)
        case .trailing: (.trailing, .trailing)
        }
        let background = row > 0 && row.isMultiple(of: 2) ? GitHubStyle.mutedFill : .clear
        return inline(text)
            .font(row == 0 ? body_.weight(.semibold) : body_)
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            // GitHub 칸 여백 6px 13px.
            .padding(.horizontal, size * 13 / 14)
            .padding(.vertical, size * 6 / 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frame)
            .background(background)
            .overlay(alignment: .trailing) {
                if !isLastColumn {
                    Rectangle().fill(GitHubStyle.border).frame(width: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if !isLastRow {
                    Rectangle().fill(GitHubStyle.border).frame(height: 1)
                }
            }
    }

    /// GitHub 제목 크기 — h1 2em · h2 1.5em · h3 1.25em · h4 1em · h5 0.875em · h6 0.85em, 모두 semibold.
    private func headingFont(_ level: Int) -> Font {
        let scale: CGFloat = switch level {
        case 1: 2
        case 2: 1.5
        case 3: 1.25
        case 4: 1
        case 5: 0.875
        default: 0.85
        }
        return model.fonts.comment(size: size * scale, weight: .semibold)
    }

    /// 줄 안 서식을 입힌 글. 인라인 코드 조각은 따로 떼어 표시(InlineCodeAttribute)를 붙인다 — 뒤 겹의 TextRenderer 가
    /// 그 조각 뒤에만 둥근 상자를 그린다(InlineCodeStyle). 코드 링크 환경이 있으면 diff 에서 찾은 조각에 번호를 달아
    /// 그 자리에서 코드를 미리 보고 diff 로 갈 수 있게 한다.
    private func inline(_ source: String) -> InlineCodeText {
        // 블록은 이미 분리했으므로 줄 안 서식만 해석한다.
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let codeRanges = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        guard !codeRanges.isEmpty else {
            return InlineCodeText(text: Text(text), hasCode: false, size: size)
        }
        let look = InlineCodeStyle.current
        let padding = size * look.horizontalPadding
        let diff = codeLinks.flatMap { model.parsedDiff(for: $0.pr) }
        var links: [CodeReference] = []
        // 코드 조각마다 links 의 몇 번째인지(못 찾았으면 nil). codeRanges 와 같은 순서다.
        var linkNumbers: [Int?] = []
        for range in codeRanges {
            var link: Int?
            if let diff, let reference = CodeReferenceScanner.reference(forCode: String(text[range].characters), in: diff) {
                link = links.count
                links.append(reference)
            }
            linkNumbers.append(link)
            // 85% 크기 고정폭에 파랑 글자·중간 굵기가 기본(InlineCodeLook.standard). 본문 크기 그대로면 한글 사이에서 무거웠다.
            text[range].swiftUI.font = look.monospaced
                ? model.fonts.code(size: size * look.fontScale, weight: look.weight)
                : model.fonts.comment(size: size * look.fontScale, weight: look.weight)
            text[range].swiftUI.foregroundColor = look.text
            // 마크다운이 붙인 "코드" 표시가 남아 있으면 SwiftUI 가 위 글꼴을 고정폭으로 바꿔 그린다(실측: 고정폭을 꺼도
            // 고정폭으로 보였다). 본문 글꼴로 쓸 때는 그 표시를 뗀다 — 코드 조각은 위에서 이미 codeRanges 로 골라 두었다.
            if !look.monospaced {
                for run in text[range].runs {
                    var intent = run.inlinePresentationIntent
                    intent?.remove(.code)
                    text[run.range].inlinePresentationIntent = intent
                }
            }
            if #unavailable(macOS 15.0) {
                text[range].swiftUI.backgroundColor = look.fill
            }
            // 상자 앞뒤 여백 — 앞 글자와 코드 마지막 글자 뒤를 그만큼 띄운다.
            let characters = text.characters
            if range.lowerBound > characters.startIndex {
                let before = characters.index(before: range.lowerBound)
                text[before..<range.lowerBound].swiftUI.kern = padding
            }
            // diff 에서 찾은 코드는 끝에 눈 표식(CodeLinkMark) 자리를 더 비운다. 렌더러가 없는 macOS 14 는 표식도 단추도 없다.
            var trailing = padding
            if link != nil, #available(macOS 15.0, *) {
                trailing += CodeLinkMark.space(codeSize: size * look.fontScale)
            }
            let last = characters.index(before: range.upperBound)
            text[last..<range.upperBound].swiftUI.kern = trailing
        }
        // 코드 조각마다 표시를 붙이려고 조각별 Text 로 나눠 다시 잇는다.
        var pieces: [Text] = []
        var cursor = text.startIndex
        for (range, link) in zip(codeRanges, linkNumbers) {
            if cursor < range.lowerBound {
                pieces.append(Text(AttributedString(text[cursor..<range.lowerBound])))
            }
            pieces.append(Text(AttributedString(text[range])).customAttribute(InlineCodeAttribute(link: link)))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            pieces.append(Text(AttributedString(text[cursor..<text.endIndex])))
        }
        let joined = pieces.dropFirst().reduce(pieces[0]) { Text("\($0)\($1)") }
        return InlineCodeText(text: joined, hasCode: true, size: size, links: links, context: codeLinks)
    }
}

/// 표 칸 배치. 칸은 행 순서로 `columns` 개씩 들어온다.
///
/// Grid 에 맡기면 칸이 모두 같은 폭으로 나뉘어 짧은 열("기기")도 긴 열만큼 넓었다. GitHub 처럼 각 열은 가장 긴 칸의
/// 한 줄 폭을 갖고, 다 못 들어가면 고르게 나눈 몫보다 좁은 열은 그대로 두고 넓은 열끼리 남은 폭을 나눠 줄바꿈한다.
/// 한 줄의 칸은 그 줄에서 가장 높은 칸 높이를 받아 바탕·선이 끝까지 닿는다.
private struct TableLayout: Layout {
    let columns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (widths, heights) = measure(proposal.width, subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (widths, heights) = measure(bounds.width, subviews)
        var y = bounds.minY
        for row in heights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else {
                    return
                }
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: widths[column], height: heights[row]))
                x += widths[column]
            }
            y += heights[row]
        }
    }

    private func measure(_ available: CGFloat?, _ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else {
            return ([], [])
        }
        var ideal = Array(repeating: CGFloat(0), count: columns)
        for (index, cell) in subviews.enumerated() {
            ideal[index % columns] = max(ideal[index % columns], ceil(cell.sizeThatFits(.unspecified).width))
        }
        let widths = Self.fit(ideal, into: available)
        var heights = Array(repeating: CGFloat(0), count: (subviews.count + columns - 1) / columns)
        for (index, cell) in subviews.enumerated() {
            let height = cell.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], height)
        }
        return (widths, heights)
    }

    private static func fit(_ ideal: [CGFloat], into available: CGFloat?) -> [CGFloat] {
        guard let available, ideal.reduce(0, +) > available else {
            return ideal
        }
        var kept = Set<Int>()
        while true {
            let remaining = available - kept.reduce(0) { $0 + ideal[$1] }
            let open = ideal.indices.filter { !kept.contains($0) }
            let share = remaining / CGFloat(max(open.count, 1))
            let narrow = open.filter { ideal[$0] <= share }
            if narrow.isEmpty {
                let total = open.reduce(0) { $0 + ideal[$1] }
                return ideal.indices.map { kept.contains($0) ? ideal[$0] : max(remaining * ideal[$0] / max(total, 1), 1) }
            }
            kept.formUnion(narrow)
        }
    }
}

private extension MarkdownBlock.Kind {
    var isListItem: Bool {
        switch self {
        case .bullet, .task, .ordered: true
        default: false
        }
    }
}
