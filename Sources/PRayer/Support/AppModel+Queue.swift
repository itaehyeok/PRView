import Foundation
import AppKit
import PRayerCore

enum PostError: LocalizedError {
    /// 기준 커밋 뒤로 새 커밋이 올라왔다. 막는 것이 아니라 **물어볼 것** — 화면이 확인 창을 띄운다.
    case headDrift(HeadDrift)
    /// 리뷰한 커밋이 강제 푸시로 빠져 인라인 코멘트를 붙일 곳이 없다. 물어볼 것도 없이 막는다.
    case reviewedCommitGone(String)
    /// 그 사이 머지됐거나 닫혔다.
    case closed(number: Int, state: String)
    case headUnknown(String)
    case engineMissing
    case api(String)

    /// 사용자가 고칠 것이 없고 **다시 누르면 되는** 실패인가.
    ///
    /// 연결이 끊겨 실패한 것과 권한이 없어 실패한 것은 할 일이 완전히 다르다.
    /// 둘을 같은 빨간 에러로 띄우면, 다시 누르면 그만인 일에 놀라고 진짜 문제는 가벼워진다.
    var isTransient: Bool {
        switch self {
        case .headUnknown(let message), .api(let message): return TransientFailure.isNetwork(message)
        case .headDrift, .reviewedCommitGone, .closed, .engineMissing: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .headDrift(let drift): return "새 커밋(\(drift.shortHead))이 올라와 게시하지 않았습니다. 아무것도 올리지 않았습니다."
        case .reviewedCommitGone(let sha):
            return "리뷰한 커밋(\(sha))이 PR 에서 사라져 인라인 코멘트를 붙일 곳이 없습니다. 아무것도 올리지 않았습니다. 다시 리뷰해 주세요."
        case .closed(let number, let state):
            return state == "MERGED"
                ? "#\(number) PR 은 이미 머지됐습니다. 아무것도 올리지 않았습니다."
                : "#\(number) PR 은 닫혔습니다. 아무것도 올리지 않았습니다."
        case .headUnknown(let message):
            // 사람이 할 일을 맨 앞에 둔다. 원문은 원인을 좇을 때만 필요하므로 괄호 안으로 민다.
            guard TransientFailure.isNetwork(message) else {
                return "현재 커밋을 확인할 수 없어 게시를 막았습니다: \(message)"
            }
            return "연결이 불안정해 게시하지 못했습니다 — 잠시 뒤 다시 시도해 주세요. "
                + "아무것도 올라가지 않았습니다. (\(message))"
        case .engineMissing: return "리뷰 설정(review.md / schema.json)을 찾을 수 없습니다."
        case .api(let message) where TransientFailure.isNetwork(message):
            return "연결이 불안정해 게시하지 못했습니다 — 잠시 뒤 다시 시도해 주세요. (\(message))"
        case .api(let message): return message
        }
    }
}

extension AppModel {
    /// 리뷰 실패 배너. 로그인이 끊긴 것이면 **다시 로그인**으로 가는 길을 함께 준다 —
    /// 원인을 알려 주기만 하고 길을 안 주면 사용자가 터미널 명령을 외워야 한다.
    func failureBanner(number: Int, message: String, engine: ReviewEngineKind = .claude) -> Banner {
        guard AuthFailure.isExpired(message) else {
            return Banner(kind: .error, message: "#\(number) 리뷰 실패: \(message)")
        }
        return Banner(kind: .error,
                      message: "\(engine.productName) 로그인이 끊겼습니다 — 다시 로그인하면 이어서 리뷰할 수 있습니다. (#\(number))",
                      actionTitle: "다시 로그인",
                      clearsOnEngineLogin: true) { [weak self] in
            self?.openEngineLogin(engine)
        }
    }

    /// 로그인이 끊겨 실패했으면 **그 자리에서** 엔진 상태를 다시 본다.
    ///
    /// 예전에는 앱을 켤 때 한 번만 확인해서, 세션이 만료된 뒤에도 툴바 표시등이 계속
    /// 초록이었다(실측). 리뷰는 실패하는데 화면은 정상이라고 말하는 상태가 이어졌다.
    func noteAuthFailureIfNeeded(_ message: String) {
        guard AuthFailure.isExpired(message) else { return }
        Task { [weak self] in await self?.checkEngines() }
    }

    /// 터미널을 열어 로그인 명령을 실행한다. 로그인 자체는 대화형이라 앱이 대신 못 한다.
    ///
    /// 온보딩·설정·툴바·실패 배너가 다 이걸 부른다. CLI 가 없으면 로그인 대신 설치로 안내한다 —
    /// 없는 경로로 로그인 창을 열면 "No such file or directory" 만 보고 끝난다(실측: 팀원 맥).
    func openEngineLogin(_ engine: ReviewEngineKind = .claude) {
        if engine == .codex { return openCodexLogin() }
        Task { [weak self] in
            guard let self else { return }
            // 방금 설치했거나 다른 곳에 깔려 있을 수 있다. 로그인 창을 열기 전에 한 번 더 찾는다.
            if !FileManager.default.isExecutableFile(atPath: settings.claudePath) {
                await checkClaude()
            }
            guard FileManager.default.isExecutableFile(atPath: settings.claudePath) else {
                banner = Banner(kind: .warning,
                                message: "이 맥에서 Claude Code CLI 를 찾지 못했습니다. 데스크톱 앱과 별개로 터미널용 CLI 가 있어야 합니다.",
                                actionTitle: "터미널에서 설치") { [weak self] in
                    self?.openEngineInstall()
                }
                return
            }
            if let problem = EngineLogin.open(path: settings.claudePath) {
                banner = Banner(kind: .error, message: problem)
                return
            }
            watchEngineLogin(result: EngineLogin.resultFile(EngineLogin.claudeLoginName))
        }
    }

    /// 공식 설치 스크립트를 터미널에서 돌리고 이어서 로그인한다. 끝나면 알아서 다시 찾는다.
    func openEngineInstall(_ engine: ReviewEngineKind = .claude) {
        if engine == .codex {
            if let problem = EngineLogin.openCodexInstall() {
                banner = Banner(kind: .error, message: problem)
                return
            }
            return watchCodexLogin(result: EngineLogin.resultFile(EngineLogin.codexInstallName))
        }
        if let problem = EngineLogin.openInstall() {
            banner = Banner(kind: .error, message: problem)
            return
        }
        watchEngineLogin(result: EngineLogin.resultFile(EngineLogin.claudeInstallName))
    }

    /// Codex 로그인 창. Claude 처럼 끝나기를 기다렸다가 상태를 다시 본다.
    private func openCodexLogin() {
        Task { [weak self] in
            guard let self else { return }
            if !FileManager.default.isExecutableFile(atPath: settings.codexPath) {
                await checkCodex(rediscover: true)
            }
            guard FileManager.default.isExecutableFile(atPath: settings.codexPath) else {
                banner = Banner(kind: .warning, message: "이 맥에서 Codex CLI 를 찾지 못했습니다.",
                                actionTitle: "터미널에서 설치") { [weak self] in
                    self?.openEngineInstall(.codex)
                }
                return
            }
            if let problem = EngineLogin.openCodex(path: settings.codexPath) {
                banner = Banner(kind: .error, message: problem)
                return
            }
            watchCodexLogin(result: EngineLogin.resultFile(EngineLogin.codexLoginName))
        }
    }

    /// Claude 의 기다림(`watchEngineLogin`)과 따로 둔다 — 두 창을 같이 열어도 서로의 기다림을 끊지 않게.
    private func watchCodexLogin(result url: URL) {
        codexLoginWatch?.cancel()
        Log.info("codex 로그인 창 열림 — 끝나기를 기다림", "app")
        codexLoginWatch = Task { [weak self] in
            let outcome = await LoginScript.waitForResult(at: url, timeout: Self.engineLoginTimeout)
            guard !Task.isCancelled, let self else { return }
            Log.info("codex 로그인 창 끝남: \(outcome)", "app")
            await self.checkCodex(rediscover: true)
            if outcome == .succeeded, self.engineReady(.codex) {
                await self.adoptReadyEngineIfNeeded()
                if self.banner?.clearsOnEngineLogin == true || self.banner == nil {
                    self.banner = Banner(kind: .info, message: "Codex 에 연결했습니다. 리뷰 모델에서 Codex 를 고를 수 있습니다.")
                }
            }
        }
    }

    /// 로그인 창을 이만큼 기다린다. 브라우저 로그인은 길어야 몇 분이다 — 그 뒤에 끝내도
    /// 앱으로 돌아오면 다시 확인하므로(`observeActivation`) 놓치지 않는다.
    private static let engineLoginTimeout: Duration = .seconds(600)

    /// 터미널 로그인 창이 끝나기를 기다린다. 그동안 로그인 안내는 "로그인하는 중" 으로 바꿔 둔다 —
    /// 다시 로그인 버튼이 그대로 있으면 눌렀는지 안 눌렀는지, 또 눌러야 하는지 헷갈린다.
    /// 창이 끝나면 그 자리에서 상태를 다시 본다. PRayer 로 돌아오지 않아도 안내가 닫힌다.
    private func watchEngineLogin(result url: URL) {
        engineLoginWatch?.cancel()
        engineLoginInProgress = true
        let startedAt = Date()
        if banner?.clearsOnEngineLogin == true {
            banner = Banner(kind: .info,
                            message: "터미널에서 로그인하는 중입니다 — 끝나면 이 안내는 저절로 닫힙니다.",
                            clearsOnEngineLogin: true,
                            inProgress: true)
        }
        Log.info("claude 로그인 창 열림 — 끝나기를 기다림", "app")
        engineLoginWatch = Task { [weak self] in
            let outcome = await LoginScript.waitForResult(at: url, timeout: Self.engineLoginTimeout)
            guard !Task.isCancelled, let self else { return }
            await self.finishEngineLogin(outcome, startedAt: startedAt)
        }
    }

    private func finishEngineLogin(_ outcome: LoginScript.Outcome, startedAt: Date) async {
        Log.info("claude 로그인 창 끝남: \(outcome)", "app")
        await checkClaude()
        // 확인하는 사이 로그인 창을 또 열었으면 새 창의 기다림이 맡는다.
        guard !Task.isCancelled else { return }
        engineLoginInProgress = false
        if outcome == .succeeded, claudeReady {
            // 로그인 명령이 성공했고 지금 로그인돼 있다. 상태 확인이 그 전 로그아웃을 못 봤어도
            // (`auth status` 가 만료를 모르는 경우) 다시 로그인한 것이 맞다.
            if !engineLoginRecovered(after: startedAt) {
                noteEngineLoginRecovered()
            }
            return
        }
        // 그 사이 앱으로 돌아와 다시 로그인한 것을 이미 확인했으면 그쪽 안내가 맞다.
        if engineLoginRecovered(after: startedAt) { return }
        // 기다리던 안내가 아직 떠 있을 때만 되돌린다. 사용자가 닫았거나 다른 안내로 바뀌었으면 그대로 둔다.
        guard banner?.inProgress == true, banner?.clearsOnEngineLogin == true else { return }
        banner = Banner(kind: .error,
                        message: "로그인이 끝나지 않았습니다 — 다시 로그인하면 이어서 리뷰할 수 있습니다.",
                        actionTitle: "다시 로그인",
                        clearsOnEngineLogin: true) { [weak self] in
            self?.openEngineLogin()
        }
    }

    // MARK: - 엔진

    /// 모델·effort 는 부르는 쪽이 이 PR 에 쓸 값으로 골라 준다(없으면 설정의 기본값).
    /// diff 리뷰와 전체 리뷰가 같은 값을 쓴다 — 예전에는 전체 리뷰에 따로 정한 모델·effort 가 있었다.
    /// - Parameter extraExclusions: 이번 리뷰에서만 뺄 파일(리뷰 전 확인 창의 "빼고 리뷰"). 설정에는 남기지 않는다.
    func makeEngine(modelOverride: String? = nil, effortOverride: String? = nil,
                    extraExclusions: [String] = []) -> ReviewEngine? {
        guard let guide = ResourceLoader.guide(userRules: settings.reviewRules),
              let schema = ResourceLoader.schema() else { return nil }
        let explainGuide = ResourceLoader.explainGuide()
        let explainSchema = ResourceLoader.explainSchema()
        let relevanceGuide = ResourceLoader.relevanceGuide()
        let relevanceSchema = ResourceLoader.relevanceSchema()
        let recheckGuide = ResourceLoader.recheckGuide()
        let recheckSchema = ResourceLoader.recheckSchema()
        var settings = self.settings
        if let modelOverride { settings.model = modelOverride }
        if let effortOverride { settings.effort = effortOverride }
        settings.excludedPathPatterns += extraExclusions.filter { !settings.excludedPathPatterns.contains($0) }
        let config = ReviewEngineConfig(settings: settings,
                                        guidePath: guide.path,
                                        guideText: guide.text,
                                        schemaPath: schema.path,
                                        schemaText: schema.text,
                                        explainGuidePath: explainGuide?.path,
                                        explainGuideText: explainGuide?.text,
                                        explainSchemaPath: explainSchema?.path,
                                        explainSchemaText: explainSchema?.text,
                                        relevanceGuidePath: relevanceGuide?.path,
                                        relevanceGuideText: relevanceGuide?.text,
                                        relevanceSchemaPath: relevanceSchema?.path,
                                        relevanceSchemaText: relevanceSchema?.text,
                                        recheckGuidePath: recheckGuide?.path,
                                        recheckGuideText: recheckGuide?.text,
                                        recheckSchemaPath: recheckSchema?.path,
                                        recheckSchemaText: recheckSchema?.text,
                                        codexCatalog: codexCatalog)
        return ReviewEngine(github: github, claude: claude, codex: codex, store: store, config: config)
    }

    // MARK: - 큐

    func updateJob(_ id: String, _ mutate: (inout ReviewJob) -> Void) {
        guard let index = jobs.lastIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    /// 수동 리뷰. 큐 맨 앞에 넣어 자동 잡보다 먼저 돌린다.
    ///
    /// 변경이 많으면 **넣기 전에** 묻는다. 예전에는 큐에 넣고 나서 배너로 알렸는데,
    /// 그때는 이미 돌기 시작한 뒤라 토큰을 쓴 다음이었다.
    ///
    /// 모델·effort 는 이 PR 에 고른 것이 있으면 그것, 없으면 기본값이다(모델·Effort 두 칸 — ReviewModelControl).
    ///
    /// 전체 리뷰인데 PR 스냅샷이 아직 없으면 먼저 묻는다(처음 한 번 클론 — `snapshotConfirmed` 는 그 확인을 거쳤다는 뜻).
    /// - Parameter skipPaths: 리뷰 전 확인 창의 답. nil 이면 아직 묻지 않았다 — 한 파일이 1,000줄 넘게 바뀌었으면 묻는다.
    ///   빈 배열은 "모두 리뷰", 값이 있으면 이번 리뷰에서만 그 파일을 뺀다.
    func reviewNow(pr: PullRequestInfo, deep: Bool = false, snapshotConfirmed: Bool = false, skipPaths: [String]? = nil) {
        guard pr.isOpen else {
            banner = Banner(kind: .warning, message: "닫힌 PR 은 리뷰할 수 없습니다.")
            return
        }
        if deep, !snapshotConfirmed, case .needsSnapshot(let missing) = reviewSource(for: pr.repo) {
            pendingSnapshotClone = PendingSnapshotClone(pr: pr, missingLinkedPath: missing)
            return
        }
        if skipPaths == nil {
            guard let diff = parsedDiff(for: pr) else {
                // 목록에서 바로 누르면 diff 를 아직 안 받았을 수 있다. 받아 본 뒤 다시 들어온다 — 못 받으면 묻지 않고 진행한다.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let loaded = await self.waitForDiff(for: pr)
                    self.reviewNow(pr: pr, deep: deep, snapshotConfirmed: true, skipPaths: loaded == nil ? [] : nil)
                }
                return
            }
            let files = SkippableFiles.find(in: diff)
            if !files.isEmpty {
                pendingSkipFiles = PendingSkipFiles(pr: pr, deep: deep, files: files, totalLines: diff.changedLines)
                return
            }
        }
        let skip = skipPaths ?? []
        let choice = reviewModelChoice(for: pr)
        let lines = parsedDiff(for: pr)?.applyingExclusions(settings.excludedPathPatterns + skip).changedLines
            ?? pr.changedLines
        if lines > settings.manualSizeWarnLines {
            pendingLargeReview = PendingLargeReview(pr: pr, lines: lines,
                                                    modelOverride: choice.model, effortOverride: choice.effort,
                                                    deep: deep, skipPaths: skip, fallbackModel: settings.model)
            return
        }
        enqueue(pr: pr, trigger: .manual, front: true,
                modelOverride: choice.model, effortOverride: choice.effort, deep: deep, skipPaths: skip)
    }

    /// 확인 창에서 "그대로 진행" 을 누른 뒤.
    func confirmPendingLargeReview() {
        guard let request = pendingLargeReview else { return }
        pendingLargeReview = nil
        enqueue(pr: request.pr, trigger: .manual, front: true,
                modelOverride: request.modelOverride, effortOverride: request.effortOverride, deep: request.deep,
                skipPaths: request.skipPaths)
        Task { await save() }
    }

    /// 리뷰 전 확인 창의 답. `skip` 이면 물은 파일을 이번 리뷰에서 빼고, `remember` 면 제외 경로에도 넣어 다음부터 묻지 않는다.
    func answerPendingSkipFiles(skip: Bool, remember: Bool) {
        guard let request = pendingSkipFiles else { return }
        pendingSkipFiles = nil
        let rules = request.files.map { ExclusionPattern.file($0.path) }
        var skipPaths: [String] = []
        if skip, remember {
            // 규칙이 되면 이번 리뷰에서도 저절로 빠진다.
            for rule in rules { addExclusion(rule) }
            banner = Banner(kind: .info,
                            message: "다음부터 이 파일 \(rules.count)개는 묻지 않고 뺍니다. 설정 › 대상 제외에서 지울 수 있습니다.")
        } else if skip {
            skipPaths = rules
        }
        // 변경이 많으면 이어서 그 확인 창이 뜬다. 앞 창이 내려가는 중에 다음 창을 올리면 SwiftUI 가 무시해서 잠깐 기다린다.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.reviewNow(pr: request.pr, deep: request.deep, snapshotConfirmed: true, skipPaths: skipPaths)
        }
    }

    func cancelPendingSkipFiles() {
        pendingSkipFiles = nil
    }

    func cancelPendingLargeReview() {
        pendingLargeReview = nil
    }

    // MARK: - PR 스냅샷

    /// 이 레포의 전체 리뷰가 읽을 클론. 파일 존재만 보니 화면에서 불러도 된다.
    func reviewSource(for repo: RepoID) -> ReviewSource {
        ReviewSource.current(for: repo, linkedPath: settings.deepReviewPath(for: repo))
    }

    /// 처음 받을 코드 크기 — 받아 둔 값이 있을 때만. 화면이 부르고, 채우는 건 `loadSnapshotCodeSize`.
    func snapshotCodeSize(for pr: PullRequestInfo) -> CodeSize? {
        snapshotCodeSizes["\(pr.repo.full)@\(pr.headRefOid)"]
    }

    /// 스냅샷이 없는 레포의 PR 이면 처음 받을 코드 크기를 GitHub 에 묻는다(확인 창과 같은 셈, 1초 남짓).
    /// 예전에는 어느 레포든 "큰 레포도 단 130MB" 라는 한 번 잰 숫자를 그대로 보였다. PR 마다 한 번만 묻는다.
    func loadSnapshotCodeSize(for pr: PullRequestInfo) async {
        guard case .needsSnapshot = reviewSource(for: pr.repo) else { return }
        let key = "\(pr.repo.full)@\(pr.headRefOid)"
        guard snapshotCodeSizes[key] == nil else { return }
        if DemoMode.isOn {
            // 데모 화면(README 캡처)에도 숫자가 보이게 — 실제로 묻지 않는다.
            snapshotCodeSizes[key] = CodeSize(files: 1_204, bytes: 183 * 1_024 * 1_024, truncated: false)
            return
        }
        guard let size = try? await github.codeSize(pr.repo, ref: pr.headRefOid) else { return }
        snapshotCodeSizes[key] = size
    }

    /// 받아 둔 스냅샷의 디스크 크기를 잰다. 파일이 수만 개라 메인 스레드 밖에서 — 화면은 지난 값을 먼저 보인다.
    func loadSnapshotDiskSize(for repo: RepoID) async {
        guard case .snapshot = reviewSource(for: repo) else { return }
        snapshotDiskSizes[repo.full] = await Task.detached { ReviewClone.size(of: repo) }.value
    }

    /// 확인 창에서 "클론하고 리뷰 시작" 을 누른 뒤. 클론은 잡이 돌 때 한다(진행이 리뷰 카드에 보인다).
    func confirmPendingSnapshotClone() {
        guard let request = pendingSnapshotClone else { return }
        pendingSnapshotClone = nil
        // 사라진 폴더의 연결은 거둔다 — 이제 이 레포는 PR 스냅샷으로 리뷰한다.
        if let missing = request.missingLinkedPath, settings.deepReviewRepoPaths[request.pr.repo.full] == missing {
            settings.deepReviewRepoPaths[request.pr.repo.full] = nil
            Log.info("사라진 클론 폴더 연결을 거둠 \(request.pr.repo.full): \(missing)", "snapshot")
            Task { await save() }
        }
        // 변경이 많으면 이어서 그 확인 창이 뜬다. 앞 창이 내려가는 중에 다음 창을 올리면 SwiftUI 가 무시해서
        // 잠깐 기다린다.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.reviewNow(pr: request.pr, deep: true, snapshotConfirmed: true)
        }
    }

    func cancelPendingSnapshotClone() {
        pendingSnapshotClone = nil
    }

    /// 전체 리뷰 잡이 읽을 클론 자리. PR 스냅샷이 없으면 여기서 받는다 — 확인은 잡을 넣기 전에 받았다.
    func prepareDeepRepo(for repo: RepoID, jobID: String) async throws -> String {
        switch reviewSource(for: repo) {
        case .linked(let path):
            return path
        case .snapshot(let path):
            try? await ReviewCloner(ghPath: settings.ghPath, host: settings.githubHost)
                .writeCredentialHelper(in: URL(fileURLWithPath: path))
            return path
        case .needsSnapshot:
            updateJob(jobID) {
                $0.enter(.cloningSnapshot)
                $0.progress = nil
                $0.clonedSnapshot = true
            }
            let cloner = ReviewCloner(ghPath: settings.ghPath, host: settings.githubHost)
            let url = try await cloner.clone(repo) { progress in
                Task { @MainActor [weak self] in
                    self?.updateJob(jobID) { $0.progress = progress }
                }
            }
            return url.path
        }
    }

    /// 리뷰가 돌거나 기다리는 동안은 그 레포의 클론을 치우지 않는다 — 쓰던 파일이 사라진다.
    func cloneInUse(_ repo: RepoID) -> Bool {
        jobs.contains { $0.repo == repo && $0.deep && $0.isActive }
    }

    /// PR 스냅샷을 지운다. 다음 전체 리뷰 때 처음처럼 확인 창을 거쳐 다시 받는다. 실패하면 이유를 돌려준다.
    func deleteReviewClone(_ repo: RepoID) async -> String? {
        if cloneInUse(repo) { return "이 레포를 리뷰하는 중이라 끝난 뒤 지울 수 있습니다." }
        do {
            // 파일이 수만 개라 메인 스레드 밖에서 지운다.
            try await Task.detached { try ReviewClone.delete(repo) }.value
            Log.info("PR 스냅샷 지움 \(repo.full)", "snapshot")
            return nil
        } catch {
            Log.error("PR 스냅샷 지우기 실패 \(repo.full): \(error.localizedDescription)", "snapshot")
            return "지우지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 확인 창에서 고른 정리 동작을 한다. 실패하면 이유를 돌려준다(누른 자리에 보인다).
    func perform(_ action: PendingCloneAction) async -> String? {
        switch action.kind {
        case .deleteSnapshot: return await deleteReviewClone(action.repo)
        case .unlink: return await unlinkClone(action.repo)
        }
    }

    /// 레포 관리 팝오버에서 고른 동작 — 팝오버가 닫혀 있을 수 있어 실패는 배너로 알린다.
    func performPendingCloneAction() {
        guard let action = pendingCloneAction else { return }
        pendingCloneAction = nil
        Task {
            if let problem = await perform(action) {
                banner = Banner(kind: .warning, message: problem)
            }
        }
    }

    /// 예전 버전에서 연결한 내 클론을 끊는다. 그 폴더는 그대로 두고, PRayer 가 그 옆에 만든 리뷰용 워크트리만
    /// 치운다(사용자 저장소의 `git worktree list` 에서도 빠진다). 앞으로 이 레포는 PR 스냅샷으로 리뷰한다.
    func unlinkClone(_ repo: RepoID) async -> String? {
        guard let path = settings.deepReviewPath(for: repo) else { return nil }
        if cloneInUse(repo) { return "이 레포를 리뷰하는 중이라 끝난 뒤 끊을 수 있습니다." }
        let removed = await WorktreeManager().removePool(repoPath: path)
        settings.deepReviewRepoPaths[repo.full] = nil
        await save()
        Log.info("클론 연결 끊음 \(repo.full): \(path) (리뷰 워크트리 \(removed)개 정리)", "snapshot")
        return nil
    }

    func reviewSelectedNow() {
        guard let pr = selectedPR else { return }
        reviewNow(pr: pr)
    }

    func enqueue(pr: PullRequestInfo, trigger: ReviewRecord.Trigger, front: Bool,
                 modelOverride: String? = nil, effortOverride: String? = nil, deep: Bool = false,
                 skipPaths: [String] = []) {
        if jobs.contains(where: { $0.id == pr.id && $0.isActive }) {
            // 이미 큐에 있어도 워커가 멈춰 있을 수 있다(예: 잠자기 후). 반드시 다시 깨운다.
            startWorkerIfNeeded()
            return
        }
        var job = ReviewJob(id: pr.id, repo: pr.repo, number: pr.number,
                            title: pr.title, pr: pr, trigger: trigger,
                            modelOverride: modelOverride, effortOverride: effortOverride, deep: deep,
                            skipPaths: skipPaths)
        job.engine = ReviewEngineKind(model: modelOverride ?? settings.model)
        if front, let firstQueued = jobs.firstIndex(where: { $0.state == .queued }) {
            jobs.insert(job, at: firstQueued)
        } else {
            jobs.append(job)
        }
        startWorkerIfNeeded()
    }

    func cancel(jobID: String) {
        guard let job = jobs.last(where: { $0.id == jobID && $0.isActive }) else { return }
        if job.state == .running {
            runningTask?.cancel()
        } else {
            updateJob(jobID) { $0.state = .cancelled }
        }
    }

    func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.workerLoop()
            self.workerTask = nil
        }
    }

    private func workerLoop() async {
        // 동시 1건. Claude 사용 한도가 터미널 개발 세션과 공유되므로 병렬로 늘리지 않는다.
        // 잠자기 중에도 계속 돈다 — 큐에 들어온 잡은 전부 사용자가 직접 누른 것이라
        // 맥이 잠들었다고 미룰 이유가 없다(자동 사전 리뷰가 있던 시절엔 그것만 건너뛰었다).
        while let next = jobs.first(where: { $0.state == .queued }) {
            updateJob(next.id) {
                $0.state = .running
                $0.startedAt = Date()
                $0.enter(.checkingPR)
                $0.claudeRange = self.claudeRange(for: next)
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(job: next)
            }
            runningTask = task
            await task.value
            runningTask = nil
        }
    }

    private func run(job: ReviewJob) async {
        // 폴링으로 목록이 교체돼도 실행할 수 있게 enqueue 시점 스냅샷을 쓴다.
        var pr = prs.first(where: { $0.id == job.id }) ?? job.pr
        // 시작 직전에 그 PR 을 다시 받는다. 목록은 폴링(기본 120초) 때 받은 것이라 그 사이 올라온
        // 커밋을 모르는데, diff 는 받는 순간의 최신을 주므로 옛 head 로 돌리면 diff 는 새 코드·
        // 워크트리와 기록은 옛 커밋을 가리키는 리뷰가 나온다. 조회가 실패하면 갖고 있던 것으로 돈다.
        if let fresh = try? await github.pullRequest(job.repo, number: job.number) {
            // 그 사이 닫혔거나 머지됐으면 실패가 아니라 건너뜀으로 처리한다.
            guard fresh.isOpen else {
                replace(with: fresh)
                updateJob(job.id) { $0.state = .cancelled; $0.message = "PR 이 \(fresh.state) 상태가 되어 건너뜁니다." }
                return
            }
            if fresh.headRefOid != pr.headRefOid {
                Log.info("리뷰 직전 새 커밋 #\(job.number) \(pr.shortHead) → \(fresh.shortHead)", "queue")
            }
            pr = fresh
            replace(with: fresh)
        }
        guard let engine = makeEngine(modelOverride: job.modelOverride, effortOverride: job.effortOverride,
                                      extraExclusions: job.skipPaths) else {
            let message = PostError.engineMissing.localizedDescription
            Log.error("리뷰 준비 실패 #\(job.number): \(message) (번들 \(Bundle.main.bundlePath))", "queue", problem: .reviewFailed)
            updateJob(job.id) { $0.state = .failed; $0.message = message }
            // 앱 번들에 리소스가 빠지면 모든 리뷰가 여기서 죽는다. 조용히 끝내지 않는다.
            banner = Banner(kind: .error, message: "#\(job.number) 리뷰를 시작하지 못했습니다: \(message)")
            if settings.notifyOnFailure {
                Notifier.reviewFailed(prKey: job.id)
            }
            return
        }
        Log.info("잡 실행 #\(job.number)\(job.deep ? " (전체 리뷰)" : "")", "queue")
        do {
            // 깊은 리뷰는 사용자가 '전체 리뷰' 로 고른 잡에서만 워크트리를 잡는다. 클론 자리는 엔진이 diff 를
            // 확인한 뒤에 묻는다 — PR 스냅샷이 없으면 그때 받는다(prepareDeepRepo).
            let repo = pr.repo
            let jobID = job.id
            var provider: (@Sendable () async throws -> String)?
            if job.deep {
                provider = { @Sendable [weak self] () async throws -> String in
                    guard let self else { throw CancellationError() }
                    return try await self.prepareDeepRepo(for: repo, jobID: jobID)
                }
            }
            let spoolID = "\(pr.repo.slug)-\(pr.number)-\(pr.headRefOid.prefix(12))"
            let outcome = try await engine.review(pr: pr, trigger: job.trigger, deepRepoProvider: provider,
                                                  onPhase: { phase in
                Task { @MainActor [weak self] in
                    self?.updateJob(jobID) {
                        guard $0.phase != phase else { return }
                        $0.enter(phase)
                        $0.progress = nil
                    }
                }
            }, onProgress: { progress in
                Task { @MainActor [weak self] in
                    self?.updateJob(jobID) { $0.progress = progress }
                }
            }, spoolID: spoolID)
            ledger = await store.loadLedger()
            if let record = outcome.record {
                remember(record)
                recordValidationProblems(record)
                updateJob(job.id) { $0.state = .done; $0.enter(.finished) }
                Log.info("잡 완료 #\(job.number) (\(record.usage.inputTokens + record.usage.outputTokens) 토큰)", "queue")
                // 리뷰가 끝났으면 로그인은 된 것이다. 상태 확인이 로그아웃을 못 잡은 맥에서도 안내를 거둔다.
                if banner?.clearsOnEngineLogin == true {
                    banner = nil
                }
                if settings.notifyOnReviewDone {
                    Notifier.reviewDone(record: record)
                }
            } else {
                let message = outcome.failureMessage ?? "리뷰에 실패했습니다."
                Log.error("잡 실패 #\(job.number): \(message)", "queue", problem: .reviewFailed)
                updateJob(job.id) { $0.state = .failed; $0.message = message; $0.phase = .failed }
                let jobEngine = ReviewEngineKind(model: job.modelOverride ?? settings.model)
                if job.trigger == .manual {
                    banner = failureBanner(number: job.number, message: message, engine: jobEngine)
                }
                noteAuthFailureIfNeeded(message)
                if outcome.limitReached {
                    Notifier.limitReached()
                    banner = Banner(kind: .error, message: "\(jobEngine.displayName) 사용 한도에 도달했습니다. 잠시 뒤에 다시 시도하세요.")
                } else if settings.notifyOnFailure {
                    Notifier.reviewFailed(prKey: job.id)
                }
            }
        } catch is CancellationError {
            updateJob(job.id) {
                // 처음 받던 클론을 멈췄으면 받던 파일은 이미 지웠다(ReviewCloner). 그 사실을 남긴다.
                if $0.clonedSnapshot && $0.phase == .cloningSnapshot {
                    $0.message = "클론을 취소했습니다. 받던 파일은 지웠습니다."
                }
                $0.state = .cancelled
                $0.progress = nil
            }
        } catch {
            let message = error.localizedDescription
            Log.error("잡 예외 #\(job.number): \(message)", "queue", problem: .reviewFailed)
            updateJob(job.id) { $0.state = .failed; $0.message = message; $0.phase = .failed }
            if job.trigger == .manual {
                banner = failureBanner(number: job.number, message: message,
                                       engine: ReviewEngineKind(model: job.modelOverride ?? settings.model))
            }
            noteAuthFailureIfNeeded(message)
            if settings.notifyOnFailure {
                Notifier.reviewFailed(prKey: job.id)
            }
        }
    }

    // MARK: - 초안 편집·게시

    /// 초안 편집은 즉시 메모리에 반영하고 디스크 저장만 묶는다(타이핑마다 파일을 쓰지 않는다).
    /// 디바운스는 레코드별로 둔다. 공용 Task 를 쓰면 다른 PR 을 편집하는 순간 앞 레코드의 저장이 취소된다.
    func update(record: ReviewRecord) {
        remember(record)
        pendingRecords[record.id] = record
        saveTasks[record.id]?.cancel()
        saveTasks[record.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            await self.store.save(record: record)
            self.pendingRecords.removeValue(forKey: record.id)
            self.saveTasks.removeValue(forKey: record.id)
        }
    }

    /// 고른 리뷰 1건만 폐기한다. 히스토리에 남은 다른 리뷰는 그대로 두고,
    /// 화면에는 그다음 최신 기록을 올린다.
    func discard(record: ReviewRecord) {
        var list = (recordHistory[record.prKey] ?? [])
            .filter { !($0.headSha == record.headSha && $0.createdAt == record.createdAt) }
        list.sort { $0.createdAt > $1.createdAt }
        recordHistory[record.prKey] = list
        if let next = list.first {
            records[record.prKey] = next
        } else {
            records.removeValue(forKey: record.prKey)
        }
        Task { await store.delete(record: record) }
    }

    enum HeadCheck: Equatable {
        case same
        case changed(String)
        /// 그 사이 머지됐거나 닫혔다(MERGED / CLOSED).
        case closed(String)
        /// 조회 실패(네트워크·rate limit 등). 확인하지 못한 것을 "같음" 으로 취급하면 stale 초안이 게시된다.
        case unknown(String)
    }

    func checkHead(for record: ReviewRecord) async -> HeadCheck {
        await checkHead(repo: record.repo, number: record.number, expected: record.headSha)
    }

    func checkHead(repo: RepoID, number: Int, expected: String) async -> HeadCheck {
        do {
            let state = try await github.headState(repo, number: number)
            if state.state != "OPEN" { return .closed(state.state) }
            return state.sha == expected ? .same : .changed(state.sha)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// 기준 커밋 뒤로 무엇이 올라왔는지 받는다. 확인 창이 이걸 그린다.
    ///
    /// 그 PR 도 같이 다시 받는다 — 막고 배너만 띄우면 화면은 폴링 전까지 옛 head 를 그려서,
    /// "새 커밋이 올라왔습니다" 라는 말을 확인할 길이 없었다(실측).
    func headDrift(repo: RepoID, number: Int, base: String, head: String) async -> HeadDrift {
        Task { [weak self] in await self?.refreshOne(repo: repo, number: number) }
        let outcome: CommitComparison.Outcome
        do {
            outcome = try await github.compareCommits(repo, base: base, head: head)
        } catch {
            Log.error("커밋 비교 실패 \(repo.full)#\(number): \(error.localizedDescription)", "queue")
            outcome = .failed
        }
        let drift = HeadDrift.make(base: base, head: head, outcome: outcome)
        Log.info("게시 직전 새 커밋 \(repo.full)#\(number) \(drift.shortBase) → \(drift.shortHead) "
                 + "(\(drift.totalCount.map { "\($0)개" } ?? "개수 모름")\(drift.baseRewritten ? ", 강제 푸시" : ""))", "queue")
        return drift
    }

    /// 코멘트 없이 승인만 게시한다.
    /// AI 리뷰 없이도 승인할 수 있어야 한다. 승인은 리뷰 결과와 무관한 동작이다
    /// (리뷰가 없거나 아직 도는 중이어도 사람은 승인할 수 있다).
    ///
    /// `acceptingHead` — 새 커밋 확인 창에서 "그대로 올림" 을 고른 head. 그 사이 또 바뀌었으면 다시 묻는다.
    func approve(pr: PullRequestInfo, body: String, acceptingHead: String? = nil) async -> Result<PostedInfo, PostError> {
        // 게시 직전에 head 를 다시 확인한다. 화면에 보이던 것과 다른 커밋을 모르고 승인하게 두지 않는다.
        let head: String
        switch await checkHead(repo: pr.repo, number: pr.number, expected: pr.headRefOid) {
        case .same:
            head = pr.headRefOid
        case .changed(let sha) where sha == acceptingHead:
            head = sha
        case .changed(let sha):
            return .failure(.headDrift(await headDrift(repo: pr.repo, number: pr.number,
                                                        base: pr.headRefOid, head: sha)))
        case .closed(let state):
            await refreshOne(repo: pr.repo, number: pr.number)
            return .failure(.closed(number: pr.number, state: state))
        case .unknown(let message):
            return .failure(.headUnknown(message))
        }
        let payload = ReviewPayload(commitID: head, event: ReviewEvent.approve.rawValue,
                                    body: body, comments: [])
        do {
            let posted = try await github.postReview(pr.repo, number: pr.number, payload: payload)
            Log.info("승인 게시 \(pr.id) (리뷰 초안 없음, 본문 \(body.count)자)", "queue")
            noteApproval(repo: pr.repo, number: pr.number)
            // 그 PR 하나만 다시 받는다(post 경로와 같다). 예전에는 목록 전체를 다시 받았는데, 그게 끝나야 이 함수가
            // 돌아와서 GitHub 에는 이미 올라간 뒤에도 버튼이 "Approve 올리는 중…" 에 6~8초 더 머물렀다(실측).
            await refreshOne(repo: pr.repo, number: pr.number)
            markLeaving(pr.id, reviewedAt: posted.postedAt, approved: true)
            return .success(posted)
        } catch {
            Log.error("승인 게시 실패 \(pr.id): \(error.localizedDescription)", "queue", problem: .postFailed)
            return .failure(.api(error.localizedDescription))
        }
    }

    func approveWithoutComments(record: ReviewRecord, body: String) async -> Result<PostedInfo, PostError> {
        await post(record: record, event: .approve, body: body, includeComments: false)
    }

    /// 게시. 사용자가 "게시" 를 눌렀을 때만 호출된다.
    ///
    /// `acceptingHead` — 새 커밋 확인 창에서 "그대로 올림" 을 고른 head. 그 사이 또 바뀌었으면 다시 묻는다.
    /// `basket` — 코드 코멘트 카드에서 "리뷰에 담기" 한 줄 코멘트(`basketItems(for:)`). 이 리뷰에 함께 실리고,
    /// 올라가면 그 카드들이 "달렸어요" 로 바뀐다.
    func post(record: ReviewRecord,
              event: ReviewEvent,
              body: String,
              includeComments: Bool = true,
              basket: [BasketItem] = [],
              acceptingHead: String? = nil) async -> Result<PostedInfo, PostError> {
        guard let engine = makeEngine() else { return .failure(.engineMissing) }
        let inlineCount = PostBuilder.inlineCount(record: record, includeComments: includeComments) + basket.count
        // 전송 직전 head 재조회. 새 커밋이 왔으면 무엇이 왔는지 보여 주고 사람이 정하게 한다.
        let commitID: String
        switch await checkHead(for: record) {
        case .same:
            commitID = record.headSha
        case .changed(let sha) where sha == acceptingHead:
            commitID = HeadDrift.postingCommit(reviewed: record.headSha, acceptedHead: sha,
                                               postsInlineComments: inlineCount > 0)
        case .changed(let sha):
            let drift = await headDrift(repo: record.repo, number: record.number, base: record.headSha, head: sha)
            // 리뷰한 커밋이 PR 에서 빠졌으면 인라인 코멘트를 달 곳이 없어 리뷰 전체가 422 로 거부된다.
            // 그대로 올릴 길이 없으니 묻지 않는다.
            if drift.blocksPosting(inlineCount: inlineCount) {
                return .failure(.reviewedCommitGone(record.shortHead))
            }
            return .failure(.headDrift(drift))
        case .closed(let state):
            await refreshOne(repo: record.repo, number: record.number)
            return .failure(.closed(number: record.number, state: state))
        case .unknown(let message):
            return .failure(.headUnknown(message))
        }
        do {
            let posted = try await engine.post(record: record, event: event, body: body,
                                               includeComments: includeComments,
                                               basket: basket.map(\.comment),
                                               commitID: commitID)
            var updated = record
            updated.posted = posted
            updated.bodyDraft = body
            if !basket.isEmpty {
                // 응답에 줄 코멘트 ID 가 없어 리뷰의 코멘트를 다시 받아 카드와 짝짓는다. 못 받아도 게시는 끝났으니
                // 카드는 리뷰 링크로 "달렸어요" 표시만 한다.
                let received = (try? await github.reviewComments(record.repo, number: record.number,
                                                                 reviewID: posted.reviewID)) ?? []
                updated.markBasketPosted(basket, posted: ReviewBasket.match(sent: basket.map(\.comment), received: received),
                                         review: posted)
                // 엔진은 게시 표시만 저장했다. 달림 표시까지 파일에 남겨야 앱을 다시 켜도 카드가 "달렸어요" 다.
                update(record: updated)
            } else {
                remember(updated)
            }
            if event == .approve { noteApproval(repo: record.repo, number: record.number) }
            // 게시하면 GitHub 이 리뷰 요청을 없애서 이 PR 은 "내 차례" 가 아니게 된다.
            // 그 사실을 다시 받아 오지 않으면 폴링(기본 120초) 전까지 목록에 그대로 남는다
            // — 승인 경로는 refresh() 를 했는데 이 경로만 빠져 있었다(실측).
            // 전체 갱신은 무겁고 느리므로 그 PR 하나만 다시 조회한다.
            await refreshOne(repo: record.repo, number: record.number)
            markLeaving(record.prKey, reviewedAt: posted.postedAt, approved: event == .approve)
            banner = Banner(kind: .info,
                            message: "#\(record.number) 게시 완료 (\(event.label)\(inlineCount > 0 ? " · 줄 코멘트 \(inlineCount)개" : " · 코멘트 없음"))",
                            actionTitle: GitHubLink.title,
                            opensGitHub: true,
                            action: { NSWorkspaceOpener.open(posted.htmlURL) })
            return .success(posted)
        } catch {
            Log.error("게시 실패 \(record.prKey): \(error.localizedDescription)", "queue", problem: .postFailed)
            return .failure(.api(error.localizedDescription))
        }
    }
}

extension AppModel {
    /// 리뷰에 담은 줄 코멘트. 카드에서 고친 글이 그대로 실린다. 자리를 못 만든 지적은 `missing` 에 — 그때는 올리지 않는다.
    func basketItems(for pr: PullRequestInfo, record: ReviewRecord) -> (items: [BasketItem], missing: [ReviewIssue]) {
        record.basketComments(diff: parsedDiff(for: pr), body: { issueBodies["\(pr.id)|\($0.key)"] })
    }

    /// 지적 하나를 리뷰에 담거나 뺀다.
    func setInBasket(_ isOn: Bool, issue: ReviewIssue, pr: PullRequestInfo) {
        guard var record = record(for: pr), record.setInBasket(isOn, for: issue) else { return }
        update(record: record)
    }

    /// 여러 지적을 주어진 순서대로 한꺼번에 담는다("모두 담기"). 기록은 한 번만 고친다.
    func addToBasket(_ issues: [ReviewIssue], pr: PullRequestInfo) {
        guard var record = record(for: pr) else { return }
        var changed = false
        for issue in issues where record.setInBasket(true, for: issue) {
            changed = true
        }
        if changed { update(record: record) }
    }

    /// 지적에 달 글 — 붙은 초안이 있으면 초안의 고친 글, 없으면 카드에서 고친 글(`issueBodies`), 그것도 없으면 지적 제목.
    /// 오른쪽 카드와 왼쪽 "담은 줄 코멘트" 칸이 같은 글을 고친다.
    func issueText(pr: PullRequestInfo, issue: ReviewIssue) -> String {
        if let record = record(for: pr), let index = record.draftIndex(for: issue) {
            return record.comments[index].editedBody
        }
        return issueBodies["\(pr.id)|\(issue.key)"] ?? issue.title
    }

    func setIssueText(_ text: String, pr: PullRequestInfo, issue: ReviewIssue) {
        if var record = record(for: pr), let index = record.draftIndex(for: issue) {
            record.comments[index].editedBody = text
            update(record: record)
        } else {
            issueBodies["\(pr.id)|\(issue.key)"] = text
        }
    }

    /// 지적 하나를 줄 코멘트로 바로 단다. 왼쪽 리뷰 게시와는 따로 간다(사용자 결정).
    ///
    /// 리뷰한 커밋에 단다. 그 뒤 새 커밋이 와도 그 커밋이 PR 에 남아 있으면 GitHub 은 옛 줄에 단 코멘트를
    /// "outdated" 로 받는다. 강제 푸시로 빠졌으면 422 가 오고, 그 메시지를 그대로 보여 준다.
    func postInline(pr: PullRequestInfo, issue: ReviewIssue, body: String?) async -> Result<PostedComment, PostError> {
        guard let engine = makeEngine() else { return .failure(.engineMissing) }
        guard let record = record(for: pr) else { return .failure(.api("리뷰 기록을 찾지 못했습니다.")) }
        guard let comment = record.inlineComment(for: issue, body: body, diff: parsedDiff(for: pr)) else {
            return .failure(.api("이 지적은 코드 옆에 달 자리가 없습니다."))
        }
        do {
            let posted = try await engine.postInline(record: record, comment: comment, commitID: record.headSha)
            // 게시하는 동안 사용자가 다른 것을 바꿨을 수 있어 최신 기록에 표시한다.
            var updated = self.record(for: pr) ?? record
            updated.markPostedInline(posted, for: issue)
            update(record: updated)
            return .success(posted)
        } catch {
            Log.error("줄 코멘트 게시 실패 \(record.prKey): \(error.localizedDescription)", "queue", problem: .postFailed)
            return .failure(.api(error.localizedDescription))
        }
    }
}

enum NSWorkspaceOpener {
    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - diff 표시용 로딩

extension AppModel {
    /// base 도 키에 넣는다 — head 가 그대로여도 PR 의 base 가 바뀌면 diff·커밋 목록이 달라진다.
    func diffKey(for pr: PullRequestInfo) -> String { "\(pr.id)@\(pr.headRefOid)>\(pr.baseRefName)" }

    /// base 가 바뀐 PR 의 디스크 diff 를 지운다. 디스크 diff 는 head 커밋으로만 캐시해서, head 가 그대로면 옛 base 기준
    /// diff 가 다시 읽힌다(메모리 캐시는 `diffKey` 에 base 가 있어 저절로 갈린다). 목록·PR 을 다시 받을 때 견줘 본다 —
    /// 어디서 바꿨든(GitHub 웹 등) 다음 갱신에 잡힌다.
    func forgetDiffsIfBaseChanged(from old: [PullRequestInfo], to new: [PullRequestInfo]) {
        guard !old.isEmpty else { return }
        let before = Dictionary(old.map { ($0.id, $0.baseRefName) }, uniquingKeysWith: { first, _ in first })
        for pr in new {
            guard let previous = before[pr.id], !previous.isEmpty, previous != pr.baseRefName else { continue }
            Log.info("base 바뀜 \(pr.id) \(previous) → \(pr.baseRefName) — 받아 둔 diff 를 버린다", "base")
            store.forgetDiff(repo: pr.repo, number: pr.number, sha: pr.headRefOid)
        }
    }

    /// 받은 diff 를 지금 제외 규칙으로 나눈 것. 규칙을 고치면(설정 › 대상 제외·변경 파일 탭 우클릭) diff 를 다시
    /// 받지 않아도 변경 파일 탭·예상 토큰이 바로 바뀐다. 예전에는 받을 때 한 번 나눈 것을 들고 있어서, 규칙을
    /// 더해도 그 PR 의 diff 를 다시 받기 전까지(새 커밋·앱 재실행) 화면이 그대로였다.
    func parsedDiff(for pr: PullRequestInfo) -> ParsedDiff? {
        let key = diffKey(for: pr)
        guard let raw = diffCache[key] else { return nil }
        let patterns = settings.excludedPathPatterns
        if let memo = exclusionMemo[key], memo.patterns == patterns { return memo.diff }
        let diff = raw.applyingExclusions(patterns)
        exclusionMemo[key] = (patterns, diff)
        return diff
    }

    /// diff 를 받아 돌려준다. 이미 다른 곳(AI 리뷰 탭이 열리며)에서 받는 중이면 그것이 끝나기를 기다린다 —
    /// `loadDiff` 는 받는 중이면 기다리지 않고 바로 돌아온다. 10초 안에 못 받으면 nil.
    func waitForDiff(for pr: PullRequestInfo) async -> ParsedDiff? {
        await loadDiff(for: pr)
        let key = diffKey(for: pr)
        var waited = 0
        while diffCache[key] == nil, loadingDiffKeys.contains(key), waited < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        return parsedDiff(for: pr)
    }

    func loadDiff(for pr: PullRequestInfo) async {
        let key = diffKey(for: pr)
        guard diffCache[key] == nil, !loadingDiffKeys.contains(key) else { return }
        loadingDiffKeys.insert(key)
        defer { loadingDiffKeys.remove(key) }
        do {
            let text: String
            if DemoMode.isOn {
                #if DEBUG
                text = DemoData.diff(for: pr)
                #else
                text = ""
                #endif
            } else if let cached = await store.cachedDiff(repo: pr.repo, number: pr.number, sha: pr.headRefOid) {
                text = cached
            } else {
                text = try await github.diff(pr.repo, number: pr.number)
                await store.cacheDiff(text, repo: pr.repo, number: pr.number, sha: pr.headRefOid)
            }
            // 큰 diff 파싱은 수백 ms 가 걸린다. 메인 액터에서 돌리면 클릭 반응이 멈춘다.
            // 제외 규칙은 여기서 걸지 않는다 — 볼 때 지금 규칙으로 나눈다(parsedDiff(for:)).
            let parsed = await Task.detached(priority: .userInitiated) {
                DiffParser.parse(text)
            }.value
            diffCache[key] = parsed
            exclusionMemo[key] = nil
            diffCacheOrder.removeAll { $0 == key }
            diffCacheOrder.append(key)
            pruneDiffCache()
        } catch is CancellationError {
            // 탭·PR 을 바꾸면 진행 중이던 요청이 취소된다. 오류가 아니므로 조용히 넘어간다.
            Log.info("diff 로딩 취소됨 \(key)", "app")
        } catch {
            Log.error("diff 로딩 실패 \(key): \(error.localizedDescription)", "app", problem: .diffLoadFailed)
            banner = Banner(kind: .error,
                            message: "diff 를 불러오지 못했습니다: \(error.localizedDescription)",
                            actionTitle: "다시 시도",
                            action: { [weak self] in
                                guard let self else { return }
                                self.diffCache.removeValue(forKey: key)
                                Task { await self.loadDiff(for: pr) }
                            })
        }
    }
}

extension AppModel {
    /// 이번 잡의 "Claude 가 읽고 판단" 90% 범위. 같은 모델·같은 리뷰 종류(전체·diff)의 지난 리뷰만 견준다 —
    /// 둘 다 시간을 크게 가른다(실측 중앙값: Opus 전체 리뷰 55초 · Sonnet diff 리뷰 125초).
    func claudeRange(for job: ReviewJob) -> ClosedRange<Double>? {
        let name = job.modelOverride ?? settings.model
        // Codex 는 계열(`codex:sol`)을 실제 모델로 푼 이름이 초안에 남는다 — 같은 이름끼리 견준다.
        let model = ClaudeStepEstimate.modelKey(modelOption(id: name)?.apiID ?? name)
        let samples = recordHistory.values.joined().compactMap { record -> ClaudeStepSample? in
            guard let lines = record.changedLines, record.usage.durationMs > 0,
                  record.isDeep == job.deep,
                  ClaudeStepEstimate.modelKey(record.model) == model else { return nil }
            return ClaudeStepSample(lines: lines, seconds: Double(record.usage.durationMs) / 1000, date: record.createdAt)
        }
        return ClaudeStepEstimate.range(lines: job.pr.additions + job.pr.deletions, samples: samples)
    }
}
