import SwiftUI

/// 목록 행 셋째 줄 조각의 역할. PRRowFactsLayout 이 어디에 놓을지 고르는 데 쓴다.
enum PRRowFactRole {
    /// 작성자·증감·승인 묶음. 늘 첫 줄 왼쪽.
    case who
    /// 레포 칩. 늘 첫 줄 오른쪽 끝.
    case chip
    /// 상태 태그(Conflict·Draft·Requested…) 하나.
    case tag
    /// 상태 태그와 라벨 사이 구분선. 태그·라벨을 한 줄로 늘어놓을 때만 보인다.
    case separator
    /// 라벨 줄.
    case labels
}

struct PRRowFactRoleKey: LayoutValueKey {
    static let defaultValue = PRRowFactRole.who
}

/// 목록 행 셋째 줄의 배치 — 받은 폭에 따라 셋 중 하나로 놓는다.
///
/// 1. 한 줄: `작성자 묶음  태그 │ 라벨 ······ 레포 칩`
/// 2. 두 줄: `작성자 묶음 ······ 레포 칩` 아래에 `태그 │ 라벨` 한 줄
/// 3. 감싸기: 2 의 첫 줄 아래에 태그(넘치면 다음 줄로 — FlowRow 와 같다), 그 아래 라벨(두 줄까지). 구분선은 숨긴다.
///
/// 고르는 규칙은 예전 `ViewThatFits(in: .horizontal)` 와 같다 — 그 배치를 폭 제한 없이 늘어놓은 폭(이상 폭)이
/// 받은 폭 이하면 그 배치, 아니면 다음 것, 셋째는 늘 된다. 간격도 예전 스택 그대로다 — 조각 사이 8, 태그·구분선·라벨
/// 사이 6, 줄 사이와 넘친 태그 사이 4, 작성자와 칩 사이는 `Spacer(minLength: 4)` 였으므로 최소 4 에 양옆 8.
///
/// 조각은 이상 크기 그대로 놓는다(줄이지 않는다). 예전 HStack 은 고른 배치 안에서 폭을 나눌 때 뒤의 Spacer·레포 칩
/// 몫까지 떼어 두고 남은 만큼만 태그에 줘서 `Confli…` 로 잘린 적이 있다. 줄어드는 것은 첫 줄도 안 들어갈 만큼 좁을 때의
/// 레포 칩뿐이다(예전에도 칩만 뒤를 잘랐다).
///
/// `ViewThatFits` 를 쓰지 않는 이유: 받은 폭이 바뀔 때마다 후보를 처음부터 다시 잰다. 목록 폭을 끌어 바꾸는 동안
/// 보이는 행마다 이 측정이 돌아 한 걸음에 30~48ms 가 걸렸다(실측: 데모 데이터·창 1440pt, 초당 20~30번밖에 못 그림).
/// 이 레이아웃으로 바꾼 뒤 목록만 볼 때는 측정 비용이 사라졌고(17.6ms — 실측 도구의 16ms 대기가 거의 전부),
/// AI 리뷰 탭을 띄워도 25ms 다. 조각들의 이상 폭은 목록 폭과 상관이 없어 SwiftUI 가 캐시해 두므로, 조각 한 벌을 두고
/// 폭만 비교해 놓으면 싸다. 같은 이유로 세 배치를 뷰 세 벌로 만들지 않는다.
///
/// 예전 `ViewThatFits` 판과 같게 그리는지는 표본 7개(태그·라벨·칩 조합) × 폭 150~520pt(1pt 간격)를 둘 다 그려
/// 픽셀·크기를 맞대어 확인했다(2026-10-20, 2,597번 모두 같음). 간격·순서를 바꾸면 이 비교를 다시 한다.
struct PRRowFactsLayout: Layout {
    /// 조각 사이 · 작성자 묶음 안의 간격.
    static let gap: CGFloat = 8
    /// 태그·구분선·라벨 사이.
    static let tagGap: CGFloat = 6
    /// 줄 사이 · 넘친 태그 사이(가로·세로 같다).
    static let lineGap: CGFloat = 4
    /// 작성자와 레포 칩 사이 최소 여백.
    static let spacerMin: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 받은 폭(proposal)으로 다시 계산한다 — 첫 줄이 넘쳐 보고한 폭이 받은 폭보다 크면 bounds 는 그 넓은 폭이라,
        // bounds 로 계산하면 크기를 잴 때와 다른 배치를 고를 수 있다.
        for item in plan(width: proposal.width ?? bounds.width, subviews: subviews).items {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                                       proposal: item.proposal)
        }
    }

    // MARK: - 배치 계산

    private struct Part {
        let index: Int
        let role: PRRowFactRole
        /// 폭을 정하지 않고 물었을 때의 크기(이상 크기).
        let size: CGSize
    }

    private struct Placement {
        let index: Int
        let origin: CGPoint
        let proposal: ProposedViewSize
    }

    /// 크기와 놓을 자리를 한 번에 정한다 — 둘을 따로 계산하면 어긋날 수 있다.
    /// `width` 가 nil(또는 무한)이면 한 줄로 늘어놓은 이상 크기를 낸다.
    private func plan(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, items: [Placement]) {
        let parts = subviews.indices.map {
            Part(index: $0, role: subviews[$0][PRRowFactRoleKey.self], size: subviews[$0].sizeThatFits(.unspecified))
        }
        let who = parts.first { $0.role == .who }
        let chip = parts.first { $0.role == .chip }
        /// 태그 → 구분선 → 라벨. 뷰를 이 순서로 넘겨받는다.
        let tagLine = parts.filter { [.tag, .separator, .labels].contains($0.role) }
        let tagLineWidth = Self.joined(tagLine.map(\.size.width), gap: Self.tagGap)

        // 첫 줄(작성자 ··· 칩)과 한 줄 배치의 이상 폭. Spacer 도 한 조각이라 양옆에 간격이 붙는다.
        let firstLineWidth = Self.joined([who?.size.width, Self.spacerMin, chip?.size.width].compactMap { $0 }, gap: Self.gap)
        let oneLineWidth = Self.joined([who?.size.width, tagLine.isEmpty ? nil : tagLineWidth, Self.spacerMin,
                                        chip?.size.width].compactMap { $0 }, gap: Self.gap)
        let twoLinesWidth = max(firstLineWidth, tagLine.isEmpty ? 0 : tagLineWidth)

        guard let width = proposedWidth, width.isFinite else {
            return oneLine(width: oneLineWidth, who: who, chip: chip, tagLine: tagLine)
        }
        // 부동소수 합이 경계에서 아주 조금 넘쳐 다른 배치를 고르지 않게 여유를 둔다.
        let tolerance: CGFloat = 0.001
        if oneLineWidth <= width + tolerance {
            return oneLine(width: width, who: who, chip: chip, tagLine: tagLine)
        }
        if twoLinesWidth <= width + tolerance {
            return twoLines(width: width, who: who, chip: chip, tagLine: tagLine)
        }
        return wrapped(width: width, who: who, chip: chip, tagLine: tagLine, subviews: subviews)
    }

    /// 1. 다 한 줄. 모두 줄 가운데에 맞춘다(예전 HStack 의 기본 정렬).
    private func oneLine(width: CGFloat, who: Part?, chip: Part?, tagLine: [Part]) -> (size: CGSize, items: [Placement]) {
        let lineHeight = ([who, chip].compactMap { $0 } + tagLine).map(\.size.height).max() ?? 0
        var items: [Placement] = []
        var x: CGFloat = 0
        if let who {
            items.append(Self.centered(who, x: x, lineTop: 0, lineHeight: lineHeight))
            x += who.size.width + Self.gap
        }
        for part in tagLine {
            items.append(Self.centered(part, x: x, lineTop: 0, lineHeight: lineHeight))
            x += part.size.width + Self.tagGap
        }
        if let chip {
            items.append(Self.centered(chip, x: width - chip.size.width, lineTop: 0, lineHeight: lineHeight))
        }
        return (CGSize(width: width, height: lineHeight), items)
    }

    /// 2. 첫 줄 작성자 ··· 칩, 둘째 줄 태그 │ 라벨.
    private func twoLines(width: CGFloat, who: Part?, chip: Part?, tagLine: [Part]) -> (size: CGSize, items: [Placement]) {
        var (height, items) = firstLine(width: width, who: who, chip: chip, chipSize: chip?.size)
        if !tagLine.isEmpty {
            let top = height + Self.lineGap
            let lineHeight = tagLine.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for part in tagLine {
                items.append(Self.centered(part, x: x, lineTop: top, lineHeight: lineHeight))
                x += part.size.width + Self.tagGap
            }
            height = top + lineHeight
        }
        return (CGSize(width: width, height: height), items)
    }

    /// 3. 첫 줄 아래에 태그를 흘리고(위쪽 맞춤, FlowRow 와 같다), 그 아래 라벨을 행 폭으로 감싼다. 구분선은 0×0 으로 숨긴다.
    private func wrapped(width: CGFloat, who: Part?, chip: Part?, tagLine: [Part],
                         subviews: Subviews) -> (size: CGSize, items: [Placement]) {
        // 첫 줄도 안 들어갈 만큼 좁으면 칩이 남은 자리만큼 줄어든다(예전 HStack 처럼 — 칩은 뒤를 자른다).
        var chipSize = chip?.size
        if let chip {
            let room = width - (who.map { $0.size.width + Self.gap } ?? 0) - Self.spacerMin - Self.gap
            if room < chip.size.width {
                chipSize = subviews[chip.index].sizeThatFits(ProposedViewSize(width: max(0, room), height: nil))
            }
        }
        var (height, items) = firstLine(width: width, who: who, chip: chip, chipSize: chipSize)
        // 작성자 묶음(줄지 않는다)과 칩의 최소 폭도 안 들어가면 첫 줄은 넘친다. 예전 HStack 처럼 넘친 폭을 그대로 보고한다.
        let firstLineMinWidth = Self.joined([who?.size.width, Self.spacerMin, chipSize?.width].compactMap { $0 }, gap: Self.gap)

        let tags = tagLine.filter { $0.role == .tag }
        if !tags.isEmpty {
            var x: CGFloat = 0
            var y = height + Self.lineGap
            var rowHeight: CGFloat = 0
            for tag in tags {
                if x > 0, x + tag.size.width > width {
                    x = 0
                    y += rowHeight + Self.lineGap
                    rowHeight = 0
                }
                items.append(Placement(index: tag.index, origin: CGPoint(x: x, y: y), proposal: ProposedViewSize(tag.size)))
                x += tag.size.width + Self.lineGap
                rowHeight = max(rowHeight, tag.size.height)
            }
            height = y + rowHeight
        }
        for separator in tagLine where separator.role == .separator {
            items.append(Placement(index: separator.index, origin: .zero, proposal: .zero))
        }
        if let labels = tagLine.first(where: { $0.role == .labels }) {
            let proposal = ProposedViewSize(width: width, height: nil)
            let size = subviews[labels.index].sizeThatFits(proposal)
            let top = height + Self.lineGap
            items.append(Placement(index: labels.index, origin: CGPoint(x: 0, y: top),
                                   proposal: ProposedViewSize(width: width, height: size.height)))
            height = top + size.height
        }
        return (CGSize(width: max(width, firstLineMinWidth), height: height), items)
    }

    /// 두 줄·감싸기의 첫 줄 — 작성자는 왼쪽, 칩은 오른쪽 끝(칩이 줄어들어도 작성자와 최소 여백은 지킨다).
    private func firstLine(width: CGFloat, who: Part?, chip: Part?, chipSize: CGSize?) -> (height: CGFloat, items: [Placement]) {
        let lineHeight = max(who?.size.height ?? 0, chipSize?.height ?? 0)
        var items: [Placement] = []
        if let who {
            items.append(Self.centered(who, x: 0, lineTop: 0, lineHeight: lineHeight))
        }
        if let chip, let chipSize {
            let earliest = (who.map { $0.size.width + Self.gap } ?? 0) + Self.spacerMin + Self.gap
            let x = max(earliest, width - chipSize.width)
            items.append(Placement(index: chip.index,
                                   origin: CGPoint(x: x, y: (lineHeight - chipSize.height) / 2),
                                   proposal: ProposedViewSize(chipSize)))
        }
        return (lineHeight, items)
    }

    private static func centered(_ part: Part, x: CGFloat, lineTop: CGFloat, lineHeight: CGFloat) -> Placement {
        Placement(index: part.index,
                  origin: CGPoint(x: x, y: lineTop + (lineHeight - part.size.height) / 2),
                  proposal: ProposedViewSize(part.size))
    }

    /// 조각 폭을 간격으로 이은 폭.
    private static func joined(_ widths: [CGFloat], gap: CGFloat) -> CGFloat {
        widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
    }
}
