import SwiftUI
import AppKit
import PRayerCore

/// PR 라벨을 보이는 한 가지 모양 — 태그 아이콘 하나 뒤에 이름을 가운뎃점으로 잇는다.
///
/// 라벨이 나오는 곳(목록 행·상세 머리 줄·개요 카드·우클릭 메뉴·필터 팝오버·숨길 라벨 편집 창)을 모두 이 모양으로
/// 맞췄다(사용자 결정). 예전에는 목록은 글씨, 상세는 색 칩이라 같은 라벨이 자리마다 달라 보였다.
///
/// 칩이 아니라 글씨인 이유: 상태 태그(Conflict·Draft·Requested…)는 PR 이 어떻게 됐는지라 칩이고, 라벨은 사람이
/// 붙인 분류라 생김새를 가른다. 경고성 라벨만 빨간 글씨 — 예전 칩의 주황(BUG·FIX)·파랑 구분은 없앴다.
enum PRLabels {
    /// 경고성 라벨인가 — 머지·리뷰를 막으라는 뜻(DO NOT·BLOCK·HOLD). 대소문자는 가리지 않는다.
    static func isWarning(_ label: String) -> Bool {
        let upper = label.uppercased()
        return upper.contains("DO NOT") || upper.contains("BLOCK") || upper.contains("HOLD")
    }

    /// 라벨 줄. 라벨이 없으면 nil.
    ///
    /// 줄은 라벨과 라벨 사이에서만 바뀐다 — 이름 안의 띄어쓰기는 붙여 두고, 가운뎃점은 앞 라벨에 붙여
    /// 줄이 "· 라벨" 로 시작하지 않게 한다.
    /// - Parameter limit: 몇 개까지 보일지(nil 이면 전부). 넘치면 "외 N" 을 붙인다.
    static func text(_ labels: [String], limit: Int? = nil, font: Font = .caption2) -> Text? {
        guard !labels.isEmpty else { return nil }
        let nonBreaking = "\u{00A0}"
        let shown = limit.map { Array(labels.prefix($0)) } ?? labels
        // 조각을 Text 보간으로 잇는다. `Text + Text` 는 macOS 26 SDK 에서 권하지 않는 꼴이 됐다.
        var text = Text(Image(systemName: "tag")).foregroundStyle(.secondary)
        for (index, label) in shown.enumerated() {
            let gap = index == 0
                ? Text(verbatim: nonBreaking)
                : Text(verbatim: nonBreaking + "· ").foregroundStyle(.tertiary)
            let name = Text(verbatim: label.replacingOccurrences(of: " ", with: nonBreaking))
                .foregroundStyle(isWarning(label) ? Color.red : Color.secondary)
            text = Text("\(text)\(gap)\(name)")
        }
        if shown.count < labels.count {
            let more = Text(verbatim: nonBreaking + "· 외" + nonBreaking + "\(labels.count - shown.count)")
                .foregroundStyle(.tertiary)
            text = Text("\(text)\(more)")
        }
        return text.font(font)
    }
}

extension PRLabels {
    /// 보일 라벨 — `limit` 개까지(nil 이면 전부). 고른 라벨(`kept`)이 넘친 쪽에 있으면 마지막 자리에 대신 넣는다 —
    /// 그 라벨만 보는 중인데 행마다 "외 N" 에 숨어 있으면 왜 이 행이 남았는지 안 보인다.
    static func shown(_ labels: [String], limit: Int?, keeping kept: [String]) -> [String] {
        guard let limit, limit > 0, labels.count > limit else { return labels }
        var shown = Array(labels.prefix(limit))
        // 고른 라벨이 하나도 안 보이면 마지막 자리를 그 라벨에 내준다 — 왜 이 행이 남았는지 보이게.
        if !PRFilterState.hasLabel(shown, kept), let match = labels.first(where: { PRFilterState.hasLabel([$0], kept) }) {
            shown[limit - 1] = match
        }
        return shown
    }
}

/// 목록 행의 라벨 줄 — `PRLabels.text` 와 같은 모양(태그 아이콘 하나 + 가운뎃점으로 이은 이름)인데 라벨마다 따로
/// 누를 수 있다. 누르면 그 라벨이 붙은 PR 만 보이고(`AppModel.toggleOnlyLabel`), 고른 라벨은 강조색 바탕으로 칠해
/// 목록 위 띠("라벨만 보는 중")와 이어 읽히게 한다.
///
/// 한 덩어리 Text 로는 라벨마다 마우스를 받을 수 없어 라벨 하나를 한 조각으로 나눠 `FlowRow` 로 잇는다. 줄은 라벨
/// 사이에서만 바뀌고 가운뎃점은 앞 라벨에 붙는다 — `PRLabels.text` 와 같은 규칙이다. 폭을 정하지 않고 물으면 한 줄
/// 그대로, 폭을 주면 그 안에서 감싼다(PRRowFactsLayout 이 두 경우를 다 쓴다).
struct PRLabelLinks: View {
    @Environment(AppModel.self) private var model
    let labels: [String]
    /// 몇 개까지 보일지(nil 이면 전부). 넘치면 "외 N" 을 붙인다.
    var limit: Int?

    var body: some View {
        let shown = PRLabels.shown(labels, limit: limit, keeping: model.filter.onlyLabels)
        let more = labels.count - shown.count
        FlowRow(spacing: 3, lineSpacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 3) {
                    if index == 0 {
                        Image(systemName: "tag")
                            .foregroundStyle(.secondary)
                    }
                    PRLabelLink(label: label)
                    if index < shown.count - 1 || more > 0 {
                        Text(verbatim: "·")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if more > 0 {
                Text(verbatim: "외\u{00A0}\(more)")
                    .foregroundStyle(.tertiary)
                    .help(labels.joined(separator: ", "))
            }
        }
        .font(.caption2)
    }
}

/// 라벨 하나 — 마우스를 올리면 옅은 바탕과 손 모양 커서, 누르면 그 라벨만 보기(고른 라벨을 다시 누르면 푼다).
private struct PRLabelLink: View {
    @Environment(AppModel.self) private var model
    let label: String
    @State private var isHovering = false

    var body: some View {
        let isOn = model.isOnlyLabel(label)
        Button {
            model.toggleOnlyLabel(label)
        } label: {
            // 굵기는 바꾸지 않는다 — 글자 폭이 바뀌면 고를 때마다 줄바꿈 자리가 움직인다.
            Text(verbatim: label.replacingOccurrences(of: " ", with: "\u{00A0}"))
                .foregroundStyle(tint(isOn: isOn))
                .background {
                    // 바탕만 글자 밖으로 조금 넓힌다 — 배치는 그대로라 옆 라벨이 밀리지 않는다.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? Color.accentColor.opacity(0.16)
                              : Color.primary.opacity(isHovering ? 0.09 : 0))
                        .padding(.horizontal, -3)
                        .padding(.vertical, -1)
                }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // 누르면 목록이 걸러져 이 행이 사라질 수 있다 — 나갔다는 알림이 없어 손 모양 커서가 남는다(ReplyChip 과 같다).
        .onDisappear {
            if isHovering { NSCursor.pop() }
        }
        .help(isOn ? "다시 누르면 모든 PR 을 봅니다" : "‘\(label)’ 라벨이 붙은 PR 만 보기")
    }

    private func tint(isOn: Bool) -> Color {
        if isOn { return .accentColor }
        if PRLabels.isWarning(label) { return .red }
        return isHovering ? .primary : .secondary
    }
}

/// 상태 태그와 라벨 사이의 얇은 구분선. 둘이 같은 줄에 있을 때만 쓴다.
struct LabelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(width: 1, height: 10)
    }
}
