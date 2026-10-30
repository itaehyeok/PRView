import Foundation
import PRayerCore

/// "이미 언급됨" 뒤의 대화 중 무엇이 정말 이어지는지 AI 에게 물어보는 경로.
///
/// 낱말 겹침으로만 고르면 놓치고 헛짚기 때문에(실측: 초안은 `.sink` 미저장, 스레드는 z-순서 —
/// 낱말은 하나도 겹치지 않는다) 후보만 코드로 모으고 판단은 모델에게 맡긴다.
/// 사용자가 누를 때만 돌고, 결과는 저장해 두어 다시 열면 즉시 보인다.
extension AppModel {
    func relevance(for key: String) -> DiscussionRelevance? { relevances[key] }
    func isMatchingRelevance(_ key: String) -> Bool { relevanceKeys.contains(key) }

    var relevanceTokensUsed: Int {
        ledger.tokens(ofKind: .relevance, inLast: TokenLedger.fiveHours)
    }

    /// 이 항목에 대한 대조 결과를 가리키는 키. 커밋이 바뀌면 다시 판단해야 하므로 head 를 넣는다.
    /// 항목 종류까지 이름에 들어 있어(`draft:` / `concern:` / `question:`) 같은 issue_key 를
    /// 쓰는 초안과 우려사항이 서로의 결과를 덮어쓰지 않는다.
    func relevanceKey(pr: PullRequestInfo, subject: DiscussionSubject) -> String {
        "\(pr.id)@\(pr.headRefOid.prefix(12)):\(subject.itemKey)"
    }

    func matchRelevance(pr: PullRequestInfo, subject: DiscussionSubject) {
        let key = relevanceKey(pr: pr, subject: subject)
        guard !relevanceKeys.contains(key) else { return }
        guard let engine = makeEngine() else {
            banner = Banner(kind: .error, message: PostError.engineMissing.localizedDescription)
            return
        }
        let discussion = RelatedDiscussionBuilder.candidates(pr: pr,
                                                             path: subject.path,
                                                             line: subject.line,
                                                             prAuthor: pr.author)
        guard !discussion.isEmpty else {
            banner = Banner(kind: .info, message: "이 파일에 오간 코멘트가 없어 대조할 것이 없습니다.")
            return
        }
        let target = RelevancePromptBuilder.Target(path: subject.path,
                                                   line: subject.line,
                                                   body: subject.body,
                                                   rationale: subject.rationale)
        relevanceKeys.insert(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.relevanceKeys.remove(key) }
            do {
                let outcome = try await engine.relevance(pr: pr, key: key, target: target,
                                                         discussion: discussion)
                self.ledger = await self.store.loadLedger()
                if let relevance = outcome.relevance {
                    self.relevances[relevance.key] = relevance
                } else if let message = outcome.failureMessage {
                    self.banner = Banner(kind: .error, message: "대조 실패: \(message)")
                }
            } catch is CancellationError {
                // 앱 종료 등. 다시 누르면 된다.
            } catch {
                self.banner = Banner(kind: .error, message: "대조 실패: \(error.localizedDescription)")
            }
        }
    }
}
