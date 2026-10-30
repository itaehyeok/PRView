import SwiftUI

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

/// 상태 태그와 라벨 사이의 얇은 구분선. 둘이 같은 줄에 있을 때만 쓴다.
struct LabelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(width: 1, height: 10)
    }
}
