import Foundation
import PRayerCore

/// 남이 쓴 코멘트를 쉬운 말로 푸는 경로.
/// 리뷰가 아니라 통역이라 코멘트 1건 + 그 자리 코드만 보낸다. 사용자가 누를 때만 돈다.
extension AppModel {
    func explanation(for target: ExplainTarget) -> CommentExplanation? {
        explanations[target.key]
    }

    func isExplaining(_ target: ExplainTarget) -> Bool {
        explainingKeys.contains(target.key)
    }

    var explainTokensUsed: Int {
        ledger.tokens(ofKind: .explain, inLast: TokenLedger.fiveHours)
    }

    func explain(target: ExplainTarget, pr: PullRequestInfo) {
        guard !explainingKeys.contains(target.key) else { return }
        guard let engine = makeEngine() else {
            banner = Banner(kind: .error, message: PostError.engineMissing.localizedDescription)
            return
        }
        explainingKeys.insert(target.key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.explainingKeys.remove(target.key) }
            do {
                let outcome = try await engine.explain(pr: pr, target: target)
                self.ledger = await self.store.loadLedger()
                if let explanation = outcome.explanation {
                    self.explanations[explanation.key] = explanation
                } else if let message = outcome.failureMessage {
                    self.banner = Banner(kind: .error, message: "설명 실패: \(message)")
                }
            } catch is CancellationError {
                // 앱 종료 등. 다시 누르면 된다.
            } catch {
                self.banner = Banner(kind: .error, message: "설명 실패: \(error.localizedDescription)")
            }
        }
    }
}
