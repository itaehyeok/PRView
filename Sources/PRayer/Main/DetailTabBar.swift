import SwiftUI
import PRayerCore

/// 상세 탭 줄 — 칸마다 [아이콘 | 이름 / 그 아래 상태 한 줄].
///
/// 기본 세그먼트(`Picker` `.segmented`)는 macOS 에서 글자만 그려서(아이콘을 줘도 안 보였다) 탭마다
/// 무엇이 있는지를 이름으로만 짐작해야 했다. 이름 아래에 상태를 붙여, 탭만 보고도 어디를 봐야 할지
/// 알게 한다: 대화 수(미해결이 있으면 그것) · AI 리뷰 단계 · 파일 수와 줄 수.
///
/// 상태를 이름 **옆**에 붙이던 때는 변경 파일 칸만 "4 +300 −1" 세 조각이 이어져 길고 어수선했다(사용자 피드백).
/// 세 칸 모두 이름 아래 한 줄로 맞췄다(사용자 선택 B안). 그래서 알릴 것이 없어도 회색으로 적는다 —
/// 대신 볼 일이 있는 상태(미해결·리뷰 완료·실패·오래됨 등)에만 색을 칠해 그것만 눈에 띄게 한다.
struct DetailTabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pr: PullRequestInfo
    /// 고른 칸 바탕이 칸을 옮겨 다니게 하는 이름표.
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { item in
                segment(item)
            }
        }
        // 고른 칸의 흰 바탕. 칸마다 그리면 옮겨 가는 도중 뒤 칸 바탕이 앞 칸 글자를 덮었다(실측) —
        // 그래서 칸들 밑에 하나만 깔고, 고른 칸이 남긴 자리표(segment 의 Color.clear)를 따라가게 한다.
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .matchedGeometryEffect(id: "selected", in: selection, isSource: false)
        }
        // 탭을 바꾸면 흰 바탕이 옆 칸으로 미끄러진다 — 순간 이동하면 어느 탭으로 갔는지 눈이 놓쳤다.
        // 이 줄에만 건다. 탭 내용(diff 등)까지 애니메이션으로 바뀌면 무겁고 어지럽다.
        // 모션 줄이기를 켰으면 예전처럼 바로 바뀐다.
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.detailTab)
        // 칸 높이를 가장 높은 칸에 맞춘다 — 리뷰 중의 진행 표시가 한 칸만 키우지 않게.
        .fixedSize(horizontal: false, vertical: true)
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func segment(_ item: DetailTab) -> some View {
        let isSelected = model.detailTab == item
        return Button {
            model.detailTab = item
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    caption(item)
                        .font(.system(size: 10.5).monospacedDigit())
                }
                .lineLimit(1)
            }
            // 글자·아이콘은 예전처럼 바로 바뀐다. 굵기가 바뀌는 이름까지 애니메이션을 타면 두 굵기가 겹쳐 흐려지면서
            // "AI 리뷰" 의 "리뷰" 가 한순간 사라졌다(실측). 움직이는 것은 바탕뿐이다.
            .transaction { $0.animation = nil }
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .background {
                // 기본 세그먼트처럼 고른 칸만 밝게 띄운다. 바탕은 body 가 칸들 밑에 그리고, 여기는 자리만 알린다.
                if isSelected {
                    Color.clear
                        .matchedGeometryEffect(id: "selected", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .help(item.help)
        .accessibilityLabel(accessibilityText(item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 탭 이름 아래 한 줄.
    @ViewBuilder
    private func caption(_ item: DetailTab) -> some View {
        switch item {
        case .overview:
            // 미해결 스레드가 남았으면 대화 수보다 그게 먼저다.
            if pr.unresolvedThreadCount > 0 {
                Text("미해결 \(pr.unresolvedThreadCount)")
                    .foregroundStyle(Color.orange)
            } else {
                Text(conversationText)
                    .foregroundStyle(Color.secondary)
            }
        case .review:
            // 단계마다 글자 폭이 달라(리뷰 전 ↔ 진행 표시 + 리뷰 중) 이 칸이 넓어졌다 좁아지면, 가운데 놓인
            // 탭 줄 전체가 좌우로 흔들린다(이 세션 전용 빌드에서 봤다). 가장 넓은 단계만큼 자리를 잡아 둔다.
            ZStack(alignment: .leading) {
                ForEach(AIReviewStage.allCases, id: \.self) { stage in
                    stageLabel(stage, forSizing: true).hidden()
                }
                stageLabel(reviewStage)
            }
        case .diff:
            // 목록 행의 증감과 같은 숫자·같은 색이다. 둘 다 GitHub 이 알려 주는 PR 전체 값이고,
            // 리뷰에서 빼는 자동 생성 파일도 들어 있다(파일 수와 같은 기준).
            HStack(spacing: 3) {
                Text("파일 \(pr.changedFiles)개 ·")
                    .foregroundStyle(Color.secondary)
                Text("+" + LineCount.compact(pr.additions))
                    .foregroundStyle(Color.green)
                Text("−" + LineCount.compact(pr.deletions))
                    .foregroundStyle(Color.red)
            }
        }
    }

    /// AI 리뷰 단계 한 줄. 도는 중이면 글자 앞에 작은 진행 표시를 단다.
    /// - Parameter forSizing: 자리만 잡는 보이지 않는 사본 — 진행 표시 대신 같은 크기의 빈칸을 둔다.
    private func stageLabel(_ stage: AIReviewStage, forSizing: Bool = false) -> some View {
        HStack(spacing: 3) {
            if stage == .running {
                if forSizing {
                    Color.clear
                        .frame(width: 10, height: 10)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                }
            }
            Text(stage.label)
        }
        .foregroundStyle(stage.tint)
    }

    /// 개요 탭 대화 칸 머리("대화 N건")와 같은 수다 — 같은 목록을 센다.
    private var conversationText: String {
        let count = PRTimelineBuilder.build(from: pr).count
        return count == 0 ? "대화 없음" : "대화 \(count)건"
    }

    private var reviewStage: AIReviewStage {
        var lastJob: AIReviewStage.LastJob?
        if let job = model.job(for: pr) {
            switch job.state {
            case .queued: lastJob = .queued
            case .running: lastJob = .running
            case .failed: lastJob = .failed(queuedAt: job.queuedAt)
            case .done, .cancelled: lastJob = nil
            }
        }
        return AIReviewStage.resolve(lastJob: lastJob, record: model.record(for: pr), headSha: pr.headRefOid)
    }

    private func accessibilityText(_ item: DetailTab) -> String {
        switch item {
        case .overview:
            let unresolved = pr.unresolvedThreadCount
            return unresolved > 0 ? "\(item.label), 미해결 스레드 \(unresolved)개" : "\(item.label), \(conversationText)"
        case .review:
            return "\(item.label), \(reviewStage.label)"
        case .diff:
            return "\(item.label) \(pr.changedFiles)개, \(pr.additions)줄 추가, \(pr.deletions)줄 삭제"
        }
    }
}

private extension AIReviewStage {
    /// 볼 일이 있는 단계만 색을 칠한다. 도는 중·리뷰 완료는 파랑(들어가 볼 것이 있다), 게시함은 초록,
    /// 실패는 빨강, 오래됨은 주황(목록 배지 덧표시와 같은 뜻), 나머지는 회색.
    var tint: Color {
        switch self {
        case .notReviewed, .queued: return .secondary
        case .running, .ready: return .accentColor
        case .posted: return .green
        case .failed: return .red
        case .stale: return .orange
        }
    }
}
