import Foundation
import PRayerCore

/// 목록 활동 줄의 @me 가 가리키는 곳 — 어느 PR 의 어느 대화 줄(`PRTimelineEntry.id`).
struct MentionJump: Equatable {
    let prID: String
    let entryID: String
}

/// 나를 부른 글(MyMentions)로 옮겨 가기.
extension AppModel {
    /// 목록 활동 줄의 @me 를 눌렀다 — 행을 누른 것처럼 고르고(`select`), 그 PR 로 옮겨 갔으면 개요 탭을 열어 그 글로 간다
    /// (답글 칩의 `openReplies` 와 같은 순서). 다른 탭을 보고 있었어도 개요 탭으로 바꾼다 — 글은 개요 탭에만 있다.
    /// ⌘ 클릭처럼 그 PR 로 안 옮겨 갔으면 아무 데도 가지 않는다(남겨 두면 나중에 그 PR 을 열 때 뜬금없이 스크롤한다).
    func openMention(of pr: PullRequestInfo, entryID: String, select: () -> Void) {
        select()
        guard selectedPRID == pr.id else { return }
        detailTab = .overview
        mentionJump = MentionJump(prID: pr.id, entryID: entryID)
        recordUsage(.mentionJump)
    }
}
