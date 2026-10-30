import Foundation
import PRayerCore

/// "코멘트와 커밋 다시 확인하기" — 리뷰 이후에 올라온 것만 보고 그 지적이 처리됐는지 묻는다.
///
/// 사용자가 누를 때만 돈다. 그리고 **누를 것이 없으면 버튼도 내지 않는다** —
/// 새 커밋도 새 코멘트도 없으면 물어볼 것이 없는데 토큰만 쓴다.
extension AppModel {
    func recheck(for key: String) -> ItemRecheck? { rechecks[key] }
    func isRechecking(_ key: String) -> Bool { recheckKeys.contains(key) }

    var recheckTokensUsed: Int {
        ledger.tokens(ofKind: .recheck, inLast: TokenLedger.fiveHours)
    }

    /// 이 항목의 결과를 가리키는 키.
    ///
    /// 지금 head 를 넣지 않는다 — 넣으면 커밋이 하나 올라올 때마다 지난 결과가 통째로 사라져
    /// "그 뒤로 또 바뀌었습니다" 를 보여 줄 수가 없다. 대신 결과 안에 판단 시점의 커밋을
    /// 적어 두고(`checkedHeadSha`) 화면에서 지금 head 와 견준다.
    func recheckKey(pr: PullRequestInfo, record: ReviewRecord, subject: DiscussionSubject) -> String {
        // 같은 커밋을 다시 리뷰하면 지적이 달라지는데, 커밋만으로 열쇠를 만들면
        // 새 지적이 지난 리뷰의 판정을 물려받는다. 리뷰 자체를 가리키는 값을 넣는다.
        "\(pr.id)@\(record.storageKey):\(subject.itemKey)"
    }

    /// 이 리뷰 이후에 무엇이 올라왔는가. 화면이 버튼을 낼지 말지 이걸로 정한다.
    func recheckDelta(pr: PullRequestInfo, record: ReviewRecord) -> RecheckDelta {
        RecheckDeltaBuilder.compute(pr: pr, record: record)
    }

    func startRecheck(pr: PullRequestInfo, record: ReviewRecord,
                      subject: DiscussionSubject, target: RecheckPromptBuilder.Target) {
        let key = recheckKey(pr: pr, record: record, subject: subject)
        guard !recheckKeys.contains(key) else { return }
        guard let engine = makeEngine() else {
            banner = Banner(kind: .error, message: PostError.engineMissing.localizedDescription)
            return
        }
        let delta = recheckDelta(pr: pr, record: record)
        guard !delta.isEmpty else {
            banner = Banner(kind: .info,
                            message: "리뷰한 커밋(\(record.shortHead)) 이후 새 커밋도 새 코멘트도 없습니다.")
            return
        }
        recheckKeys.insert(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.recheckKeys.remove(key) }
            do {
                // 새 커밋이 있을 때만 비교 diff 를 받는다. 커밋 제목만 보고
                // "고쳐졌다" 를 판단하게 두면 확신에 찬 오답이 나온다.
                var newDiff: String?
                if !delta.newCommits.isEmpty {
                    // try? 로 삼키면 안 된다 — 비교 diff 가 없으면 모델은 판단할 근거가 없어
                    // "판단할 근거가 없습니다" 를 돌려주는데, 사용자는 돈만 쓰고 왜인지 모른다.
                    newDiff = try await self.github.compareDiff(pr.repo,
                                                                base: record.headSha,
                                                                head: pr.headRefOid)
                }
                let outcome = try await engine.recheck(pr: pr, record: record, key: key,
                                                       target: target, delta: delta,
                                                       newDiffText: newDiff)
                self.ledger = await self.store.loadLedger()
                if let result = outcome.result {
                    self.rechecks[result.key] = result
                } else if let message = outcome.failureMessage {
                    self.banner = Banner(kind: .error, message: "다시 확인 실패: \(message)")
                }
            } catch is CancellationError {
                // 앱 종료 등. 다시 누르면 된다.
            } catch {
                self.banner = Banner(kind: .error,
                                     message: "다시 확인 실패: \(error.localizedDescription)")
            }
        }
    }
}
