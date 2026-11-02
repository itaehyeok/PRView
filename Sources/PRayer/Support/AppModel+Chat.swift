import Foundation
import PRayerCore

/// 상세 화면 하단 대화창 — 리뷰를 만든 대화를 앱 안에서 이어 묻는다(`ReviewChatRunner`).
/// 사용자가 보낼 때만 돈다. 대화는 리뷰한 그 세션에 덧붙어 터미널의 `--resume` 에도 이어진다.
extension AppModel {
    /// 그 리뷰의 대화 ID(소문자 UUID). 대화를 남기기 전 버전의 리뷰에는 없다.
    func chatSessionID(for record: ReviewRecord) -> String? {
        record.sessionID.flatMap(ClaudeSession.normalizedID)
    }

    func chat(for record: ReviewRecord) -> ReviewChat? {
        chatSessionID(for: record).flatMap { chats[$0] }
    }

    func isChatting(_ sessionID: String) -> Bool {
        chatTasks[sessionID] != nil
    }

    func sendChat(_ question: String, record: ReviewRecord) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let sessionID = chatSessionID(for: record), chatTasks[sessionID] == nil else { return }
        recordUsage(.chat)
        let engine = record.engineKind
        var chat = chats[sessionID] ?? ReviewChat(sessionID: sessionID, engine: engine)
        // 형식 안내는 답을 한 번이라도 받기 전까지 붙인다 — 첫 질문이 모델에 닿지도 못하고 실패했으면 다음 질문이 첫 질문이다.
        let isFirst = !chat.messages.contains { $0.role == .assistant && !$0.failed }
        chat.messages.append(ChatMessage(role: .user, text: question))
        chat.updatedAt = Date()
        chats[sessionID] = chat
        chatReplies[sessionID] = ""

        guard !DemoMode.isOn else {
            finishChat(sessionID: sessionID, text: "데모 모드에서는 \(engine.displayName) 에 묻지 않습니다.", failure: nil)
            return
        }
        // 답을 받는 도중 앱이 꺼져도 물은 말은 남게 먼저 적어 둔다.
        let asked = chat
        Task { _ = await store.save(chat: asked) }

        let turn = ChatTurn(engine: engine,
                            executablePath: engine == .claude ? settings.claudePath : settings.codexPath,
                            sessionID: sessionID,
                            model: record.model,
                            question: question,
                            isFirst: isFirst)
        let runner = ReviewChatRunner(codex: codex)
        let repo = record.repo.full
        let number = record.number
        let onPartial: @Sendable (String) -> Void = { [weak self] partial in
            guard let self else { return }
            Task { @MainActor in
                // 끝난 뒤 늦게 도착한 조각이 비운 자리를 다시 채우지 않게, 아직 도는 동안에만 받는다.
                guard self.chatTasks[sessionID] != nil else { return }
                self.chatReplies[sessionID] = partial
            }
        }
        chatTasks[sessionID] = Task { [weak self] in
            do {
                let result = try await runner.send(turn, onPartial: onPartial)
                guard let self else { return }
                // 멈췄어도 그때까지 쓴 토큰은 남긴다(리뷰 원장과 같은 규칙).
                _ = await self.store.append(entry: LedgerEntry(repo: repo, number: number,
                                                           tokens: result.usage.billableTokens,
                                                           costUSD: result.usage.costUSD,
                                                           model: result.usage.model, kind: .chat))
                self.ledger = await self.store.loadLedger()
                let failure: String?
                if result.cancelled {
                    failure = "답하다 멈췄습니다."
                } else if result.limitReached {
                    failure = "\(engine.productName) 사용 한도에 걸렸습니다. 한도가 풀린 뒤 다시 물어보세요."
                } else {
                    failure = result.failureMessage
                }
                self.finishChat(sessionID: sessionID, text: result.text, failure: failure)
                Log.info("대화 \(repo)#\(number) 토큰 \(result.usage.billableTokens)\(failure.map { " — \($0)" } ?? "")", "chat")
            } catch {
                self?.finishChat(sessionID: sessionID, text: nil, failure: error.localizedDescription)
            }
        }
    }

    func stopChat(sessionID: String) {
        chatTasks[sessionID]?.cancel()
    }

    /// 받은 답(실패했으면 그때까지 받은 글과 까닭)을 대화에 넣고 저장한다.
    private func finishChat(sessionID: String, text: String?, failure: String?) {
        chatTasks[sessionID] = nil
        chatReplies[sessionID] = nil
        guard var chat = chats[sessionID] else { return }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.messages.append(ChatMessage(role: .assistant, text: text))
        }
        if let failure {
            chat.messages.append(ChatMessage(role: .assistant, text: failure, failed: true))
        }
        chat.updatedAt = Date()
        chats[sessionID] = chat
        guard !DemoMode.isOn else { return }
        Task { _ = await store.save(chat: chat) }
    }
}
