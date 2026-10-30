import SwiftUI
import PRayerCore

/// 목록 폭에 따라 행에 무엇까지 보여줄지.
///
/// 좁아질 때 모든 조각을 억지로 남기면 글자가 줄바꿈되고 칩이 `리...`·`sample-...` 로 잘려서
/// **아무 정보도 주지 못하는 조각**만 자리를 차지한다. 잘라 보여주는 대신 덜 중요한 순서로
/// 아예 뺀다. 끝까지 남기는 것은 "무엇을 해야 하는가" 에 필요한 것들이다 —
/// 상태 뱃지 · 번호 · 제목 · 작성자 · 승인 수.
///
/// 상태 태그·라벨은 빼지 않는다. 한 줄에 안 들어가면 아랫줄로 내려 다 보인다(PRRow 의 셋째 줄) —
/// 예전에는 라벨 수를 폭으로 줄였는데(넓음 4 · 보통 1 · 좁음 0), 좁은 목록에서 라벨이 하나도 안 보였다.
enum PRRowDensity {
    /// 전부 보여 준다.
    case full
    /// 레포 칩을 뺀다(색점만 남긴다).
    case compact
    /// 레포 칩·생성 시각까지 뺀다.
    case tight

    init(width: CGFloat) {
        switch width {
        case ..<380: self = .tight
        case ..<460: self = .compact
        default: self = .full
        }
    }

    var showsCreatedAt: Bool { self != .tight }
    var showsRepoChip: Bool { self == .full }
}

private struct PRRowDensityKey: EnvironmentKey {
    static let defaultValue = PRRowDensity.full
}

extension EnvironmentValues {
    var prRowDensity: PRRowDensity {
        get { self[PRRowDensityKey.self] }
        set { self[PRRowDensityKey.self] = newValue }
    }
}

/// 레포를 가리키는 작은 색점.
///
/// 이름 칩은 좁아지면 `sample-...` 로 잘려 아무것도 알려 주지 못한다. 점은 폭을 거의 먹지 않으면서
/// "이 행은 다른 레포" 라는 것만은 남긴다(이름은 마우스를 올리면 나온다).
struct RepoDot: View {
    let name: String

    /// 12색(사용자 결정). 앞 8색은 예전 팔레트와 같은 순서라 이미 익숙한 색이 그대로 남는다(RepoColors.legacyIndex).
    /// 빨강은 Conflict·Closed 태그와, 노랑은 흰 바탕에서 잘 안 보여 맨 뒤에 둔다 — 레포가 11·12개째일 때만 쓰인다.
    /// 노랑은 시스템 노랑 대신 어두운 금색이다(작은 점이라 밝은 노랑은 흰 바탕에서 사라진다).
    /// 분홍·빨강 자리는 RepoColors.reddish, 파랑·청록·남색·하늘 자리는 RepoColors.bluish 와 맞아야 한다(앞자리 레포가 피하는 색).
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .brown,
                                           .mint, .cyan, Color(red: 0.80, green: 0.62, blue: 0.0), .red]

    /// 지금 나눠 준 색(RepoColors.key → 팔레트 자리). AppModel 이 설정이 바뀔 때마다 갈아 끼운다.
    /// 행·탭이 저마다 모델을 들고 오지 않아도 같은 색을 쓰게 하려고 여기 둔다.
    @MainActor static var assignments: [String: Int] = [:]

    var body: some View {
        Circle()
            .fill(Self.color(for: name))
            .frame(width: 6, height: 6)
            .help(name)
    }

    /// 이 레포의 색. 위쪽 레포 탭(이름 앞 점·고른 탭 밑줄)과 행의 점·레포 칩이 모두 이 색을 쓴다 —
    /// 탭에서 고른 레포와 목록의 행이 색으로 이어지게 하려는 것이다. 나눠 준 색이 없으면(설정에 없는 레포)
    /// 예전 규칙(이름 해시)으로 고른다.
    @MainActor static func color(for name: String) -> Color {
        let index = assignments[RepoColors.key(name)] ?? RepoColors.legacyIndex(for: name)
        return palette[index % palette.count]
    }
}
