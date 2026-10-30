import SwiftUI
import PRayerCore

/// 상대 시각("now", "1h", "2d")을 그리는 자리.
///
/// 그냥 `Text(RelativeTime.compact(date))` 로 두면 **한 번 그린 값이 그대로 굳는다.**
/// 이 문자열은 "지금" 이 언제냐에 따라 달라지는데 뷰의 입력은 날짜 하나뿐이라,
/// SwiftUI 는 시간이 흐른 것을 모르고 본문을 다시 계산할 이유를 못 찾는다.
/// 실측: 1시간 21분 전에 올라온 승인이 목록에서 계속 "now" 로 남아 있었고,
/// 같은 사건이 오른쪽 상세에서는 "1h ago" 로 나와 두 화면이 서로 다른 말을 했다.
///
/// 모델의 30초 틱을 **입력으로 읽어** 시간이 흐르면 다시 그려지게 한다.
struct RelativeTimeText: View {
    enum Style {
        /// "now", "12m", "2h" — 폭이 좁은 자리.
        case compact
        /// "just now", "12m ago" — 문장처럼 읽는 자리.
        case ago
    }

    let date: Date
    var style: Style = .compact
    /// 앞에 붙는 고정 문구("Created" 등). 별도 Text 로 나누면 줄바꿈·간격이 어긋난다.
    var prefix: String = ""

    /// 옵셔널로 받는다. 메뉴·팝오버처럼 환경이 안 심긴 자리에서 그려도 죽지 않아야 한다
    /// (CLAUDE.md 의 "@Environment 를 읽는 뷰" 함정). 없으면 그 순간의 시각으로 그린다.
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        let now = model?.relativeTimeTick ?? Date()
        let text = style == .compact
            ? RelativeTime.compact(date, now: now)
            : RelativeTime.ago(date, now: now)
        Text(prefix.isEmpty ? text : "\(prefix) \(text)")
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}
