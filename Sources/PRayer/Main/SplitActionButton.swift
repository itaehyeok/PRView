import SwiftUI
import PRayerCore

/// 몸통 + `▾` 두 조각으로 나뉜 버튼.
///
/// 몸통을 누르면 **지금 고른 동작을 그대로 실행**하고, `▾` 를 눌러야 목록이 열린다.
/// 목록에서 항목을 고르는 것은 선택만 바꾼다 — 되돌릴 수 없는 동작(게시)이 드롭다운에서
/// 곧바로 나가지 않게 하려는 것이다. 몸통 라벨은 항상 하는 일을 그대로 적는다.
struct SplitActionButton: View {
    struct Choice: Identifiable {
        let id: String
        let label: String
        let detail: String
        /// nil 이면 고를 수 있다.
        let disabledReason: String?
        /// 있으면 `detail` 대신 한 줄씩 그린다 — 줄이 접혀도 글이 표시 뒤에서 시작한다.
        var points: [Point] = []
    }

    /// 설명 한 줄. `mark` 는 `+`·`−`·`·` 같은 앞 표시.
    struct Point {
        let mark: String
        let text: String
    }

    let title: String
    let systemImage: String
    var prominent = true
    var isBusy = false
    /// 도는 동안 몸통에 적을 글("GitHub 에 올리는 중…"). nil 이면 제목 그대로 빙글이만 돈다.
    var busyTitle: String?
    /// 몸통 색. nil 이면 강조 버튼은 강조색, 아니면 회색 바탕. 실패한 게시의 "다시 시도" 가 빨강을 쓴다.
    var tint: Color?
    /// nil 이면 누를 수 있다.
    var disabledReason: String?
    let choices: [Choice]
    let selectedID: String
    let onRun: () -> Void
    let onSelect: (String) -> Void
    /// 캡처용(DebugLaunch) — 화면이 자리를 잡은 뒤 목록을 펼쳐 둔다.
    var debugOpensChoices = false

    @State private var showChoices = false
    @Environment(\.colorScheme) private var colorScheme

    /// 흐리게 그리는 것은 못 누르는 이유가 있을 때뿐이다. 도는 중에 흐려지면 "눌리지 않은 것" 처럼 보여
    /// 지금 무슨 일이 일어나는지가 버튼에서 읽히지 않았다(2026-10-22 게시 상태 시안 A).
    private var isDimmed: Bool { disabledReason != nil && !isBusy }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRun) {
                HStack(spacing: 5) {
                    if isBusy {
                        // 강조색 바탕에선 어두운 모양의 빙글이(흰색)라야 보인다.
                        ProgressView().controlSize(.small)
                            .environment(\.colorScheme, prominent ? .dark : colorScheme)
                    } else {
                        Image(systemName: systemImage).font(.caption)
                    }
                    Text(isBusy ? (busyTitle ?? title) : title).fixedSize()
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabledReason != nil)
            // 도는 동안은 누르지 못하게만 한다. disabled 로 막으면 글자까지 흐려져 "올리는 중…" 이 안 읽혔다(실측).
            .allowsHitTesting(!isBusy)

            Rectangle()
                .fill(Color.primary.opacity(prominent ? 0.25 : 0.12))
                .frame(width: 1, height: 16)

            Button {
                showChoices = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 도는 동안 다른 방식을 고르면 지금 올리는 것과 버튼 이름이 어긋난다.
            .allowsHitTesting(!isBusy)
            .help("다른 방식 고르기")
            .popover(isPresented: $showChoices, arrowEdge: .bottom) { choiceList }
            .task {
                guard debugOpensChoices else { return }
                try? await Task.sleep(for: .seconds(3))
                showChoices = true
            }
        }
        .foregroundStyle(prominent && !isDimmed ? Color.white : (tint ?? Color.primary))
        .opacity(isDimmed ? 0.5 : 1)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(prominent ? (tint ?? Color.accentColor) : (tint?.opacity(0.1) ?? Color.primary.opacity(0.08)))
        }
        .overlay {
            if let tint, !prominent {
                RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.55))
            }
        }
        .help(disabledReason ?? "")
    }

    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(choices) { choice in
                Button {
                    showChoices = false
                    onSelect(choice.id)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(choice.id == selectedID ? 1 : 0)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.label).font(.system(size: 12, weight: .medium))
                            // 고를 수 없으면 왜 안 되는지를 그 자리에 적는다.
                            if choice.disabledReason == nil, !choice.points.isEmpty {
                                ForEach(Array(choice.points.enumerated()), id: \.offset) { _, point in
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(point.mark)
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 8, alignment: .leading)
                                        Text(point.text)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.caption2)
                                }
                            } else {
                                Text(choice.disabledReason ?? choice.detail)
                                    .font(.caption2)
                                    .foregroundStyle(choice.disabledReason == nil ? .secondary : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(choice.disabledReason != nil)
                .opacity(choice.disabledReason == nil ? 1 : 0.55)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280)
        // 글자색을 여기서 다시 정한다. popover 는 이 버튼 안에 달려 있어서 바깥 HStack 의
        // `.foregroundStyle(.white)`(강조 버튼의 흰 글자)를 그대로 물려받는다.
        // 그러면 흰 배경 위에 흰 글자가 되어 제목이 안 보인다 — 색을 직접 지정한
        // 설명 줄만 읽히는 상태가 된다(실측).
        .foregroundStyle(Color.primary)
    }
}


/// "다시 리뷰" 를 하나의 분할 버튼으로. 몸통은 전체 리뷰, `▾` 로 diff 리뷰.
///
/// 예전에는 버튼 두 개가 나란히 있었다. 게시 버튼과 나란히 놓이면 한 줄에 버튼이 넷이라
/// 무엇이 주된 동작인지 읽히지 않았다. 몸통은 늘 diff 로 시작했는데, 실제로는 전체 리뷰가 더 낫다
/// (사용자 피드백) — 전체 리뷰로 시작한다(머리 줄 버튼과 같은 약속).
struct ReviewLaunchSplitButton: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let hasRecord: Bool

    /// 고른 적이 없으면 nil — 전체 리뷰로 시작한다. 클론이 없는 레포도 처음 한 번 PR 스냅샷을 받으면 된다.
    @State private var chosenDeep: Bool?

    private var deep: Bool { chosenDeep ?? true }

    private var title: String {
        if deep { return hasRecord ? "전체로 다시 리뷰" : "전체 리뷰" }
        return hasRecord ? "diff 로 다시 리뷰" : "diff 리뷰"
    }

    var body: some View {
        // 받는 양은 이 레포의 지금 상태로 적는다(ReviewLaunch.points 주석).
        let source = model.reviewSource(for: pr.repo)
        let codeSize = model.snapshotCodeSize(for: pr)
        SplitActionButton(
            title: title,
            systemImage: deep ? ReviewLaunch.worktree.symbol : ReviewLaunch.diff.symbol,
            prominent: false,
            isBusy: model.isReviewing(pr),
            disabledReason: model.isReviewing(pr) ? "이미 리뷰 중입니다." : nil,
            choices: [
                SplitActionButton.Choice(id: "worktree",
                                         label: "전체 리뷰",
                                         detail: ReviewLaunch.worktree.detail(source: source, codeSize: codeSize),
                                         disabledReason: nil,
                                         points: ReviewLaunch.worktree.points(source: source, codeSize: codeSize)),
                SplitActionButton.Choice(id: "diff",
                                         label: "diff 리뷰",
                                         detail: ReviewLaunch.diff.detail(source: source, codeSize: nil),
                                         disabledReason: nil,
                                         points: ReviewLaunch.diff.points(source: source, codeSize: nil)),
            ],
            selectedID: deep ? "worktree" : "diff",
            onRun: { model.reviewNow(pr: pr, deep: deep) },
            onSelect: { chosenDeep = ($0 == "worktree") },
            debugOpensChoices: DebugLaunch.showReviewChoices)
            .task(id: "\(pr.repo.full)@\(pr.headRefOid)") { await model.loadSnapshotCodeSize(for: pr) }
    }
}
