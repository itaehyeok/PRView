import AppKit
import SwiftUI
import PRayerCore

struct AIReviewView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// 돌아올 자리(`ReviewItemKey`). 있으면 이 탭이 그려질 때 그 행으로 스크롤한다 —
    /// 탭을 옮기면 이 뷰가 새로 만들어져 스크롤이 맨 위로 돌아가기 때문이다.
    var returnKey: String? = nil
    /// 변경 파일 탭에 다녀왔으면 돌아온 행을 잠깐 칠해 어디로 돌아왔는지 보여 준다.
    var flashOnAppear = false
    /// 변경 파일 탭에서 본 항목. 행에 "diff 에서 봄" 을 붙인다.
    var seenInDiff: Set<String> = []
    /// 그 줄로 이동한다. 두 번째 값은 돌아올 자리(누른 행의 `ReviewItemKey`).
    let onJumpToDiff: (String, String) -> Void
    /// 우려사항·질문을 변경 파일 탭에서 그 줄 아래에 펼쳐 따라간다.
    var onFollow: (ReviewFollow) -> Void = { _ in }
    var onReturned: () -> Void = {}
    @State private var flashKey: String?
    /// 좁은 창에서 보고 있는 탭. nil 이면 돌아온 자리로 고른다(`currentTab`).
    @State private var narrowTab: PanelTab?
    /// 이 행으로 스크롤해 잠깐 칠해 달라는 요청(`ReviewIssue.key`). 안내 줄의 "머지를 막는 이슈" 가 쓴다.
    @State private var scrollRequest: String?
    @State private var showPostSheet = false
    @State private var showDiscardConfirm = false
    @State private var showApproveConfirm = false
    /// "리뷰 없이 Approve" 버튼의 마지막 크기 — 올라간 순간 이 자리에서 체크로 줄어든다(`ApproveCheckMorph`).
    @State private var approveButtonSize: CGSize = .zero
    /// 지금 도는 Approve 연출이 시작한 버튼 크기. 끝나면 nil.
    @State private var approveMorph: CGSize?
    @State private var showRequestChangesConfirm = false
    /// 게시 중·실패는 앱 모델에 둔다(`AppModel.postingKeys` 주석) — 이 화면은 PR 을 오갈 때마다 새로 그려진다.
    private var isPosting: Bool { model.postingKeys.contains(PostingKey.review(pr)) }
    private var isApproving: Bool { model.postingKeys.contains(PostingKey.approve(pr)) }
    private var postFailure: String? { model.postFailures[PostingKey.review(pr)] }
    private var approveFailure: String? { model.postFailures[PostingKey.approve(pr)] }
    /// 게시하려는데 새 커밋이 올라와 있으면 무엇이 왔는지 보여 주고 그대로 올릴지 묻는다.
    @State private var pendingDrift: PendingDrift?
    /// 스크롤 막대 모양. 마우스를 꽂고 빼면 바뀐다(`scrollContentWidth`).
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    /// "리뷰에 담기" 고스트가 날아갈 자리들(`BasketFlight`). 관찰하지 않는 상자다.
    @State private var basketFrames = BasketFrames()
    /// 지금 날아가는 고스트. 도착 자리(`tripTarget`)를 받으면 그리로 움직이고, 내려앉으면 nil.
    @State private var trip: BasketFlight.Trip?
    @State private var tripTarget: CGRect?
    /// 이 줄이 보이게 칸을 굴려 달라는 요청(`ReviewIssue.key`) — 담은 줄이 왼쪽 칸 화면 밖에 생겼을 때.
    @State private var revealRequest: String?

    var body: some View {
        Group {
            if let job = model.job(for: pr), job.isActive {
                // 리뷰가 도는 동안 무엇이 진행 중인지 보여준다.
                VStack(spacing: 0) {
                    RunningReviewCard(job: job) {
                        model.cancel(jobID: job.id)
                    }
                    .padding(16)
                    // 승인은 리뷰 결과를 기다릴 필요가 없는 동작이다.
                    standaloneApproveBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    if let record = model.record(for: pr) {
                        Divider()
                        content(record: record)
                    } else {
                        Spacer()
                    }
                }
            } else if let record = model.record(for: pr) {
                content(record: record)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showPostSheet) {
            if let record = model.record(for: pr) {
                PostSheet(pr: pr, record: record)
            }
        }
        .sheet(item: $pendingDrift) { pending in
            NewCommitsSheet(prompt: pending.prompt, onConfirm: pending.confirm)
        }
        // 코멘트가 붙는 코드 조각을 보여주려면 diff 가 필요하다.
        .task(id: pr.id) { await model.loadDiff(for: pr) }
        .onChange(of: pr.id) { approveMorph = nil }
        #if DEBUG
        // 확인 캡처용 — 아무것도 올리지 않고 Approve 연출만 돌린다(`PRAYER_DEBUG_APPROVE_MORPH`).
        .task(id: pr.id) {
            guard DebugLaunch.approveMorphPace != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if approveButtonSize != .zero { approveMorph = approveButtonSize }
        }
        #endif
        // "코멘트 없이" 는 **인라인 코멘트**가 없다는 뜻이었는데, 리뷰 본문(요약)은 그대로 올라갔다.
        // 실제로 무엇이 올라가는지 보여주고 본문 포함 여부를 고르게 한다.
        .confirmationDialog("Approve 를 올릴까요?", isPresented: $showApproveConfirm, titleVisibility: .visible) {
            Button("요약과 함께 Approve") { approveOnly(includeBody: true) }
            Button("본문 없이 Approve 만") { approveOnly(includeBody: false) }
            Button("취소", role: .cancel) {}
        } message: {
            Text(approveMessage)
        }
    }

    /// 지금 승인을 올릴 수 있는가.
    /// 이미 이 커밋을 승인했으면 또 올려도 승인 표가 늘지 않고 리뷰 목록만 지저분해진다.
    private var canApprove: Bool {
        !pr.viewerDidAuthor && !pr.viewerApprovedCurrentHead
    }

    private var approveBlockedReason: String? {
        if pr.viewerDidAuthor { return "내가 올린 PR 은 GitHub 이 Approve 를 거부합니다." }
        if pr.viewerApprovedCurrentHead {
            return "이 커밋(\(String(pr.headRefOid.prefix(7))))은 이미 내가 Approve 했습니다. 새 커밋이 올라오면 다시 Approve 할 수 있습니다."
        }
        return nil
    }

    private var approveHelp: String {
        if let reason = approveBlockedReason { return reason }
        if pr.viewerApproved {
            return "리뷰한 커밋 이후 새 커밋이 올라와 다시 Approve 할 수 있습니다."
        }
        return "인라인 코멘트 없이 Approve 를 남깁니다. Approve 수에 1표로 집계됩니다."
    }

    /// 근거로 제시된 코드 위치로 diff 를 이동시킨다. 줄을 모르면 파일만 연다.
    private func jump(to evidence: CodeEvidence, from origin: String) {
        onJumpToDiff("\(evidence.path)#RIGHT#\(evidence.line ?? 1)", origin)
    }

    /// 변경 파일 탭에서 돌아왔으면 누르고 떠난 행으로 간다. 화면 위쪽 3할 쯤에 둔다 —
    /// 맨 위에 붙이면 그 위의 맥락(어느 절인지)이 안 보인다.
    private func restorePlace(_ proxy: ScrollViewProxy) {
        guard let returnKey else { return }
        let id = ReviewRowID.of(returnKey)
        // 막 그려진 참이라 행이 아직 자리를 안 잡았다. 한 박자 늦게 민다(SettingsView 와 같은 처리).
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
        guard flashOnAppear else { return }
        onReturned()
        flashKey = returnKey
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.5)) { flashKey = nil }
        }
    }

    /// 돌아온 직후 잠깐 띄우는 알림. 행 깜빡임만으로는 화면이 왜 움직였는지 모를 수 있다.
    @ViewBuilder
    private var returnToast: some View {
        if flashKey != nil {
            Label("보던 자리로 돌아왔습니다", systemImage: "arrow.uturn.backward")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.top, 8)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        // 리뷰가 실패하면 잡이 비활성이 되면서 이 화면으로 돌아온다.
        // 아무 말도 없이 "아직 리뷰하지 않았습니다" 만 뜨면 눌러도 아무 일이 없는 것처럼 보인다.
        if let job = model.job(for: pr), job.state == .failed || job.state == .cancelled {
            // 로그인이 끊긴 것이라면 "다시 리뷰" 버튼은 눌러도 또 실패한다.
            // 할 일이 다르므로 문구도 버튼도 바꾼다. 그 뒤 다시 로그인했으면 다시 리뷰로 돌려놓는다.
            let authFailed = job.state == .failed && AuthFailure.isExpired(job.message ?? "")
            let loggedInAgain = authFailed && model.engineLoginRecovered(after: job.startedAt ?? job.queuedAt)
            let authExpired = authFailed && !loggedInAgain
            VStack(spacing: 0) {
                calloutBox(kind: loggedInAgain ? .info : .warning,
                           icon: loggedInAgain
                             ? "checkmark.circle.fill"
                             : (job.state == .failed ? "exclamationmark.triangle.fill" : "xmark.circle"),
                           text: authExpired
                             ? "Claude Code 로그인이 끊겼습니다. 다시 로그인하면 이어서 리뷰할 수 있습니다."
                             : loggedInAgain
                             ? "Claude Code 에 다시 로그인했습니다. 이어서 리뷰할 수 있습니다."
                             : (job.state == .failed
                                ? "리뷰가 실패했습니다: \(job.message ?? "원인을 알 수 없습니다.")"
                                : (job.message ?? "리뷰를 취소했습니다."))) {
                    if authExpired && model.engineLoginInProgress {
                        // 눌러 놓고 터미널에서 로그인하는 중이다. 버튼을 또 두면 눌렀는지 헷갈린다.
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("터미널에서 로그인하는 중")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if authExpired {
                        Button("터미널에서 다시 로그인") {
                            model.openEngineLogin()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        ReviewLaunchButtons(pr: pr, hasRecord: false)
                    }
                }
                .padding(16)
                unreviewedPlaceholder
            }
        } else {
            unreviewedPlaceholder
        }
    }

    /// 카드는 ContentUnavailableView 의 actions 에 넣지 않는다. 높이가 모자라면 그 뷰가 아이콘을 빼면서 actions 자리를
    /// 400pt 로 줄여 460pt 카드 두 칸의 양옆이 잘렸다(실측: 창 높이 692 + 알림 배너). 밖에 두고, 모자라면 스크롤한다.
    private var unreviewedPlaceholder: some View {
        let estimate = PromptBuilder.estimatedTokens(changedLines: pr.changedLines)
        return GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 8) {
                    ContentUnavailableView {
                        Label("아직 리뷰하지 않았습니다", systemImage: "sparkles")
                    } description: {
                        VStack(spacing: 4) {
                            Text("변경 \(pr.changedLines)줄 · 예상 \(estimate / 1000)k 토큰")
                            if let reason = model.skipReason(for: pr) {
                                Text("참고: \(reason.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // ContentUnavailableView 가 아래에 두는 여백을 덜어 설명과 카드 사이를 actions 에 있던 때와 맞춘다.
                    .padding(.bottom, -28)
                    // 두 방법을 설명 단 두 칸으로(ReviewLaunchCards) — 같은 무게의 버튼 둘이면 무엇을 고를지 몰랐다.
                    // "초안만 이 맥에" 안내도 그 안에 있다(PR 스냅샷 줄보다 위에 와야 해서).
                    ReviewLaunchCards(pr: pr)
                    Divider().frame(width: 260)
                    // actions 안에서는 버튼이 카드 폭만큼 늘어났다(macOS 26 의 actions 버튼 크기). 그 모양을 그대로 둔다.
                    Group {
                        if #available(macOS 26.0, *) {
                            standaloneApproveBar.buttonSizing(.flexible)
                        } else {
                            standaloneApproveBar
                        }
                    }
                    .frame(width: 460)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func content(record: ReviewRecord) -> some View {
        let binding = Binding<ReviewRecord>(
            get: { model.records[pr.id] ?? record },
            set: { model.update(record: $0) }
        )
        // 안쪽 내용 폭은 스크롤 **바깥** 폭으로 정한다(`scrollContentWidth`). 안쪽에서 남은 폭을 따르면
        // 항상 보이는 스크롤 막대가 생기고 없어질 때마다 폭이 15pt 오간다. 그 사이에 두 칸·탭 기준(872)이
        // 걸리면 두 칸(길다 → 막대 생김 → 좁아짐) → 탭(짧다 → 막대 없어짐 → 넓어짐) → 두 칸 … 을 끝없이
        // 되풀이해 앱이 멈췄다(실측: 창 1250 · 목록 342.8 · 시스템 설정 "스크롤 막대 항상 보기", CPU 100%).
        GeometryReader { geometry in
            let contentWidth = scrollContentWidth(outer: geometry.size.width)
            let twoColumns = (contentWidth ?? 0) >= Self.twoColumnMinWidth
            ScrollViewReader { proxy in
                Group {
                    if twoColumns {
                        splitColumns(record: record, binding: binding, outerWidth: geometry.size.width)
                    } else {
                        // 좁으면 위아래로 쌓지 않고 탭으로 오간다 — 쌓으면 코드 코멘트가 본문 아래로 밀려 있는 줄도 몰랐다(사용자 피드백).
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                headerArea(record: record, stacked: true)
                                VStack(alignment: .leading, spacing: 12) {
                                    panelTabs(record: record)
                                    switch currentTab(record) {
                                    case .body:
                                        bodyColumn(record: record, binding: binding)
                                    case .comments:
                                        issueSection(record: record, binding: binding, showsVerdict: false)
                                    }
                                }
                            }
                            .frame(width: contentWidth, alignment: .leading)
                            .padding(16)
                        }
                    }
                }
                .onChange(of: twoColumns, initial: true) { _, isTwo in basketFrames.twoColumns = isTwo }
                .overlay(alignment: .top) { returnToast }
                .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                    scrollerStyle = NSScroller.preferredScrollerStyle
                }
                .onAppear { restorePlace(proxy) }
                .task(id: record.id) {
                    // 확인용: 그 번째 코드 코멘트까지 내려 둔다(뒤에 띄운 사본은 밖에서 스크롤할 수 없다).
                    guard let index = DebugLaunch.reviewScrollIndex, record.issues.indices.contains(index) else { return }
                    try? await Task.sleep(for: .seconds(3))
                    scrollRequest = record.issues[index].key
                }
                .onChange(of: scrollRequest) { _, key in
                    guard let key else { return }
                    scrollRequest = nil
                    withAnimation { proxy.scrollTo(ReviewRowID.of(key), anchor: UnitPoint(x: 0.5, y: 0.1)) }
                    flashKey = key
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(.easeOut(duration: 0.5)) { flashKey = nil }
                    }
                }
                // 담은 줄이 왼쪽 칸 화면 밖에 생기면 거기까지 굴린다 — 고스트가 보이는 곳에 내려앉게. 이미 보이면 그대로다.
                .onChange(of: revealRequest) { _, key in
                    guard let key else { return }
                    revealRequest = nil
                    proxy.scrollTo(ReviewRowID.of(key))
                }
            }
        }
    }

    /// 판정 줄과 그 아래 안내들. 두 칸이면 두 칸 위에 고정되고, 좁으면 스크롤 맨 위에 온다.
    /// Approve 안내 줄은 PR 전체에 대한 말이라 두 패널 위에 전체 폭으로 둔다 — 왼쪽 칸 안에 두면
    /// 그만큼 왼쪽 상자만 내려가 두 패널의 시작 높이가 어긋났다(사용자 피드백).
    @ViewBuilder
    private func headerArea(record: ReviewRecord, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            verdictHeader(record: record, stacked: stacked)
            if record.headSha != pr.headRefOid {
                // 한 줄로 줄인 안내(NewCommitsCallout 주석). 예전 상자는 버튼·모델 칸·설명줄을 세로로 쌓아 세 줄이었다.
                NewCommitsCallout(pr: pr, reviewedHead: record.shortHead)
            }
            if !record.validationIssues.isEmpty {
                calloutBox(kind: .warning, icon: "exclamationmark.triangle", text: validationText(record)) {
                    EmptyView()
                }
            }
            if !record.isPosted {
                ApprovalHint(pr: pr, record: record, onShowBlockers: { showBlockers(in: record) })
            }
        }
    }

    /// 넓은 창 — 왼쪽 리뷰 본문 · 오른쪽 코드 코멘트가 **각자 스크롤된다**(사용자 요청, 2026-10-27). 예전엔 스크롤 하나에
    /// 왼쪽만 위에 붙어 따라와서(StickyLeadingColumns), 왼쪽이 길면 오른쪽을 끝까지 내려야 왼쪽 아래가 보였다.
    /// 왼쪽은 GitHub 리뷰 맨 위에 올라갈 본문, 오른쪽은 작성자에게 남길 지적(우려사항·질문·초안을 합침) — 반대로도 놓아
    /// 봤다가 이쪽이 낫다고 되돌렸다(사용자 결정, 2026-10-20). 판정 줄·안내 줄은 두 칸 위에 고정한다.
    ///
    /// 칸 폭은 바깥 폭으로 정하고 항상 보이는 막대 폭을 늘 뺀다 — 칸 안에서 막대가 생겼다 없어지며 폭이 바뀌면
    /// 끝없이 다시 재던 함정(scrollContentWidth 주석)을 그대로 밟는다.
    private func splitColumns(record: ReviewRecord, binding: Binding<ReviewRecord>, outerWidth: CGFloat) -> some View {
        let scroller = scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let column = max(0, (outerWidth - 32 - Self.columnSpacing) / 2)
        let inner = max(0, column - scroller)
        return VStack(alignment: .leading, spacing: 0) {
            headerArea(record: record, stacked: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ScrollView {
                    bodyColumn(record: record, binding: binding)
                        .frame(width: inner, alignment: .topLeading)
                        .padding(.bottom, 16)
                        // 막대가 없을 때 스크롤 뷰가 내용을 가운데로 보내 칸이 막대 폭의 반만큼 오른쪽으로 밀렸다.
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: column)
                .recordBasketFrame { basketFrames.leftViewport = $0 }
                ScrollView {
                    issueSection(record: record, binding: binding)
                        .frame(width: inner, alignment: .topLeading)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: column)
                .recordBasketFrame { basketFrames.rightViewport = $0 }
            }
            .padding(.horizontal, 16)
            .coordinateSpace(.named(BasketFlight.space))
            // 고스트는 두 칸 위에 띄운다 — 칸 안에서 옮기면 스크롤·둥근 상자 가장자리에서 잘린다.
            .overlay(alignment: .topLeading) { flightLayer }
        }
    }

    /// 두 칸(리뷰 본문 · 코드 코멘트)으로 놓을 때 한 칸의 기준 폭과 칸 사이.
    private static let columnWidth: CGFloat = 430
    private static let columnSpacing: CGFloat = 12
    /// 이 폭부터 두 칸, 좁으면 탭. 예전 `ViewThatFits` 가 고르던 기준(두 칸의 이상 폭 430 + 12 + 430)과 같다.
    private static let twoColumnMinWidth = columnWidth * 2 + columnSpacing

    /// 스크롤 안 내용 폭 — 바깥 폭에서 좌우 여백(16 × 2)과 **항상 보이는 막대의 폭을 늘** 뺀다.
    /// 막대가 있든 없든 안쪽 폭이 같아서, 두 칸·탭과 새 커밋 안내 줄의 배치가 막대 때문에
    /// 뒤집히지 않는다. 막대가 없을 때는 오른쪽에 막대 폭만큼 빈 자리가 남는다. 겹쳐 보이는 막대는 자리를 차지하지 않는다.
    private func scrollContentWidth(outer: CGFloat) -> CGFloat? {
        guard outer > 0 else { return nil }
        let scroller = scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return max(0, outer - 32 - scroller)
    }

    /// 좁으면(`stacked` — 두 칸 대신 탭으로 볼 때) 결과 줄과 실행 정보 줄로 나눈다.
    /// 한 줄에 다 놓으려면 870pt 안팎이 드는데, 그보다 좁으면 남은 폭에 맞춰 게시 알약이 눌려
    /// 글자가 한 자씩 세로로 쌓였다(사용자 스크린샷, 2026-10-22). 나누는 기준은 두 칸·탭과 같은 폭이라
    /// 헤더만 따로 재지 않는다 — ViewThatFits 로 재면 폭이 바뀔 때마다 한 번 더 잰다(위 두 칸 주석).
    @ViewBuilder
    private func verdictHeader(record: ReviewRecord, stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    verdictLabel(record)
                    Spacer(minLength: 0)
                    postedPill(record)
                }
                runFacts(record)
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                verdictLabel(record)
                Divider().frame(height: 14)
                runFacts(record)
                Spacer()
                postedPill(record)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// 판정. 헤더에서 폭이 모자랄 때 줄어드는 건 판정 글 하나다 — 실행 정보·게시 알약은 제 폭을 지켜서,
    /// 넘치면 판정 글이 두 줄로 접힌다. 상태 배지(Blocker·LGTM 등)는 목록 행과 코드 코멘트 칸 머리 줄에 있어 두지 않는다
    /// (2026-10-23 사용자 결정 — 그때는 PR 헤더에 있었고 10-30 에 코드 코멘트 칸으로 옮겼다).
    @ViewBuilder
    private func verdictLabel(_ record: ReviewRecord) -> some View {
        Text(pr.viewerDidAuthor ? ownVerdictText(record.output.verdict) : verdictText(record.output.verdict))
            .font(.callout.bold())
            .lineLimit(2)
    }

    /// 언제·어떤 모델로·얼마나 들여 만든 리뷰인지.
    private func runFacts(_ record: ReviewRecord) -> some View {
        HStack(spacing: 10) {
            // 언제 만든 리뷰인지가 없어서 "이게 아까 것인지 방금 것인지" 를 알 수 없었다.
            // 커밋 해시보다 이게 먼저 궁금한 정보라 앞에 둔다.
            // 같은 PR 을 여러 번 리뷰했으면 여기서 지난 리뷰를 골라 볼 수 있다.
            ReviewHistoryPicker(pr: pr, record: record)
            // 커밋 해시와 "Claude · claude-opus-5-5" 는 뺐다 — Opus 만 봐도 Claude 인 줄 알고, 해시는 거의 안 읽었다
            // (사용자 피드백). 새 커밋이 왔는지는 위의 새 커밋 안내 줄이 따로 알려 준다.
            Text("·")
            Text(model.recordModelName(record))
            Tag(text: record.isDeep ? "전체 리뷰" : "diff 리뷰",
                color: record.isDeep ? .purple : .secondary)
                .font(.caption)
            Text("·")
            Text("\(record.usage.billableTokens / 1000)k 토큰")
                .font(.caption)
            Text("·")
            Text("\(record.usage.durationMs / 1000)초")
                .font(.caption)
        }
        // "43k 토큰" 같은 칸이 두 줄로 꺾이지 않게 제 폭을 지킨다.
        .fixedSize()
    }

    /// "게시됨" 세 글자만으로는 무엇이 어디로 갔는지 알 수 없다.
    /// 무엇으로(승인·코멘트·변경요청), 언제, 인라인 몇 건인지까지 적고 GitHub 로 연결한다.
    @ViewBuilder
    private func postedPill(_ record: ReviewRecord) -> some View {
        if let posted = record.posted {
            Button {
                NSWorkspaceOpener.open(posted.htmlURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill").font(.system(size: 9))
                    Text(postedSummary(posted)).font(.caption)
                    // 누르면 GitHub 의 그 리뷰로 간다는 표시. ↗ 보다 어디로 가는지가 바로 읽힌다.
                    GitHubMark(size: 9)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(Color.green)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 알약은 줄어들지 않는다. 폭을 내주면 글자가 한 자씩 세로로 쌓였다.
            .fixedSize()
            .help("이 초안을 GitHub 에 올렸습니다. 눌러서 올라간 리뷰를 엽니다.")
        }
    }

    /// 게시 결과 한 줄. 무엇으로 올렸는지가 핵심이다(승인으로 올렸는데 코멘트로 착각하면 곤란하다).
    /// 앞에 붙던 "GitHub 에" 는 뺐다 — 알약 끝의 GitHub 마크가 같은 말을 하고, 좁은 창에서 자리만 먹었다.
    private func postedSummary(_ posted: PostedInfo) -> String {
        let kind = ReviewEvent(rawValue: posted.event)?.label ?? posted.event
        var parts = ["\(kind) 로 게시"]
        if posted.commentCount > 0 { parts.append("인라인 \(posted.commentCount)건") }
        parts.append(RelativeTime.ago(posted.postedAt))
        return parts.joined(separator: " · ")
    }

    /// 코멘트가 붙는 위치의 코드 조각(앞뒤 2줄).
    private func snippet(for state: DraftCommentState) -> [DiffLine] {
        guard let diff = model.parsedDiff(for: pr),
              let file = diff.file(matching: state.comment.path) else { return [] }
        return file.snippet(around: state.comment.line, side: state.comment.side)
    }

    /// AI 리뷰 없이 승인하는 줄. 리뷰가 없든 도는 중이든 항상 쓸 수 있다.
    /// 버튼이 지금 상태를 말한다(시안 A) — 올리는 중엔 글로, 끝나면 초록 결과로, 실패하면 "다시 시도" 와 이유로.
    @ViewBuilder
    private var standaloneApproveBar: some View {
        VStack(spacing: 4) {
            if let from = approveMorph {
                ApproveCheckMorph(from: from, text: "이 커밋에 Approve 했어요",
                                  pace: DebugLaunch.approveMorphPace ?? 1) { approveMorph = nil }
            } else if pr.viewerApprovedCurrentHead && !isApproving {
                PostedStatusLabel(text: "이 커밋에 Approve 했어요")
            } else {
                // 되묻지 않는다 — AI 리뷰 뒤 Approve 로 게시할 때도 묻지 않는다. 되묻는 건 변경 요청뿐이다.
                Button {
                    plainApprove()
                } label: {
                    if isApproving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Approve 올리는 중…")
                        }
                        .fixedSize()
                    } else if approveFailure != nil {
                        Label("Approve 실패 — 다시 시도", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize()
                    } else {
                        Label("리뷰 없이 Approve", systemImage: "checkmark.seal")
                            .fixedSize()
                    }
                }
                .disabled(isApproving || !canApprove || !pr.isOpen)
                .help(approveHelp)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { approveButtonSize = $0 }
            }
            if let failure = approveFailure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = approveBlockedReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func plainApprove(acceptingHead: String? = nil) {
        let key = PostingKey.approve(pr)
        let pr = pr
        model.postingKeys.insert(key)
        model.postFailures[key] = nil
        Task {
            let result = await model.approve(pr: pr, body: "", acceptingHead: acceptingHead)
            model.postingKeys.remove(key)
            if case .failure(.headDrift(let drift)) = result {
                pendingDrift = PendingDrift(drift: drift,
                                            prompt: HeadDriftPrompt.make(drift: drift, subject: .plainApprove),
                                            confirm: { plainApprove(acceptingHead: drift.headSha) })
            } else if case .failure(let error) = result {
                // 실패는 누른 그 자리에 남긴다. 몇 초 뒤 사라지는 아래 알림으로는 놓쳤다.
                model.postFailures[key] = PostFailureText.of(error)
            } else {
                model.banner = Banner(kind: .success, message: "#\(pr.number) Approve 했어요")
                // 다른 PR 로 옮겨 갔으면 그 PR 의 버튼 자리에서 돌지 않게 한다.
                if model.selectedPR?.id == pr.id, approveButtonSize != .zero { approveMorph = approveButtonSize }
            }
        }
    }

    /// 지금 이 PR·이 초안에서 무엇을 고를 수 있는지 판단할 재료. "전송 내용 자세히" 창과 같은 셈을 쓴다.
    private func actionContext(_ record: ReviewRecord) -> PostActionContext {
        // 왼쪽 게시에 실리는 줄 코멘트는 오른쪽 카드에서 "리뷰에 담기" 한 것뿐이다. 담지 않은 카드는 각자 바로 단다.
        var context = PostActionPlan.context(record: record, pr: pr)
        context.inlineCount = record.basketIssues.count
        return context
    }

    /// 지금 고른 게시 방식(`PostActionPlan.current` — 골라 둔 것이 더 이상 고를 수 없으면 권장값).
    private func currentAction(_ record: ReviewRecord) -> PostAction {
        PostActionPlan.current(saved: record.plannedAction, in: actionContext(record))
    }

    /// 고른 방식 그대로 게시한다. 시트를 거치지 않는다.
    private func postNow(record: ReviewRecord, action: PostAction, acceptingHead: String? = nil) {
        let key = PostingKey.review(pr)
        let pr = pr
        model.postingKeys.insert(key)
        model.postFailures[key] = nil
        Task {
            // 승인만 게시는 본문도 인라인도 보내지 않는다 — 버튼 이름이 곧 보내는 내용이다.
            let body = action.includesContent ? PostBuilder.composedBody(record: record) : ""
            var basket: [BasketItem] = []
            if action.includesContent, !record.basketIssues.isEmpty {
                // 초안 없는 지적은 diff 에서 자리를 찾는다. 하나라도 못 찾으면 올리지 않는다 — 담은 것 중 일부만
                // 빠진 채 Approve 가 나가면 사용자는 다 달렸다고 믿는다.
                _ = await model.waitForDiff(for: pr)
                let built = model.basketItems(for: pr, record: record)
                guard built.missing.isEmpty else {
                    model.postingKeys.remove(key)
                    let places = built.missing.map { $0.place ?? $0.title }.joined(separator: ", ")
                    model.postFailures[key] = "리뷰에 담은 줄 코멘트 중 \(built.missing.count)개(\(places))의 자리를 찾지 못했습니다. 빼고 다시 게시하세요."
                    return
                }
                basket = built.items
            }
            let result = await model.post(record: record,
                                          event: action.event,
                                          body: body,
                                          includeComments: false,
                                          basket: basket,
                                          acceptingHead: acceptingHead)
            model.postingKeys.remove(key)
            switch result {
            case .success(let posted):
                let withInline = basket.isEmpty ? "" : " · 줄 코멘트 \(basket.count)개"
                model.banner = Banner(kind: .success,
                                      message: "#\(pr.number) \(PostedStatusLabel.postedAs(action.event)) 게시했어요\(withInline)",
                                      actionTitle: GitHubLink.title,
                                      opensGitHub: true) {
                    NSWorkspaceOpener.open(posted.htmlURL)
                }
            case .failure(.headDrift(let drift)):
                let inline = basket.count
                pendingDrift = PendingDrift(drift: drift,
                                            prompt: HeadDriftPrompt.make(drift: drift,
                                                                         subject: .review(event: action.event,
                                                                                          label: action.label,
                                                                                          inlineCount: inline)),
                                            confirm: { postNow(record: record, action: action,
                                                               acceptingHead: drift.headSha) })
            case .failure(let error):
                // 실패는 누른 그 자리에 남긴다. 버튼이 "다시 시도" 로 바뀌고 이유가 바로 아래에 적힌다.
                model.postFailures[key] = PostFailureText.of(error)
            }
        }
    }

    /// 승인에 붙일 본문. 게시 전에 사용자가 눈으로 확인할 수 있어야 한다.
    private var approveMessage: String {
        let body = (model.record(for: pr).map(approveBody) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["인라인 코멘트는 올리지 않습니다."]
        if body.isEmpty {
            lines.append("본문도 비어 있어 APPROVE 만 남습니다.")
        } else {
            lines.append("\n\"요약과 함께 Approve\" 을 고르면 아래 본문이 GitHub 리뷰에 그대로 올라갑니다:\n")
            lines.append(body.count > 300 ? String(body.prefix(300)) + "…" : body)
        }
        return lines.joined(separator: "\n")
    }

    /// "요약과 함께 Approve" 의 본문. 게시 전이면 본문에서 고친 요약·잘된 점을 반영해 다시 만든다 —
    /// `bodyDraft` 는 리뷰가 끝난 순간의 원문으로 만든 값이라 고친 글이 빠진다. 게시한 뒤에는 올라간 그대로.
    private func approveBody(_ record: ReviewRecord) -> String {
        record.isPosted ? record.bodyDraft : PostBuilder.defaultBody(record: record)
    }

    private func approveOnly(includeBody: Bool) {
        let key = PostingKey.approve(pr)
        model.postingKeys.insert(key)
        model.postFailures[key] = nil
        Task {
            defer { model.postingKeys.remove(key) }
            guard let record = model.record(for: pr) else { return }
            let body = includeBody
                ? approveBody(record).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let result = await model.approveWithoutComments(record: record, body: body)
            if case .failure(let error) = result {
                model.postFailures[key] = PostFailureText.of(error)
            }
        }
    }

    /// 내 PR 은 Approve 할 일이 없어 고칠 것이 있는지로 말한다.
    private func ownVerdictText(_ verdict: Verdict) -> String {
        switch verdict {
        case .approve: return "고칠 것 없음"
        case .comment: return "짚을 것 있음"
        case .requestChanges: return "고칠 것 있음"
        }
    }

    private func verdictText(_ verdict: Verdict) -> String {
        switch verdict {
        case .approve: return "인라인 코멘트 없이 Approve 가능"
        case .comment: return "코멘트 필요"
        case .requestChanges: return "변경이 필요함"
        }
    }

    private func validationText(_ record: ReviewRecord) -> String {
        record.validationIssues.map(\.message).joined(separator: "\n")
    }

    @ViewBuilder
    private func draftSection(record: ReviewRecord, binding: Binding<ReviewRecord>) -> some View {
        GroupBox("예상 코멘트 초안 (\(record.comments.count)) — 사안별로 하나씩") {
            if record.comments.isEmpty {
                Text(pr.viewerDidAuthor ? "코드에 짚을 것이 없습니다." : "인라인 코멘트 없이 Approve 해도 되는 상태입니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                VStack(spacing: 10) {
                    // 본문 상자와 같은 약속 — 체크한 것만 올라간다. 예전에는 맨 아래 "게시 미리보기" 가
                    // 올라갈 코멘트를 한 번 더 그렸는데, 카드와 같은 글이라 두 번 읽게 했다.
                    inlineSummary(record)
                    ForEach(Array(record.comments.enumerated()), id: \.element.id) { index, state in
                        let draftKey = ReviewItemKey.draft(state.comment)
                        let movedFrom = movedItemKey(of: state, in: record)
                        DraftCommentCard(state: state,
                                         pr: pr,
                                         record: record,
                                         snippet: snippet(for: state),
                                         readOnly: record.isPosted,
                                         clearedNote: record.clearedNote(for: ReviewItemKey.draft(state.comment)),
                                         onCleared: { note in
                                             var updated = binding.wrappedValue
                                             updated.setCleared(note, for: ReviewItemKey.draft(state.comment))
                                             binding.wrappedValue = updated
                                         },
                                         onToggle: { include in
                                             var updated = binding.wrappedValue
                                             guard index < updated.comments.count else { return }
                                             updated.comments[index].include = include
                                             binding.wrappedValue = updated
                                         },
                                         onEdit: { text in
                                             var updated = binding.wrappedValue
                                             guard index < updated.comments.count else { return }
                                             updated.comments[index].editedBody = text
                                             binding.wrappedValue = updated
                                         },
                                         onJump: {
                                             onJumpToDiff("\(state.comment.path)#\(state.comment.side.rawValue)#\(state.comment.line)",
                                                          draftKey)
                                         },
                                         onJumpToEvidence: { evidence in
                                             jump(to: evidence, from: draftKey)
                                         },
                                         movedFromLabel: movedFrom.map { ReviewPlaceName.of($0, in: record) },
                                         onUndoMove: movedFrom.map { itemKey in
                                             {
                                                 var updated = binding.wrappedValue
                                                 updated.undoMoveToInline(itemKey)
                                                 binding.wrappedValue = updated
                                             }
                                         })
                        .id(ReviewRowID.of(draftKey))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.yellow.opacity(flashKey == draftKey ? 0.2 : 0))
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    /// 게시 조작부. 본문과 한 세트라(무엇을 올릴지 → 올리기) 넓은 창에서는 왼쪽 본문 바로 아래에 둔다.
    private func postControls(record: ReviewRecord, binding: Binding<ReviewRecord>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let context = actionContext(record)
            let action = currentAction(record)
            // 조작부를 둘로 줄인다. 예전에는 이벤트 세그먼트 3 + 버튼 6 이 한 화면에 있었다.
            // 게시는 되돌릴 수 없고 확인 창도 없애 두었으므로, 버튼 몸통 라벨이
            // 마지막 방어선이다 — 그래서 "게시" 가 아니라 "코멘트+승인 게시" 라고 적는다.
            // 게시한 뒤에는 회색으로 잠긴 게시 버튼 대신 무엇으로 올렸는지를 그 자리에 둔다. 잠긴 버튼은 이름이
            // 다음 권장 동작("코멘트만 게시")으로 바뀌어, 아직 안 올린 것처럼 읽혔다(2026-10-22 시안 A).
            // 결과는 따로 한 줄이다 — 다시 리뷰 버튼까지 한 줄에 두면 좁은 상세(460pt)에서 넘쳤다.
            if let posted = record.posted, !isPosting {
                HStack(alignment: .center, spacing: 8) {
                    PostedStatusLabel(text: "\(PostedStatusLabel.postedAs(posted.event)) 게시됨")
                        .help("\(RelativeTime.ago(posted.postedAt)) GitHub 에 올렸습니다.")
                    Button {
                        NSWorkspaceOpener.open(posted.htmlURL)
                    } label: {
                        GitHubLinkLabel(title: "GitHub 에서 보기", markSize: 12)
                            .fixedSize()
                    }
                    .help("GitHub 에 올라간 이 리뷰를 엽니다")
                }
            }
            HStack(alignment: .center, spacing: 8) {
                if pr.viewerDidAuthor {
                    // 내 PR 리뷰는 이미 올린 PR 을 스스로 확인하는 용도다 — 게시 버튼 자리에 점선 칩을 둔다
                    // (시안 B, 2026-10-29 사용자 결정 — 꺼 둔 버튼(D)·위 띠(C)는 고르지 않았다).
                    OwnPRNoPostChip()
                } else if record.posted == nil || isPosting {
                    SplitActionButton(
                        title: postFailure == nil ? PostActionPlan.buttonLabel(action, in: context) : "게시 실패 — 다시 시도",
                        systemImage: postFailure != nil ? "exclamationmark.triangle"
                            : action.event == .approve ? "checkmark.seal" : "paperplane",
                        prominent: postFailure == nil,
                        isBusy: isPosting,
                        busyTitle: "GitHub 에 올리는 중…",
                        tint: postFailure == nil ? nil : .red,
                        disabledReason: record.isPosted
                            ? "이미 게시했습니다."
                            : PostActionPlan.disabledReason(action, in: context),
                        choices: PostActionPlan.menu(for: context).map { candidate in
                            SplitActionButton.Choice(id: candidate.rawValue,
                                                     label: candidate.menuLabel,
                                                     detail: candidate.explanation,
                                                     disabledReason: PostActionPlan.disabledReason(candidate, in: context))
                        },
                        selectedID: action.rawValue,
                        onRun: {
                            // 변경 요청만 되묻는다. 작성자 흐름을 막는 동작이다.
                            if action == .requestChanges {
                                showRequestChangesConfirm = true
                            } else {
                                postNow(record: record, action: action)
                            }
                        },
                        onSelect: { raw in
                            var updated = binding.wrappedValue
                            updated.plannedAction = raw
                            binding.wrappedValue = updated
                        })
                        .confirmationDialog("변경 요청으로 올릴까요?", isPresented: $showRequestChangesConfirm) {
                            Button("변경 요청 게시", role: .destructive) {
                                postNow(record: record, action: .requestChanges)
                            }
                            Button("취소", role: .cancel) {}
                        } message: {
                            Text("작성자가 다시 리뷰를 요청해야 Approve 절차가 진행됩니다.")
                        }
                }

                // 올리는 동안 다시 리뷰하면 올리는 초안이 발밑에서 바뀐다.
                ReviewLaunchSplitButton(pr: pr, hasRecord: true)
                    .disabled(isPosting)
                    .opacity(isPosting ? 0.45 : 1)

                Spacer()

                // "전송 내용 자세히"·"폐기" 는 뺐다 — 본문은 왼쪽 상자가 곧 게시될 모양이고, 줄 코멘트는 오른쪽에서
                // 따로 단다. 글자 링크 둘이 게시 버튼 옆에서 눈만 끌었다(사용자 피드백).
                InfoHint(text: """
                    전체로 다시 리뷰: diff와 연관된 코드(호출부, 프로토콜 등)까지 확인합니다. \
                    비용·시간은 diff와 비슷합니다.

                    diff 로 다시 리뷰: diff만 봅니다. 클론 없이 바로 시작합니다.

                    둘 다 지금 초안을 새 결과로 대체합니다.
                    """)
            }
            if let failure = postFailure, !isPosting {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // "본문 포함 · Approve 1표" 요약 줄과 예상 토큰 안내 줄은 뺐다 — 무엇이 올라가는지는 바로 위 본문 상자가
            // 보여 주고, 버튼 이름이 리뷰 종류를 말한다(사용자 피드백).
            // 다시 리뷰할 때 쓸 모델. 여기서 바꾸면 위 '다시 리뷰' 버튼이 그 모델로 돈다.
            // 오른쪽 끝에 있던 "끝에 붙이기 · 없음/👥/by Claude" 메뉴는 없앴다 — 보이는 표기는 늘 안 붙인다(2026-10-20 사용자 결정).
            HStack(alignment: .center, spacing: 8) {
                ReviewModelControl(pr: pr, alignment: .leading)
                Spacer(minLength: 8)
            }
        }
    }

    /// 좁은 창의 두 탭.
    private enum PanelTab { case body, comments }

    /// 보고 있는 탭. 고른 적이 없으면 첫 탭(리뷰 본문) — 단, 변경 파일 탭에서 코드 코멘트로 돌아왔으면 코드 코멘트.
    /// 탭을 옮기면 이 뷰가 새로 만들어져 고른 탭을 잊는데, 그때 본문 탭이 열리면 돌아올 행이 숨어 스크롤이 헛돈다.
    private func currentTab(_ record: ReviewRecord) -> PanelTab {
        if let narrowTab { return narrowTab }
        if DebugLaunch.opensCommentPanel { return .comments }
        // 리뷰에 담은 것은 리뷰 본문 탭(담은 줄 코멘트)에 있다.
        if let returnKey, !record.isPosted, record.basketKeys.contains(returnKey) { return .body }
        if let returnKey, record.issues.contains(where: { $0.key == returnKey }) { return .comments }
        return .body
    }

    /// GitHub PR 화면의 "Conversation 3 · Files changed 1" 같은 밑줄 탭. 순서는 넓은 화면의 열 순서와 같다.
    /// 코드 코멘트 탭에는 넓은 화면의 코드 코멘트 칸 머리 줄과 같은 판정 칩을 단다 — 판정이 PR 제목 밑에서 빠져,
    /// 상세에서 본문 탭을 보는 동안 판정이 보이는 곳은 여기뿐이다(2026-10-30 사용자 결정). 예전엔 아직 안 단 코드 코멘트 수를
    /// 파란 숫자 배지로 달았다. 그 수는 칸 머리 줄의 "0/5 달림" 에 그대로 있다.
    private func panelTabs(record: ReviewRecord) -> some View {
        let composedCount = PostBuilder.composedBody(record: record).count
        let selected = currentTab(record)
        let chips = VerdictChip.chips(for: record)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                panelTabButton(title: "리뷰 본문", systemImage: "text.alignleft",
                               isSelected: selected == .body, action: { narrowTab = .body }) {
                    Text(composedCount == 0 ? "본문 없음" : "\(composedCount)자")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.secondary)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                // 탭 전체가 버튼이라 칩은 누를 것 없이 글자만 둔다 — 첫 카드로 가는 건 탭을 연 뒤 카드 목록에서.
                panelTabButton(title: "코드 코멘트", systemImage: "chevron.left.forwardslash.chevron.right",
                               isSelected: selected == .comments, action: { narrowTab = .comments }) {
                    HStack(spacing: 4) {
                        ForEach(chips, id: \.text) { VerdictChipLabel(chip: $0) }
                    }
                }
                .help(chips == [.lgtm] ? "코드에 남길 지적이 없습니다" : FindingCounts(record: record).summary)
                Spacer()
            }
            Divider()
        }
    }

    private func panelTabButton<Badge: View>(title: String, systemImage: String, isSelected: Bool,
                                             action: @escaping () -> Void,
                                             @ViewBuilder badge: () -> Badge) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(model.fonts.ui(weight: isSelected ? .semibold : .regular))
                    badge()
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                // 밑줄은 강조색 — GitHub 처럼 주황으로 두니 그때 옆에 있던 파란 숫자 배지와 따로 놀았다(사용자 피드백).
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    }

    /// 리뷰 본문 열 — 본문 상자, 게시 조작부, 이어서 대화하기. 예전엔 이어서 대화하기가 두 열 아래에 가로로 걸쳐
    /// 어느 쪽 것인지 흐렸다(사용자 피드백).
    private func bodyColumn(record: ReviewRecord, binding: Binding<ReviewRecord>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            bodyCard(record: record, binding: binding)
            postControls(record: record, binding: binding)
            // 게시 줄과 이어서 대화하기 사이를 띄운다 — 붙어 있어 한 덩어리처럼 보였다(사용자 피드백).
            Divider()
                .padding(.top, 24)
            ResumeConversationSection(record: record)
                .padding(.top, 8)
        }
    }

    private func bodyCard(record: ReviewRecord, binding: Binding<ReviewRecord>) -> some View {
        ReviewBodyCard(pr: pr, record: record, binding: binding, isPosting: isPosting,
                       basketFrames: basketFrames,
                       hiddenIssueKey: trip?.intoBasket == true ? trip?.issue.key : nil,
                       flashKey: flashKey,
                       onUnbasket: { issue in moveBasket(issue, into: false) },
                       onJumpToCode: { issue in jump(toIssue: issue, in: record) })
            .recordBasketFrame { basketFrames.body = $0 }
    }

    /// 날아가는 고스트. 도착 자리를 받기 전에는 출발 자리에 떠 있다.
    @ViewBuilder
    private var flightLayer: some View {
        if let trip {
            let rect = tripTarget ?? trip.from
            // 윗변을 맞춘다 — 가운데를 맞추면 키 큰 카드 한복판에 내려앉아, 카드가 위아래로 펼쳐지듯 나타났다.
            // 폭은 출발 때 그대로 둔다. 폭을 같이 옮기면 날아가는 동안 글이 줄마다 다시 감기며 겹쳐 보였다.
            BasketGhost(issue: trip.issue, text: trip.text, checked: trip.intoBasket)
                .frame(width: trip.from.width)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// 체크로 담기·빼기. 두 칸이 나란히 보이면 고스트가 카드 → 왼쪽 담은 줄(빼기는 반대)로 날아가 내려앉고, 좁은 창(탭)에서는
    /// 그냥 바꾼다 — 탭은 한 번에 한쪽만 보여 날아갈 곳이 화면에 없다.
    ///
    /// 두 칸이 따로 스크롤되어 도착 자리가 그 칸의 화면 밖일 수 있다. 담을 때는 왼쪽 칸을 그 줄까지 굴리고(revealRequest),
    /// 뺄 때는 오른쪽 칸을 굴리지 않고 보이는 자리 끝까지만 날려 보낸다 — 읽던 오른쪽이 멋대로 움직이지 않게.
    private func moveBasket(_ issue: ReviewIssue, into: Bool) {
        let change = {
            withAnimation(.easeInOut(duration: 0.3)) { model.setInBasket(into, issue: issue, pr: pr) }
        }
        let source = into ? basketFrames.cards[issue.key] : basketFrames.rows[issue.key]
        guard basketFrames.twoColumns, trip == nil, let source, source.width > 0 else {
            change()
            return
        }
        // 도착 자리는 바꾼 뒤 새로 잰 값만 믿는다. 전에 적힌 값은 다른 배치(빠지기 전·옮기기 전)의 것이다.
        if into { basketFrames.rows[issue.key] = nil } else { basketFrames.cards[issue.key] = nil }
        tripTarget = nil
        trip = BasketFlight.Trip(issue: issue, text: model.issueText(pr: pr, issue: issue), intoBasket: into, from: source)
        change()
        if into { revealRequest = issue.key }
        let frames = basketFrames
        Task { @MainActor in
            var landing: CGRect?
            for _ in 0..<12 where landing == nil {
                try? await Task.sleep(for: .milliseconds(16))
                landing = into ? frames.rows[issue.key] : frames.cards[issue.key]
            }
            // 처음 잰 자리는 굴리기 전일 수 있다. 두 박자 기다려 마지막 값을 쓴다.
            try? await Task.sleep(for: .milliseconds(32))
            landing = (into ? frames.rows[issue.key] : frames.cards[issue.key]) ?? landing
            // 끝내 못 재면(그쪽이 안 그려졌으면) 본문 상자 아래 / 오른쪽 칸 쪽으로만 보낸다.
            let fallback = into
                ? CGRect(x: frames.body.minX, y: frames.body.maxY - 60, width: frames.body.width, height: 60)
                : source.offsetBy(dx: source.width + Self.columnSpacing, dy: 0)
            let target = BasketFlight.keepInside(landing ?? fallback,
                                                 viewport: into ? frames.leftViewport : frames.rightViewport)
            withAnimation(.easeInOut(duration: BasketFlight.duration)) { tripTarget = target }
            try? await Task.sleep(for: .seconds(BasketFlight.duration))
            withAnimation(.easeOut(duration: 0.15)) {
                trip = nil
                tripTarget = nil
            }
        }
    }

    /// 오른쪽 "코드 코멘트" 목록. 왼쪽 본문과 같은 상자 틀이고, 줄마다 GitHub 의 줄 코멘트 모양(파일 줄 → 코드 → 내 코멘트)이다.
    private func issueSection(record: ReviewRecord, binding: Binding<ReviewRecord>, showsVerdict: Bool = true) -> some View {
        let issues = record.issues
        let diff = model.parsedDiff(for: pr)
        let postedCount = issues.filter { record.postedComment(for: $0) != nil }.count
        // 필수 → 권장 → 참고 순. 같은 중요도 안에서는 모델이 쓴 순서 그대로(안정 정렬).
        // "머지를 막는 이슈 N"·"그 밖의 코멘트 N" 묶음 머리는 뺐다 — 카드 맨 위 띠가 중요도를 말한다(2026-10-20 사용자 결정).
        // 리뷰에 담은 것은 왼쪽 리뷰 본문의 "담은 줄 코멘트" 로 넘어가 있어 여기서는 뺀다(빼면 제자리로 돌아온다).
        // 내 PR 은 게시하지 않으므로 담을 리뷰도 없다 — 담아 둔 것이 남아 있어도 카드는 제자리에 둔다.
        let basketed = Set(record.isPosted || pr.viewerDidAuthor ? [] : record.basketIssues.map(\.key))
        let sorted = issues.enumerated()
            .sorted { ($0.element.importance, $0.offset) < ($1.element.importance, $1.offset) }
            .map(\.element)
            .filter { !basketed.contains($0.key) }
        // "모두 담기" 가 담을 카드 — 카드 체크가 켜지는 것과 같은 조건(바로 다는 중인 카드도 뺀다), 오른쪽 목록 순서 그대로.
        let addable = pr.viewerDidAuthor ? [] : sorted.filter {
            record.canAddToBasket($0, diff: diff) && !model.postingIssueKeys.contains("\(pr.id)|\($0.key)")
        }
        return ReviewPanelBox(isDashed: true) {
            if !addable.isEmpty {
                basketAllCheckbox(addable, total: sorted.count, anyIn: !basketed.isEmpty,
                                  isPostingReview: model.postingKeys.contains(PostingKey.review(pr)))
            }
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("코드 코멘트")
                .font(model.fonts.ui(weight: .semibold))
            Text("\(issues.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            // 판정 칩 — 예전엔 빨간 글자 "필수 N" 이 이 자리에, 판정 칩은 PR 제목 밑에 있었다. 판정이 코드 코멘트를 센
            // 결과라는 게 안 보여 여기로 옮겼다(VerdictChip 주석, 2026-10-30 사용자 결정 시안 C·X).
            // 좁은 창은 바로 위 탭이 같은 칩을 달고 있어 여기서는 뺀다.
            if showsVerdict {
                verdictChips(record: record, cards: sorted)
            }
            // "달림 0 · 누르면 바로 달림" 은 두 안내를 붙여 읽기 어려웠다(사용자 피드백). 센 것만 두고,
            // 바로 달린다는 안내는 달기 버튼 설명으로 옮겼다. 담은 것이 있으면 그 수를 앞에 붙인다.
            // 내 PR 은 달 일이 없어 센 것도 두지 않는다.
            if !pr.viewerDidAuthor {
                let basketCount = record.isPosted ? 0 : record.basketIssues.count
                Text(issues.isEmpty ? "" : (basketCount > 0 ? "담음 \(basketCount) · " : "") + "\(postedCount)/\(issues.count) 달림")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("리뷰에 담은 코멘트 수와, 이 PR 에 코드 코멘트를 몇 개 달았는지")
            }
        } content: {
            if issues.isEmpty {
                Text("코드에 남길 코멘트가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if sorted.isEmpty {
                Label("모두 리뷰에 담았어요 — 왼쪽 리뷰 본문 아래 '담은 줄 코멘트' 에 있어요", systemImage: "arrow.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            issueRows(sorted, record: record, binding: binding, diff: diff)
        }
    }

    /// 머리 줄 "코드 코멘트" 앞 "모두 담기" 체크 — 남은 카드를 한꺼번에 리뷰에 담는다. 카드 체크와 같은 열에 서서
    /// 목록 맨 위 전체 체크처럼 읽힌다. 머리 줄 아래 따로 한 줄("☐ 5개 모두 리뷰에 담기")이던 것을 올렸다 — 줄 하나가
    /// 줄어 카드가 바로 시작한다(사용자 요청, 2026-10-28). 글자는 마우스를 올렸을 때 보인다.
    /// 체크하면 카드가 왼쪽으로 넘어가 이 체크도 사라지므로 체크된 채로 남는 일은 없다.
    /// 여러 장이 한꺼번에 움직여 날아가는 고스트는 띄우지 않는다 — 카드가 빠지고 왼쪽에 쌓이는 것만 애니메이션.
    private func basketAllCheckbox(_ addable: [ReviewIssue], total: Int, anyIn: Bool, isPostingReview: Bool) -> some View {
        let title = anyIn ? "남은 \(addable.count)개 모두 담기"
            : (addable.count == total ? "\(addable.count)개 모두 리뷰에 담기" : "\(addable.count)개 리뷰에 담기")
        return Toggle(isOn: Binding(get: { false }, set: { isOn in
            guard isOn else { return }
            withAnimation(.easeInOut(duration: 0.3)) { model.addToBasket(addable, pr: pr) }
        })) {
            Text(title)
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .controlSize(.small)
        .disabled(isPostingReview)
        .help("\(title) — 코드 코멘트를 왼쪽 리뷰 본문 아래 '담은 줄 코멘트' 로 옮깁니다. 담으면 리뷰를 게시할 때 한 번에 달려요. 하나씩 빼려면 그 체크를 끄세요.")
    }

    @ViewBuilder
    private func issueRows(_ list: [ReviewIssue], record: ReviewRecord,
                           binding: Binding<ReviewRecord>, diff: ParsedDiff?) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, issue in
            if index > 0 { Divider() }
            issueRow(issue, record: record, binding: binding, diff: diff)
                .id(ReviewRowID.of(issue.key))
                .modifier(FlashHighlight(isOn: flashKey == issue.key, bleed: 0))
                .recordBasketFrame { basketFrames.cards[issue.key] = $0 }
                // 빼서 돌아오는 카드는 고스트가 내려앉을 때까지 숨겨 둔다 — 둘이 겹쳐 보이지 않게.
                .opacity(trip?.intoBasket == false && trip?.issue.key == issue.key ? 0 : 1)
        }
    }

    /// 코드 코멘트 칸 머리 줄의 판정 칩들(좁은 창 탭은 탭 버튼 안이라 `VerdictChipLabel` 만 쓴다). 칩을 누르면 그 묶음(필수 / 권장·참고)의 첫 카드로 간다 —
    /// 오른쪽 목록에 남은 카드(`cards`, 화면 순서)에서 먼저 찾고, 다 담았으면 왼쪽 '담은 줄 코멘트' 쪽 것으로.
    /// 셀 카드가 없는 칩(LGTM·숫자 없는 Non-blocker)은 누를 것이 없어 글자만 둔다.
    private func verdictChips(record: ReviewRecord, cards: [ReviewIssue]) -> some View {
        let findings = FindingCounts(record: record)
        return HStack(spacing: 4) {
            ForEach(VerdictChip.chips(for: record), id: \.text) { chip in
                let target = Self.firstCard(of: chip, in: cards, record: record)
                let help = Self.verdictChipHelp(chip, findings: findings, canJump: target != nil)
                // 꺼진 버튼으로 두면 칩이 흐려져 목록의 같은 칩과 달라 보인다 — 누를 것이 없으면 버튼으로 감싸지 않는다.
                if let target {
                    Button {
                        narrowTab = .comments
                        scrollRequest = target.key
                    } label: {
                        VerdictChipLabel(chip: chip)
                    }
                    .buttonStyle(.plain)
                    .help(help)
                } else {
                    VerdictChipLabel(chip: chip)
                        .help(help)
                }
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private static func firstCard(of chip: VerdictChip, in cards: [ReviewIssue], record: ReviewRecord) -> ReviewIssue? {
        let belongs: (ReviewIssue) -> Bool
        switch chip {
        case .blocker: belongs = { $0.importance == .required && !record.isCleared($0.key) }
        case .nonBlocker(.some): belongs = { $0.importance != .required && !record.isCleared($0.key) }
        case .nonBlocker(nil), .lgtm: return nil
        }
        return cards.first(where: belongs) ?? record.issues.first(where: belongs)
    }

    private static func verdictChipHelp(_ chip: VerdictChip, findings: FindingCounts, canJump: Bool) -> String {
        let jump = canJump ? " — 누르면 첫 카드로 갑니다" : ""
        switch chip {
        case .blocker:
            return "필수 \(findings.required) — 머지를 막는 지적\(jump)"
        case .nonBlocker(.some):
            return "권장 \(findings.recommended) · 참고 \(findings.informational) — 머지를 막지 않는 지적\(jump)"
        case .nonBlocker(nil):
            return "지적을 모두 '문제 아님' 으로 정리했습니다"
        case .lgtm:
            return "코드에 남길 지적이 없습니다"
        }
    }

    /// 안내 줄의 "머지를 막는 이슈" 를 누름 — 코드 코멘트의 첫 막는 이슈로 스크롤해 잠깐 칠한다.
    private func showBlockers(in record: ReviewRecord) {
        guard let first = record.issues.first(where: \.isBlocking) else { return }
        narrowTab = .comments
        scrollRequest = first.key
    }

    private func issueRow(_ issue: ReviewIssue, record: ReviewRecord,
                          binding: Binding<ReviewRecord>, diff: ParsedDiff?) -> some View {
        IssueCard(pr: pr, issue: issue,
                  onJump: { jump(toIssue: issue, in: record) },
                  onJumpToEvidence: { evidence in jump(to: evidence, from: issue.key) },
                  onBasket: { isOn in moveBasket(issue, into: isOn) })
    }



    /// 지적의 자리로. 우려사항·질문은 변경 파일 탭에서 그 줄 아래에 펼쳐 따라가고, 초안만 있는 것은 그 줄로 간다.
    private func jump(toIssue issue: ReviewIssue, in record: ReviewRecord) {
        if issue.kind != .draftOnly, ReviewFollowList.items(in: record.output).contains(where: { $0.key == issue.key }) {
            onFollow(ReviewFollow(itemKey: issue.key, locationIndex: 0))
        } else if let path = issue.path, let line = issue.line {
            onJumpToDiff("\(path)#RIGHT#\(line)", issue.key)
        }
    }

    /// 이 초안이 우려사항·질문을 옮겨 만든 것이면 그 항목의 키.
    private func movedItemKey(of state: DraftCommentState, in record: ReviewRecord) -> String? {
        record.movedToInline?.first { $0.value == state.comment.issueKey }?.key
    }

    /// "체크한 2건만 인라인 코멘트로 올라갑니다 · 제외 1건" — 무엇이 빠지는지까지 한 줄로.
    private func inlineSummary(_ record: ReviewRecord) -> some View {
        let postable = record.comments.filter(\.isPostable).count
        let excluded = record.comments.count - postable
        var text = "체크한 \(postable)건만 인라인 코멘트로 올라갑니다"
        if excluded > 0 {
            text += " · 제외 \(excluded)건(체크를 껐거나 정리했거나, diff 에서 줄을 못 찾은 코멘트)"
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum CalloutKind { case info, warning }

    @ViewBuilder
    private func calloutBox<Trailing: View>(kind: CalloutKind,
                                            icon: String,
                                            text: String,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(kind == .warning ? .orange : .accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
        .padding(10)
        .background((kind == .warning ? Color.orange : Color.accentColor).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 왜 이런 코멘트·질문을 하는지, 어떤 코드가 근거인지 펼쳐서 보여준다.
/// 사용자가 직접 판단하고 게시할 수 있어야 하므로 기본은 접힌 상태로 두고 한 번에 펼친다.
struct RationaleBox: View {
    let title: String
    let rationale: String?
    let evidence: [CodeEvidence]?
    let onJump: (CodeEvidence) -> Void

    @State private var isExpanded = false

    private var hasContent: Bool {
        !(rationale ?? "").isEmpty || !(evidence ?? []).isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "lightbulb")
                            .font(.caption)
                        Text(title)
                            .font(.caption.weight(.medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if isExpanded {
                    if let rationale, !rationale.isEmpty {
                        Text(rationale)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let evidence, !evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(evidence) { item in
                                Button {
                                    onJump(item)
                                } label: {
                                    HStack(alignment: .top, spacing: 5) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.line.map { "\(item.fileName):\($0)" } ?? item.fileName)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(Color.accentColor)
                                            Text(item.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(item.path)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct AuthorQuestionRow: View {
    let question: AuthorQuestion
    let pr: PullRequestInfo
    let record: ReviewRecord
    let clearedNote: String?
    /// 리뷰 본문에 들어가는가. 본문에는 질문 한 줄만 올라가서 그 줄만 흐리게 한다(ConcernRow 와 같다).
    var isInBody = true
    let onCleared: (String?) -> Void
    let onJump: (CodeEvidence) -> Void
    /// 인라인으로 옮겼으면 그 자리("Foo.swift:42").
    var movedTo: String? = nil
    /// 변경 파일 탭에서 본 항목인가.
    var isSeen = false
    /// 사용자가 고친 질문 문장(`ReviewTextEdits`). nil 이면 원문.
    var editedText: String? = nil
    /// 질문 문장 고치기. nil 을 넘기면 원문으로. 이 클로저가 nil 이면 고칠 수 없다(게시한 리뷰).
    var onEditText: ((String?) -> Void)? = nil

    @State private var showDiscussion = false
    /// 편집기를 열었는가. 모델 데이터가 아니라 화면 상태다.
    @State private var isEditing = false

    /// 질문에는 자리(path·line)가 없을 수 있다. 근거가 있으면 그 자리를 쓴다.
    private var anchorEvidence: CodeEvidence? { question.evidence?.first }

    /// 줄까지 아는 근거. 우려사항의 `파일:줄` 처럼 접지 않고 보인다 —
    /// 예전에는 "왜 물어보나" 를 펼쳐야만 근거 링크가 보여서, 질문은 코드로 가는 길이 숨어 있었다.
    private var lineEvidence: [CodeEvidence] { (question.evidence ?? []).filter { $0.line != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing, let onEditText {
                // 고치는 동안에는 질문 줄 자리에 편집기가 들어간다 — 요약·잘된 점과 같다.
                // 줄을 그대로 두고 아래에 편집기를 열면 같은 글이 위아래로 두 번 보였다(사용자 피드백).
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.callout)
                        .padding(.top, 8)
                    ReviewTextEditor(original: question.question, current: editedText ?? question.question,
                                     minHeight: 40,
                                     onSave: { text in
                                         onEditText(text)
                                         isEditing = false
                                     },
                                     onCancel: { isEditing = false })
                    .id(record.id)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Label(editedText ?? question.question, systemImage: "questionmark.circle")
                        .font(.callout)
                        .strikethrough(clearedNote != nil, color: .secondary)
                        .foregroundStyle(clearedNote != nil ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if editedText != nil { EditedMark() }
                    if question.isDuplicate {
                        DuplicateTagButton(isExpanded: showDiscussion) { showDiscussion.toggle() }
                    }
                    Spacer(minLength: 0)
                    // 인라인으로 옮긴 질문은 본문에 없다 — 문장은 옮긴 초안에서 고친다.
                    if onEditText != nil, movedTo == nil {
                        EditTextButton { isEditing = true }
                    }
                }
                .opacity(isInBody ? 1 : 0.55)
            }
            if !lineEvidence.isEmpty || isSeen {
                HStack(spacing: 8) {
                    ForEach(Array(lineEvidence.enumerated()), id: \.offset) { _, evidence in
                        Button {
                            onJump(evidence)
                        } label: {
                            Text("\(evidence.fileName):\(evidence.line ?? 0)")
                                .font(.caption.monospaced())
                        }
                        .buttonStyle(.link)
                        .help("변경 파일 탭에서 이 줄 아래에 펼쳐 봅니다 — \(evidence.note)")
                    }
                    if isSeen { SeenInDiffMark() }
                }
                .padding(.leading, 20)
            }
            if let movedTo { MovedToInlineNote(place: movedTo) }
            if let note = question.existingNote, !note.isEmpty {
                Label(note, systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDiscussion {
                RelatedDiscussionPanel(pr: pr, subject: .of(question),
                                       onJump: anchorEvidence.map { evidence in { onJump(evidence) } })
            }
            RationaleBox(title: "왜 물어보나",
                         rationale: question.rationaleKo,
                         evidence: question.evidence,
                         onJump: onJump)
            RecheckBox(pr: pr, record: record, subject: .of(question),
                       kindLabel: "작성자 질문", severity: nil)
            // 인라인으로 옮긴 것을 정리하면 "문제없다" 와 같은 자리의 질문이 같이 나간다. 정리는 옮긴 초안 쪽에서 한다.
            if movedTo == nil {
                ClearedControl(topic: ClearedTopic.of(question), note: clearedNote, onChange: onCleared)
            }
        }
        .padding(.bottom, 2)
        .onAppear {
            if DebugLaunch.editText == ReviewItemKey.question(question), onEditText != nil { isEditing = true }
        }
    }
}

/// 변경 파일 탭에서 따라가며 본 항목 표시. 여러 개를 넘겨 봤을 때 어디까지 봤는지 남긴다.
struct SeenInDiffMark: View {
    var body: some View {
        Label("diff 에서 봄", systemImage: "checkmark")
            .font(.caption2)
            .foregroundStyle(Color.purple)
            .labelStyle(.titleAndIcon)
            .help("변경 파일 탭에서 이 항목을 봤습니다")
    }
}

/// 우려사항·질문을 그 줄의 인라인 초안으로 옮겼다는 안내. 본문에서 빠진다는 것까지 적는다.
struct MovedToInlineNote: View {
    let place: String

    var body: some View {
        Label("\(place) 의 인라인 코멘트 초안으로 옮김 · 리뷰 본문에서는 뺍니다", systemImage: "text.bubble")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "이미 언급됨" 태그 겸 펼침 버튼. 세 항목(초안·우려사항·질문)이 함께 쓴다.
struct DuplicateTagButton: View {
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 2) {
                Text("이미 언급됨")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.orange)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "오간 대화 접기" : "누가 무슨 말을 했는지 보기")
    }
}

struct ConcernRow: View {
    let concern: Concern
    /// "이미 언급됨" 을 펼쳤을 때 오간 대화를 찾을 대상.
    let pr: PullRequestInfo
    /// 언제 만든 리뷰인지 알아야 "그 뒤에 올라온 것" 을 셀 수 있다.
    let record: ReviewRecord
    let clearedNote: String?
    /// 리뷰 본문에 들어가는가. 본문에는 머리 줄("- [심각도] 제목")만 올라가서 그 줄만 흐리게 한다.
    /// 아래 도구까지 흐리면 "문제없음으로 정리" 한 줄 — 본문의 '확인했고 문제없던 것' 에 따로
    /// 올라간다 — 까지 안 올라가는 것처럼 보인다.
    var isInBody = true
    let onCleared: (String?) -> Void
    let onJump: () -> Void
    /// 인라인으로 옮겼으면 그 자리("Foo.swift:42").
    var movedTo: String? = nil
    /// 변경 파일 탭에서 본 항목인가.
    var isSeen = false
    /// 사용자가 고친 제목(`ReviewTextEdits`). nil 이면 원문.
    var editedText: String? = nil
    /// 제목 고치기. nil 을 넘기면 원문으로. 이 클로저가 nil 이면 고칠 수 없다(게시한 리뷰).
    var onEditText: ((String?) -> Void)? = nil

    @State private var showDiscussion = false
    /// 편집기를 열었는가. 모델 데이터가 아니라 화면 상태다.
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isEditing, let onEditText {
                // 고치는 동안에는 제목 자리에 편집기가 들어간다 — 요약·잘된 점과 같다.
                // 제목 줄을 그대로 두고 아래에 편집기를 열면 같은 글이 위아래로 두 번 보였다(사용자 피드백).
                HStack(alignment: .top, spacing: 6) {
                    Tag(text: concern.severity.label, color: color)
                        .padding(.top, 8)
                    ReviewTextEditor(original: concern.title, current: editedText ?? concern.title,
                                     hint: "본문에는 [\(concern.severity.label)] 뒤에 이 한 줄이 올라갑니다.",
                                     minHeight: 40,
                                     onSave: { text in
                                         onEditText(text)
                                         isEditing = false
                                     },
                                     onCancel: { isEditing = false })
                    .id(record.id)
                }
            } else {
                HStack(spacing: 6) {
                    headline
                    Spacer()
                    if isSeen { SeenInDiffMark() }
                    if concern.line != nil {
                        Button {
                            onJump()
                        } label: {
                            Text("\(shortPath):\(concern.line ?? 0)")
                                .font(.caption.monospaced())
                        }
                        .buttonStyle(.link)
                        .help("변경 파일 탭에서 이 줄 아래에 펼쳐 봅니다")
                    }
                    // 수정은 코드 링크와 떨어진 맨 끝에 둔다. 인라인으로 옮긴 항목은 본문에 없어 옮긴 초안에서 고친다.
                    if onEditText != nil, movedTo == nil {
                        EditTextButton { isEditing = true }
                    }
                }
            }
            if let movedTo { MovedToInlineNote(place: movedTo) }
            if let note = concern.existingNote, !note.isEmpty {
                Label(note, systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDiscussion {
                RelatedDiscussionPanel(pr: pr, subject: .of(concern), onJump: onJump)
            }
            RecheckBox(pr: pr, record: record, subject: .of(concern),
                       kindLabel: "우려사항", severity: concern.severity.label)
            // 인라인으로 옮긴 것을 정리하면 "문제없다" 와 같은 자리의 지적이 같이 나간다. 정리는 옮긴 초안 쪽에서 한다.
            if movedTo == nil {
                ClearedControl(topic: ClearedTopic.of(concern), note: clearedNote, onChange: onCleared)
            }
        }
        .onAppear {
            if DebugLaunch.editText == ReviewItemKey.concern(concern), onEditText != nil { isEditing = true }
        }
    }

    /// 본문에 올라가는 부분(심각도·제목·이미 언급됨). 본문에 안 넣으면 이 줄만 흐리다.
    private var headline: some View {
        HStack(spacing: 6) {
            Tag(text: concern.severity.label, color: color)
            Text(editedText ?? concern.title)
                .font(.callout.weight(.medium))
                .strikethrough(clearedNote != nil, color: .secondary)
                .foregroundStyle(clearedNote != nil ? Color.secondary : Color.primary)
            if editedText != nil { EditedMark() }
            if concern.isDuplicate {
                DuplicateTagButton(isExpanded: showDiscussion) { showDiscussion.toggle() }
            }
        }
        .opacity(isInBody ? 1 : 0.55)
    }

    private var shortPath: String {
        (concern.path as NSString).lastPathComponent
    }

    private var color: Color {
        switch concern.severity {
        case .blocker: return .red
        case .major: return .orange
        case .minor: return .secondary
        case .nit: return .secondary
        }
    }
}

struct DraftCommentCard: View {
    @Environment(AppModel.self) private var model
    let state: DraftCommentState
    /// "이미 언급됨" 을 펼쳤을 때 관련 대화를 찾을 대상. 스레드 본문은 이미 여기 들어 있다.
    let pr: PullRequestInfo
    /// 언제 만든 리뷰인지 알아야 "그 뒤에 올라온 것" 을 셀 수 있다.
    let record: ReviewRecord
    /// 코멘트가 달릴 위치의 코드 조각. 어디에 붙는지 눈으로 확인할 수 있어야 한다.
    let snippet: [DiffLine]
    let readOnly: Bool
    /// 읽어 보고 "문제 아님" 으로 정리했다면 그 한 줄. 정리하면 인라인으로는 올리지 않는다.
    let clearedNote: String?
    let onCleared: (String?) -> Void
    let onToggle: (Bool) -> Void
    let onEdit: (String) -> Void
    let onJump: () -> Void
    let onJumpToEvidence: (CodeEvidence) -> Void
    /// 우려사항·질문을 옮겨 만든 초안이면 그 항목 이름("우려사항 2").
    var movedFromLabel: String? = nil
    var onUndoMove: (() -> Void)? = nil
    /// 지적 목록 안에 넣을 때는 올릴지 말지를 카드 위 "코드 옆에 달기 | 본문에 | 안 올림" 이 정한다 —
    /// 체크박스까지 있으면 같은 것을 두 군데서 고르게 된다.
    var showsToggle = true
    /// 지적 카드 안에 넣을 때. 머리 줄(자리·심각도)·근거·재확인·정리는 카드가 따로 가지므로 코드 조각과 글만 남긴다.
    var compact = false

    /// 관련 대화를 펼쳤는가. 이건 모델 데이터가 아니라 화면 상태라서 @State 가 맞다
    /// (아래 주석의 함정은 "모델 데이터를 @State 로 복사하는 것" 에 대한 것이다).
    @State private var showDiscussion = false

    /// @State 로 복사해 두면 "다시 리뷰" 로 같은 issue_key 의 새 초안이 와도 카드가 옛 본문을 보여준다
    /// (SwiftUI 가 뷰를 재사용해 onAppear 가 다시 불리지 않는다). prop 에 직접 바인딩한다.
    private var text: String { state.editedBody }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
            HStack(spacing: 6) {
                if showsToggle {
                    Toggle("", isOn: Binding(get: { state.include }, set: onToggle))
                        .labelsHidden()
                        .disabled(readOnly || state.anchorStatus == .unresolved)
                }
                Tag(text: state.comment.severity.label, color: severityColor)
                Button {
                    onJump()
                } label: {
                    Text("\(state.comment.path):\(state.comment.line)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                Tag(text: state.comment.side == .right ? "새 코드" : "삭제된 줄", color: .secondary)
                if state.comment.isDuplicate {
                    Button {
                        showDiscussion.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Text("이미 언급됨")
                            Image(systemName: showDiscussion ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.orange)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showDiscussion ? "오간 대화 접기" : "누가 무슨 말을 했는지 보기")
                }
                Spacer()
                Text("\(text.count)자")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(text.count > ReviewLimits.schemaMaxBodyChars ? .orange : .secondary)
            }
            }

            if let note = state.comment.existingNote, !note.isEmpty {
                Label(note, systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let movedFromLabel {
                HStack(spacing: 6) {
                    Label("리뷰 본문의 \(movedFromLabel)에서 이 줄로 옮긴 초안입니다", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(Color.purple)
                    if let onUndoMove, !readOnly {
                        Button("본문으로 되돌리기", action: onUndoMove)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if showDiscussion {
                RelatedDiscussionPanel(pr: pr, subject: .of(state.comment, body: text), onJump: onJump)
            }

            // 이 코멘트가 붙는 자리
            if !snippet.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snippet) { line in
                        let isTarget = state.comment.side == .right
                            ? line.newLine == state.comment.line
                            : line.oldLine == state.comment.line
                        HStack(spacing: 6) {
                            Text(lineNumber(line))
                                .font(model.fonts.code(size: max(9, model.settings.codeFontSize - 1)))
                                .foregroundStyle(.tertiary)
                                .frame(width: 34, alignment: .trailing)
                            Text((isTarget ? "▸" : " ") + prefix(line) + line.text)
                                .font(model.fonts.code())
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isTarget ? Color.orange.opacity(0.25) : Color.clear)
                    }
                }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
            }

            if state.anchorStatus != .ok {
                Label(state.anchorStatus == .fixed
                      ? "모델이 준 줄(\(state.originalLine ?? 0))이 어긋나 앵커 텍스트로 보정했습니다."
                      : "diff 에서 줄을 특정할 수 없어 인라인으로 게시되지 않습니다.",
                      systemImage: state.anchorStatus == .fixed ? "wand.and.stars" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(state.anchorStatus == .fixed ? Color.secondary : Color.orange)
            }

            if !compact {
                RationaleBox(title: "왜 이 코멘트인가",
                             rationale: state.comment.rationaleKo,
                             evidence: state.comment.evidence,
                             onJump: onJumpToEvidence)
            }

            // 정리한 코멘트는 올리지 않으므로 본문 편집기를 띄우지 않는다. 자리만 먹고
            // "고쳐서 올릴 수 있다" 는 오해를 준다.
            if clearedNote == nil {
                TextEditor(text: Binding(get: { state.editedBody }, set: onEdit))
                .font(.callout)
                .frame(minHeight: 68)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .disabled(readOnly)
            }

            if !compact {
                RecheckBox(pr: pr, record: record, subject: .of(state.comment, body: text),
                           kindLabel: "인라인 코멘트 초안", severity: state.comment.severity.label)
            }

            if !readOnly, !compact {
                ClearedControl(topic: ClearedTopic.of(state.comment),
                               note: clearedNote,
                               onChange: onCleared)
            }
        }
        .padding(8)
        .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
        // 정리한 것은 흐리게 하지 않는다 — 흐리면 "버린 것" 처럼 보이는데,
        // 실제로는 본문에 "확인했다" 로 남는 항목이다.
        .opacity(state.include || clearedNote != nil ? 1 : 0.55)
    }

    private func lineNumber(_ line: DiffLine) -> String {
        (state.comment.side == .right ? line.newLine : line.oldLine).map(String.init) ?? ""
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        default: return " "
        }
    }

    private var severityColor: Color {
        switch state.comment.severity {
        case .blocker: return .red
        case .major: return .orange
        case .minor, .nit: return .secondary
        }
    }
}

/// 게시를 마친 자리에 버튼 대신 두는 초록 결과(시안 A — 버튼이 상태를 말한다). 옆 버튼과 같은 높이로 그린다.
struct PostedStatusLabel: View {
    let text: String

    /// 흰 글자를 얹는 초록. 시스템 초록은 흰 글자와 대비가 2:1 남짓이라 한 단계 어둡게 쓴다.
    static let fill = Color(red: 0.12, green: 0.54, blue: 0.26)
    /// 바탕 위에 바로 쓰는 초록 글자. 밝은 바탕엔 위의 어두운 초록, 어두운 바탕엔 시스템 초록이라야 읽힌다.
    static let text = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.12, green: 0.54, blue: 0.26, alpha: 1)
    })

    var body: some View {
        Label(text, systemImage: "checkmark")
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Self.fill, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }

    /// 게시한 리뷰 종류를 문장 앞에 붙일 때. 버튼 이름("코멘트만")을 그대로 쓰면 "코멘트만 로" 가 되어 따로 둔다.
    static func postedAs(_ event: ReviewEvent) -> String {
        switch event {
        case .approve: return "Approve 로"
        case .comment: return "코멘트로"
        case .requestChanges: return "변경 요청으로"
        }
    }

    static func postedAs(_ rawEvent: String) -> String {
        ReviewEvent(rawValue: rawEvent).map { postedAs($0) } ?? "\(rawEvent) 로"
    }
}

/// 게시가 실패한 자리에 적는 글. 무엇이 안 됐는지 + 초안이 남아 있다는 것 — 다시 시도해도 되는지가 먼저 궁금하다.
enum PostFailureText {
    static func of(_ error: PostError) -> String {
        "\(error.localizedDescription) 초안은 그대로 있어요."
    }
}

/// 코드 코멘트 한 줄. GitHub 의 줄 코멘트 모양 — 파일 줄 → 코드 → 말풍선(아바타·아이디 + 달 글) → 달기 · 근거 보기.
///
/// "문제없음으로 정리" 는 뺐다(사용자 결정, 2026-10-20) — 달지 않을 것은 그냥 두면 된다. 예전에 정리해 둔 기록은
/// 가운데에 "정리했어요 · 되돌리기" 로 그대로 보인다.
///
/// 왼쪽 리뷰 게시와는 따로 간다 — "코드 옆에 코멘트 달기" 는 누르는 즉시 그 줄에 코멘트 하나를 단다(사용자 결정).
/// 달았거나 정리했으면 흐리게 잠그고 가운데에 결과를 띄운다.
struct IssueRow: View {
    let issue: ReviewIssue
    /// "경로:줄". 자리를 모르면 nil.
    let place: String?
    let snippet: [DiffLine]
    let targetLine: Int
    let side: DiffSide
    /// 달 글. 초안이 있으면 초안의 고친 글, 없으면 항목 글.
    let text: Binding<String>
    /// 처음 글에서 고쳤는가. 고쳤으면 "초기화" 가 뜬다.
    let isEdited: Bool
    let onReset: () -> Void
    let existingNote: String?
    let anchorNote: String?
    let posted: PostedComment?
    let clearedNote: String?
    /// 코드 옆에 달 수 없는 이유. 있으면 달기 버튼이 꺼진다.
    let codeBlockedReason: String?
    let rationale: String?
    let evidence: [CodeEvidence]?
    let isPosting: Bool
    let onPost: () -> Void
    let onUnclear: () -> Void
    let onJump: () -> Void
    let onJumpToEvidence: (CodeEvidence) -> Void
    /// 달기 버튼 옆 버튼(AI 리뷰 탭의 "코드에서 보기"). nil 이면 없다.
    var link: Link? = nil
    /// "리뷰에 담기" 상태. nil 이면 담을 수 없다(리뷰를 이미 올렸다) — 그때는 예전처럼 바로 달기만 있다.
    var basket: Basket? = nil
    /// false 면 달기 버튼을 두지 않는다 — 내 PR(게시하지 않음). 코드에서 보기·근거만 남는다.
    var allowsPosting = true

    struct Basket {
        /// 담겨 있는가.
        let isIn: Bool
        /// 담은 리뷰를 올리는 중인가. 그 사이 담고 빼면 이미 떠난 리뷰와 화면이 엇갈린다.
        let isPostingReview: Bool
        let onToggle: (Bool) -> Void
    }

    struct Link {
        let title: String
        let systemImage: String
        let help: String
        let action: () -> Void
    }

    @State private var showWhy = false

    private var isDone: Bool { posted != nil || clearedNote != nil }
    private var hasWhy: Bool { !(rationale ?? "").isEmpty || !(evidence ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            importanceStrip
            content
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 10)
        }
        .opacity(isDone ? 0.3 : 1)
        .disabled(isDone)
        .overlay { if isDone { doneBadge } }
    }

    /// 카드 머리 줄 — 담기 체크 · 중요도 칩 · 파일 이름:줄.
    ///
    /// 예전엔 중요도 색을 옅게 깐 띠에 "☐ 리뷰에 담기 · 권장 · 고치면 좋음 · 긴 경로" 를 다 적어 카드마다 같은 글이 되풀이됐다.
    /// 칸이 정신없다는 피드백에 따라 체크 글자·중요도 뜻·경로 앞부분은 마우스를 올렸을 때 보이게 하고, 색은 칩에만 남겼다
    /// (2026-10-27 사용자 결정, 시안 1번. 10-20 에 띠로 정하며 버렸던 칩을 되살린 것이다).
    private var importanceStrip: some View {
        let color = importanceColor(issue.importance)
        return HStack(spacing: 6) {
            basketCheckbox
            Text(issue.importance.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
                .help("\(issue.importance.label) · \(issue.importance.meaning) — \(issue.importance.help)")
            if let place {
                Button(action: onJump) {
                    Text(Self.shortPlace(place))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.link)
                .help("\(place) — 변경 파일 탭에서 이 줄을 봅니다")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Sources/Login/LoginView.swift:43" → "LoginView.swift:43". 같은 이름 파일이 여럿이면 마우스를 올려 전체 경로를 본다.
    static func shortPlace(_ place: String) -> String {
        guard let slash = place.lastIndex(of: "/") else { return place }
        return String(place[place.index(after: slash)...])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let existingNote, !existingNote.isEmpty {
                Label(existingNote, systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !snippet.isEmpty {
                // 코드를 누르면 변경 파일 탭에서 그 파일의 그 줄을 연다. 위 경로 링크보다 누를 자리가 넓다.
                Button(action: onJump) {
                    CodeSnippetView(lines: snippet, targetLine: targetLine, side: side)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("변경 파일 탭에서 이 파일의 이 줄을 엽니다")
            }
            if let anchorNote {
                Label(anchorNote, systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 카드마다 되풀이되던 내 아바타·아이디와 입력 칸 테두리는 뺐다 — 글만 둔다(2026-10-27 시안 3번).
            // 앞말 "(비블로커)" 는 중요도 칩과 뜻이 겹쳐 화면에서만 떼어 보인다(IssueCard 가 고칠 때 다시 붙인다).
            GrowingTextEditor(text: text, minHeight: 20, spareLineOnlyWhileEditing: true)
                .padding(.horizontal, -5)
            HStack(spacing: 8) {
                if allowsPosting {
                    postButtons
                }
                // 달기 바로 옆 — 달기 전에 그 줄을 다른 탭에서 확인하고 돌아오는 흐름이라(사용자 피드백).
                // AI 리뷰 탭은 "코드에서 보기". 변경 파일 탭은 없다 — 돌아가기는 상세 탭 줄의 돌아가기 버튼(DetailTabRow).
                // 글자 없이 아이콘만 둔다 — 카드마다 버튼 셋이 글자로 늘어서 칸이 붐볐다(2026-10-27 시안 4번). 이름은 마우스를 올리면.
                if let link {
                    Button(action: link.action) {
                        Image(systemName: link.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .help("\(link.title) — \(link.help)")
                    .accessibilityLabel(link.title)
                }
                if hasWhy {
                    Button {
                        showWhy.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("근거 보기 — AI 가 왜 이렇게 봤는지와 근거가 되는 코드 줄")
                    .accessibilityLabel("근거 보기")
                    .popover(isPresented: $showWhy, arrowEdge: .bottom) { whyPopover }
                }
                Spacer()
                if isEdited { ResetTextButton(action: onReset) }
            }
            .foregroundStyle(.secondary)
            if let codeBlockedReason {
                Text(codeBlockedReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 머리 줄 맨 앞 "☐ 리뷰에 담기". 체크하면 왼쪽 리뷰 본문의 "담은 줄 코멘트" 로 넘어가고, 거기서 체크를 끄면
    /// 오른쪽 제자리로 돌아온다 — 담기·빼기 두 버튼 대신 체크 하나로 오간다(사용자 요청, 2026-10-27). 변경 파일 탭은
    /// 왼쪽이 없어 카드가 그 자리에 남고 체크만 바뀐다.
    @ViewBuilder
    private var basketCheckbox: some View {
        if let basket {
            HStack(spacing: 4) {
                // 글자는 마우스를 올렸을 때 보인다. 카드마다 되풀이하지 않는다(시안 1번).
                Toggle(isOn: Binding(get: { basket.isIn }, set: { basket.onToggle($0) })) {
                    Text("리뷰에 담기")
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                // 빼는 것은 언제든(올리는 중만 빼고), 담는 것은 달 수 있는 코멘트일 때만.
                .disabled(basket.isPostingReview || (!basket.isIn && (codeBlockedReason != nil || isPosting)))
                .help(basket.isIn
                      ? "왼쪽 리뷰를 게시할 때 이 코멘트가 그 리뷰의 줄 코멘트로 함께 달립니다. 체크를 끄면 뺍니다."
                      : (codeBlockedReason ?? "왼쪽 리뷰를 게시할 때 본문·Approve 와 한 리뷰로 함께 답니다(작성자 알림 한 번)"))
                if basket.isIn && basket.isPostingReview {
                    ProgressView().controlSize(.mini)
                }
            }
            .fixedSize()
        }
    }

    /// 달기 버튼 — 이 코멘트 하나를 지금 그 줄에 단다. 담기는 머리 줄 맨 앞 체크다(basketCheckbox).
    /// 담겨 있으면 버튼 대신 함께 달린다는 말만 둔다. 담을 수 있을 때도 이름·파란 버튼은 담기 전과 같다(사용자 결정 10-27).
    @ViewBuilder
    private var postButtons: some View {
        if let basket, basket.isIn {
            Text(basket.isPostingReview ? "리뷰와 함께 올리는 중…" : "리뷰를 게시할 때 함께 달려요")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(action: onPost) {
                HStack(spacing: 4) {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "text.bubble")
                    }
                    // 아이콘 자리 빙글이만으로는 눌렸는지가 안 읽혔다. 하는 일을 글로 말한다(시안 A).
                    Text(isPosting ? "GitHub 에 다는 중…" : "코멘트 달기")
                }
            }
            // 파란 강조는 화면 위 게시 버튼 하나에만 둔다 — 카드마다 파란 버튼이 있어 칸이 붐볐다(2026-10-27 시안 4번).
            .buttonStyle(.bordered)
            .foregroundStyle(.primary)
            .controlSize(.small)
            .disabled(codeBlockedReason != nil || isPosting || basket?.isPostingReview == true)
            .help(codeBlockedReason ?? (basket == nil
                ? "누르면 확인 없이 바로 GitHub 의 그 줄에 이 코멘트를 답니다"
                : "리뷰에 담지 않고 이 코멘트 하나만 지금 바로 GitHub 의 그 줄에 답니다"))
        }
    }

    private var whyPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("근거")
                .font(.headline)
            if let rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((evidence ?? []).enumerated()), id: \.offset) { _, item in
                Button {
                    showWhy = false
                    onJumpToEvidence(item)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.line.map { "\(item.fileName):\($0)" } ?? item.fileName)
                            .font(.caption.monospaced())
                        if !item.note.isEmpty {
                            Text(item.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    /// 달았거나 정리한 줄 가운데에 띄우는 결과.
    @ViewBuilder
    private var doneBadge: some View {
        VStack(spacing: 6) {
            Label(posted != nil ? "코드 옆에 달렸어요" : "문제없음으로 정리했어요",
                  systemImage: posted != nil ? "checkmark.circle.fill" : "checkmark.seal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(posted != nil ? Color.green : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(posted != nil ? Color.green.opacity(0.5) : Color.secondary.opacity(0.4)))
            if let posted {
                Button("GitHub 에서 보기") { NSWorkspaceOpener.open(posted.htmlURL) }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Button("되돌리기", action: onUnclear)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// 버튼 옆 (i) — 호버하면 기능을 설명한다.
struct InfoHint: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { showing = $0 }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel("버튼 설명")
    }
}

/// 단계 진행 표시. 전체 리뷰는 워크트리 단계가 더 있고, PR 스냅샷을 처음 받는 잡은 클론 단계가 더 있다.
struct PhaseTrack: View {
    let current: ReviewPhase
    let deep: Bool
    var clonedSnapshot = false

    private var steps: [ReviewPhase] { Self.steps(deep: deep, clonedSnapshot: clonedSnapshot) }

    private var currentIndex: Int { Self.index(of: current, in: steps) }

    /// 이 잡이 거칠 단계. 진행 카드의 단계 목록(`PhaseChecklist`)도 같은 순서를 쓴다.
    static func steps(deep: Bool, clonedSnapshot: Bool) -> [ReviewPhase] {
        var result: [ReviewPhase] = [.checkingPR, .loadingDiff]
        if deep {
            if clonedSnapshot { result.append(.cloningSnapshot) }
            result += [.fetchingCommit, .fetchingFiles, .preparingWorktree]
        }
        result += [.running, .validating]
        return result
    }

    static func index(of current: ReviewPhase, in steps: [ReviewPhase]) -> Int {
        // 지금 단계가 목록에 없으면(반납·완료) 마지막으로 본다.
        steps.firstIndex(of: current) ?? (current.isTerminal || current == .releasingWorktree ? steps.count - 1 : 0)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Capsule()
                    .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 3)
                    .help(step.label)
            }
        }
        .frame(maxWidth: 260)
        .padding(.top, 2)
    }
}

/// 진행 카드의 단계 목록 — 끝난 단계는 ✓ 와 걸린 시간, 지금 단계는 지금까지 걸린 시간, 남은 단계는 이름만.
///
/// 점 막대(`PhaseTrack`)는 단계 이름이 마우스를 올려야 보여서, 오래 걸릴 때 무엇을 하는 중인지 알 수 없었다
/// (2026-10-27 사용자 요청, 시안 B4). 예상은 "Claude 가 읽고 판단" 에만 범위로 붙인다 — 다른 단계는 몇 초면 끝난다.
struct PhaseChecklist: View {
    let job: ReviewJob
    let now: Date

    var body: some View {
        let steps = PhaseTrack.steps(deep: job.deep, clonedSnapshot: job.clonedSnapshot)
        let current = PhaseTrack.index(of: job.phase, in: steps)
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                GridRow {
                    mark(index < current ? .done : index == current ? .current : .pending)
                    name(step, isCurrent: index == current, isPending: index > current)
                    time(step, index: index, current: current)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: 380, alignment: .leading)
        .padding(.top, 2)
    }

    private enum Mark { case done, current, pending }

    private func mark(_ mark: Mark) -> some View {
        Group {
            switch mark {
            case .done:
                Image(systemName: "checkmark").foregroundStyle(.green)
            case .current:
                Image(systemName: "circle.inset.filled").foregroundStyle(Color.accentColor)
            case .pending:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 12)
    }

    @ViewBuilder
    private func name(_ step: ReviewPhase, isCurrent: Bool, isPending: Bool) -> some View {
        HStack(spacing: 4) {
            Text(step.stepName(engine: job.engine))
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : isPending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            if step == .running, let range = job.claudeRange {
                Text("· \(ClaudeStepEstimate.text(range))")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("이 PR 크기(\(job.pr.additions + job.pr.deletions)줄)와 비슷한 지난 리뷰로 잡은 범위 — 10번 중 9번은 이 안에 끝났습니다")
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func time(_ step: ReviewPhase, index: Int, current: Int) -> some View {
        if index == current {
            Text(ClaudeStepEstimate.clock(max(0, now.timeIntervalSince(job.phaseAt))))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
        } else if index < current {
            // 건너뛴 단계(받을 것이 없던 단계)는 시간이 없다.
            Text(job.duration(of: step).map { ClaudeStepEstimate.clock($0.rounded()) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        } else {
            Text("")
        }
    }
}

/// 리뷰가 도는 동안 보여주는 진행 카드. 경과 시간이 1초마다 올라간다.
struct RunningReviewCard: View {
    @Environment(AppModel.self) private var model
    let job: ReviewJob
    let onCancel: () -> Void

    private var elapsed: TimeInterval {
        guard let startedAt = job.startedAt else { return 0 }
        // model.clockTick 이 1초마다 갱신돼 이 뷰가 다시 그려진다.
        return max(0, model.clockTick.timeIntervalSince(startedAt))
    }

    private var queuePosition: Int {
        let queued = model.jobs.filter { $0.state == .queued }
        return (queued.firstIndex { $0.id == job.id }.map { $0 + 1 }) ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                if job.state == .running {
                    HStack(spacing: 6) {
                        Text(job.progressTitle)
                            .font(.callout.weight(.medium))
                        Text(formatted(elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if job.deep {
                            Tag(text: "전체 리뷰", color: .purple)
                        }
                    }
                    if job.showsTransferProgress {
                        transferProgress
                    } else {
                        HStack(spacing: 4) {
                            // Claude 단계의 "보통 1~3분" 은 단계 목록의 예상 범위가 대신한다. 범위를 못 잡았을 때만 쓴다.
                            if let hint = job.phase.hint, job.phase != .running || job.claudeRange == nil {
                                Text(hint)
                            } else {
                                Text("\(job.engine.displayName) · 끝나면 알림이 옵니다")
                            }
                            Text("· 초안만 만드는 중이라 GitHub 에는 아무것도 올라가지 않습니다")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    // 어디까지 왔고 단계마다 얼마나 걸렸는지.
                    PhaseChecklist(job: job, now: model.clockTick)
                } else {
                    Text(queuePosition > 1 ? "대기 중 · 앞에 \(queuePosition - 1)건" : "대기 중")
                        .font(.callout.weight(.medium))
                    Text("리뷰는 한 번에 한 건씩 돕니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(job.cancelTitle, action: onCancel)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.3), lineWidth: 0.8))
    }

    /// 받기·풀기 진행 막대. 처음 클론하는 잡은 세 단계를 합친 전체 진행을, 그 밖에는 지금 단계의 진행을 채운다.
    /// git 이 아직 퍼센트를 안 찍었으면(서버가 목록을 세는 동안) 막대를 움직이는 모양으로 둔다.
    private var transferProgress: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let value = job.cloneFraction ?? job.progress?.fraction {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
            }
            HStack(spacing: 6) {
                Text(job.progressDetail ?? "서버에서 준비하는 중")
                    .monospacedDigit()
                if job.clonedSnapshot {
                    Text("· 처음 한 번만")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds < 60 ? "\(seconds)초" : "\(seconds / 60)분 \(seconds % 60)초"
    }
}

/// 중요도 색. 필수는 붉게(머지를 막는 이슈 안내 줄과 같은 색), 권장은 주황, 참고는 청록(2026-10-20 사용자 결정).
/// 카드 머리 띠는 이 색을 옅게(0.1) 깔고 이름 글자에 그대로 쓴다.
func importanceColor(_ importance: ReviewImportance) -> Color {
    switch importance {
    case .required: return .red
    case .recommended: return .orange
    case .informational: return .teal
    }
}

/// 내 PR 의 게시 버튼 자리 — "내 PR은 게시 안 함" 점선 칩(시안 B). 꺼진 버튼처럼 눌러 볼 것이 아니라
/// 왜 올리는 버튼이 없는지만 말한다. 내 PR 은 GitHub 이 Approve·변경 요청을 거부하고, 내 PR 리뷰는 스스로 확인하는 용도라
/// 코멘트도 올리지 않는다(사용자 결정, 2026-10-29).
struct OwnPRNoPostChip: View {
    var body: some View {
        Label("내 PR은 게시 안 함", systemImage: "lock")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .fixedSize()
            .help("내 PR이라 GitHub에 올리지 않습니다. 코멘트가 필요하면 GitHub에서 직접 남기세요.")
    }
}
