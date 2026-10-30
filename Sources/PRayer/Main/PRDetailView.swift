import SwiftUI
import PRayerCore

enum DetailTab: String, CaseIterable, Identifiable {
    case overview, review, diff

    var id: String { rawValue }
    /// 탭 이름. 보기 메뉴(⌃⌘1·2·3)도 이 이름을 쓴다.
    /// "개요·스레드"·"Diff" 에서 바꿨다 — 스레드는 코드 대화만 같아 보이고, Diff 는 영어 약어라 무엇이 있는 칸인지가 덜 읽혔다.
    var label: String {
        switch self {
        case .overview: return "개요·대화"
        case .review: return "AI 리뷰"
        case .diff: return "변경 파일"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "bubble.left.and.text.bubble.right"
        case .review: return "sparkles"
        case .diff: return "plus.forwardslash.minus"
        }
    }

    var help: String {
        switch self {
        case .overview: return "PR 정보·본문·리뷰 대화 (⌃⌘1)"
        case .review: return "AI 리뷰 초안 (⌃⌘2)"
        case .diff: return "바뀐 파일과 줄 (⌃⌘3)"
        }
    }
}

struct PRDetailView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// 스크롤 위치는 PR 마다 새로 잡는 게 맞다(탭과 달리 이건 @State 로 남긴다).
    @State private var scrollTargetKey: String?
    /// 개요 탭에서 펼친 칸. 탭 안이 아니라 여기 둔다 — 탭을 옮기면 탭 뷰가 사라져 펼친 것이 풀린다.
    /// 상세 화면은 PR 마다 새로 만들어지므로(`.id(pr.id)`) PR 을 바꾸면 다시 전부 접힌다.
    @State private var overviewExpanded: Set<String> = []
    /// 변경 파일 탭에서 따라가는 AI 리뷰 항목. 탭 뷰는 탭을 옮길 때마다 새로 만들어지므로 여기 둔다.
    @State private var follow: ReviewFollow?
    /// 변경 파일 탭의 "커밋별로 보기"(켰는지·고른 커밋). 탭을 오가도 남고, PR 을 바꾸면 꺼진다.
    @State private var commitBrowse = CommitBrowse(isOn: DebugLaunch.diffByCommit)
    /// AI 리뷰 탭에서 변경 파일 탭으로 건너간 자리(`ReviewItemKey`). 돌아오면 그 행으로 스크롤한다.
    /// 예전에는 리뷰 탭이 새로 그려지며 맨 위로 돌아가, 보던 우려사항을 다시 찾아 내려가야 했다.
    @State private var reviewReturnKey: String?
    /// 변경 파일 탭에 다녀온 뒤 처음 리뷰 탭을 열 때만 그 행을 깜빡여 알린다. 개요 탭에서 넘어올 때는 깜빡이지 않는다.
    @State private var returnFlashPending = false
    /// 탭 줄의 "AI 리뷰로 돌아가기" 버튼이 돌아갈 자리(`ReviewItemKey`). AI 리뷰 탭에서 코드로 건너왔을 때만 있다.
    /// `reviewReturnKey` 와 따로 둔다 — 그건 돌아온 뒤에도 남아 리뷰 탭 스크롤에 쓰이고, 이건 변경 파일 탭을
    /// 떠나는 순간 지운다(탭을 눌러 직접 온 변경 파일 탭에는 돌아갈 곳이 없다).
    @State private var backKey: String?
    /// 변경 파일 탭에서 본 리뷰 항목. 리뷰 탭에 "diff 에서 봄" 으로 표시한다.
    @State private var seenInDiff: Set<String> = []

    /// 탭 선택은 모델에 있다. PR 을 바꿔도 보던 탭이 유지된다(AppModel.detailTab 주석 참고).
    private var tab: DetailTab { model.detailTab }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 탭마다 아이콘·이름·상태(DetailTabBar 주석 참고). 코드로 건너왔으면 왼쪽 빈자리에 돌아가기 버튼.
            DetailTabRow(showsBack: tab == .diff && backKey != nil, onBack: goBackToReview) {
                DetailTabBar(pr: pr)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            // 내 PR 이면 탭 줄 바로 아래 머지 줄(MergeBar 주석 참고). 아래 줄도 MergeBar 가 긋는다.
            MergeBar(pr: pr)
            Group {
                switch tab {
                case .overview:
                    OverviewTab(pr: pr, expanded: $overviewExpanded) { key in
                        follow = nil
                        returnFlashPending = false
                        scrollTargetKey = key
                        commitBrowse.showWholePR()
                        model.detailTab = .diff
                    }
                case .review:
                    AIReviewView(pr: pr,
                                 returnKey: reviewReturnKey,
                                 flashOnAppear: returnFlashPending,
                                 seenInDiff: seenInDiff,
                                 onJumpToDiff: { key, origin in
                                     follow = nil
                                     scrollTargetKey = key
                                     jumpToDiff(from: origin)
                                 },
                                 onFollow: { target in
                                     follow = target
                                     seenInDiff.insert(target.itemKey)
                                     jumpToDiff(from: target.itemKey)
                                 },
                                 onReturned: { returnFlashPending = false })
                case .diff:
                    DiffTab(pr: pr,
                            commitBrowse: $commitBrowse,
                            scrollTargetKey: $scrollTargetKey,
                            follow: $follow,
                            onSeen: { seenInDiff.insert($0) })
                }
            }
            // 내용이 적어도 위에서부터 채운다. 이게 없으면 빈 화면일 때 헤더까지 가운데로 내려온다.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: pr.id) {
            if tab == .diff { await model.loadDiff(for: pr) }
        }
        .onChange(of: model.detailTab) { _, newValue in
            if newValue == .diff {
                Task { await model.loadDiff(for: pr) }
            } else {
                // 탭을 눌러 다른 곳으로 갔다가 변경 파일 탭으로 다시 오면 돌아갈 곳이 없다.
                backKey = nil
            }
        }
        .task(id: pr.id) { await runDebugFollow() }
        .task(id: pr.id) { await runDebugSweep() }
        // 코멘트 그림 중 비공개 첨부는 이 PR 의 본문·대화로 서명 주소를 얻는다(MarkdownImageView).
        .environment(\.markdownImagePR, MarkdownImagePR(repo: pr.repo, number: pr.number))
    }

    /// `PRAYER_DEBUG_SCROLL_SWEEP`(DebugLaunch) — diff 를 위아래로 훑어 레이아웃 루프에 걸리는 자리를 찾는다.
    private func runDebugSweep() async {
        guard let step = DebugLaunch.scrollSweep, DebugLaunch.selectPR == "\(pr.repo.full)#\(pr.number)" else { return }
        await DebugScrollSweep.run(step: step, keyToggles: DebugLaunch.sweepKeyToggles)
    }

    /// `PRAYER_DEBUG_FOLLOW`(DebugLaunch) — 버튼을 못 누르는 실측에서 따라가기·옮기기·돌아오기를 차례로 해 본다.
    /// 배포판에서는 DebugLaunch 가 늘 nil 이라 바로 끝난다.
    private func runDebugFollow() async {
        guard let index = DebugLaunch.followIndex, DebugLaunch.selectPR == "\(pr.repo.full)#\(pr.number)" else { return }
        try? await Task.sleep(for: .seconds(2))
        guard let record = model.record(for: pr) else { return }
        let items = ReviewFollowList.items(in: record.output)
        if items.indices.contains(index) {
            follow = ReviewFollow(itemKey: items[index].key, locationIndex: 0)
            seenInDiff.insert(items[index].key)
            jumpToDiff(from: items[index].key)
        } else {
            // 새 출력 형식(코드 코멘트 한 목록)은 따라갈 우려사항·질문이 없다. 카드의 "코드에서 보기" 처럼 그 코멘트의 줄로 간다.
            // 아래 단계(return·diff)는 이 길에서도 돈다 — move·next 는 따라가는 항목이 없어 건너뛴다.
            guard record.comments.indices.contains(index) else { return }
            let comment = record.comments[index].comment
            follow = nil
            scrollTargetKey = "\(comment.path)#RIGHT#\(comment.line)"
            jumpToDiff(from: ReviewItemKey.draft(comment))
        }
        for step in DebugLaunch.followSteps {
            try? await Task.sleep(for: .seconds(4))
            switch step {
            case "move":
                guard let current = follow, let diff = model.parsedDiff(for: pr), var updated = model.record(for: pr),
                      let item = ReviewFollowList.items(in: updated.output).first(where: { $0.key == current.itemKey })
                else { continue }
                updated.moveToInline(item, locationIndex: current.locationIndex, diff: diff)
                model.update(record: updated)
            case "next":
                guard let current = follow, let updated = model.record(for: pr) else { continue }
                let list = ReviewFollowList.items(in: updated.output)
                let at = list.firstIndex { $0.key == current.itemKey } ?? 0
                let next = list[(at + 1) % list.count]
                follow = ReviewFollow(itemKey: next.key, locationIndex: 0)
                seenInDiff.insert(next.key)
            case "return":
                goBackToReview()
            case "diff":
                model.detailTab = .diff
            default:
                continue
            }
        }
    }

    /// AI 리뷰 탭의 `origin` 자리에서 변경 파일 탭으로 건너간다("코드에서 보기"·코드 링크). 갈 줄은 부르는 쪽이 정한다.
    private func jumpToDiff(from origin: String) {
        reviewReturnKey = origin
        returnFlashPending = true
        backKey = origin
        commitBrowse.showWholePR()
        model.detailTab = .diff
    }

    /// 탭 줄의 돌아가기 버튼(⌘[) — 건너온 AI 리뷰 자리로 스크롤하고 잠깐 칠한다. `jumpToDiff` 의 반대 길이다.
    private func goBackToReview() {
        guard let backKey else { return }
        reviewReturnKey = backKey
        returnFlashPending = true
        model.detailTab = .review
    }

    private var header: some View {
        let job = model.job(for: pr)
        let record = model.record(for: pr)
        return VStack(alignment: .leading, spacing: 8) {
            PRTitleLine(pr: pr)
            // 자리가 모자라면 라벨 → 브랜치(두 줄로 내린 뒤 이름 가운데) 순으로 줄이고, 칩·오른쪽 버튼은 줄이지 않는다.
            // 예전엔 한 줄로 이은 브랜치가 자리를 다 먹어 "리뷰중" 이 한 글자씩 세로로 접히고 "취소" 가 "…" 로 줄었다.
            HStack(spacing: 8) {
                // 판정(Blocker·Non-blocker·LGTM)은 여기 두지 않는다 — 코드 코멘트를 센 결과라 AI 리뷰 탭 코드 코멘트 칸
                // 머리 줄로 옮겼다(2026-10-30 사용자 결정). 진행 상태·GitHub 리뷰 상태(Reviewing·Approved 등)만 남는다.
                let badge = model.badge(for: pr)
                if !badge.badge.isVerdict {
                    BadgeChip(result: badge)
                        .fixedSize()
                }
                PRBranchPair(pr: pr)
                    .layoutPriority(1)
                // 목록 행과 같은 말·같은 모양으로 맞춘다(사용자 결정) — 예전에는 여기만 "충돌", 라벨은 색 칩이었다.
                if pr.mergeable == .conflicting {
                    Tag(text: "Conflict", color: .red)
                        .fixedSize()
                }
                if let labels = PRLabels.text(pr.labels) {
                    if pr.mergeable == .conflicting { LabelSeparator() }
                    // 자리가 모자라면 끝을 줄인다. 전부는 툴팁과 아래 개요 카드에 있다.
                    labels
                        .lineLimit(1)
                        .help(pr.labels.joined(separator: ", "))
                }
                if model.isRefreshing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("최신 정보 가져오는 중")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                actions(job: job)
                    .fixedSize()
                    .layoutPriority(2)
            }
            if let reason = model.skipReason(for: pr), record == nil {
                Text("참고: \(reason.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// 리뷰를 시작하는 버튼은 여기 두지 않는다 — AI 리뷰 탭에 같은 두 버튼(전체 리뷰·diff 리뷰)과 모델·Effort 두 칸이
    /// 있어서, 머리 줄까지 두면 같은 일을 하는 버튼이 한 화면에 두 벌이었다(사용자 요청으로 뺐다).
    /// 리뷰가 도는 동안의 "리뷰 중 · 취소" 는 어느 탭을 보든 보여야 해서 남긴다.
    /// "GitHub에서 보기" 도 여기 있었는데 제목을 누르면 열리게 바꾸며 뺐다(PRTitleLine).
    @ViewBuilder
    private func actions(job: ReviewJob?) -> some View {
        HStack(spacing: 8) {
            if let job, job.isActive {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    // 탭 줄 "AI 리뷰" 칸 아래와 같은 이름 — 예전엔 여기만 "리뷰중"·"대기" 였다.
                    Text((job.state == .running ? AIReviewStage.running : .queued).label)
                        .font(.caption)
                }
                Button("취소") { model.cancel(jobID: job.id) }
            }
        }
    }
}

// MARK: - 개요·스레드

struct OverviewTab: View {
    @Environment(AppModel.self) private var model

    /// 취소는 주황, 진짜 실패는 빨강. 사람이 할 일이 다르다.
    /// 통과는 회색으로 둔다 — 바로 앞 충돌 칸이 더 중요해서, 통과까지 초록이면 둘이 같은 무게로 읽혔다
    /// (2026-10-28 사용자 결정). 손이 갈 때만 색이 뜬다.
    private func ciTint(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .passing: return .secondary
        case .cancelled: return .orange
        case .failed: return .red
        }
    }
    let pr: PullRequestInfo
    /// 펼친 칸(본문 `bodyKey`, 대화 항목 `entry.id`). 처음엔 비어 있어 전부 접힌 채로 연다 — 긴 본문과
    /// 대화가 다 펼쳐져 있으면 PR 정보 아래가 스크롤 몇 번 거리라 무엇이 오갔는지 한눈에 안 들어왔다
    /// (사용자 요청). PR 정보 줄(승인·충돌·CI·미해결)은 열자마자 봐야 하므로 접지 않는다.
    @Binding var expanded: Set<String>
    /// 코멘트 안의 코드 참조를 눌렀을 때 diff 로 이동시킨다.
    var onJumpToDiff: (String) -> Void = { _ in }

    static let bodyKey = "body"

    var body: some View {
        let entries = PRTimelineBuilder.build(from: pr)
        let keys = collapsibleKeys(entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !keys.isEmpty { expandControls(keys) }
                factsCard
                bodyCard
                timelineCard(entries)
            }
            .padding(16)
        }
        .task(id: pr.id) {
            if DebugLaunch.expandAll { expanded = keys }
        }
    }

    /// 접고 펼 수 있는 칸 전부. 커밋·본문 없는 승인은 원래 한 줄이라 빠진다.
    private func collapsibleKeys(_ entries: [PRTimelineEntry]) -> Set<String> {
        var keys = Set(entries.filter(TimelineRow.isCollapsible).map(\.id))
        if !pr.bodyText.isEmpty { keys.insert(Self.bodyKey) }
        return keys
    }

    private func expandControls(_ keys: Set<String>) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Button("전체 펼치기") { withAnimation(Self.collapseAnimation) { expanded = keys } }
            Text("·").foregroundStyle(.tertiary)
            Button("전체 접기") { withAnimation(Self.collapseAnimation) { expanded = [] } }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    /// 펼치고 접을 때 칸 높이가 늘고 줄며 내용이 드러난다(사용자 요청). 바뀌는 자리는 전부 이 셋을 지난다 —
    /// 줄 안에서 `isExpanded` 를 바꿔도 `expandedBinding` 의 set 으로 들어온다.
    static let collapseAnimation: Animation = .smooth(duration: 0.25)

    private func toggle(_ key: String) {
        withAnimation(Self.collapseAnimation) {
            if expanded.contains(key) {
                expanded.remove(key)
            } else {
                expanded.insert(key)
            }
        }
    }

    private func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { isOn in
                    withAnimation(Self.collapseAnimation) {
                        if isOn {
                            expanded.insert(key)
                        } else {
                            expanded.remove(key)
                        }
                    }
                })
    }

    // MARK: 주요사항

    private var factsCard: some View {
        let threshold = model.settings.approvalThreshold(for: pr)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Avatar(login: pr.author, name: model.settings.displayName(pr.author))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.settings.displayName(pr.author))
                        .font(model.fonts.ui(weight: .medium))
                        .help(pr.author)
                    // `.relative` 포맷도 시계를 입력으로 받지 않아 한 번 그린 값이 굳는다.
                    HStack(spacing: 4) {
                        Text("올림 \(pr.createdAt.formatted(date: .abbreviated, time: .shortened)) · 마지막 활동")
                        RelativeTimeText(date: pr.updatedAt, style: .ago)
                    }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 라벨은 바로 위 헤더 줄에 있어 여기서는 뺐다(2026-10-23 사용자 결정 — 전부 보려면 헤더 라벨에 마우스).
                if pr.isDraft { Tag(text: "Draft", color: .secondary) }
            }

            // 내가 리뷰해도 되는 PR 인지 한눈에. 팀 레포는 CODEOWNERS 로 전원이 리뷰어라
            // 요청 여부만으로는 부족해서 "이미 리뷰함" 까지 같이 보여준다.
            ReviewerStatusRow(pr: pr)

            // 변경 줄 수는 위 탭 줄("변경 파일 · +98 −18")에 늘 보여 여기서 뺐다(2026-10-27 사용자 결정).
            HStack(spacing: 8) {
                Fact(icon: "person.2.fill",
                     title: "Approve",
                     value: "\(pr.approvalCount)/\(threshold)",
                     tint: pr.approvalCount >= threshold ? .green : .accentColor,
                     detail: pr.approvalCountAtHead != pr.approvalCount
                        ? "현재 커밋 기준 \(pr.approvalCountAtHead)명"
                        : (pr.approvals.isEmpty ? nil
                           : pr.approvals.map { model.settings.displayName($0.login) }.joined(separator: ", ")))
                // GitHub 의 `mergeable` 은 base 와 코드가 충돌하는지만 말한다 — Approve·CI·브랜치 규칙은 보지 않는다.
                // 전에는 "머지 · 가능" 으로 적어 Approve 0/3 인 PR 도 지금 머지할 수 있는 것처럼 읽혔다
                // (2026-10-28 사용자 지적). 그래서 이름을 "base 와 충돌" 로 바꾸고 Approve 바로 옆에 둔다.
                Fact(icon: "arrow.triangle.merge",
                     title: "base 와 충돌",
                     value: conflictText,
                     tint: conflictTint,
                     detail: nil)
                // 합쳐진 값(FAILURE)만 보여 주면 무엇이 왜 실패했는지 알 수 없어
                // GitHub 을 열어 봐야 했다. 이름을 옆에 적고, 취소는 실패와 색을 나눈다.
                Fact(icon: pr.checkOutcome.isProblem ? "xmark.circle.fill" : "checkmark.circle.fill",
                     title: "CI",
                     value: pr.checkState ?? "없음",
                     tint: pr.checkState == nil ? .secondary : ciTint(pr.checkOutcome),
                     detail: pr.checkOutcome.detail)
                Fact(icon: "bubble.left.and.bubble.right",
                     title: "미해결 스레드",
                     value: "\(pr.unresolvedThreadCount)",
                     tint: pr.unresolvedThreadCount > 0 ? .orange : .secondary,
                     detail: nil)
            }
        }
        .overviewCard()
    }

    private var conflictTint: Color {
        switch pr.mergeable {
        case .mergeable: return .green
        case .conflicting: return .red
        case .unknown: return .secondary
        }
    }

    private var conflictText: String {
        switch pr.mergeable {
        case .mergeable: return "없음"
        case .conflicting: return "있음"
        case .unknown: return "확인 중"
        }
    }

    // MARK: PR 본문

    private var bodyCard: some View {
        Group {
            // 머리 줄이 위아래 2pt 씩 커졌으므로(CollapseHeader) 간격을 그만큼 줄여 보이는 간격은 그대로 둔다.
            VStack(alignment: .leading, spacing: 6) {
                if pr.bodyText.isEmpty {
                    Text("본문이 없습니다.").font(.callout).foregroundStyle(.secondary)
                        .padding(Self.bodyCardPadding)
                } else {
                    // 접힌 동안은 머리와 미리보기를 합친 칸 전체가 버튼이다(CollapsibleBlock). 펼쳐도 같은 뷰를
                    // 그대로 둬야 머리가 제자리에 있고 아래만 늘어난다 — 접힌 칸과 펼친 칸을 다른 뷰로 갈아 끼우면
                    // 애니메이션 동안 두 칸이 겹쳐 흐려졌다 나타났다.
                    // 카드 여백을 칸 안쪽에 둬 칸이 곧 카드가 되게 한다 — 여백이 칸 밖에 있으면 마우스를 올렸을 때
                    // 글자 둘레만 칠해지고 카드 가장자리는 흰 채로 남았다.
                    let isOpen = expanded.contains(Self.bodyKey)
                    CollapsibleBlock(isCollapsed: !isOpen, expand: { toggle(Self.bodyKey) },
                                     highlight: EdgeInsets(), cornerRadius: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            CollapseHeader(isOpen: isOpen, toggle: isOpen ? { toggle(Self.bodyKey) } : nil) { bodyTitle }
                            if isOpen {
                                MarkdownText(text: pr.bodyText)
                                CollapseFooter { toggle(Self.bodyKey) }
                            } else {
                                CollapsedPreview(text: MarkdownPreview.text(pr.bodyText), lines: 2)
                            }
                        }
                        .padding(Self.bodyCardPadding)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 칸 높이가 늘어나는 동안 먼저 자리 잡은 본문이 카드 아래로 비어져 나오지 않게.
            .clipped()
        }
        .overviewCard(padding: 0)
    }

    /// 본문 카드의 여백. 다른 카드(`overviewCard` 기본값)와 같다 — 칸 안쪽으로 옮겼을 뿐이다.
    private static let bodyCardPadding: CGFloat = 12

    @ViewBuilder
    private var bodyTitle: some View {
        Text("본문").font(model.fonts.ui(weight: .medium))
        Text("\(pr.bodyText.count.formatted())자")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: 대화 (사람 리뷰 · 봇 코멘트 · 커밋을 시간순으로)

    /// 카드로 감싸지 않는다 — 코멘트가 저마다 상자라(TimelineRow) 바깥 카드까지 두면 상자 안 상자가 된다.
    private func timelineCard(_ entries: [PRTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 접어 두면 어디가 남았는지 안 보이므로 미해결 수를 머리에 같이 둔다.
            HStack(spacing: 6) {
                Text("대화 \(entries.count)건")
                    .font(model.fonts.ui(weight: .medium))
                if pr.unresolvedThreadCount > 0 {
                    Tag(text: "미해결 \(pr.unresolvedThreadCount)", color: .orange)
                }
            }
            if entries.isEmpty {
                Text("아직 코멘트도 커밋도 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overviewCard()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        TimelineRow(entry: entry, isHead: isHead(entry), pr: pr, onJumpToDiff: onJumpToDiff,
                                    isExpanded: expandedBinding(entry.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }

    private func isHead(_ entry: PRTimelineEntry) -> Bool {
        if case .commit(let commit) = entry { return commit.oid == pr.headRefOid }
        return false
    }
}

/// 타임라인 한 줄. 왼쪽 세로선으로 GitHub 대화 탭처럼 이어 보이게 한다(시안 C4-2, 2026-10-27 사용자 결정).
///
/// 커밋·본문 없는 승인은 선 위 한 줄, 사람이 쓴 글(코멘트·코드 코멘트·본문 있는 리뷰)은 아바타를 선 위에 두고
/// 글을 상자에 담는다. 코드 코멘트 상자는 맨 위에 파일 줄을 둬 어느 코드에 단 말인지 먼저 보이게 한다 —
/// GitHub 리뷰 스레드와 같은 순서다. 펼치면 답글을 같은 상자 안에 쌓는다(시안 C4-5).
struct TimelineRow: View {
    @Environment(AppModel.self) private var model
    let entry: PRTimelineEntry
    let isHead: Bool
    let pr: PullRequestInfo
    let onJumpToDiff: (String) -> Void
    /// 접고 펼 수 있는 줄의 펼침 상태. 커밋·본문 없는 승인은 원래 한 줄이라 쓰지 않는다.
    @Binding var isExpanded: Bool
    @State private var isRailHovering = false
    @State private var isBoxHovering = false

    static func isCollapsible(_ entry: PRTimelineEntry) -> Bool {
        switch entry {
        case .commit: return false
        case .review(let review): return !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .comment, .thread: return true
        }
    }

    /// 상자에 담는 줄 — 사람이 쓴 글이 있는 줄이다.
    private var isBoxed: Bool { Self.isCollapsible(entry) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            rail
            Group {
                if isBoxed {
                    box
                } else {
                    line
                        .frame(minHeight: 22)
                }
            }
            .padding(.bottom, isBoxed ? 12 : 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 왼쪽 표시와 세로선. 펼친 줄에서는 이 선을 눌러도 접힌다 — 선이 곧 펼친 내용의 높이라 긴 본문
    /// 어디에서든 손이 닿는다(GitHub 대화의 스레드 선과 같은 쓰임).
    ///
    /// 펼침 상태에 따라 뷰를 갈아 끼우지 않고 누르기만 켜고 끈다 — 갈아 끼우면 접고 펼 때 얼굴이 깜빡였다.
    private var rail: some View {
        let collapses = isBoxed && isExpanded
        let lit = collapses && isRailHovering
        return VStack(spacing: 0) {
            marker
            Rectangle()
                .fill(lit ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.quaternary))
                .frame(width: lit ? 2 : 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 22)
        .contentShape(Rectangle())
        .onHover { isRailHovering = $0 }
        .gesture(TapGesture().onEnded { isExpanded = false }, including: collapses ? .all : .subviews)
        .help(collapses ? "눌러서 접기" : "")
    }

    /// 상자 줄은 쓴 사람 얼굴, 한 줄짜리는 종류 아이콘(옅은 색 동그라미).
    @ViewBuilder
    private var marker: some View {
        if isBoxed {
            Avatar(login: entry.author, name: model.settings.displayName(entry.author), size: 22)
        } else {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .background(Circle().fill(tint.opacity(0.16)).padding(-0.5))
        }
    }

    // MARK: 한 줄 (커밋 · 본문 없는 리뷰)

    @ViewBuilder
    private var line: some View {
        switch entry {
        case .commit(let commit):
            // 커밋은 한 줄로 둔다. 대화를 접어 두면 커밋이 목록 대부분을 차지하는데, 두 줄이면 코멘트가
            // 화면 밖으로 밀린다(실측: 대화 38건 중 커밋 다수인 PR 에서 접어도 스크롤이 길었다).
            HStack(spacing: 6) {
                headerLabel(action: "커밋")
                Text(commit.messageHeadline)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isHead { Tag(text: "head", color: .accentColor) }
                Text(commit.abbreviatedOid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .review(let review):
            HStack(spacing: 6) {
                headerLabel(action: reviewLabel(review.state), actionTint: tint)
                Spacer(minLength: 0)
            }
        case .comment, .thread:
            EmptyView()
        }
    }

    // MARK: 상자 (코멘트 · 코드 코멘트 · 본문 있는 리뷰)

    /// 접힌 상자는 상자 전체가 펼치는 버튼이다(사용자 결정 — CollapsibleBlock 과 같은 쓰임).
    /// 펼쳐도 같은 상자를 두고 누르기만 끈다 — 상자째 갈아 끼우면 높이가 늘지 않고 두 상자가 겹쳐 흐려졌다.
    private var box: some View {
        boxFrame
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { isBoxHovering = $0 }
            .gesture(TapGesture().onEnded { isExpanded = true }, including: isExpanded ? .subviews : .all)
            .accessibilityAddTraits(isExpanded ? [] : .isButton)
            .accessibilityHint(isExpanded ? "" : "누르면 펼칩니다")
    }

    private var boxFrame: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .thread(let thread, _) = entry, thread.path != nil {
                fileBar(thread)
                Divider()
            }
            VStack(alignment: .leading, spacing: 4) {
                boxHeader
                if !isExpanded {
                    CollapsedPreview(text: previewText, lines: 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 펼치면 GitHub 코멘트 상자처럼 머리가 옅은 띠가 되고, 본문은 그 아래 16pt 여백 안에 든다(사용자 결정).
            // 접힌 줄은 그대로 촘촘하게 둔다 — 대화를 훑어보는 목록이라서.
            .background(Color.primary.opacity(isExpanded ? 0.035 : 0))
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    expandedBody
                        .environment(\.codeLinks, CodeLinkContext(pr: pr, onJump: onJumpToDiff))
                    collapseFooter
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.overviewCardFill)
        .overlay(Color.primary.opacity(isBoxHovering && !isExpanded ? 0.03 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(boxBorder, lineWidth: 0.8))
        .opacity(isSettled ? 0.72 : 1)
    }

    /// 손이 가야 하는 글(미해결 코드 코멘트·변경 요청)만 테두리에 색을 준다.
    private var boxBorder: Color {
        switch entry {
        case .thread(let thread, _) where !thread.isResolved && !thread.isOutdated:
            return Color.orange.opacity(0.55)
        case .review(let review) where review.state.uppercased() == "CHANGES_REQUESTED":
            return Color.orange.opacity(0.55)
        default:
            return Color(nsColor: .separatorColor)
        }
    }

    /// 해결됐거나 코드가 바뀌어 지난 스레드는 흐리게 — 다시 볼 일이 적다.
    private var isSettled: Bool {
        if case .thread(let thread, _) = entry { return thread.isResolved || thread.isOutdated }
        return false
    }

    /// 코드 코멘트 상자 맨 위 파일 줄. 해결 여부도 여기 둔다 — 그 코드 자리의 상태라서.
    private func fileBar(_ thread: PRReviewThread) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)
            fileBarPath(thread)
            Spacer(minLength: 6)
            statusTags(thread)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35))
    }

    /// 파일 경로가 곧 그 코드로 가는 자리다 — 올리면 그 줄 근처 코드가 뜨고, 누르면 diff 로 간다.
    @ViewBuilder
    private func fileBarPath(_ thread: PRReviewThread) -> some View {
        let path = thread.path ?? ""
        let text = Text("\(path)\(thread.line.map { ":\($0)" } ?? "")")
            .font(.caption.monospaced())
        if !path.isEmpty, model.parsedDiff(for: pr)?.files.contains(where: { $0.path == path }) == true {
            CodeLink(reference: CodeReference(path: path, line: thread.line, label: path),
                     context: CodeLinkContext(pr: pr, onJump: onJumpToDiff)) { isHovering in
                text
                    .underline(isHovering)
                    .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } else {
            text
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
        }
    }

    @ViewBuilder
    private func statusTags(_ thread: PRReviewThread) -> some View {
        if thread.isResolved {
            Tag(text: "해결됨", color: .green)
        } else {
            Tag(text: "미해결", color: .orange)
        }
        if thread.isOutdated { Tag(text: "outdated", color: .secondary) }
    }

    /// 누가·무엇을·언제, 오른쪽 끝에 답글 요약. 상자 전체가 버튼이므로 머리는 모양만 그린다(펼친 뒤엔 접기 버튼).
    /// 답글 요약은 머리 바깥에 둔다 — 머리 안에 Spacer 를 하나 더 두면 머리 끝의 Spacer 와 자리를 반씩 나눠 가운데에 뜬다.
    private var boxHeader: some View {
        HStack(spacing: 6) {
            CollapseHeader(isOpen: isExpanded, toggle: isExpanded ? { isExpanded = false } : nil) {
                headerContent
            }
            if case .thread(let thread, _) = entry, let reply = thread.latestReply {
                replySummary(reply, count: thread.comments.count - 1)
            }
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        switch entry {
        case .thread(let thread, _):
            headerLabel(action: thread.path == nil ? "코멘트" : "코드 코멘트")
            // 파일 줄이 없는(PR 전체에 단) 스레드는 해결 여부를 머리에 둔다.
            if thread.path == nil { statusTags(thread) }
        case .review(let review):
            headerLabel(action: reviewLabel(review.state), actionTint: tint)
        case .comment:
            headerLabel(action: "코멘트")
        case .commit:
            EmptyView()
        }
    }

    private var previewText: String {
        switch entry {
        case .thread(let thread, _): return MarkdownPreview.text(thread.comments.first?.body ?? "")
        case .review(let review): return MarkdownPreview.text(review.body)
        case .comment(let comment): return MarkdownPreview.text(comment.body)
        case .commit: return ""
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        switch entry {
        case .review(let review):
            MarkdownText(text: review.body)
                .padding(.top, 2)
        case .comment(let comment):
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: comment.body)
                ExplainBox(target: ExplainTarget(comment: comment), pr: pr)
            }
            .padding(.top, 2)
        case .thread(let thread, _):
            ThreadCard(thread: thread, pr: pr)
        case .commit:
            EmptyView()
        }
    }

    /// 스레드 줄의 "답글 N · 마지막으로 답한 사람 언제" — 답글이 달렸다는 것을 원글 줄에서 바로 본다(사용자 요청).
    /// 내가 답했어도 따로 칠하지 않고 이름으로 적는다(사용자 결정: "이름하고 상대시간이 나오면 된다").
    private func replySummary(_ reply: ReviewThreadComment, count: Int) -> some View {
        HStack(spacing: 3) {
            Text("답글 \(count) · \(model.settings.displayName(reply.author))")
            if let date = PRActivityBuilder.isoDate(reply.createdAt) {
                RelativeTimeText(date: date, style: .compact)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help("마지막 답글: \(reply.author)")
    }

    private var collapseFooter: some View {
        CollapseFooter { isExpanded = false }
            .padding(.top, 2)
    }

    @ViewBuilder
    private func headerLabel(action: String, actionTint: Color = .secondary) -> some View {
        Text(model.settings.displayName(entry.author))
            .font(.caption.weight(.semibold))
            .help(entry.author)
        Text(action)
            .font(.caption)
            .foregroundStyle(actionTint)
        RelativeTimeText(date: entry.at, style: .ago)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(entry.at.formatted(date: .abbreviated, time: .shortened))
    }

    private func reviewLabel(_ state: String) -> String {
        switch state.uppercased() {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "변경 요청"
        case "DISMISSED": return "리뷰 무효화"
        default: return "리뷰"
        }
    }

    /// 한 줄짜리의 동그라미 아이콘. 색 동그라미 위에 올리므로 속이 빈 기호를 쓴다.
    private var icon: String {
        switch entry {
        case .commit: return "arrow.up"
        case .comment, .thread: return "text.bubble"
        case .review(let review):
            switch review.state.uppercased() {
            case "APPROVED": return "checkmark"
            case "CHANGES_REQUESTED": return "exclamationmark"
            case "DISMISSED": return "arrow.uturn.backward"
            default: return "text.bubble"
            }
        }
    }

    private var tint: Color {
        switch entry {
        case .commit: return .secondary
        case .comment, .thread: return .accentColor
        case .review(let review):
            switch review.state.uppercased() {
            case "APPROVED": return .green
            case "CHANGES_REQUESTED": return .orange
            case "DISMISSED": return .orange
            default: return .accentColor
            }
        }
    }
}

/// 접고 펴는 줄의 머리. 화살표와 제목을 한 버튼으로 묶어 줄 어디를 눌러도 바뀐다.
///
/// `toggle` 이 있고 없음에 따라 뷰를 갈아 끼우지 않고 누르기만 켜고 끈다 — 갈아 끼우면 펼칠 때 화살표가
/// 돌지 않고 머리째 깜빡였다(펼침 애니메이션).
struct CollapseHeader<Label: View>: View {
    let isOpen: Bool
    /// nil 이면 버튼이 아니라 모양만 그린다 — 접힌 칸은 칸 전체가 버튼(CollapsibleBlock)이라 안에 또 두지 않는다.
    var toggle: (() -> Void)? = nil
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        let isButton = toggle != nil
        face
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(isButton && isHovering ? 0.05 : 0))
                    .padding(.horizontal, -4)
            }
            .onHover { isHovering = $0 }
            .gesture(TapGesture().onEnded { toggle?() }, including: isButton ? .all : .subviews)
            .accessibilityAddTraits(isButton ? .isButton : [])
            .accessibilityHint(isButton ? (isOpen ? "누르면 접습니다" : "누르면 펼칩니다") : "")
    }

    /// 위아래 2pt 는 누르는 자리를 글자 높이보다 넓히려는 것이다. 왼쪽 아이콘(20pt)과 높이도 맞는다.
    private var face: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 10)
            label()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// 접힌 동안 보이는 미리보기. 누르는 것은 이걸 감싼 칸(CollapsibleBlock)이 맡는다.
struct CollapsedPreview: View {
    let text: String
    let lines: Int

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .truncationMode(.tail)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 접고 펴는 칸 — 접힌 동안은 칸 전체가 펼치는 버튼이다(사용자 결정). 마우스를 올리면 옅게 칠해 어디까지 눌리는지 보인다.
///
/// 예전에는 머리 한 줄(글자 높이)과 미리보기 글자만 눌려서 손이 잘 안 갔다. `highlight` 는 칠하는 자리를 칸보다
/// 넓히거나(음수) 줄이는(양수) 값이다 — 칠만 하고, 누르는 자리는 칸 그대로다.
/// 펼친 뒤에도 같은 뷰로 남아 누르기만 끈다 — 접힌 칸과 펼친 칸이 다른 뷰면 펼침 애니메이션 동안 둘이 겹쳤다.
struct CollapsibleBlock<Content: View>: View {
    var isCollapsed = true
    let expand: () -> Void
    var highlight = EdgeInsets(top: -3, leading: -4, bottom: -3, trailing: -4)
    /// 칠하는 자리의 모서리. 카드를 통째로 칠할 때는 카드 모서리와 맞춘다.
    var cornerRadius: CGFloat = 6
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isCollapsed && isHovering ? 0.05 : 0))
                    .padding(highlight)
            }
            .onHover { isHovering = $0 }
            .gesture(TapGesture().onEnded(expand), including: isCollapsed ? .all : .subviews)
            .accessibilityAddTraits(isCollapsed ? .isButton : [])
            .accessibilityHint(isCollapsed ? "누르면 펼칩니다" : "")
    }
}

/// 펼친 칸 맨 아래의 접기 띠(사용자 결정). 긴 본문을 다 읽은 자리에서 머리까지 올라가지 않고 접는다.
struct CollapseFooter: View {
    let collapse: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: collapse) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                Text("접기")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// 리뷰를 시작하는 두 가지 방법. 어디서 눌러도 같은 뜻이 되도록 한 곳에 모아 둔다.
enum ReviewLaunch {
    /// diff 만 보고 리뷰. 저장소를 건드리지 않는다.
    case diff
    /// PR head 를 워크트리로 체크아웃하고 호출부까지 확인. diff 밖을 보면서도 비용·시간은 diff 와 크게
    /// 다르지 않다(아래 `detail` 주석). 클론이 없는 레포는 처음 한 번 PR 스냅샷을 받는다(ReviewClone).
    case worktree

    /// ✨ 는 전체 리뷰에 준다 — 더 꼼꼼한 쪽이다. 예전에는 diff 가 ✨ 에 파란 버튼까지 달고 있어
    /// 그쪽이 권하는 방법처럼 보였다(사용자 피드백 — 실제로는 전체 리뷰가 낫다).
    var symbol: String { self == .diff ? "doc.text.magnifyingglass" : "sparkles" }

    /// 두 버튼 중 살짝 앞세울 쪽 — 늘 전체 리뷰. 예전에는 로컬 클론 경로가 없는 레포면 diff 를 앞세웠는데,
    /// 이제는 경로 없이도 PR 스냅샷을 받아 전체 리뷰가 된다.
    static let emphasized: ReviewLaunch = .worktree

    /// 메뉴에 한 줄씩 보이는 설명 — `+` 고를 이유 · `−` 감수할 점 · `·` 알아 둘 것(사용자가 시안 B-2 로 정했다).
    ///
    /// 예전에는 diff "빠르고 쌉니다" · 전체 "느리고 비쌉니다" 였다. 리뷰 기록으로 재 보니 같은 모델에서 전체 리뷰
    /// 비용이 diff 의 1.1~1.5배, 시간은 비슷해서 과장이었다(사용자 피드백). 전체 리뷰는 무엇을 어디에 받는지 적는다 —
    /// 레포 전체를 받는 줄 알고 망설이지 않게.
    ///
    /// 받는 양은 이 레포의 지금 상태로 적는다(2026-10-26). 예전에는 어느 레포든, 이미 받아 둔 뒤에도 "처음 한 번 …
    /// 큰 레포도 단 130MB"(한 레포를 한 번 잰 숫자)였다. 처음이면 GitHub 에 물은 코드 크기(확인 창과 같은 셈),
    /// 받아 뒀으면 달라진 파일만 받는다는 말 — 그 양은 받기 전에는 알 수 없어 숫자를 쓰지 않는다.
    func points(source: ReviewSource, codeSize: CodeSize?) -> [SplitActionButton.Point] {
        switch self {
        case .diff:
            return [.init(mark: "+", text: "받을 것 없이 바로 시작"),
                    .init(mark: "−", text: "diff만 봄 (연관된 코드는 못 봄)")]
        case .worktree:
            var points: [SplitActionButton.Point] = [
                .init(mark: "+", text: "diff와 연관된 코드(호출부, 프로토콜 등)까지 확인"),
                .init(mark: "+", text: "비용·시간은 diff와 비슷"),
            ]
            let folder = (ReviewClone.directory.path as NSString).abbreviatingWithTildeInPath
            switch source {
            case .needsSnapshot:
                let size = codeSize.map { " — 코드 약 \(ByteSizeText.short($0.bytes))\($0.truncated ? " 이상" : "")" } ?? ""
                points.append(.init(mark: "−", text: "처음 한 번 PR 시점 파일만 받음\(size)"))
                points.append(.init(mark: "·", text: "저장: \(folder) (설정에서 지울 수 있음)"))
            case .snapshot:
                points.append(.init(mark: "·", text: "받아 둔 PR 스냅샷 사용 — 달라진 파일만 더 받음"))
            case .linked(let path):
                points.append(.init(mark: "·", text: "연결해 둔 클론 사용 — \((path as NSString).abbreviatingWithTildeInPath)"))
            }
            return points
        }
    }

    /// 리뷰 전 화면 카드의 짧은 설명(ReviewLaunchCards). 받는 양은 카드 아래 한 줄(SnapshotNote)이 따로 말한다.
    var cardPoints: [SplitActionButton.Point] {
        switch self {
        case .diff:
            return [.init(mark: "+", text: "받을 것 없이 바로 시작"),
                    .init(mark: "−", text: "바뀐 줄만 봄")]
        case .worktree:
            return [.init(mark: "+", text: "호출부·프로토콜까지 확인"),
                    .init(mark: "+", text: "비용·시간은 diff와 비슷")]
        }
    }

    /// 마우스를 올렸을 때 보이는 글 — 메뉴 줄을 그대로 잇는다.
    func detail(source: ReviewSource, codeSize: CodeSize?) -> String {
        points(source: source, codeSize: codeSize).map { "\($0.mark) \($0.text)" }.joined(separator: "\n")
    }
}

/// 리뷰 전 화면(AI 리뷰 탭)의 두 방법 — 설명을 단 두 칸 + 모델 + 초안 안내 + 받는 양 한 줄(시안 A-2, 2026-10-26 사용자 결정).
/// 예전에는 같은 무게의 버튼 둘이라 무엇을 골라야 할지 아래 작은 회색 글을 읽어야 알았다.
struct ReviewLaunchCards: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    var body: some View {
        let source = model.reviewSource(for: pr.repo)
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                card(.worktree, source: source)
                card(.diff, source: source)
            }
            // 두 칸 높이를 맞춘다 — 버튼이 같은 줄에 온다. 폭은 정해 준다 — 빈 화면(ContentUnavailableView)의
            // 버튼 자리는 안의 것만큼만 넓어서, 맡기면 두 칸이 한 칸 폭(170pt)으로 눌렸다.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 460)
            // 리뷰를 시작하는 자리에서 모델을 바로 고른다(ReviewModelControl 주석 참고).
            ReviewModelControl(pr: pr)
            // 시작 버튼이 GitHub 에 바로 올린다고 오해하기 쉽다. 버튼에 대한 말이라 버튼·모델 바로 아래에 둔다.
            Label("초안만 이 맥에 만듭니다. GitHub 에는 올라가지 않습니다.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 받는 양·저장 폴더는 버튼과 다른 이야기라 초안 안내와 40pt(VStack 간격 10 + 30) 띄운다. 아래 구분선과는
            // 바깥 VStack 간격 8pt 그대로(2026-10-26 사용자 결정 — 예전엔 초안 안내 위에 붙어 있었다).
            SnapshotNote(pr: pr, source: source)
                .padding(.top, 30)
        }
        .task(id: "\(pr.repo.full)@\(pr.headRefOid)") {
            await model.loadSnapshotCodeSize(for: pr)
            await model.loadSnapshotDiskSize(for: pr.repo)
        }
    }

    private func card(_ launch: ReviewLaunch, source: ReviewSource) -> some View {
        let emphasized = launch == ReviewLaunch.emphasized
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(launch == .worktree ? "전체 리뷰" : "diff 리뷰", systemImage: launch.symbol)
                    .font(.callout.weight(.semibold))
                if emphasized {
                    Text("추천")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(launch.cardPoints.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(point.mark)
                            .foregroundStyle(.tertiary)
                            .frame(width: 9, alignment: .leading)
                        Text(point.text)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            startButton(launch, emphasized: emphasized)
                .disabled(model.isReviewing(pr))
                .help(launch.detail(source: source, codeSize: model.snapshotCodeSize(for: pr)))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(emphasized ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: emphasized ? 2 : 1)
        }
    }

    /// 앞세울 쪽만 파랗게 채운다 — 한 화면에 채운 버튼은 하나.
    @ViewBuilder
    private func startButton(_ launch: ReviewLaunch, emphasized: Bool) -> some View {
        let button = Button {
            model.reviewNow(pr: pr, deep: launch == .worktree)
        } label: {
            Text(launch == .worktree ? "전체 리뷰 시작" : "diff 리뷰 시작")
                .frame(maxWidth: .infinity)
        }
        if emphasized {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// 전체 리뷰가 받는 양 한 줄 — 처음이면 받을 코드 크기(GitHub 에 물은 값), 받아 뒀으면 이 맥에서 차지하는 크기.
/// 숫자는 둘 다 잰 값이다. 못 쟀으면 숫자만 빼고 말한다(크기 때문에 리뷰를 막지 않는다).
/// 받아 뒀으면 줄 끝에 "저장된 폴더 열기" — 경로는 글로 적지 않는다(2026-10-26 사용자 결정, 긴 경로가 줄을 늘린다).
struct SnapshotNote: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let source: ReviewSource

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: icon)
            }
            if case .snapshot(let path) = source {
                Text("·")
                // 클론은 체크아웃이 없어(.git 뿐) 폴더 안이 비어 보인다. 그 폴더를 고른 채 상위 폴더를 연다 —
                // 옆의 리뷰용 워크트리(-review-N)도 같이 보인다.
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("저장된 폴더 열기", systemImage: "folder")
                }
                .buttonStyle(.link)
                // 줄 전체의 .secondary 가 링크 색을 덮어 회색 글처럼 보였다(실측) — 누를 수 있게 보이도록 강조색.
                .foregroundStyle(.tint)
                .help("이 레포의 PR 스냅샷 폴더를 Finder 에서 엽니다")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .help(help)
    }

    private var icon: String {
        switch source {
        case .needsSnapshot: return "arrow.down.circle"
        case .snapshot: return "checkmark.circle"
        case .linked: return "folder"
        }
    }

    private var text: String {
        switch source {
        case .needsSnapshot(let missing):
            let lead = missing == nil ? "전체 리뷰는 처음 한 번 PR 스냅샷을 받습니다"
                : "연결해 둔 클론 폴더가 없어 처음 한 번 PR 스냅샷을 받습니다"
            guard let size = model.snapshotCodeSize(for: pr) else { return lead }
            return lead + " · 받을 코드 약 \(ByteSizeText.short(size.bytes))\(size.truncated ? " 이상" : "")"
        case .snapshot:
            // "달라진 파일만 더 받습니다" 는 툴팁(help)으로 — 폴더 열기가 붙어도 줄 길이를 지금과 비슷하게 둔다.
            guard let bytes = model.snapshotDiskSizes[pr.repo.full] else { return "PR 스냅샷 받아 둠" }
            return "PR 스냅샷 받아 둠 · \(ByteSizeText.short(bytes)) 사용 중"
        case .linked(let path):
            return "연결해 둔 클론을 씁니다 · \((path as NSString).abbreviatingWithTildeInPath)"
        }
    }

    private var help: String {
        let folder = (ReviewClone.directory.path as NSString).abbreviatingWithTildeInPath
        switch source {
        case .needsSnapshot:
            return "PR 시점의 파일만 받습니다(지난 버전들은 받지 않음). 크기는 그 커밋의 파일 합(압축 전)이라 실제로 받는 양과 조금 다릅니다. "
                + "저장: \(folder) — 설정에서 지울 수 있습니다."
        case .snapshot:
            return "다음 리뷰부터는 받아 둔 코드와 달라진 파일만 받아서 대개 몇 초면 됩니다. 크기는 설정에서 보는 값과 같고, 거기서 지울 수 있습니다."
        case .linked:
            return "예전 버전에서 연결한 클론입니다. 설정에서 연결을 끊으면 PR 스냅샷으로 바뀝니다."
        }
    }
}

/// 두 방법에 대한 설명줄. **독립 View 여야 한다** — 다른 뷰의 계산 프로퍼티로 꺼내 쓰면
/// 그 인스턴스에 @Environment 가 설치되지 않아 읽는 순간 트랩한다(실측: AI 리뷰 탭 진입 시 크래시).
struct ReviewLaunchCaption: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    var body: some View {
        Text(Self.text(model: model, pr: pr))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// 설명줄 글. 한 줄짜리 새 커밋 안내(NewCommitsCallout)는 이 글을 마우스를 올렸을 때 보인다.
    /// 환경이 아니라 인자로 모델을 받으므로 어디서 불러도 안전하다(위 주석의 함정과 무관).
    @MainActor
    static func text(model: AppModel, pr: PullRequestInfo) -> String {
        let estimatedTokens = PromptBuilder.estimatedTokens(
            changedLines: model.parsedDiff(for: pr)?.changedLines ?? pr.changedLines)
        // 아직 PR 스냅샷이 없는 레포면 처음 한 번 클론한다는 걸 미리 알린다(누르면 확인 창이 뜬다).
        var needsFirstClone = false
        if case .needsSnapshot = model.reviewSource(for: pr.repo) { needsFirstClone = true }
        return "diff 리뷰 약 \(estimatedTokens / 1000)k 토큰 · 전체 리뷰는 호출부까지 읽어 더 오래 걸립니다"
            + (needsFirstClone ? " · 처음 전체 리뷰 때 PR 스냅샷을 클론합니다" : "")
    }
}

/// AI 리뷰 탭용: 두 방법을 버튼 두 개로 나란히 보여준다.
struct ReviewLaunchButtons: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let hasRecord: Bool
    /// true 면 버튼만 그린다. 다른 버튼들과 한 줄에 놓을 때 쓴다
    /// (아래 설명줄이 붙으면 VStack 높이 때문에 줄 정렬이 깨진다).
    var compact = false

    var body: some View {
        if compact {
            buttons
        } else {
            VStack(spacing: 6) {
                buttons
                // 리뷰를 시작하는 자리에서 모델을 바로 고른다(ReviewModelControl 주석 참고).
                ReviewModelControl(pr: pr)
                ReviewLaunchCaption(pr: pr)
            }
        }
    }

    /// 머리 줄 버튼과 같은 약속(A안) — 같은 모양, 전체 리뷰가 앞, 앞세울 쪽만 파랗게. 예전에는 diff 가
    /// 파랗게 채운 버튼이라 그쪽을 권하는 것처럼 보였다. 클론이 없는 레포도 누르면 PR 스냅샷을 받을지 묻는다
    /// (예전에는 설정의 클론 경로 칸으로 보냈다).
    private var buttons: some View {
            HStack(spacing: 8) {
                let emphasized = ReviewLaunch.emphasized
                Button {
                    model.reviewNow(pr: pr, deep: true)
                } label: {
                    Label(hasRecord ? "전체로 다시 리뷰" : "전체 리뷰", systemImage: ReviewLaunch.worktree.symbol)
                        .foregroundStyle(emphasized == .worktree ? Color.accentColor : Color.primary)
                        .fixedSize()
                }
                .disabled(model.isReviewing(pr))
                .help(ReviewLaunch.worktree.detail(source: model.reviewSource(for: pr.repo),
                                                   codeSize: model.snapshotCodeSize(for: pr)))

                Button {
                    model.reviewNow(pr: pr)
                } label: {
                    Label(hasRecord ? "diff 로 다시 리뷰" : "diff 리뷰", systemImage: ReviewLaunch.diff.symbol)
                        .foregroundStyle(emphasized == .diff ? Color.accentColor : Color.primary)
                        .fixedSize()
                }
                .disabled(model.isReviewing(pr))
                .help(ReviewLaunch.diff.detail(source: model.reviewSource(for: pr.repo), codeSize: nil))
            }
    }

    // 설명줄은 ReviewLaunchCaption 이 담당한다.

}

/// 내가 이 PR 의 리뷰어인지, 이미 리뷰했는지.
struct ReviewerStatusRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    private enum State {
        case author
        case requestedNotReviewed
        case alreadyReviewed(String)
        case notRequested
    }

    private var state: State {
        if pr.viewerDidAuthor { return .author }
        if let reviewState = pr.viewerLatestReviewState,
           ["APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED"].contains(reviewState.uppercased()) {
            return .alreadyReviewed(reviewState.uppercased())
        }
        return pr.viewerHasReviewRequest ? .requestedNotReviewed : .notRequested
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(title)
                .font(model.fonts.ui(delta: -2, weight: .medium))
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 칠하지 않고 테두리만 — 바로 아래 상태 칸들이 색 아이콘을 달고 있어 여기까지 칠하면 색이 겹친다(시안 F).
        .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.45), lineWidth: 0.8))
        .help(help)
    }

    private var title: String {
        switch state {
        case .author: return "내가 올린 PR"
        case .requestedNotReviewed: return "나에게 리뷰가 요청됐습니다"
        case .alreadyReviewed(let reviewState):
            switch reviewState {
            case "APPROVED": return "내가 이미 Approve 했습니다"
            case "CHANGES_REQUESTED": return "내가 변경을 요청했습니다"
            case "DISMISSED": return "내 리뷰가 무효화됐습니다"
            default: return "내가 이미 코멘트했습니다"
            }
        case .notRequested: return "나는 리뷰어로 지정돼 있지 않습니다"
        }
    }

    private var detail: String? {
        switch state {
        case .author: return "GitHub 이 자기 PR Approve 를 막습니다"
        case .requestedNotReviewed:
            let threshold = model.settings.approvalThreshold(for: pr)
            return "Approve \(pr.approvalCount)/\(threshold)"
        case .alreadyReviewed:
            guard let commit = pr.viewerLatestReviewCommit else { return nil }
            return commit == pr.headRefOid ? "현재 커밋 기준" : "리뷰한 커밋 이후 새 커밋이 있습니다"
        case .notRequested: return "리뷰해도 되지만 요청은 없습니다"
        }
    }

    private var symbol: String {
        switch state {
        case .author: return "person.crop.circle.badge.exclamationmark"
        case .requestedNotReviewed: return "person.crop.circle.badge.checkmark"
        case .alreadyReviewed(let reviewState):
            return reviewState == "APPROVED" ? "checkmark.seal.fill" : "bubble.left.fill"
        case .notRequested: return "person.crop.circle.badge.questionmark"
        }
    }

    private var tint: Color {
        switch state {
        case .author: return .secondary
        case .requestedNotReviewed: return .accentColor
        case .alreadyReviewed(let reviewState):
            if reviewState == "APPROVED" { return .green }
            return reviewState == "CHANGES_REQUESTED" ? .orange : .secondary
        case .notRequested: return .secondary
        }
    }

    private var help: String {
        switch state {
        case .author:
            return "내가 작성자입니다. Approve 버튼은 GitHub 이 거부하므로 비활성됩니다."
        case .requestedNotReviewed:
            return "GitHub 이 나를 리뷰어로 요청했고 아직 내 리뷰가 없습니다."
        case .alreadyReviewed:
            return "이 PR 에 이미 내 리뷰가 있습니다. 새 커밋이 올라왔으면 다시 볼 필요가 있습니다."
        case .notRequested:
            return "리뷰 요청 목록에 내가 없습니다. 팀 레포는 CODEOWNERS 설정에 따라 달라질 수 있습니다."
        }
    }
}

/// 남이 쓴 코멘트를 쉬운 말로 풀어 준다. 누를 때만 돌고, 한 번 만든 것은 저장해 다시 만들지 않는다.
struct ExplainBox: View {
    @Environment(AppModel.self) private var model
    let target: ExplainTarget
    let pr: PullRequestInfo?
    @State private var isExpanded = true

    var body: some View {
        if let pr {
            if let explanation = model.explanation(for: target) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Image(systemName: explanation.isQuestion ? "questionmark.bubble" : "text.magnifyingglass")
                                .font(.caption)
                            Text(explanation.point)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if isExpanded {
                        Text(explanation.detail)
                            .font(model.fonts.comment(size: model.settings.commentFontSize - 1))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !explanation.action.isEmpty {
                            Label(explanation.action,
                                  systemImage: explanation.isQuestion ? "arrowshape.turn.up.left" : "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !explanation.terms.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(explanation.terms) { term in
                                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                                        Text(term.term)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Text(term.meaning)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.top, 1)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            } else if model.isExplaining(target) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("쉬운 말로 푸는 중").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    model.explain(target: target, pr: pr)
                } label: {
                    Label("쉽게 설명", systemImage: "text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("이 코멘트가 무슨 말인지, 무엇을 하면 되는지 풀어 줍니다. 코멘트와 그 자리 코드만 보냅니다")
            }
        }
    }
}

/// 칩이 넘치면 다음 줄로 흘려보낸다.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 변경량은 색을 나눠 위아래로 놓는다(한 줄에 +462 −18 로 두면 수식처럼 읽힌다).
/// 개요 정보 칸 — 아이콘을 상태 색의 옅은 네모에 담고, 값은 검게(시안 F3, 2026-10-27 사용자 결정).
/// 값까지 칠하면 칸마다 색이 겹쳐 시끄럽다. 실패·충돌·미해결처럼 손이 가야 하는 값만 그 색으로 쓴다.
struct Fact: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    let detail: String?

    private var valueTint: Color {
        tint == .red || tint == .orange ? tint : .primary
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.8))
        .help(detail ?? "")
    }
}

/// 개요 탭의 카드 바탕 — 라이트는 흰 바탕, 다크는 창보다 살짝 밝게. 옅은 테두리로 가른다(시안 F).
/// GroupBox 의 회색 바탕은 카드끼리·칸끼리 모두 회색이라 화면이 탁했다.
extension View {
    func overviewCard(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.overviewCardFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.8))
    }
}

extension Color {
    static let overviewCardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.white
    })
}

/// 펼친 코드 코멘트 상자의 속 — 첫 글은 본문만, 답글은 아바타와 함께 들여 쌓는다(시안 C4-5).
/// 파일 줄·해결 여부·누가 언제는 감싼 상자(TimelineRow)의 머리가 이미 보여 여기서는 다시 그리지 않는다.
struct ThreadCard: View {
    @Environment(AppModel.self) private var model
    let thread: PRReviewThread
    /// 설명 기능에 필요. 없으면 설명 버튼을 감춘다.
    var pr: PullRequestInfo?
    @State private var expanded = false

    private var visibleComments: [ReviewThreadComment] {
        expanded ? thread.comments : Array(thread.comments.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleComments.enumerated()), id: \.offset) { index, comment in
                if index == 0 {
                    MarkdownText(text: comment.body)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Divider()
                    CommentBubble(comment: comment, isReply: true)
                }
            }
            if thread.comments.count > 3 {
                Divider()
                Button(expanded ? "접기" : "답글 \(thread.comments.count - 3)개 더 보기") {
                    expanded.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.vertical, 6)
            }
            if pr != nil {
                Divider()
                ExplainBox(target: ExplainTarget(thread: thread), pr: pr)
                    .padding(.vertical, 6)
            }
        }
    }
}

struct CommentBubble: View {
    @Environment(AppModel.self) private var model
    let comment: ReviewThreadComment
    let isReply: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Avatar(login: comment.author, name: model.settings.displayName(comment.author), size: 18)
                Text(model.settings.displayName(comment.author))
                    .font(.caption.weight(.semibold))
                    .help(comment.author)
                if let date = ISO8601DateFormatter().date(from: comment.createdAt) {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            MarkdownText(text: comment.body)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.leading, isReply ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
