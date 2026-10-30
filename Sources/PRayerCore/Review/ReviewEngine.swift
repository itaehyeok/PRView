import Foundation

public struct ReviewEngineConfig: Sendable {
    public var settings: Settings
    /// `--system-prompt-file` 로 넘길 실제 파일 경로.
    public var guidePath: String
    public var guideText: String
    public var schemaPath: String
    public var schemaText: String
    /// 코멘트 설명 전용.
    public var explainGuidePath: String?
    public var explainGuideText: String?
    public var explainSchemaPath: String?
    public var explainSchemaText: String?
    /// 이미 언급된 사안 대조 전용.
    public var relevanceGuidePath: String?
    public var relevanceGuideText: String?
    public var relevanceSchemaPath: String?
    public var relevanceSchemaText: String?
    /// 지적이 그 뒤에 처리됐는지 다시 확인하는 호출용.
    public var recheckGuidePath: String?
    public var recheckGuideText: String?
    public var recheckSchemaPath: String?
    public var recheckSchemaText: String?
    public var promptVersion: String
    /// Codex 가 알려 준 모델 목록. 계열(`codex:sol`)을 실제 모델로 풀고, 그 모델이 받는 effort 인지 본다.
    public var codexCatalog: CodexCatalog?

    public init(settings: Settings, guidePath: String, guideText: String,
                schemaPath: String, schemaText: String,
                explainGuidePath: String? = nil, explainGuideText: String? = nil,
                explainSchemaPath: String? = nil, explainSchemaText: String? = nil,
                relevanceGuidePath: String? = nil, relevanceGuideText: String? = nil,
                relevanceSchemaPath: String? = nil, relevanceSchemaText: String? = nil,
                recheckGuidePath: String? = nil, recheckGuideText: String? = nil,
                recheckSchemaPath: String? = nil, recheckSchemaText: String? = nil,
                codexCatalog: CodexCatalog? = nil) {
        self.codexCatalog = codexCatalog
        self.explainGuidePath = explainGuidePath
        self.explainGuideText = explainGuideText
        self.explainSchemaPath = explainSchemaPath
        self.explainSchemaText = explainSchemaText
        self.relevanceGuidePath = relevanceGuidePath
        self.relevanceGuideText = relevanceGuideText
        self.relevanceSchemaPath = relevanceSchemaPath
        self.relevanceSchemaText = relevanceSchemaText
        self.recheckGuidePath = recheckGuidePath
        self.recheckGuideText = recheckGuideText
        self.recheckSchemaPath = recheckSchemaPath
        self.recheckSchemaText = recheckSchemaText
        self.settings = settings
        self.guidePath = guidePath
        self.guideText = guideText
        self.schemaPath = schemaPath
        self.schemaText = schemaText
        self.promptVersion = PromptVersion.compute(guide: guideText, schema: schemaText)
    }
}

public struct ReviewPreparation: Sendable {
    public var diff: ParsedDiff
    public var prompt: String
    public var estimatedTokens: Int
    public var changedLinesAfterExclusion: Int
}

public struct ReviewOutcome: Sendable {
    public var record: ReviewRecord?
    public var usage: EngineUsage
    public var failureMessage: String?
    public var limitReached: Bool
    public var timedOut: Bool

    public var succeeded: Bool { record != nil }
}

/// GitHub 조회 → 프롬프트 → Claude·Codex 실행 → 초안 검증 → 저장까지 리뷰 1건의 전 과정.
///
/// 어느 엔진으로 돌지는 설정의 모델 값이 정한다(`ReviewEngineKind(model:)` — Codex 모델은 `codex:` 앞말).
/// 리뷰·설명·대조·다시 확인이 모두 같은 엔진으로 돈다.
public struct ReviewEngine: Sendable {
    public let github: GitHubClient
    public let claude: ClaudeRunner
    public let codex: CodexRunner
    public let store: Store
    public let config: ReviewEngineConfig

    public init(github: GitHubClient, claude: ClaudeRunner, codex: CodexRunner = CodexRunner(),
                store: Store, config: ReviewEngineConfig) {
        self.github = github
        self.claude = claude
        self.codex = codex
        self.store = store
        self.config = config
    }

    public var engineKind: ReviewEngineKind { ReviewEngineKind(model: config.settings.model) }

    /// 원장·실패 결과에 남길 모델 이름 — Codex 는 실제로 부른 모델(`gpt-5.6-sol`), Claude 는 저장값 그대로.
    var modelLabel: String {
        switch engineKind {
        case .claude: return config.settings.model
        case .codex: return CodexModels.resolve(config.settings.model, catalog: config.codexCatalog) ?? config.settings.model
        }
    }

    /// 엔진에 맞춰 실행 파일·모델·effort 를 푼 요청. 보조 호출(설명·대조·다시 확인)은 `effort` 를 넘기지 않는다
    /// — 짧은 호출까지 올리면 토큰만 더 든다.
    func request(prompt: String, guidePath: String, guideText: String, schemaPath: String, schemaText: String,
                 timeout: TimeInterval, effort: String? = nil,
                 workingDirectory: String? = nil, allowedTools: [String] = [],
                 stdioDirectory: URL? = nil, persistSession: Bool = false) -> EngineRequest {
        let settings = config.settings
        let engine = engineKind
        let path: String
        let model: String?
        let effortArgument: String?
        switch engine {
        case .claude:
            path = settings.claudePath
            model = settings.model
            effortArgument = effort.flatMap(EffortLevel.argument(for:))
        case .codex:
            path = settings.codexPath
            model = CodexModels.resolve(settings.model, catalog: config.codexCatalog)
            effortArgument = effort.flatMap { CodexModels.effortArgument($0, choice: settings.model, catalog: config.codexCatalog) }
        }
        return EngineRequest(prompt: prompt,
                             executablePath: path,
                             guidePath: guidePath,
                             guideText: guideText,
                             schemaPath: schemaPath,
                             schemaText: schemaText,
                             model: model,
                             timeout: timeout,
                             workingDirectory: workingDirectory ?? AppPaths.claudeWorkingDirectory.path,
                             allowedTools: allowedTools,
                             stdioDirectory: stdioDirectory,
                             effort: effortArgument,
                             persistSession: persistSession,
                             engine: engine)
    }

    func run(_ request: EngineRequest) async throws -> EngineRunResult {
        switch request.engine {
        case .claude: return try await claude.run(request: request)
        case .codex: return try await codex.run(request: request)
        }
    }

    func execute(prompt: String,
                 workingDirectory: String? = nil, allowedTools: [String] = [],
                 stdioDirectory: URL? = nil, persistSession: Bool = false) async throws -> EngineRunResult {
        let request = self.request(prompt: prompt, guidePath: config.guidePath, guideText: config.guideText,
                              schemaPath: config.schemaPath, schemaText: config.schemaText,
                              timeout: Settings.reviewTimeout, effort: config.settings.effort,
                              workingDirectory: workingDirectory, allowedTools: allowedTools,
                              stdioDirectory: stdioDirectory, persistSession: persistSession)
        return try await run(request)
    }

    /// diff 를 받아 제외 규칙을 적용한다. 토큰을 쓰지 않으므로 크기 재판정에도 쓸 수 있다.
    public func prepare(pr: PullRequestInfo) async throws -> ReviewPreparation {
        let diffText: String
        if let cached = await store.cachedDiff(repo: pr.repo, number: pr.number, sha: pr.headRefOid) {
            diffText = cached
        } else {
            diffText = try await github.diff(pr.repo, number: pr.number)
            await store.cacheDiff(diffText, repo: pr.repo, number: pr.number, sha: pr.headRefOid)
        }
        let parsed = DiffParser.parse(diffText, excluding: config.settings.excludedPathPatterns)
        let prompt = PromptBuilder.build(PromptInput(pr: pr, diff: parsed))
        return ReviewPreparation(diff: parsed,
                                 prompt: prompt,
                                 estimatedTokens: PromptBuilder.estimatedTokens(changedLines: parsed.changedLines),
                                 changedLinesAfterExclusion: parsed.changedLines)
    }

    /// 깊은 리뷰: PR head 를 체크아웃한 워크트리를 주고 읽기 도구만 열어 준다.
    /// diff 밖 호출부까지 확인할 수 있는 대신 토큰을 훨씬 많이 쓴다. 기본은 꺼져 있다.
    public static let deepReviewTools = ["Read", "Grep", "Glob"]

    public func review(pr: PullRequestInfo,
                       trigger: ReviewRecord.Trigger,
                       preparation: ReviewPreparation? = nil,
                       deepRepoPath: String? = nil,
                       deepRepoProvider: (@Sendable () async throws -> String)? = nil,
                       onPhase: (@Sendable (ReviewPhase) -> Void)? = nil,
                       onProgress: (@Sendable (GitProgress) -> Void)? = nil,
                       spoolID: String? = nil) async throws -> ReviewOutcome {
        let prep: ReviewPreparation
        if let preparation {
            prep = preparation
        } else {
            onPhase?(.loadingDiff)
            prep = try await prepare(pr: pr)
        }

        if prep.diff.isEmpty {
            let detail = prep.diff.excludedFiles.isEmpty
                ? "diff 가 비어 있습니다."
                : "변경이 전부 잠금 파일·제외 경로(\(prep.diff.excludedFiles.map(\.path).prefix(3).joined(separator: ", ")) 등)라 리뷰할 코드가 없습니다."
            return ReviewOutcome(record: nil, usage: EngineUsage(model: modelLabel),
                                 failureMessage: detail, limitReached: false, timedOut: false)
        }

        // 깊은 리뷰면 워크트리를 만들고 읽기 도구를 연다. 끝나면 반드시 지운다.
        // 클론 자리를 바로 받지 않고 여기서 묻는 경우(deepRepoProvider)는 PR 스냅샷을 처음 받아야 할 때다 —
        // diff 가 비어 리뷰하지 않을 PR 때문에 몇십 초짜리 클론을 먼저 하지 않으려고 diff 확인 뒤로 미룬다.
        var worktree: WorktreeManager.Prepared?
        var workingDirectory: String?
        var tools: [String] = []
        var resolvedRepoPath = deepRepoPath
        if let deepRepoProvider {
            resolvedRepoPath = try await deepRepoProvider()
        }
        if let deepRepoPath = resolvedRepoPath {
            onPhase?(.preparingWorktree)
            let manager = WorktreeManager()
            let prepared = try await manager.prepare(repoPath: deepRepoPath,
                                                     number: pr.number,
                                                     headSha: pr.headRefOid,
                                                     repo: pr.repo,
                                                     onPhase: onPhase,
                                                     onProgress: onProgress)
            worktree = prepared
            workingDirectory = prepared.path.path
            tools = Self.deepReviewTools
        }
        defer {
            // 체크아웃은 남기고 락만 푼다(풀 재사용).
            if let worktree {
                onPhase?(.releasingWorktree)
                Task.detached { await WorktreeManager().release(worktree) }
            }
        }

        Log.info("리뷰 시작 \(pr.id) head=\(pr.shortHead)\(tools.isEmpty ? "" : " (깊은 리뷰)") 변경 \(prep.changedLinesAfterExclusion)줄 예상 \(prep.estimatedTokens)토큰", "engine")
        // 결과를 영속 폴더에 남긴다. 앱이 여기서 죽어도 다음 실행에서 수확할 수 있다.
        var spoolDirectory: URL?
        if let spoolID {
            let job = SpooledJob(id: spoolID, pr: pr, trigger: trigger, deep: worktree != nil,
                                 model: config.settings.model,
                                 phase: .running)
            spoolDirectory = await ReviewSpool().begin(job: job)
        }

        onPhase?(.running)
        // 본 리뷰만 대화를 남긴다 — 리뷰 맨 아래 "Claude 에서 이어서 대화하기" 가 이 대화를 연다.
        let run = try await execute(prompt: prep.prompt,
                                    workingDirectory: workingDirectory, allowedTools: tools,
                                    stdioDirectory: spoolDirectory, persistSession: true)

        let entry = LedgerEntry(repo: pr.repo.full,
                                number: pr.number,
                                tokens: run.usage.billableTokens,
                                costUSD: run.usage.costUSD,
                                model: run.usage.model)
        _ = await store.append(entry: entry)

        if run.cancelled {
            throw CancellationError()
        }

        guard let output = run.output else {
            if let spoolID { await ReviewSpool().finish(id: spoolID) }
            Log.error("리뷰 실패 \(pr.id): \(run.failureMessage ?? "원인 불명")", "engine")
            return ReviewOutcome(record: nil, usage: run.usage,
                                 failureMessage: run.failureMessage,
                                 limitReached: run.limitReached,
                                 timedOut: run.timedOut)
        }

        onPhase?(.validating)
        let record = await finalize(pr: pr, trigger: trigger, output: output, run: run,
                                    diff: prep.diff, deep: worktree != nil)
        if let spoolID { await ReviewSpool().finish(id: spoolID) }
        Log.info("리뷰 완료 \(pr.id) verdict=\(output.verdict.rawValue) 코멘트 \(record.comments.count)건 토큰 \(run.usage.billableTokens)", "engine")
        return ReviewOutcome(record: record, usage: run.usage, failureMessage: nil,
                             limitReached: false, timedOut: false)
    }

    /// 모델 출력 → 검증 → 초안 저장. 정상 경로와 "앱이 죽은 뒤 수확" 경로가 같은 코드를 쓴다.
    func finalize(pr: PullRequestInfo,
                  trigger: ReviewRecord.Trigger,
                  output rawOutput: ReviewOutput,
                  run: EngineRunResult,
                  diff: ParsedDiff,
                  deep: Bool) async -> ReviewRecord {
        let tidied = rawOutput.tidied()
        if tidied != rawOutput {
            Log.info("모델 출력에 짝 없는 따옴표가 있어 걷어 냈다 \(pr.id)", "engine")
        }
        let output = ReviewFormatGuard.conform(tidied)
        if output.verdict != tidied.verdict {
            Log.info("판정을 코멘트 중요도에 맞춰 바꿨다 \(pr.id): \(tidied.verdict.rawValue) → \(output.verdict.rawValue)", "engine")
        }
        let validated = DraftValidator.validate(output: output,
                                                diff: diff,
                                                limits: ReviewLimits(settings: config.settings))
        // 같은 커밋을 다시 리뷰한 경우 이미 게시한 사실을 잃지 않도록 승계한다
        // (초안 파일은 (repo, number, headSha) 로만 구분돼 덮어쓰기 때문).
        let previouslyPosted = await store.loadRecord(repo: pr.repo, number: pr.number,
                                                      headSha: pr.headRefOid)?.posted
        var record = ReviewRecord(repo: pr.repo,
                                  number: pr.number,
                                  headSha: pr.headRefOid,
                                  baseRefName: pr.baseRefName,
                                  promptVersion: config.promptVersion,
                                  model: run.usage.model.isEmpty ? modelLabel : run.usage.model,
                                  // "리뷰 이후" 의 기준점. 로컬 시계가 아니라 이 스냅샷의 GitHub 시각이다.
                                  snapshotUpdatedAt: pr.updatedAt,
                                  trigger: trigger,
                                  deep: deep ? true : nil,
                                  output: output,
                                  comments: validated.comments,
                                  // 잘된 점은 처음엔 끈다(사용자 결정, 2026-10-20). 본문 미리보기에 흐리게 남아 있어 한 번에 켤 수 있다.
                                  includeStrengths: false,
                                  bodyDraft: PostBuilder.defaultBody(output: output, includeStrengths: true),
                                  usage: run.usage,
                                  validationIssues: validated.issues)
        record.posted = previouslyPosted
        record.sessionID = run.sessionID
        record.engine = run.engine
        record.changedLines = pr.additions + pr.deletions
        await store.save(record: record)
        return record
    }

    // MARK: - 앱이 죽은 뒤 결과 수확

    /// 지난 실행에서 돌던 리뷰들을 살펴본다.
    /// 결과 파일이 완전하면 초안으로 저장하고, 아직 돌고 있으면 그대로 알린다.
    public func harvestSpooledJobs() async -> [SpoolHarvest] {
        let spool = ReviewSpool()
        var results: [SpoolHarvest] = []
        for entry in await spool.pending() {
            let job = entry.job
            guard let stdout = await spool.output(in: entry.directory) else {
                if await spool.isAlive(entry.directory) {
                    results.append(.stillRunning(job))
                } else {
                    await spool.finish(id: job.id)
                    results.append(.lost(job, reason: "결과 파일이 비어 있습니다. 앱이 꺼질 때 프로세스도 함께 끝난 것으로 보입니다."))
                }
                continue
            }

            let process = ProcessResult(exitCode: 0, stdout: stdout,
                                        stderr: await spool.stderr(in: entry.directory), timedOut: false)
            // 잡의 모델 값이 엔진을 말한다(Codex 는 `codex:` 앞말). Codex 결과는 이벤트 줄과 마지막 메시지 파일이다.
            let parsed: EngineRunResult
            switch ReviewEngineKind(model: job.model) {
            case .claude:
                parsed = claude.parse(result: process, model: job.model)
            case .codex:
                parsed = CodexRunner.parse(result: process,
                                           lastMessageURL: CodexRunner.lastMessageURL(in: entry.directory),
                                           model: CodexModels.resolve(job.model, catalog: config.codexCatalog) ?? job.model)
            }
            guard let output = parsed.output else {
                if await spool.isAlive(entry.directory) {
                    results.append(.stillRunning(job))
                } else {
                    await spool.finish(id: job.id)
                    results.append(.lost(job, reason: parsed.failureMessage ?? "결과가 잘려 있어 읽을 수 없습니다."))
                }
                continue
            }

            // 검증에는 diff 가 필요하다. 리뷰 전에 캐시해 둔 것이 그대로 남아 있다.
            guard let diffText = await store.cachedDiff(repo: job.pr.repo, number: job.pr.number,
                                                        sha: job.pr.headRefOid) else {
                await spool.finish(id: job.id)
                results.append(.lost(job, reason: "diff 캐시가 없어 초안을 검증할 수 없습니다. 다시 리뷰해 주세요."))
                continue
            }
            let diff = DiffParser.parse(diffText, excluding: config.settings.excludedPathPatterns)
            let record = await finalize(pr: job.pr, trigger: job.trigger, output: output,
                                        run: parsed, diff: diff, deep: job.deep)
            _ = await store.append(entry: LedgerEntry(repo: job.pr.repo.full,
                                                      number: job.pr.number,
                                                      tokens: parsed.usage.billableTokens,
                                                      costUSD: parsed.usage.costUSD,
                                                      model: parsed.usage.model,
                                                      kind: .review))
            await spool.finish(id: job.id)
            Log.info("종료된 리뷰 수확 \(job.pr.id) 토큰 \(parsed.usage.billableTokens)", "spool")
            results.append(.recovered(record))
        }
        return results
    }

    // MARK: - 이미 언급된 사안 대조

    public struct RelevanceOutcome: Sendable {
        public var relevance: DiscussionRelevance?
        public var usage: EngineUsage
        public var failureMessage: String?
    }

    /// 초안이 짚은 사안과 PR 에 오간 코멘트를 대조해, 정말 이어지는 대목과 칠할 문구를 받아 온다.
    ///
    /// 코드도 diff 도 보내지 않는다 — 대조에 필요한 것은 초안 본문과 코멘트들뿐이다.
    /// 모델이 돌려준 인용은 **본문에 그대로 있는지 확인해서** 없는 것은 버린다.
    /// 지어낸 인용을 그대로 칠하면 사용자가 원문에 없는 문장을 원문으로 읽는다.
    public func relevance(pr: PullRequestInfo,
                          key: String,
                          target: RelevancePromptBuilder.Target,
                          discussion: RelatedDiscussion) async throws -> RelevanceOutcome {
        guard let guidePath = config.relevanceGuidePath,
              let guideText = config.relevanceGuideText,
              let schemaPath = config.relevanceSchemaPath,
              let schemaText = config.relevanceSchemaText else {
            return RelevanceOutcome(relevance: nil, usage: EngineUsage(),
                                    failureMessage: "대조 설정(relevance.md / relevance-schema.json)을 찾을 수 없습니다.")
        }
        let prompt = RelevancePromptBuilder.build(pr: pr, target: target, discussion: discussion)
        let request = self.request(prompt: prompt, guidePath: guidePath, guideText: guideText,
                              schemaPath: schemaPath, schemaText: schemaText, timeout: 150)
        let run = try await self.run(request)
        _ = await store.append(entry: LedgerEntry(repo: pr.repo.full,
                                                  number: pr.number,
                                                  tokens: run.usage.billableTokens,
                                                  costUSD: run.usage.costUSD,
                                                  model: run.usage.model,
                                                  kind: .relevance))
        if run.cancelled { throw CancellationError() }
        guard let json = run.structuredJSON,
              let decoded = try? JSONDecoder().decode(RelevanceOutput.self, from: json) else {
            return RelevanceOutcome(relevance: nil, usage: run.usage,
                                    failureMessage: run.failureMessage ?? "대조 결과를 만들지 못했습니다.")
        }
        let bodies = RelatedDiscussionBuilder.messagesByID(discussion).mapValues(\.body)
        let verified = decoded.related.compactMap { match -> DiscussionRelevance.Match? in
            guard let body = bodies[match.messageID] else { return nil }
            let quotes = match.quotes.filter { body.contains($0) }
            guard !quotes.isEmpty else { return nil }
            return DiscussionRelevance.Match(messageID: match.messageID,
                                             relevance: match.relevance,
                                             quotes: quotes,
                                             whyKo: match.whyKo)
        }
        let dropped = decoded.related.count - verified.count
        if dropped > 0 {
            Log.info("대조 인용 \(dropped)건은 원문에서 찾지 못해 버렸다", "engine")
        }
        // 근거가 하나도 남지 않으면 "이어지는 대화 없음" 으로 내린다.
        let verdict = verified.isEmpty ? DiscussionRelevance.Verdict.notRelated : decoded.verdict
        let result = DiscussionRelevance(key: key,
                                         summaryKo: decoded.summaryKo,
                                         verdict: verdict,
                                         matches: verified,
                                         usage: run.usage)
        _ = await store.save(relevance: result)
        Log.info("대조 완료 \(key) 토큰 \(run.usage.billableTokens) 관련 \(verified.count)건", "engine")
        return RelevanceOutcome(relevance: result, usage: run.usage, failureMessage: nil)
    }

    // MARK: - 다시 확인 (리뷰 이후 커밋·코멘트로 처리됐는지)

    public struct RecheckOutcome: Sendable {
        public var result: ItemRecheck?
        public var usage: EngineUsage
        public var failureMessage: String?
    }

    /// 지적 하나가 그 뒤에 처리됐는지 묻는다.
    ///
    /// 델타(새 커밋·새 코멘트)는 호출자가 만들어 넘긴다 — 비어 있으면 애초에 부르지 않는다.
    /// 새 커밋이 있을 때만 compare diff 를 받아 붙인다. 그게 없으면 "고쳐졌다" 를
    /// 커밋 제목만 보고 판단하게 되는데, 그건 확신에 찬 오답으로 가는 지름길이다.
    public func recheck(pr: PullRequestInfo,
                        record: ReviewRecord,
                        key: String,
                        target: RecheckPromptBuilder.Target,
                        delta: RecheckDelta,
                        newDiffText: String?) async throws -> RecheckOutcome {
        guard let guidePath = config.recheckGuidePath,
              let guideText = config.recheckGuideText,
              let schemaPath = config.recheckSchemaPath,
              let schemaText = config.recheckSchemaText else {
            return RecheckOutcome(result: nil, usage: EngineUsage(),
                                  failureMessage: "다시 확인 설정(recheck.md / recheck-schema.json)을 찾을 수 없습니다.")
        }
        let excluded = config.settings.excludedPathPatterns
        // 리뷰 당시 코드는 이미 받아 둔 것만 쓴다. 이것 때문에 새로 내려받지 않는다.
        let reviewedDiff = (await store.cachedDiff(repo: pr.repo, number: pr.number, sha: record.headSha))
            .map { DiffParser.parse($0, excluding: excluded) }
        let newDiff = newDiffText.map { DiffParser.parse($0, excluding: excluded) }
        let prompt = RecheckPromptBuilder.build(pr: pr, record: record, target: target,
                                                delta: delta, reviewedDiff: reviewedDiff, newDiff: newDiff)
        let request = self.request(prompt: prompt, guidePath: guidePath, guideText: guideText,
                              schemaPath: schemaPath, schemaText: schemaText, timeout: 180)
        let run = try await self.run(request)
        _ = await store.append(entry: LedgerEntry(repo: pr.repo.full,
                                                  number: pr.number,
                                                  tokens: run.usage.billableTokens,
                                                  costUSD: run.usage.costUSD,
                                                  model: run.usage.model,
                                                  kind: .recheck))
        if run.cancelled { throw CancellationError() }
        guard let json = run.structuredJSON,
              let decoded = try? JSONDecoder().decode(RecheckOutput.self, from: json) else {
            return RecheckOutcome(result: nil, usage: run.usage,
                                  failureMessage: run.failureMessage ?? "다시 확인에 실패했습니다.")
        }
        // 모델이 준 근거를 그대로 믿지 않는다. 커밋·코멘트 근거는 실제로 델타에 있는 것만 남긴다
        // (relevance() 가 인용을 원문과 대조하는 것과 같은 이유다 — 없는 근거를 화면에 칠하면
        // 사용자는 원문에 없는 사실을 원문으로 읽는다).
        let commitRefs = Set(delta.newCommits.flatMap {
            [$0.oid.lowercased(), $0.abbreviatedOid.lowercased()]
        })
        let commentAuthors = Set(delta.newComments.map { $0.author.lowercased() })
        var dropped = 0
        let evidence = decoded.evidence.compactMap { item -> ItemRecheck.Evidence? in
            let ref = item.ref.lowercased()
            switch item.kind {
            case .commit:
                guard commitRefs.contains(where: { $0.hasPrefix(ref) || ref.hasPrefix($0) }) else {
                    dropped += 1
                    return nil
                }
            case .comment:
                guard commentAuthors.contains(where: { $0.contains(ref) || ref.contains($0) }) else {
                    dropped += 1
                    return nil
                }
            case .code:
                break   // 코드 근거는 diff 안의 자리라 여기서 검증할 대상이 없다.
            }
            return ItemRecheck.Evidence(kind: item.kind, ref: item.ref, path: item.path,
                                        line: item.line, note: item.note)
        }
        if dropped > 0 {
            Log.info("다시 확인: 델타에 없는 근거 \(dropped)건을 버렸다 (\(key))", "engine")
        }
        // 근거 없이 "고쳐졌다" 는 결론은 받지 않는다. 화면에 확신만 남고 근거가 없으면
        // 사용자가 확인할 방법이 없다 — 그럴 바에는 모른다고 말하는 편이 낫다.
        let status = decoded.status.downgradedIfUnsupported(evidenceCount: evidence.count)
        if status != decoded.status {
            Log.info("다시 확인: 근거가 없어 \(decoded.status.rawValue) 를 \(status.rawValue) 로 내렸다 (\(key))", "engine")
        }
        let result = ItemRecheck(key: key,
                                 status: status,
                                 summaryKo: decoded.summaryKo,
                                 evidence: evidence,
                                 reviewedHeadSha: record.headSha,
                                 checkedHeadSha: pr.headRefOid,
                                 newCommitCount: delta.newCommits.count,
                                 newCommentCount: delta.newComments.count,
                                 usage: run.usage)
        _ = await store.save(recheck: result)
        Log.info("다시 확인 완료 \(key) → \(status.rawValue) 토큰 \(run.usage.billableTokens)", "engine")
        return RecheckOutcome(result: result, usage: run.usage, failureMessage: nil)
    }

    // MARK: - 코멘트 설명

    public struct ExplainOutcome: Sendable {
        public var explanation: CommentExplanation?
        public var usage: EngineUsage
        public var failureMessage: String?
    }

    /// 남이 쓴 코멘트 1건을 쉬운 말로 푼다. 코멘트 + 그 자리 코드만 보내서 리뷰보다 훨씬 싸다.
    public func explain(pr: PullRequestInfo, target: ExplainTarget) async throws -> ExplainOutcome {
        guard let guidePath = config.explainGuidePath,
              let guideText = config.explainGuideText,
              let schemaPath = config.explainSchemaPath,
              let schemaText = config.explainSchemaText else {
            return ExplainOutcome(explanation: nil, usage: EngineUsage(model: modelLabel),
                                  failureMessage: "설명 설정(explain.md / explain-schema.json)을 찾을 수 없습니다.")
        }

        // 이미 받아 둔 diff 만 쓴다. 설명 때문에 새로 내려받지 않는다.
        let diffText = await store.cachedDiff(repo: pr.repo, number: pr.number, sha: pr.headRefOid)
        let diff = diffText.map { DiffParser.parse($0, excluding: config.settings.excludedPathPatterns) }
        let prompt = ExplainPromptBuilder.build(pr: pr, target: target, diff: diff)

        let request = self.request(prompt: prompt, guidePath: guidePath, guideText: guideText,
                              schemaPath: schemaPath, schemaText: schemaText, timeout: 150)
        let run = try await self.run(request)

        _ = await store.append(entry: LedgerEntry(repo: pr.repo.full,
                                                  number: pr.number,
                                                  tokens: run.usage.billableTokens,
                                                  costUSD: run.usage.costUSD,
                                                  model: run.usage.model,
                                                  kind: .explain))
        if run.cancelled { throw CancellationError() }

        let decoded: ExplanationOutput? = run.structuredJSON.flatMap {
            try? JSONDecoder().decode(ExplanationOutput.self, from: $0)
        }
        guard let decoded else {
            return ExplainOutcome(explanation: nil, usage: run.usage,
                                  failureMessage: run.failureMessage ?? "설명을 만들지 못했습니다.")
        }
        let explanation = CommentExplanation(key: target.key,
                                             point: decoded.point,
                                             detail: decoded.detail,
                                             action: decoded.action,
                                             terms: decoded.terms,
                                             isQuestion: decoded.isQuestion,
                                             usage: run.usage)
        _ = await store.save(explanation: explanation)
        Log.info("코멘트 설명 완료 \(target.key) 토큰 \(run.usage.billableTokens)", "engine")
        return ExplainOutcome(explanation: explanation, usage: run.usage, failureMessage: nil)
    }

    /// 줄 코멘트 하나를 바로 단다. 사용자가 지적 카드의 "코드 옆에 코멘트 달기" 를 눌렀을 때만 호출된다.
    /// 기록 저장은 앱이 한다(`AppModel.postInline`) — 여기서 저장하면 앱이 들고 있는 기록과 엇갈린다.
    public func postInline(record: ReviewRecord, comment: ReviewPayload.Comment,
                           commitID: String) async throws -> PostedComment {
        let posted = try await github.postReviewComment(record.repo, number: record.number,
                                                        commitID: commitID, comment: comment)
        Log.info("줄 코멘트 게시 \(record.prKey) \(comment.path):\(comment.line)", "engine")
        return posted
    }

    /// 게시. 사용자가 "게시" 를 눌렀을 때만 호출된다.
    public func post(record: ReviewRecord,
                     event: ReviewEvent,
                     body: String,
                     includeComments: Bool = true,
                     basket: [ReviewPayload.Comment] = [],
                     commitID: String? = nil) async throws -> PostedInfo {
        let payload = PostBuilder.payload(record: record,
                                          event: event,
                                          body: body,
                                          includeComments: includeComments,
                                          basket: basket,
                                          commitID: commitID)
        let posted = try await github.postReview(record.repo, number: record.number, payload: payload)
        var updated = record
        updated.posted = posted
        updated.bodyDraft = body
        await store.save(record: updated)
        Log.info("게시 완료 \(record.prKey) event=\(event.rawValue) 코멘트 \(payload.comments.count)건", "engine")
        return posted
    }
}
