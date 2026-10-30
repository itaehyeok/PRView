import SwiftUI
import PRayerCore

/// 코드 코멘트 카드 하나 — AI 리뷰 탭 오른쪽과 변경 파일 탭(그 줄 바로 아래)이 **같은 카드**를 쓴다.
///
/// 예전에는 변경 파일 탭에 주황 초안 칸과 보라 우려사항 칸이 따로 있고 버튼도 달라서, 같은 사안이 두 모양으로
/// 보였다(사용자 피드백). 어차피 둘 다 코드 옆에 다는 것이라 한 카드로 합쳤다. 기록·고친 글·다는 중 상태는
/// 모두 AppModel 에서 읽어, 한 탭에서 고치거나 달면 다른 탭에도 그대로 보인다.
struct IssueCard: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let issue: ReviewIssue
    /// 파일 경로·코드 조각·"코드에서 보기" 를 보일지. 변경 파일 탭은 그 줄 바로 아래라 뺀다.
    var showsLocation = true
    var onJump: () -> Void = {}
    var onJumpToEvidence: (CodeEvidence) -> Void = { _ in }
    /// 담기·빼기를 부르는 쪽이 맡는다(AI 리뷰 탭은 넘어가는 애니메이션과 같이). nil 이면 바로 담고 뺀다.
    var onBasket: ((Bool) -> Void)? = nil

    /// 초안 없는 지적의 고친 글·다는 중 표시의 키.
    private var bodyKey: String { "\(pr.id)|\(issue.key)" }

    var body: some View {
        if let record = model.record(for: pr) {
            row(record)
        }
    }

    private func row(_ record: ReviewRecord) -> some View {
        let draftIndex = record.draftIndex(for: issue)
        let draft = draftIndex.map { record.comments[$0] }
        let question = issue.kind == .question
            ? (record.output.questionsForAuthor ?? []).first { ReviewItemKey.question($0) == issue.key }
            : nil
        let diff = model.parsedDiff(for: pr)
        return IssueRow(issue: issue,
                        place: showsLocation
                            ? (draft.map { "\($0.comment.path):\($0.comment.line)" } ?? issue.path.map { "\($0):\(issue.line ?? 0)" })
                            : nil,
                        snippet: showsLocation ? snippet(draft: draft, diff: diff) : [],
                        targetLine: draft?.comment.line ?? issue.line ?? 0,
                        side: draft?.comment.side ?? issue.side,
                        // 앞말 "(비블로커)" 는 중요도 칩과 뜻이 겹쳐 칸에서는 떼어 보이고, 고치면 다시 붙여 둔다 — 올라가는 글은 그대로다.
                        text: Binding(get: { ReviewFormatGuard.withoutNonBlockerPrefix(model.issueText(pr: pr, issue: issue)) },
                                      set: { edited in
                                          let stored = model.issueText(pr: pr, issue: issue)
                                          model.setIssueText(ReviewFormatGuard.restoringNonBlockerPrefix(edited, from: stored),
                                                             pr: pr, issue: issue)
                                      }),
                        isEdited: draft.map { $0.editedBody != $0.comment.body }
                            ?? (model.issueBodies[bodyKey].map { $0 != issue.title } ?? false),
                        onReset: {
                            if let draft {
                                change { record in
                                    guard let at = record.comments.firstIndex(where: { $0.id == draft.id }) else { return }
                                    record.comments[at].editedBody = record.comments[at].comment.body
                                }
                            } else {
                                model.issueBodies[bodyKey] = nil
                            }
                        },
                        existingNote: draft?.comment.existingNote ?? question?.existingNote,
                        anchorNote: draft?.anchorStatus == .fixed
                            ? "모델이 준 줄(\(draft?.originalLine ?? 0))이 어긋나 앵커 텍스트로 보정했습니다." : nil,
                        posted: record.postedComment(for: issue),
                        clearedNote: record.clearedNote(for: issue.key),
                        codeBlockedReason: record.codeBlockedReason(for: issue, diff: diff),
                        rationale: draft?.comment.rationaleKo ?? question?.rationaleKo,
                        evidence: draft?.comment.evidence ?? question?.evidence,
                        isPosting: model.postingIssueKeys.contains(bodyKey),
                        onPost: { post() },
                        onUnclear: { change { $0.setCleared(nil, for: issue.key) } },
                        onJump: onJump,
                        onJumpToEvidence: onJumpToEvidence,
                        link: link,
                        basket: basket(record),
                        allowsPosting: !pr.viewerDidAuthor)
    }

    /// "리뷰에 담기" 상태. 리뷰를 이미 올렸으면 더 실을 리뷰가 없어 바로 달기만 남긴다.
    private func basket(_ record: ReviewRecord) -> IssueRow.Basket? {
        // 내 PR 은 게시하지 않아 담을 리뷰가 없다(시안 B).
        guard !record.isPosted, !pr.viewerDidAuthor else { return nil }
        let pr = pr
        let issue = issue
        return IssueRow.Basket(isIn: record.isInBasket(issue),
                               isPostingReview: model.postingKeys.contains(PostingKey.review(pr)),
                               onToggle: onBasket ?? { isOn in model.setInBasket(isOn, issue: issue, pr: pr) })
    }

    /// 달기 버튼 옆 "코드에서 보기" — AI 리뷰 탭에만 있다. 변경 파일 탭에서 돌아가는 길은 카드마다 두지 않고
    /// 상세 탭 줄의 돌아가기 버튼(DetailTabRow) 하나로 모았다(사용자 결정, 2026-10-23).
    private var link: IssueRow.Link? {
        guard showsLocation else { return nil }
        return IssueRow.Link(title: "코드에서 보기", systemImage: "arrow.up.right.square",
                             help: "변경 파일 탭에서 이 파일의 이 줄을 엽니다", action: onJump)
    }

    /// 그 줄 앞뒤 한 줄씩. 초안이 있으면 초안 자리, 없으면 지적의 자리. 두 줄씩 다섯 줄이던 것을 줄였다 —
    /// 더 보려면 코드를 눌러 변경 파일 탭으로 간다(2026-10-27 시안 2번).
    private func snippet(draft: DraftCommentState?, diff: ParsedDiff?) -> [DiffLine] {
        let path = draft?.comment.path ?? issue.path
        let line = draft?.comment.line ?? issue.line
        guard let path, let line, let file = diff?.file(matching: path) else { return [] }
        return file.snippet(around: line, side: draft?.comment.side ?? issue.side, context: 1)
    }

    private func change(_ edit: (inout ReviewRecord) -> Void) {
        guard var record = model.record(for: pr) else { return }
        edit(&record)
        model.update(record: record)
    }

    /// 바로 단다. 확인 창은 없다 — 버튼 이름("코드 옆에 코멘트 달기")이 곧 하는 일이다.
    private func post() {
        let key = bodyKey
        model.postingIssueKeys.insert(key)
        let body = model.issueBodies[key]
        Task {
            let result = await model.postInline(pr: pr, issue: issue, body: body)
            model.postingIssueKeys.remove(key)
            guard case .failure(let error) = result else { return }
            // 연결이 끊긴 것처럼 다시 누르면 되는 실패만 "다시 시도" 를 단다.
            var retry: (@MainActor () -> Void)?
            if error.isTransient { retry = { post() } }
            model.banner = Banner(kind: error.isTransient ? .warning : .error,
                                  message: error.localizedDescription,
                                  actionTitle: error.isTransient ? "다시 시도" : nil,
                                  action: retry)
        }
    }
}
