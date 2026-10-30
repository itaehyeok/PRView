import AppKit
import PRayerCore

/// 슬랙 리뷰 요청 창에 넘기는 것 — 어느 PR 들을 요청하나.
struct SlackRequestDraft: Identifiable {
    let id = UUID()
    var prs: [PullRequestInfo]
    /// 연동 실패 화면 시험(DEBUG `PRAYER_DEBUG_SLACK_FAIL`) — 이 실패로 연 것처럼 보인다(다시 확인부터는 진짜로 묻는다).
    var simulatedFailure: SlackConnectorError? = nil
}

/// 내 채널을 받는 동안의 상태 — 두 갈래 중 무엇이 끝났나.
struct SlackChannelsLoading: Equatable {
    var postedDone = false
    var memberDone = false
}

/// 슬랙 리뷰 요청 — 내 PR 을 골라(여러 개도) 우클릭 → 슬랙 채널에 리뷰를 부탁하는 글을 보낸다.
///
/// 보내기는 claude.ai Slack 커넥터가 한다(`SlackConnector`). 앱은 글을 만들어 보여 주고, 사용자가 "보내기" 를
/// 누른 그 글만 보낸다 — 자동으로 보내는 길은 없다.
extension AppModel {
    var slackConnector: SlackConnector { SlackConnector(claudePath: settings.claudePath) }

    // MARK: - 내 PR 여러 개 고르기

    /// "내가 올린 PR" 행 클릭. ⌘ 는 하나씩 더하고 빼고, ⇧ 는 시작점부터 범위로 — Finder·메일과 같다(RowSelection).
    func clickMyPR(_ pr: PullRequestInfo, in list: [PullRequestInfo]) {
        click(pr, in: list, selection: \.myPRSelection)
    }

    /// 같이 고른 것으로 보이는가(둘 이상 골랐을 때만).
    func isInMyPRSelection(_ pr: PullRequestInfo) -> Bool {
        myPRSelection.isMarked(pr.id)
    }

    /// 우클릭한 PR 로 요청할 PR 들. 같이 고른 것 안에서 눌렀으면 고른 것 전부, 밖이면 그것 하나 — Finder 와 같은 규칙.
    /// 순서는 목록 순서(최근 올린 것이 위)를 따른다.
    func slackTargets(for pr: PullRequestInfo) -> [PullRequestInfo] {
        let mine = myOpenPRs
        let ids = Set(myPRSelection.targets(for: pr.id, in: mine.map(\.id)))
        let chosen = mine.filter { ids.contains($0.id) }
        return chosen.isEmpty ? [pr] : chosen
    }

    func requestSlackReview(for pr: PullRequestInfo) {
        slackRequest = SlackRequestDraft(prs: slackTargets(for: pr))
    }

    /// Approve 가 모자란 내 PR — "내가 올린 PR" 머리글의 "Approve 모자란 N건 요청 글 만들기…" 가 한꺼번에 담는다.
    /// 셈은 행의 2/3 과 같다(그 PR 이 향하는 브랜치의 규칙). Draft 는 아직 리뷰받을 때가 아니라 뺀다.
    /// 목록 순서(최근 올린 것이 위)를 따르고, 검색어·레포 고르기로 좁혀 둔 그대로다(보이는 것만 담는다).
    var myPRsNeedingApproval: [PullRequestInfo] {
        myOpenPRs.filter { !$0.isDraft && $0.approvalCount < settings.approvalThreshold(for: $0) }
    }

    func requestSlackReviewForUnderApproved() {
        let prs = myPRsNeedingApproval
        guard !prs.isEmpty else { return }
        slackRequest = SlackRequestDraft(prs: prs)
    }

    // MARK: - 글

    func slackItems(_ prs: [PullRequestInfo]) -> [SlackPRItem] {
        prs.map { SlackPRItem(pr: $0, host: settings.githubHost) }
    }

    /// 요청 창 미리보기에 쓸 PR — 고른 PR 이 없으면(연동 실패 화면 시험) 내 PR 앞의 둘, 그것도 없으면 가짜 PR.
    func slackPreviewItems(_ prs: [PullRequestInfo]) -> [SlackPRItem] {
        if !prs.isEmpty { return slackItems(prs) }
        let mine = Array(myOpenPRs.prefix(2))
        return mine.isEmpty ? SlackTemplate.sampleItems : slackItems(mine)
    }

    /// 슬랙 설정을 고치고 저장한다.
    func updateSlack(_ change: (inout SlackSettings) -> Void) {
        change(&settings.slack)
        Task { await save() }
    }

    /// 이 PR 들 중 전에 요청한 것 — 보내기 창이 "어제 #채널 에 요청함" 을 보여 준다.
    func previousSlackRequests(_ prs: [PullRequestInfo]) -> [(pr: PullRequestInfo, entry: SlackRequestEntry)] {
        prs.compactMap { pr in slackRequests[pr.id].map { (pr, $0) } }
    }

    /// 내 채널을 받는다 — 글을 쓴 채널과 들어가 있는 채널을 따로 받아, 먼저 끝난 것부터 목록에 넣는다
    /// (`SlackConnector.postedChannels`·`memberChannels`). 받은 목록은 설정에 저장해 다음에는 바로 보인다.
    func loadMySlackChannels() {
        guard !DemoMode.isOn else { return }
        guard slackChannelsLoading == nil, let me = settings.slack.me else { return }
        slackChannelsLoading = SlackChannelsLoading()
        slackChannelsError = nil
        let connector = slackConnector
        Task {
            var posted: [SlackDestination]?
            var member: [SlackDestination]?
            var lastError: Error?
            var failedParts: [String] = []
            await withTaskGroup(of: (Bool, Result<[SlackDestination], Error>).self) { group in
                group.addTask {
                    do { return (true, .success(try await connector.postedChannels(me: me))) } catch { return (true, .failure(error)) }
                }
                group.addTask {
                    do { return (false, .success(try await connector.memberChannels())) } catch { return (false, .failure(error)) }
                }
                for await (isPosted, result) in group {
                    switch result {
                    case .success(let list):
                        if isPosted { posted = list } else { member = list }
                    case .failure(let error):
                        lastError = error
                        let part = isPosted ? "글을 쓴 채널" : "들어가 있는 채널"
                        failedParts.append(part)
                        ProblemLog.shared.record(.other, detail: "슬랙 내 채널(\(part)) 받기 실패: \(SlackErrorView.wrap(error).localizedDescription)")
                    }
                    if isPosted { slackChannelsLoading?.postedDone = true } else { slackChannelsLoading?.memberDone = true }
                    let merged = SlackSettings.mergedChannels(posted: posted ?? [], member: member ?? [])
                    if !merged.isEmpty { updateSlack { $0.myChannels = merged } }
                }
            }
            if posted == nil, member == nil {
                slackChannelsError = lastError.map(SlackErrorView.wrap) ?? .unreadable("채널을 받지 못했습니다.")
            } else {
                updateSlack { $0.myChannelsFetchedAt = Date() }
                // 한쪽만 실패했으면 받은 만큼 보이되, 빠진 것이 있다는 사실은 말한다 — 안 그러면 목록이 다인 줄 안다.
                if let failed = failedParts.first, let lastError {
                    slackChannelsError = .partial("\(failed)는 받지 못했습니다 — \(SlackErrorView.wrap(lastError).localizedDescription)")
                }
            }
            slackChannelsLoading = nil
        }
    }

    /// 보낸 것을 남긴다. 나에게 보낸 시험은 남기지 않는다 — 요청한 적 없는데 "요청함" 이 뜨면 헷갈린다.
    func recordSlackRequest(_ prs: [PullRequestInfo], destination: SlackDestination, link: String?) {
        guard destination.kind != .me else { return }
        let entry = SlackRequestEntry(sentAt: Date(), destination: destination, link: link)
        for pr in prs { slackRequests[pr.id] = entry }
        let snapshot = slackRequests
        Task { await store.save(slackRequests: snapshot) }
    }
}
