import SwiftUI
import PRayerCore

/// 리뷰 대기 목록 **맨 위**에 따로 묶는 "내가 올린 PR".
///
/// 별도 탭으로 만들지 않은 이유: "내 PR 누가 승인했나" 는 찾아가서 들여다보는 질문이 아니라
/// 지나가다 흘깃 보는 질문이다. 탭이면 일부러 눌러야 알 수 있고, 그러면 안 누르게 된다.
/// 아침에 리뷰하러 목록을 여는 그 자리에 있어야 눈에 들어온다.
///
/// 이 그룹은 **라벨·사람 필터를 받지 않는다**(검색어·레포 고르기만 받는다 — AppModel.myOpenPRs 주석 참고). 배경을 옅게 깔되
/// 색만으로 구분하지 않는다 — 행 배경은 이미 선택 상태가 쓰고 있어서, 색에 뜻을 더 얹으면
/// 무엇을 말하는 색인지 흐려진다. 머리글이 경계를 말하고 배경은 거들기만 한다.
struct MyPRSection: View {
    @Environment(AppModel.self) private var model

    /// 접어 둔 것은 다음에 켤 때도 접혀 있어야 한다 — 매번 다시 접게 하면 안 접는다.
    @AppStorage(Self.collapsedKey) private var isCollapsed = false
    static let collapsedKey = "myPRGroupCollapsed"
    /// 몇 건이 넘으면 접어 두는가. 이보다 많으면 리뷰 목록이 화면 밖으로 밀린다.
    private static let compactLimit = 3
    /// 행을 눌렀을 때 — 목록이 방향키를 받게 한다(PRListView).
    var onRowTap: () -> Void = {}

    /// 지금 보이는 행. 목록의 방향키 이동도 이 순서를 따라야 접힌 행으로 건너가지 않는다.
    static func shown(_ mine: [PullRequestInfo], collapsed: Bool, showsAll: Bool) -> [PullRequestInfo] {
        collapsed ? [] : (showsAll ? mine : Array(mine.prefix(compactLimit)))
    }

    var body: some View {
        let mine = model.myOpenPRs
        if !mine.isEmpty {
            let showsAll = model.myPRShowsAll
            let shown = Self.shown(mine, collapsed: isCollapsed, showsAll: showsAll)
            VStack(alignment: .leading, spacing: 2) {
                header(count: mine.count)
                ForEach(shown) { pr in
                    let isMarked = pr.id == model.selectedPRID || model.isInMyPRSelection(pr)
                    // 아래 리뷰 목록과 **같은 방식**으로 고른 표시를 낸다. 여기만 표시가 없으면
                    // 눌러서 오른쪽이 바뀌어도 "내가 이걸 고른 게 맞나" 를 알 수 없다(실측).
                    MyPRRow(pr: pr)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectionBackground(pr))
                        .overlay(alignment: .leading) {
                            if isMarked {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.accentColor)
                                    .frame(width: 3)
                                    .padding(.vertical, 4)
                            }
                        }
                        .contentShape(Rectangle())
                        // ⌘·⇧ 클릭으로 여러 개를 고른다 — 같이 고른 것을 우클릭해 슬랙에 한 번에 요청한다.
                        .onTapGesture {
                            onRowTap()
                            model.clickMyPR(pr, in: shown)
                        }
                        .contextMenu { menu(for: pr) }
                        .padding(.horizontal, 6)
                        .listRowTransition()
                        .id(pr.id)
                }
                if !isCollapsed, mine.count > Self.compactLimit {
                    Button(showsAll ? "접기" : "더 보기 (\(mine.count - Self.compactLimit))") {
                        model.myPRShowsAll.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06))
            Divider()
        }
    }

    /// 우클릭 메뉴. 같이 고른 것 안에서 누르면 고른 것 전부를, 밖이면 그 PR 하나를 요청한다(`AppModel.slackTargets`).
    @ViewBuilder
    private func menu(for pr: PullRequestInfo) -> some View {
        let targets = model.slackTargets(for: pr)
        // "슬랙에 리뷰 요청" 은 누르면 바로 보내지는 것처럼 읽혔다(사용자 피드백). 누르면 글을 만들어 보여 줄 뿐이고
        // 보내기는 그 창에서 따로 누른다 — 이름이 그 순서를 말하게 한다.
        Button(targets.count > 1 ? "슬랙 리뷰 요청 글 만들기 (\(targets.count)건)…" : "슬랙 리뷰 요청 글 만들기…") {
            model.requestSlackReview(for: pr)
        }
        // 전에 보낸 적이 있으면 메뉴에서 바로 보인다 — 또 보낼지 여기서 판단한다.
        if targets.count == 1, let entry = model.slackRequests[pr.id] {
            Text("마지막 요청: \(SlackAgo.text(entry.sentAt)) · \(entry.destination.label)")
        }
        Divider()
        Button {
            if let url = pr.htmlURL(host: model.settings.githubHost) { NSWorkspace.shared.open(url) }
        } label: {
            Label { Text(GitHubLink.title) } icon: { Image("GitHubMark") }
        }
    }

    /// 이 그룹은 이미 옅은 배경 위에 있다. 아래 목록과 같은 불투명도를 쓰면 묻히므로
    /// 조금 더 진하게 깔고 테두리로 경계를 준다.
    private func selectionBackground(_ pr: PullRequestInfo) -> some View {
        let isSelected = pr.id == model.selectedPRID || model.isInMyPRSelection(pr)
        return RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            }
    }

    /// 머리글 — 접기 · 건수 · 안내, 오른쪽 끝에 캡슐 단추 "Slack으로 리뷰 요청하기 (N)".
    /// 목록 폭(최소 320pt)이 좁으면 안내 → 단추 글 순으로 줄인다. 안내를 잘린 채로 두면 아무것도 말하지 못한다.
    private func header(count: Int) -> some View {
        let needing = model.myPRsNeedingApproval
        return ViewThatFits(in: .horizontal) {
            headerRow(count: count, needing: needing, showsHint: true, button: .full)
            headerRow(count: count, needing: needing, showsHint: false, button: .full)
            headerRow(count: count, needing: needing, showsHint: false, button: .short)
            headerRow(count: count, needing: needing, showsHint: false, button: .icon)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
    }

    private enum RequestButtonStyle { case full, short, icon }

    private func headerRow(count: Int, needing: [PullRequestInfo], showsHint: Bool,
                           button: RequestButtonStyle) -> some View {
        HStack(spacing: 6) {
            Button { isCollapsed.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("내가 올린 PR \(count)건")
                        .font(.caption.weight(.semibold))
                    if showsHint { hint }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "내가 올린 PR 펴기" : "내가 올린 PR 접기")
            if !needing.isEmpty {
                requestButton(needing, style: button)
            }
        }
        .lineLimit(1)
    }

    /// 이 그룹만 필터를 안 받는다는 사실을 화면이 직접 말해야 한다.
    /// 안 그러면 "필터를 켰는데 왜 얘네는 남아 있지" 가 된다.
    /// 레포 고르기는 받으므로 "필터와 무관" 이라고만 쓰면 틀린 말이 된다.
    /// 여러 개를 골랐으면 그 사실과 할 수 있는 일을 머리글이 말한다 — 우클릭 메뉴는 눈에 안 보인다.
    @ViewBuilder
    private var hint: some View {
        if model.myPRSelection.isMultiple {
            Text("\(model.myPRSelection.ids.count)건 고름 · 우클릭 → 슬랙 리뷰 요청 글 만들기")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        } else {
            Text("라벨·사람 필터와 무관")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Approve 가 모자란 내 PR 을 한꺼번에 담아 리뷰 요청 글 창을 연다. 바로 보내지 않는다(창에서 미리보기를 보고 보낸다).
    ///
    /// 모양은 캡슐 단추 + 건수 배지(2026-10-20 사용자가 시안 A-2 를 골랐다). 예전 "Approve 모자란 N건 요청 글 만들기…"
    /// 링크 글자는 길고 단추로 안 보였다(사용자: "모양도 이름도 별로"). 무엇을 담는지(Approve 모자란 것만, Draft 빼고)는
    /// 마우스를 올리면 말한다.
    private func requestButton(_ prs: [PullRequestInfo], style: RequestButtonStyle) -> some View {
        Button {
            model.requestSlackReviewForUnderApproved()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperplane")
                switch style {
                case .full: Text("Slack으로 리뷰 요청하기")
                case .short: Text("리뷰 요청")
                case .icon: EmptyView()
                }
                Text(verbatim: "\(prs.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.accentColor))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.leading, style == .icon ? 6 : 8)
            .padding(.trailing, 3)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Approve 가 모자란 내 PR \(prs.count)건(Draft 빼고)으로 슬랙 리뷰 요청 글을 만듭니다 — 미리보기를 보고 보냅니다.\n"
              + prs.map { "#\($0.number) \($0.approvalCount)/\(model.settings.approvalThreshold(for: $0))" }.joined(separator: " · "))
    }
}

/// 내 PR 한 줄. 리뷰용 행과 **말해야 하는 것이 다르다** —
/// 내가 무엇을 했나(Approved)가 아니라, **몇 명이 봤고 누가 안 봤나**가 중요하다.
private struct MyPRRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    private var threshold: Int { model.settings.approvalThreshold(for: pr) }

    var body: some View {
        let summary = MyPRReviewSummary(pr: pr)
        HStack(alignment: .top, spacing: 8) {
            ApprovalPill(count: pr.approvalCount,
                         threshold: threshold,
                         changesRequested: pr.reviewDecision == "CHANGES_REQUESTED")
                .help(pillHelp(summary))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    // 리뷰 행 제목과 같은 크기(PRRow 주석 참고).
                    Text(pr.title)
                        .font(model.fonts.ui(delta: -1))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // "Created 19h ago" 는 제목 자리를 먹는다 — 이 그룹은 다 내가 올린 것이라 "올린 시각" 이란 걸
                    // 따로 말하지 않아도 된다. 날짜는 마우스를 올리면 나온다.
                    RelativeTimeText(date: pr.createdAt)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("올림 \(pr.createdAt.formatted(date: .abbreviated, time: .shortened))")
                }
                // 둘째 줄은 요약 한 줄 — 누가 승인했나 · 코멘트 몇 개 · 안 풀린 것.
                // 사람마다 한 줄씩 늘어놓는 목록은 만들어 보고 뺐다(사용자: "원래처럼 간단하게").
                // 넘치면 자르지 않고 조각째 아랫줄로 내린다 — 잘린 조각은 아무것도 말하지 못한다.
                FlowRow(spacing: 8) {
                    if pr.isDraft { Tag(text: "Draft", color: .secondary) }
                    if pr.mergeable == .conflicting { Tag(text: "Conflict", color: .red) }
                    if case let outcome = pr.checkOutcome, outcome.isProblem {
                        Label(outcome.isCancelledOnly ? "CI 취소" : "CI 실패",
                              systemImage: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(outcome.isCancelledOnly ? Color.orange : Color.red)
                            .help(outcome.detail ?? "")
                    }
                    summaryPieces(summary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    /// 0 인 조각은 내지 않는다. 승인한 사람만 이름으로 부른다(보통 2~3명).
    ///
    /// "미응답 N" 은 뺐다. 리뷰 요청은 CODEOWNERS 가 팀 전체에 자동으로 걸어서
    /// "아직 안 본 팀원 전부" 일 뿐이고, 몇 명 더 필요한지는 2/3 이 말한다.
    /// 남은 사람 이름은 2/3 에 마우스를 올리면 나온다(pillHelp).
    @ViewBuilder
    private func summaryPieces(_ summary: MyPRReviewSummary) -> some View {
        if !summary.approvers.isEmpty {
            piece(symbol: "checkmark.circle.fill", tint: .green, text: approverText(summary.approvers))
                .help(approverHelp(summary.approvers))
        }
        if !summary.changesRequestedBy.isEmpty {
            piece(symbol: "exclamationmark.triangle.fill", tint: .orange,
                  text: Text(names(summary.changesRequestedBy)).foregroundStyle(.secondary))
                .help("변경 요청 — " + summary.changesRequestedBy.joined(separator: ", "))
        }
        if summary.commentCount > 0 {
            piece(symbol: "text.bubble", tint: .secondary,
                  text: Text(verbatim: "\(summary.commentCount)").foregroundStyle(.secondary))
                .help("다른 사람이 남긴 코멘트 \(summary.commentCount)개")
        }
        if summary.unresolvedThreadCount > 0 {
            piece(symbol: "exclamationmark.bubble", tint: .orange,
                  text: Text("미해결 \(summary.unresolvedThreadCount)").foregroundStyle(.orange))
                .help("아직 안 풀린 코드 코멘트 스레드 \(summary.unresolvedThreadCount)개")
        }
        if summary.approvers.isEmpty, summary.changesRequestedBy.isEmpty,
           summary.commentCount == 0, summary.unresolvedThreadCount == 0 {
            Text("리뷰 기다리는 중")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func pillHelp(_ summary: MyPRReviewSummary) -> String {
        let count = pr.approvalCount
        var help = "Approve \(count)/\(threshold)"
        if count < threshold { help += " — \(threshold - count)명 더 필요" }
        if !summary.pending.isEmpty {
            let names = summary.pending.map { model.settings.displayName($0) }.joined(separator: " · ")
            help += "\n리뷰 요청이 남은 사람 \(summary.pending.count)명: \(names)"
        }
        return help
    }

    private func piece(symbol: String, tint: Color, text: Text) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            text
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
    }

    /// 승인한 사람 이름. 마지막 푸시 전에 한 승인은 흐리게 — 승인 수에는 들지만 지금 코드를 본 건 아니다.
    private func approverText(_ approvers: [MyPRReviewSummary.Approver]) -> Text {
        let limit = 3
        var text = Text(verbatim: "")
        for (index, approver) in approvers.prefix(limit).enumerated() {
            let name = Text(verbatim: model.settings.displayName(approver.login))
                .foregroundStyle(approver.isStale ? .tertiary : .secondary)
            text = index == 0 ? name : Text("\(text)\(Text(verbatim: " · ").foregroundStyle(.tertiary))\(name)")
        }
        if approvers.count > limit {
            text = Text("\(text)\(Text(" 외 \(approvers.count - limit)").foregroundStyle(.tertiary))")
        }
        return text
    }

    private func approverHelp(_ approvers: [MyPRReviewSummary.Approver]) -> String {
        let stale = approvers.filter(\.isStale).map(\.login)
        var help = "Approve — " + approvers.map(\.login).joined(separator: ", ")
        if !stale.isEmpty {
            help += "\n흐린 이름은 마지막 푸시 전에 한 승인: " + stale.joined(separator: ", ")
        }
        return help
    }

    private func names(_ logins: [String]) -> String {
        let shown = logins.prefix(3).map { model.settings.displayName($0) }.joined(separator: " · ")
        return logins.count > 3 ? "\(shown) 외 \(logins.count - 3)" : shown
    }
}
