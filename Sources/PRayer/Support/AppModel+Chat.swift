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

        let arguments = chatArguments(chat: chat, record: record)
        // 리뷰한 설정 그대로면 답에 표시를 달지 않는다 — 표시가 붙은 답만 보면 어디서 바꿨는지 보인다.
        let stamp = chat.hasCustomModel ? arguments : nil
        guard !DemoMode.isOn else {
            finishChat(sessionID: sessionID, text: "데모 모드에서는 \(engine.displayName) 에 묻지 않습니다.", failure: nil,
                       stamp: stamp)
            return
        }
        // 답을 받는 도중 앱이 꺼져도 물은 말은 남게 먼저 적어 둔다.
        let asked = chat
        Task { _ = await store.save(chat: asked) }

        let turn = ChatTurn(engine: engine,
                            executablePath: engine == .claude ? settings.claudePath : settings.codexPath,
                            sessionID: sessionID,
                            model: arguments.model,
                            effort: arguments.effort,
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
                self.finishChat(sessionID: sessionID, text: result.text, failure: failure, stamp: stamp)
                Log.info("대화 \(repo)#\(number) \(turn.model ?? "-")\(turn.effort.map { "·\($0)" } ?? "") "
                         + "토큰 \(result.usage.billableTokens)\(failure.map { " — \($0)" } ?? "")", "chat")
            } catch {
                self?.finishChat(sessionID: sessionID, text: nil, failure: error.localizedDescription, stamp: nil)
            }
        }
    }

    func stopChat(sessionID: String) {
        chatTasks[sessionID]?.cancel()
    }

    /// 받은 답(실패했으면 그때까지 받은 글과 까닭)을 대화에 넣고 저장한다. `stamp` 는 리뷰와 다른 모델·Effort 로
    /// 물었을 때만 있다 — 받은 글에 그 모델·단계를 적어 둔다(답 아래 작은 글자).
    private func finishChat(sessionID: String, text: String?, failure: String?, stamp: ChatArguments?) {
        chatTasks[sessionID] = nil
        chatReplies[sessionID] = nil
        guard var chat = chats[sessionID] else { return }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.messages.append(ChatMessage(role: .assistant, text: text,
                                             model: stamp?.shownModel, effort: stamp?.effort))
        }
        if let failure {
            chat.messages.append(ChatMessage(role: .assistant, text: failure, failed: true))
        }
        chat.updatedAt = Date()
        chats[sessionID] = chat
        guard !DemoMode.isOn else { return }
        Task { _ = await store.save(chat: chat) }
    }

    // MARK: - 모델·Effort (입력 줄의 두 칸)

    /// 대화창 두 칸에 보일 값. 고른 게 없으면 리뷰한 모델과 빈 Effort(칸에는 그 모델의 CLI 기본값이 보인다).
    func chatModelChoice(for record: ReviewRecord) -> ChatModelChoice {
        let reviewed = reviewedModelChoiceID(record)
        let chat = chat(for: record)
        return ChatModelChoice(model: chat?.model ?? reviewed, effort: chat?.effort ?? "",
                               reviewedModel: reviewed, isCustom: chat?.hasCustomModel ?? false)
    }

    /// 리뷰 기록의 모델(실제 모델 이름)을 모델 칸 저장값으로. 계열의 최신이 그 모델이면 계열로 친다 — 메뉴의 그 계열
    /// 줄에 ✓ 와 "리뷰한 모델" 이 붙게. 계열이 이미 새 버전으로 넘어갔으면 그 버전에 고정한 이름이다.
    func reviewedModelChoiceID(_ record: ReviewRecord) -> String {
        switch record.engineKind {
        case .claude:
            // CLI 는 날짜 붙은 이름(`claude-haiku-4-5-20251001`)으로 답하기도 한다.
            let reviewed = ClaudeModels.undatedModelID(record.model)
            return modelOptions.first { ClaudeModels.undatedModelID($0.apiID) == reviewed }?.id ?? record.model
        case .codex:
            // 예전 수확 버그로 계열 저장값(`codex:sol`)이 남은 초안도 있다 — 이미 칸 저장값이다.
            if CodexModels.stripped(record.model) != nil { return record.model }
            return codexModelOptions.first { CodexModels.resolve($0.id, catalog: codexCatalog) == record.model }?.id
                ?? CodexModels.id(record.model)
        }
    }

    /// 리뷰한 모델을 고르면 고른 것을 지운다(nil = 리뷰한 모델 그대로). 그 모델이 받지 않는 Effort 가 남으면
    /// 함께 지운다 — Codex 는 모델마다 단계가 다르다.
    func chooseChatModel(_ modelID: String, for record: ReviewRecord) {
        let reviewed = reviewedModelChoiceID(record)
        updateChatChoice(record) { chat in
            chat.model = modelID == reviewed ? nil : modelID
            if let effort = chat.effort, !effortLevels(forModel: modelID).contains(effort) {
                chat.effort = nil
            }
        }
    }

    func chooseChatEffort(_ level: String, for record: ReviewRecord) {
        updateChatChoice(record) { $0.effort = level }
    }

    /// "리뷰한 설정으로 되돌리기" — 리뷰한 모델에 Effort 는 넘기지 않는다(리뷰 때 단계는 기록에 없다).
    func resetChatModel(for record: ReviewRecord) {
        updateChatChoice(record) { chat in
            chat.model = nil
            chat.effort = nil
        }
    }

    /// 아직 묻지 않은 대화에서 골라도 기억한다 — 첫 질문부터 고른 모델로 묻게. 빈 대화는 열린 것으로 치지 않는다
    /// (`ChatDrawer.isOpen` 은 말이 있어야 연다).
    private func updateChatChoice(_ record: ReviewRecord, _ change: (inout ReviewChat) -> Void) {
        guard let sessionID = chatSessionID(for: record) else { return }
        var chat = chats[sessionID] ?? ReviewChat(sessionID: sessionID, engine: record.engineKind)
        change(&chat)
        // 오래된 대화를 지울 때(`Store.save(chat:)`, 30일) 막 고른 것이 같이 지워지지 않게 손댄 때로 친다.
        chat.updatedAt = Date()
        chats[sessionID] = chat
        guard !DemoMode.isOn else { return }
        let changed = chat
        Task { _ = await store.save(chat: changed) }
    }

    /// CLI 에 넘길 모델·Effort. 고른 게 없으면 리뷰한 모델(실제 모델 이름)에 Effort 없이 — 예전 그대로다.
    private func chatArguments(chat: ReviewChat, record: ReviewRecord) -> ChatArguments {
        switch record.engineKind {
        case .claude:
            // 계열 별칭(`sonnet`)은 그대로 넘긴다 — 리뷰도 그렇게 부른다(CLI 가 그 계열의 최신으로 푼다).
            let model = chat.model ?? record.model
            return ChatArguments(model: model,
                                 effort: chat.effort.flatMap(EffortLevel.argument(for:)),
                                 shownModel: chat.model.map { modelOption(id: $0)?.apiID ?? $0 } ?? record.model)
        case .codex:
            // 계열(`codex:terra`)은 목록의 가장 새 버전으로 푼다. 못 풀면(목록을 아직 못 받음) 리뷰한 모델로 묻는다 —
            // `-m` 을 빼면 Codex 기본 모델이 답해 고른 것과 리뷰 모델 어느 쪽도 아니게 된다.
            let model = chat.model.flatMap { CodexModels.resolve($0, catalog: codexCatalog) } ?? record.model
            let choice = chat.model ?? reviewedModelChoiceID(record)
            return ChatArguments(model: model,
                                 effort: chat.effort.flatMap {
                                     CodexModels.effortArgument($0, choice: choice, catalog: codexCatalog)
                                 },
                                 shownModel: model)
        }
    }

    /// 답 아래 작은 글자에 쓸 모델 이름 — 리뷰 요약 줄(`modelLabel`)과 같은 규칙.
    func chatModelName(_ modelID: String, engine: ReviewEngineKind) -> String {
        switch engine {
        case .claude: return ClaudeModels.displayName(forModelID: modelID)
        case .codex: return CodexModels.displayName(forModelID: modelID)
        }
    }
}

/// 대화창 두 칸의 값(`AppModel.chatModelChoice(for:)`).
struct ChatModelChoice {
    /// 모델 칸 저장값 — 리뷰 모델 칸과 같은 꼴(`opus`·`codex:sol`).
    var model: String
    /// Effort 저장값. 빈 문자열은 넘기지 않는다는 뜻이다.
    var effort: String
    /// 리뷰한 모델에 해당하는 저장값. 메뉴에서 그 줄에 "리뷰한 모델" 을 단다.
    var reviewedModel: String
    /// 리뷰와 다르게 골라 둔 것이 있는가 — "리뷰한 설정으로 되돌리기" 를 보일지.
    var isCustom: Bool
}

/// 질문 하나에 넘기는 모델·Effort.
struct ChatArguments {
    /// `--model`·`-m` 에 넘길 이름.
    var model: String?
    /// `--effort`·`model_reasoning_effort` 값. 그 엔진이 받는 단계로 거른 것이다.
    var effort: String?
    /// 답 아래에 보일 모델 — Claude 는 별칭을 지금 그 계열의 실제 모델 이름으로 푼 것이다. 나중에 계열이 새 버전으로
    /// 넘어가도 그때 답한 모델 이름이 남는다.
    var shownModel: String?
}
