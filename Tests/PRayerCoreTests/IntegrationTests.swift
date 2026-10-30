import XCTest
@testable import PRayerCore

/// 실제 gh / Claude 를 호출하는 통합 테스트. 토큰을 쓰므로 환경변수로만 실행한다.
///   PRAYER_INTEGRATION=1 xcodebuild ... test          → GitHub 읽기 경로만
///   PRAYER_INTEGRATION=1 PRAYER_REVIEW_PR=<번호> ...    → 실제 리뷰 1건까지
final class IntegrationTests: XCTestCase {
    /// 통합 테스트가 실제로 조회할 레포. `PRAYER_TEST_REPO=owner/name` 으로 준다.
    ///
    /// 여기에 진짜 레포명을 박을 수 없다 — **공개 저장소**라 사내 레포명이 커밋에 남는다.
    /// 그렇다고 가짜 이름만 두면 `--review` 같은 실측 경로가 통째로 안 돈다(실제로 끊겨 있었다).
    /// 그래서 기본값은 가짜로 두고, 각자 `Local.env` 에 자기 레포를 적게 한다(커밋되지 않는다).
    private var repo: RepoID {
        let raw = ProcessInfo.processInfo.environment["PRAYER_TEST_REPO"] ?? "acme/sample-ios"
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return RepoID(owner: "acme", name: "sample-ios") }
        return RepoID(owner: parts[0], name: parts[1])
    }
    private var client: GitHubClient { GitHubClient(ghPath: "/opt/homebrew/bin/gh") }

    private func requireIntegration() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRAYER_INTEGRATION"] == "1",
                          "PRAYER_INTEGRATION=1 일 때만 실행합니다.")
    }

    /// 소스 트리의 Resources 를 쓴다(테스트 번들에는 없다). 지침은 앱처럼 기본 규칙 + 사용자 규칙 + 앱 형식 규칙을
    /// 이어 임시 파일로 쓴다. 사용자 규칙은 `PRAYER_REVIEW_RULES=<파일>` 로 준다(없으면 규칙 없음).
    private func resources() throws -> (guidePath: String, guide: String, schemaPath: String, schema: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let base = try String(contentsOf: root.appendingPathComponent("Resources/review.md"), encoding: .utf8)
        let format = try String(contentsOf: root.appendingPathComponent("Resources/review-format.md"), encoding: .utf8)
        var rules = ""
        if let path = ProcessInfo.processInfo.environment["PRAYER_REVIEW_RULES"], !path.isEmpty {
            rules = try String(contentsOfFile: path, encoding: .utf8)
        }
        let guide = ReviewGuideText.compose(base: base, format: format, userRules: rules)
        let guideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prayer-review-guide-\(UUID().uuidString).md")
        try guide.write(to: guideURL, atomically: true, encoding: .utf8)
        let schemaURL = root.appendingPathComponent("Resources/schema.json")
        return (guideURL.path,
                guide,
                schemaURL.path,
                try String(contentsOf: schemaURL, encoding: .utf8))
    }

    /// PR 스냅샷 전체 흐름 — 가벼운 클론(https + gh 인증) → 리뷰할 PR 의 파일 받기(진행) → 워크트리 → 다음 PR.
    /// 실제로 받으므로(큰 레포라도 얕게 받아 수십 초) 통합 테스트로만 돈다. 받은 것은 임시 폴더에 두고 끝나면 지운다.
    func testReviewCloneEndToEnd() async throws {
        try requireIntegration()
        let prs = try await client.pullRequests(repos: [repo]).prs
        guard let first = prs.first else { throw XCTSkip("열린 PR 이 없습니다") }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("prayer-clone-it-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ProgressRecorder()

        let started = Date()
        let clone = try await ReviewCloner(ghPath: client.ghPath, host: client.host)
            .clone(repo, base: base) { recorder.add($0) }
        print("클론 \(Int(Date().timeIntervalSince(started)))초 · \(ByteSizeText.short(ReviewClone.size(of: repo, base: base)))")
        XCTAssertTrue(ReviewClone.exists(repo, base: base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReviewClone.stagingPath(for: repo, base: base).path))
        XCTAssertTrue(recorder.stages.contains(.receiving), "클론 진행을 못 읽었습니다")

        let manager = WorktreeManager()
        let prepareStarted = Date()
        let prepared = try await manager.prepare(repoPath: clone.path, number: first.number, headSha: first.headRefOid,
                                                 repo: repo, onProgress: { recorder.add($0) })
        print("#\(first.number) 워크트리 \(Int(Date().timeIntervalSince(prepareStarted)))초 · 진행 \(recorder.count)번")
        let files = try FileManager.default.contentsOfDirectory(atPath: prepared.path.path)
        XCTAssertGreaterThan(files.count, 1, "워크트리에 파일이 없습니다")
        XCTAssertTrue(recorder.stages.contains(.updating), "체크아웃 진행을 못 읽었습니다")
        await manager.release(prepared)

        if let second = prs.dropFirst().first {
            let againStarted = Date()
            let again = try await manager.prepare(repoPath: clone.path, number: second.number, headSha: second.headRefOid, repo: repo)
            print("#\(second.number) 재사용 \(Int(Date().timeIntervalSince(againStarted)))초")
            XCTAssertTrue(again.reused)
            await manager.release(again)
        }
    }

    func testAccountAndScopes() async throws {
        try requireIntegration()
        let account = try await client.account()
        XCTAssertFalse(account.login.isEmpty)
        XCTAssertTrue(account.hasRequiredScopes, "repo, read:org 스코프가 필요합니다: \(account.scopes)")
    }

    func testPullRequestListShape() async throws {
        try requireIntegration()
        let result = try await client.pullRequests(repos: [repo])
        do {
            XCTAssertFalse(result.prs.isEmpty, "열린 PR 이 하나도 없습니다")
            for pr in result.prs {
                XCTAssertEqual(pr.repo, repo)
                XCTAssertFalse(pr.headRefOid.isEmpty, "#\(pr.number) headRefOid 없음")
                XCTAssertFalse(pr.nodeID.isEmpty)
                XCTAssertTrue(pr.isOpen)
            }
            // CODEOWNERS 로 리뷰어가 자동 등록되는 레포를 가정한다.
            XCTAssertTrue(result.prs.contains { $0.viewerHasReviewRequest || $0.viewerDidAuthor || $0.viewerHasSubmittedReview },
                          "리뷰 요청·작성·리뷰 이력이 전혀 없습니다")
            print("PR \(result.prs.count)건, rate 잔여 \(result.rateRemaining.map(String.init) ?? "?")")
        }
    }

    /// blocker 회귀: 조직 소유 레포가 목록에 잡히는지(ownerAffiliations 누락 시 0건이었다).
    func testViewerRepositoriesIncludeOrganizationRepos() async throws {
        try requireIntegration()
        let result = try await client.viewerRepositories()
        XCTAssertFalse(result.repos.isEmpty)
        let orgRepos = result.repos.filter { $0.repo.owner == "acme" }
        XCTAssertFalse(orgRepos.isEmpty, "조직 레포가 하나도 없습니다 — ownerAffiliations 확인 필요")
        print("레포 \(result.repos.count)건 (전체 \(result.totalCount.map(String.init) ?? "?"), 잘림 \(result.truncated)), acme \(orgRepos.count)건, org \(result.organizations.count)개")
        // 목록에 없더라도 이름으로 직접 확인할 수 있어야 한다.
        let direct = try await client.repository(repo)
        XCTAssertEqual(direct?.repo, repo)
        print("단건 조회: \(direct?.repo.full ?? "없음") 기본 브랜치 \(direct?.defaultBranch ?? "?") 권한 \(direct?.permission ?? "?")")
    }

    func testDiffFetchAndParse() async throws {
        try requireIntegration()
        let prs = try await client.pullRequests(repos: [repo]).prs
        guard let pr = prs.min(by: { $0.changedLines < $1.changedLines }) else {
            return XCTFail("PR 없음")
        }
        do {
            let text = try await client.diff(pr.repo, number: pr.number)
            XCTAssertFalse(text.isEmpty)
            let parsed = DiffParser.parse(text, excluding: ["*.pbxproj"])
            print("#\(pr.number) 파일 \(parsed.files.count)개 · 제외 \(parsed.excludedFiles.count)개 · \(parsed.changedLines)줄")
            // 파싱된 줄 번호가 실제 diff 와 어긋나지 않는지: hunk 헤더 없는 파일이 없어야 한다.
            for file in parsed.files where !file.isBinary {
                XCTAssertTrue(file.lines.contains { $0.kind == .hunk }, "\(file.path) 에 hunk 헤더가 없습니다")
            }
        }
    }

    /// 코멘트 설명 실측. PRAYER_EXPLAIN_PR=<번호>
    func testExplainPipeline() async throws {
        try requireIntegration()
        guard let numberText = ProcessInfo.processInfo.environment["PRAYER_EXPLAIN_PR"],
              let number = Int(numberText) else {
            throw XCTSkip("PRAYER_EXPLAIN_PR=<번호> 가 필요합니다.")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = try resources()
        guard let pr = try await client.pullRequest(repo, number: number) else {
            return XCTFail("PR #\(number) 를 찾지 못했습니다")
        }
        guard let thread = pr.threads.first(where: { !$0.isResolved && $0.path != nil }) ?? pr.threads.first else {
            throw XCTSkip("사람 리뷰 코멘트가 없습니다.")
        }
        let explainGuide = root.appendingPathComponent("Resources/explain.md")
        let explainSchema = root.appendingPathComponent("Resources/explain-schema.json")
        let config = ReviewEngineConfig(settings: Settings.default,
                                        guidePath: resource.guidePath,
                                        guideText: resource.guide,
                                        schemaPath: resource.schemaPath,
                                        schemaText: resource.schema,
                                        explainGuidePath: explainGuide.path,
                                        explainGuideText: try String(contentsOf: explainGuide, encoding: .utf8),
                                        explainSchemaPath: explainSchema.path,
                                        explainSchemaText: try String(contentsOf: explainSchema, encoding: .utf8))
        let engine = ReviewEngine(github: client, claude: ClaudeRunner(), store: Store(), config: config)
        // 설명은 캐시된 diff 만 쓴다. 없으면 먼저 받아 둔다.
        _ = try? await engine.prepare(pr: pr)
        let outcome = try await engine.explain(pr: pr, target: ExplainTarget(thread: thread))
        if let failure = outcome.failureMessage { return XCTFail("설명 실패: \(failure)") }
        guard let explanation = outcome.explanation else { return XCTFail("설명이 없습니다") }
        print("=== 코멘트 설명 (\(thread.path ?? "-"):\(thread.line ?? 0)) ===")
        print("원문: \(thread.comments.first?.body.prefix(200) ?? "")")
        print("---")
        print("한 줄: \(explanation.point)")
        print("설명: \(explanation.detail)")
        print("할 일: \(explanation.action)")
        for term in explanation.terms { print("용어: \(term.term) — \(term.meaning)") }
        print("질문인가: \(explanation.isQuestion)")
        print("토큰 \(explanation.usage.billableTokens) · $\(explanation.usage.costUSD) · \(explanation.usage.durationMs / 1000)초")
        XCTAssertFalse(explanation.detail.isEmpty)
        XCTAssertLessThan(explanation.usage.billableTokens, 20_000)
    }

    /// 깊은 리뷰(워크트리 + 읽기 도구) 실측. PRAYER_DEEP_PR=<번호> PRAYER_DEEP_REPO=<로컬 클론 경로>
    func testDeepReviewPipeline() async throws {
        try requireIntegration()
        let env = ProcessInfo.processInfo.environment
        guard let numberText = env["PRAYER_DEEP_PR"], let number = Int(numberText),
              let repoPath = env["PRAYER_DEEP_REPO"] else {
            throw XCTSkip("PRAYER_DEEP_PR=<번호> PRAYER_DEEP_REPO=<경로> 가 필요합니다.")
        }
        let resource = try resources()
        guard let pr = try await client.pullRequest(repo, number: number) else {
            return XCTFail("PR #\(number) 를 찾지 못했습니다")
        }
        var settings = Settings.default
        if let model = env["PRAYER_DEEP_MODEL"] { settings.model = model }
        let config = ReviewEngineConfig(settings: settings,
                                        guidePath: resource.guidePath,
                                        guideText: resource.guide,
                                        schemaPath: resource.schemaPath,
                                        schemaText: resource.schema)
        let engine = ReviewEngine(github: client, claude: ClaudeRunner(), store: Store(), config: config)
        let started = Date()
        let outcome = try await engine.review(pr: pr, trigger: .manual, deepRepoPath: repoPath)
        let elapsed = Date().timeIntervalSince(started)
        if let failure = outcome.failureMessage { return XCTFail("깊은 리뷰 실패: \(failure)") }
        guard let record = outcome.record else { return XCTFail("기록이 없습니다") }
        let usage = record.usage
        print("=== 깊은 리뷰 #\(number) (\(settings.model)) ===")
        print("토큰: 입력 \(usage.inputTokens) + 캐시생성 \(usage.cacheCreationTokens) + 캐시읽기 \(usage.cacheReadTokens) + 출력 \(usage.outputTokens) = 청구 \(usage.billableTokens)")
        print("비용: $\(usage.costUSD) · 소요 \(Int(elapsed))초")
        print("verdict=\(record.output.verdict.rawValue) 코멘트 \(record.comments.count)건 우려 \(record.output.concerns.count)건")
        for comment in record.comments {
            print("  - \(comment.comment.path):\(comment.comment.line) [\(comment.comment.severity.rawValue)]")
            print("    \(comment.editedBody.prefix(120))")
            if let evidence = comment.comment.evidence {
                for item in evidence { print("    근거: \(item.path):\(item.line ?? 0) — \(item.note)") }
            }
        }
        XCTAssertFalse(record.output.summaryKo.isEmpty)
    }

    /// 실제 Claude 호출 1회. PRAYER_REVIEW_PR 로 PR 번호를 지정해야 실행된다.
    /// 여러 PR 을 한 번에 리뷰하고 **문체 규칙으로 채점**한다. 프롬프트를 고친 뒤
    /// "정말 원하는 결과가 나오나" 를 한 건씩 눈으로 보는 대신 같은 잣대로 잰다.
    ///
    ///     bash Scripts/test.sh --review-batch <번호>,<번호>,<번호>
    ///
    /// 결과는 `PRayer-eval` 데이터 폴더에 저장된다(test.sh 가 넣어 준다). 실제 앱의 초안을
    /// 건드리지 않기 위해서다 — 고치는 도중의 프롬프트로 만든 초안이 앱에 섞이면 안 된다.
    func testReviewBatch() async throws {
        try requireIntegration()
        let env = ProcessInfo.processInfo.environment
        guard let list = env["PRAYER_REVIEW_PRS"] else {
            throw XCTSkip("PRAYER_REVIEW_PRS=<번호,번호,…> 가 필요합니다.")
        }
        let numbers = list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !numbers.isEmpty else { throw XCTSkip("PR 번호를 읽지 못했습니다: \(list)") }
        let limit = max(1, Int(env["PRAYER_REVIEW_CONCURRENCY"] ?? "") ?? 4)
        let resource = try resources()
        // 실제로 쓰는 모델·effort 로 재려면 PRAYER_REVIEW_MODEL·PRAYER_REVIEW_EFFORT 를 준다(없으면 기본값 — sonnet).
        var settings = Settings.default
        if let model = env["PRAYER_REVIEW_MODEL"], !model.isEmpty { settings.model = model }
        if let effort = env["PRAYER_REVIEW_EFFORT"], !effort.isEmpty { settings.effort = effort }
        let config = ReviewEngineConfig(settings: settings,
                                        guidePath: resource.guidePath,
                                        guideText: resource.guide,
                                        schemaPath: resource.schemaPath,
                                        schemaText: resource.schema)
        let engine = ReviewEngine(github: client, claude: ClaudeRunner(), store: Store(), config: config)
        print("### 모델 \(settings.model) · effort \(settings.effort.isEmpty ? "기본" : settings.effort)")
        print("### 사용자 리뷰 규칙: \(env["PRAYER_REVIEW_RULES"] ?? "없음")")
        print("### 데이터 폴더: \(AppPaths.support.path)")
        print("### \(numbers.count)건 · 동시 \(limit)")

        struct Result: Sendable { let number: Int; let record: ReviewRecord?; let failure: String? }
        var results: [Result] = []
        // 한꺼번에 다 띄우면 사용 한도에 걸리기 쉽다. 몇 개씩만 동시에 돌린다.
        var pending = numbers[...]
        await withTaskGroup(of: Result.self) { group in
            func launch(_ number: Int) {
                group.addTask { [client, repo] in
                    do {
                        guard let pr = try await client.pullRequest(repo, number: number) else {
                            return Result(number: number, record: nil, failure: "PR 을 찾지 못했습니다")
                        }
                        let outcome = try await engine.review(pr: pr, trigger: .manual)
                        return Result(number: number, record: outcome.record, failure: outcome.failureMessage)
                    } catch {
                        return Result(number: number, record: nil, failure: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<min(limit, pending.count) { launch(pending.removeFirst()) }
            for await result in group {
                results.append(result)
                if let next = pending.first { pending.removeFirst(); launch(next) }
            }
        }

        var hard = 0, soft = 0, tokens = 0
        for result in results.sorted(by: { $0.number < $1.number }) {
            print("\n### ─── #\(result.number) ───")
            guard let record = result.record else {
                print("### 실패: \(result.failure ?? "원인 불명")")
                hard += 1
                continue
            }
            let o = record.output
            tokens += record.usage.billableTokens
            print("### verdict=\(o.verdict.rawValue) 코멘트=\(record.comments.count) 우려=\(o.concerns.count) 질문=\((o.questionsForAuthor ?? []).count) 토큰=\(record.usage.billableTokens) \(record.usage.durationMs / 1000)초")
            print("### 요약: \(o.summaryKo)")
            for strength in o.strengths { print("### 잘된점: \(strength)") }
            if let note = o.concernsNoteKo { print("### 우려안내: \(note)") }
            if let note = o.questionsNoteKo { print("### 질문안내: \(note)") }
            for concern in o.concerns { print("###   우려[\(concern.severity.rawValue)] \(concern.title)") }
            for state in record.comments {
                let c = state.comment
                let body = c.body.replacingOccurrences(of: "\n", with: " ")
                print("###   코멘트[\(ReviewImportance(severity: c.severity).label)·\(state.anchorStatus.rawValue)] \(c.path):\(c.line) — \(body.prefix(220))")
            }
            for question in o.questionsForAuthor ?? [] { print("###   질문 \(question.question)") }
            let issues = ReviewStyleCheck.check(o)
            for issue in issues { print("### \(issue)") }
            hard += issues.filter { $0.level == .hard }.count
            soft += issues.filter { $0.level == .soft }.count
            if issues.isEmpty { print("### ✓ 규칙 통과") }
        }
        print("\n### 채점: 위반 \(hard)건(✗) · 확인 \(soft)건(△) · 토큰 합계 \(tokens)")
    }

    func testFullReviewPipeline() async throws {
        try requireIntegration()
        guard let numberText = ProcessInfo.processInfo.environment["PRAYER_REVIEW_PR"],
              let number = Int(numberText) else {
            throw XCTSkip("PRAYER_REVIEW_PR=<번호> 가 필요합니다.")
        }
        let resource = try resources()
        guard let pr = try await client.pullRequest(repo, number: number) else {
            return XCTFail("PR #\(number) 를 찾지 못했습니다")
        }
        do {
            var settings = Settings.default
            // effort 를 바꿔 가며 잴 때 쓴다(PRAYER_REVIEW_EFFORT=low|medium|high|xhigh|max). 없으면 기본값.
            settings.effort = ProcessInfo.processInfo.environment["PRAYER_REVIEW_EFFORT"] ?? ""
            // 모델을 바꿔 잴 때(PRAYER_REVIEW_MODEL=opus·codex:sol 등). Codex 면 이 맥의 codex 에 목록을 물어 계열을 푼다.
            var codexCatalog: CodexCatalog?
            if let modelName = ProcessInfo.processInfo.environment["PRAYER_REVIEW_MODEL"], !modelName.isEmpty {
                settings.model = modelName
                if ReviewEngineKind(model: modelName) == .codex {
                    let codex = CodexRunner()
                    guard let path = await codex.discoverPath(),
                          let version = await codex.status(path: path).version else {
                        throw XCTSkip("이 맥에서 codex 를 찾지 못했습니다.")
                    }
                    settings.codexPath = path
                    codexCatalog = await codex.probeCatalog(path: path, version: version)
                    print("codex \(version) 모델: \(codexCatalog?.models.map(\.id) ?? [])")
                }
            }
            let config = ReviewEngineConfig(settings: settings,
                                            guidePath: resource.guidePath,
                                            guideText: resource.guide,
                                            schemaPath: resource.schemaPath,
                                            schemaText: resource.schema,
                                            codexCatalog: codexCatalog)
            let engine = ReviewEngine(github: client,
                                      claude: ClaudeRunner(),
                                      store: Store(),
                                      config: config)
            let prep = try await engine.prepare(pr: pr)
            print("프롬프트 \(prep.prompt.count)자 · 예상 \(prep.estimatedTokens)토큰")
            XCTAssertTrue(prep.prompt.contains("<pr_data>"))

            let outcome = try await engine.review(pr: pr, trigger: ReviewRecord.Trigger.manual, preparation: prep)
            if let failure = outcome.failureMessage {
                return XCTFail("리뷰 실패: \(failure)")
            }
            guard let record = outcome.record else {
                return XCTFail("기록이 없습니다")
            }
            print("verdict=\(record.output.verdict.rawValue) 코멘트=\(record.comments.count) 토큰=\(record.usage.billableTokens) 비용=\(record.usage.costUSD) \(record.usage.durationMs / 1000)초")
            for state in record.comments {
                print("  [\(state.anchorStatus.rawValue)] \(state.comment.path):\(state.comment.line) \(state.comment.side.rawValue) (\(state.editedBody.count)자) \(state.editedBody.prefix(60))")
            }
            for issue in record.validationIssues {
                print("  검증: \(issue.message)")
            }
            // 게시 가능한 코멘트는 앵커가 확정된 것뿐이어야 한다.
            for state in record.comments where state.isPostable {
                XCTAssertNotEqual(state.anchorStatus, AnchorStatus.unresolved)
            }
            XCTAssertLessThanOrEqual(record.comments.count, ReviewLimits.schemaMaxComments)
            XCTAssertFalse(record.output.summaryKo.isEmpty)
        }
    }
}

extension IntegrationTests {
    /// 워크트리 풀 재사용 실측. PRAYER_POOL_REPO=<로컬 클론> 로 실행한다(토큰 소모 없음).
    func testWorktreePoolReuse() async throws {
        try requireIntegration()
        guard let repoPath = ProcessInfo.processInfo.environment["PRAYER_POOL_REPO"] else {
            throw XCTSkip("PRAYER_POOL_REPO=<경로> 가 필요합니다.")
        }
        let manager = WorktreeManager()

        // 1) 상위 폴더를 고르면 분명하게 실패해야 한다.
        let parent = (repoPath as NSString).deletingLastPathComponent
        do {
            _ = try await manager.repositoryRoot(of: parent)
            // 부모가 우연히 저장소일 수도 있으니 실패하지 않으면 넘어간다.
            print("(상위 폴더도 저장소여서 검증 생략: \(parent))")
        } catch {
            print("상위 폴더 거부 확인: \(error.localizedDescription.split(separator: "\n").first ?? "")")
        }

        let root = try await manager.repositoryRoot(of: repoPath)
        let matches = await manager.originMatches(root: root, repo: repo)
        print("저장소 최상위: \(root) · origin 일치: \(matches)")
        XCTAssertTrue(matches)

        // 레포의 열린 PR 앞 두 건으로 잰다(번호를 박으면 그 레포에서만 돈다).
        let open = try await client.pullRequests(repos: [repo]).prs
        guard open.count >= 2 else {
            throw XCTSkip("검증에 쓸 열린 PR 이 두 건 이상 필요합니다.")
        }
        let first = open[0], second = open[1]

        // 2) 첫 준비 = 생성
        var started = Date()
        let a = try await manager.prepare(repoPath: repoPath, number: first.number, headSha: first.headRefOid)
        let createSeconds = Date().timeIntervalSince(started)
        print("1차(\(a.reused ? "재사용" : "생성")) \(a.path.lastPathComponent) — \(String(format: "%.1f", createSeconds))초")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path.appendingPathComponent(".prayer-lock").path))

        // 3) 락이 잡혀 있으면 다음 준비는 **다른** 워크트리를 써야 한다.
        let b = try await manager.prepare(repoPath: repoPath, number: second.number, headSha: second.headRefOid)
        print("2차(\(b.reused ? "재사용" : "생성")) \(b.path.lastPathComponent)")
        XCTAssertNotEqual(a.path, b.path, "락이 걸린 워크트리를 또 쓰면 안 된다")

        await manager.release(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path.appendingPathComponent(".prayer-lock").path))

        // 4) 반납했으니 같은 자리를 재사용하고, 그때는 바뀐 파일만 갱신돼 훨씬 빨라야 한다.
        started = Date()
        let c = try await manager.prepare(repoPath: repoPath, number: second.number, headSha: second.headRefOid)
        let reuseSeconds = Date().timeIntervalSince(started)
        print("3차(\(c.reused ? "재사용" : "생성")) \(c.path.lastPathComponent) — \(String(format: "%.1f", reuseSeconds))초")
        XCTAssertEqual(c.path, a.path)
        XCTAssertTrue(c.reused)

        await manager.release(b)
        await manager.release(c)
        print("생성 \(String(format: "%.1f", createSeconds))초 → 재사용 \(String(format: "%.1f", reuseSeconds))초")
    }
}

extension IntegrationTests {
    /// 앱이 리뷰 중 죽은 상황을 만들어 결과 수확을 검증한다. 토큰을 쓰지 않는다.
    /// PRAYER_HARVEST_PR=<이미 초안이 있는 PR 번호>
    func testSpoolHarvest() async throws {
        try requireIntegration()
        guard let numberText = ProcessInfo.processInfo.environment["PRAYER_HARVEST_PR"],
              let number = Int(numberText) else {
            throw XCTSkip("PRAYER_HARVEST_PR=<번호> 가 필요합니다.")
        }
        let store = Store()
        guard let pr = try await client.pullRequest(repo, number: number) else {
            return XCTFail("PR #\(number) 를 찾지 못했습니다")
        }
        guard let existing = await store.loadRecord(repo: repo, number: number, headSha: pr.headRefOid) else {
            throw XCTSkip("이 PR 의 초안이 없어 합성 결과를 만들 수 없습니다.")
        }
        // 리뷰가 시작되면 diff 가 캐시된다. 수확은 그 캐시로 검증한다.
        let resource = try resources()
        let config = ReviewEngineConfig(settings: Settings.default,
                                        guidePath: resource.guidePath, guideText: resource.guide,
                                        schemaPath: resource.schemaPath, schemaText: resource.schema)
        let engine = ReviewEngine(github: client, claude: ClaudeRunner(), store: store, config: config)
        _ = try await engine.prepare(pr: pr)

        // 1) 앱이 죽은 뒤의 상태를 그대로 만든다: job.json + 완전한 stdout.
        let spool = ReviewSpool()
        let id = "harvest-test-\(number)"
        let directory = await spool.begin(job: SpooledJob(id: id, pr: pr, trigger: .manual, deep: false,
                                                          model: "sonnet", phase: .running))
        let outputJSON = try JSONEncoder().encode(existing.output)
        let cliShaped: [String: Any] = [
            "is_error": false,
            "result": String(data: outputJSON, encoding: .utf8) ?? "",
            "duration_ms": 1234,
            "total_cost_usd": 0.111,
            "usage": ["input_tokens": 1000, "output_tokens": 2000,
                      "cache_creation_input_tokens": 10, "cache_read_input_tokens": 20],
        ]
        let stdout = try JSONSerialization.data(withJSONObject: cliShaped)
        try stdout.write(to: directory.appendingPathComponent("stdout"))
        let pendingBefore = await spool.pending()
        XCTAssertFalse(pendingBefore.isEmpty)

        // 2) 수확
        let results = await engine.harvestSpooledJobs()
        let recovered = results.compactMap { result -> ReviewRecord? in
            if case .recovered(let record) = result { return record }
            return nil
        }
        for result in results {
            if case .lost(let job, let reason) = result { print("잃음: #\(job.pr.number) \(reason)") }
            if case .stillRunning(let job) = result { print("계속 돌고 있음: #\(job.pr.number)") }
        }
        XCTAssertEqual(recovered.count, 1, "완전한 결과 파일은 초안으로 살아나야 한다")
        if let record = recovered.first {
            print("수확 성공: #\(record.number) 코멘트 \(record.comments.count)건 토큰 \(record.usage.billableTokens)")
            XCTAssertEqual(record.number, number)
            XCTAssertEqual(record.usage.billableTokens, 3010)   // 1000 + 10 + 2000
        }
        // 3) 수확 후에는 스풀이 비어 있어야 한다(다음 실행에서 또 수확하면 안 된다).
        let pendingAfter = await spool.pending()
        XCTAssertTrue(pendingAfter.isEmpty)

        // 4) 잘린 결과는 "잃음" 으로 처리돼야 한다.
        let broken = await spool.begin(job: SpooledJob(id: "harvest-broken-\(number)", pr: pr,
                                                       trigger: .manual, deep: false, model: "sonnet"))
        try Data("{\"is_error\":false,\"result\":\"{\\\"verdict\\\"".utf8)
            .write(to: broken.appendingPathComponent("stdout"))
        let second = await engine.harvestSpooledJobs()
        XCTAssertTrue(second.contains { if case .lost = $0 { return true } else { return false } })
        let pendingFinal = await spool.pending()
        XCTAssertTrue(pendingFinal.isEmpty)
    }

    /// 실제 PR 로 "이미 언급됨" 대조를 돌려 본다.
    ///   Scripts/test.sh --relevance <번호>
    func testRelevancePipeline() async throws {
        try requireIntegration()
        guard let numberText = ProcessInfo.processInfo.environment["PRAYER_RELEVANCE_PR"],
              let number = Int(numberText) else {
            throw XCTSkip("PRAYER_RELEVANCE_PR=<번호> 가 필요합니다.")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = try resources()
        guard let pr = try await client.pullRequest(repo, number: number) else {
            return XCTFail("PR #\(number) 를 찾지 못했습니다")
        }
        // 저장된 초안에서 "이미 언급됨" 으로 표시된 코멘트를 찾아 그것으로 대조한다.
        let records = await Store().loadRecords()
        guard let record = records["\(repo.full)#\(number)"]?.first,
              let target = record.comments.first(where: { $0.comment.isDuplicate })?.comment
                  ?? record.comments.first?.comment else {
            throw XCTSkip("이 PR 의 저장된 리뷰 초안이 없습니다.")
        }
        let guide = root.appendingPathComponent("Resources/relevance.md")
        let schema = root.appendingPathComponent("Resources/relevance-schema.json")
        let config = ReviewEngineConfig(settings: Settings.default,
                                        guidePath: resource.guidePath,
                                        guideText: resource.guide,
                                        schemaPath: resource.schemaPath,
                                        schemaText: resource.schema,
                                        relevanceGuidePath: guide.path,
                                        relevanceGuideText: try String(contentsOf: guide, encoding: .utf8),
                                        relevanceSchemaPath: schema.path,
                                        relevanceSchemaText: try String(contentsOf: schema, encoding: .utf8))
        let engine = ReviewEngine(github: client, claude: ClaudeRunner(), store: Store(), config: config)
        let candidates = RelatedDiscussionBuilder.candidates(pr: pr, path: target.path,
                                                             line: target.line, prAuthor: pr.author)
        print("### 후보 \(candidates.messageCount)건 (스레드 \(candidates.threads.count)개)")
        let outcome = try await engine.relevance(
            pr: pr,
            key: "live-\(number)",
            target: RelevancePromptBuilder.Target(path: target.path, line: target.line,
                                                  body: target.body, rationale: target.rationaleKo),
            discussion: candidates)
        if let message = outcome.failureMessage { return XCTFail("대조 실패: \(message)") }
        let result = try XCTUnwrap(outcome.relevance)
        let bodies = RelatedDiscussionBuilder.messagesByID(candidates)
        print("### 판정: \(result.verdict.label) · 토큰 \(result.usage.billableTokens) · $\(String(format: "%.3f", result.usage.costUSD))")
        print("### 요약: \(result.summaryKo)")
        for match in result.matches {
            let author = bodies[match.messageID]?.author ?? "?"
            print("###  \(match.messageID) \(author) [\(match.relevance.label)] \(match.whyKo)")
            for quote in match.quotes { print("###    칠할 문구: \(quote)") }
        }
        // 인용은 원문에 그대로 있어야 한다(엔진이 이미 걸러 내지만 계약을 여기서도 못 박는다).
        for match in result.matches {
            let body = try XCTUnwrap(bodies[match.messageID]?.body)
            for quote in match.quotes {
                XCTAssertTrue(body.contains(quote), "원문에 없는 인용: \(quote)")
            }
        }
    }

    /// 저장된 초안의 지적 하나를, 그 뒤에 올라온 커밋·코멘트와 실제로 대조해 본다.
    func testRecheckPipeline() async throws {
        try requireIntegration()
        guard let numberText = ProcessInfo.processInfo.environment["PRAYER_RECHECK_PR"],
              let number = Int(numberText) else {
            throw XCTSkip("PRAYER_RECHECK_PR=<번호> 가 필요합니다.")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = try resources()
        guard let pr = try await client.pullRequest(repo, number: number) else {
            return XCTFail("PR #\(number) 를 찾지 못했습니다")
        }
        let records = await Store().loadRecords()
        guard let record = records["\(repo.full)#\(number)"]?.first else {
            throw XCTSkip("이 PR 의 저장된 리뷰 초안이 없습니다.")
        }
        let delta = RecheckDeltaBuilder.compute(pr: pr, record: record)
        print("### 리뷰 커밋 \(record.shortHead) → 지금 \(pr.headRefOid.prefix(7))")
        print("### 새 커밋 \(delta.newCommits.count)개 · 새 코멘트 \(delta.newComments.count)건 · 경계정확=\(delta.commitBoundaryExact)")
        guard !delta.isEmpty else {
            throw XCTSkip("리뷰 이후 새 커밋도 새 코멘트도 없습니다 — 대조할 것이 없습니다.")
        }
        guard let item = record.output.draftComments.first ?? record.output.concerns.first.map({
            DraftComment(issueKey: $0.issueKey, path: $0.path, line: $0.line ?? 1, side: .right,
                         body: $0.title, severity: $0.severity, anchorText: $0.anchorText ?? "")
        }) else {
            throw XCTSkip("대조할 지적이 없습니다.")
        }
        let guide = root.appendingPathComponent("Resources/recheck.md")
        let schema = root.appendingPathComponent("Resources/recheck-schema.json")
        let config = ReviewEngineConfig(settings: Settings.default,
                                        guidePath: resource.guidePath,
                                        guideText: resource.guide,
                                        schemaPath: resource.schemaPath,
                                        schemaText: resource.schema,
                                        recheckGuidePath: guide.path,
                                        recheckGuideText: try String(contentsOf: guide, encoding: .utf8),
                                        recheckSchemaPath: schema.path,
                                        recheckSchemaText: try String(contentsOf: schema, encoding: .utf8))
        let engine = ReviewEngine(github: client, claude: ClaudeRunner(), store: Store(), config: config)
        var newDiff: String?
        if !delta.newCommits.isEmpty {
            newDiff = try? await client.compareDiff(repo, base: record.headSha, head: pr.headRefOid)
            print("### 비교 diff \((newDiff ?? "").count)자")
        }
        let outcome = try await engine.recheck(
            pr: pr, record: record, key: "live-recheck-\(number)",
            target: RecheckPromptBuilder.Target(kindLabel: "인라인 코멘트 초안",
                                                severity: item.severity.label,
                                                path: item.path, line: item.line,
                                                body: item.body, rationale: item.rationaleKo),
            delta: delta, newDiffText: newDiff)
        if let message = outcome.failureMessage { return XCTFail("다시 확인 실패: \(message)") }
        let result = try XCTUnwrap(outcome.result)
        print("### 판정: \(result.status.label) · 토큰 \(result.usage.billableTokens) · $\(String(format: "%.3f", result.usage.costUSD))")
        print("### 요약: \(result.summaryKo)")
        for evidence in result.evidence {
            print("###  [\(evidence.kind.rawValue)] \(evidence.ref) \(evidence.path ?? "")\(evidence.line.map { ":\($0)" } ?? "") — \(evidence.note)")
        }
        // 근거 없는 확신은 엔진이 이미 내리지만 계약을 여기서도 못 박는다.
        if result.evidence.isEmpty {
            XCTAssertTrue(result.status == .untouched || result.status == .cannotTell,
                          "근거가 없는데 \(result.status.rawValue) 로 남았습니다")
        }
    }
}


/// 진행 콜백은 다른 스레드에서 온다.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GitProgress] = []

    func add(_ progress: GitProgress) {
        lock.lock()
        items.append(progress)
        lock.unlock()
    }

    var stages: Set<GitProgress.Stage> {
        lock.lock()
        defer { lock.unlock() }
        return Set(items.map(\.stage))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}
