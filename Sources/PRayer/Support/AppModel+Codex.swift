import Foundation
import PRayerCore

/// Codex 연결 — 상태 확인, 모델 목록, 엔진마다의 준비 여부.
///
/// Claude 와 같은 자리에서 같은 방식으로 본다: 앱이 토큰을 받지 않고 이 맥의 `codex` 로그인을 빌려 쓰며,
/// 모델 목록·effort 단계는 Codex 에 묻는다(`CodexModelProbe`, 토큰 0). 어느 한쪽만 붙인 사람도 나중에 다른 쪽을
/// 설정 › 연결에서 붙일 수 있다.
extension AppModel {
    /// - Parameter rediscover: 경로에 실행 파일이 없을 때 셸에 다시 찾아볼지. 앱 전환마다 부르는 확인은 실행당 한 번만 찾는다.
    func checkCodex(rediscover: Bool = false) async {
        var path = settings.codexPath
        if !FileManager.default.isExecutableFile(atPath: path), rediscover || !codexDiscoveryTried {
            codexDiscoveryTried = true
            if let discovered = await codex.discoverPath() {
                path = discovered
                settings.codexPath = discovered
                await save()
            }
        }
        let status = await codex.status(path: path)
        codexStatus = status
        if status.isInstalled {
            Log.info("codex 상태: 로그인=\(status.loginKnown ? String(status.loggedIn) : "모름") 계정=\(status.accountLabel ?? "-") 버전=\(status.version ?? "-")", "app")
        }
        refreshCodexCatalogIfNeeded(path: path, status: status)
    }

    /// 목록이 오래됐거나 CLI 가 바뀌었으면 다시 묻는다. 기다리지 않는다.
    ///
    /// Codex 는 서버에서 받은 목록을 CLI 버전에 맞춰 걸러 준다 — CLI 를 올리지 않아도 새 모델이 생길 수 있어
    /// 시간이 지나면(`CodexCatalog.maxAge`) 같은 CLI 라도 다시 묻는다.
    private func refreshCodexCatalogIfNeeded(path: String, status: EngineStatus) {
        guard status.isReady, let version = status.version,
              codexCatalog?.isFresh(path: path, version: version) != true else { return }
        let bucket = Int(Date().timeIntervalSince1970 / CodexCatalog.maxAge)
        let attempt = "\(path)|\(version)|\(bucket)"
        guard codexProbeAttempt != attempt else { return }
        codexProbeAttempt = attempt
        Task { [weak self] in await self?.probeCodexModels(path: path, version: version) }
    }

    private func probeCodexModels(path: String, version: String) async {
        guard let catalog = await codex.probeCatalog(path: path, version: version) else {
            Log.error("codex 모델 목록을 받지 못했다(codex \(version))", "app")
            return
        }
        Log.info("모델 확인(codex \(version)): \(catalog.models.map { "\($0.id)[\($0.efforts.joined(separator: ","))]" }.joined(separator: " ")) · 기능 \(catalog.features.count)개", "app")
        // 새 목록에서 빠지거나 계열의 최신이 아니게 된 모델을 '과거 버전 고르기' 에 남긴다 — 골라 둔 사람이 계속 고를 수 있게.
        if let previous = codexCatalog {
            let latest = Set(CodexModels.options(catalog: catalog).map(\.apiID))
            let gone = previous.models.map(\.id).filter { !latest.contains($0) }
            await rememberModels(gone.map(CodexModels.id))
        }
        codexCatalog = catalog
        await store.save(codexCatalog: catalog)
    }

    // MARK: - 엔진별

    func engineStatus(_ engine: ReviewEngineKind) -> EngineStatus? {
        switch engine {
        case .claude: return claudeStatus
        case .codex: return codexStatus
        }
    }

    func engineReady(_ engine: ReviewEngineKind) -> Bool {
        engineStatus(engine)?.isReady ?? false
    }

    /// 지금 리뷰를 돌릴 수 있는 엔진. 화면이 연결 안 된 쪽을 "연결하기" 로 바꿔 보인다.
    var readyEngines: [ReviewEngineKind] {
        ReviewEngineKind.allCases.filter(engineReady)
    }

    /// 그 엔진으로 처음 바꿀 때 고를 모델 — Claude 는 기본 계열, Codex 는 Codex 가 기본으로 쓰는 계열.
    func defaultModel(for engine: ReviewEngineKind) -> String {
        switch engine {
        case .claude: return Settings.default.model
        case .codex: return CodexModels.defaultChoice(catalog: codexCatalog)
        }
    }

    /// 기본 모델의 엔진이 준비되지 않았고 다른 쪽은 준비됐으면 그쪽으로 기본값을 옮긴다.
    /// Codex 만 붙인 사람이 처음부터 Claude 기본값(`sonnet`)으로 리뷰를 눌러 실패하지 않게 — 온보딩을 마칠 때·설정에서 연결할 때 부른다.
    func adoptReadyEngineIfNeeded() async {
        let current = ReviewEngineKind(model: settings.model)
        guard !engineReady(current), let other = readyEngines.first else { return }
        settings.model = defaultModel(for: other)
        settings.effort = ""
        Log.info("기본 리뷰 엔진을 \(other.displayName) 로 옮김(\(current.displayName) 미연결)", "app")
        await save()
    }

    // MARK: - 모델 목록

    /// Codex 계열 목록 — 계열마다 가장 새 모델. 화면이 Claude 목록(`modelOptions`) 옆에 같이 보인다.
    var codexModelOptions: [ReviewModelOption] { CodexModels.options(catalog: codexCatalog) }

    /// Codex 의 '과거 버전 고르기' — 계열의 최신이 아닌 모델과 앱이 기억해 둔 이름.
    var codexPastModelOptions: [ReviewModelOption] {
        CodexModels.pastOptions(catalog: codexCatalog,
                                remembered: rememberedModels.filter { ReviewEngineKind(model: $0) == .codex })
    }

    /// 그 모델의 Effort 칸 단계. Claude 는 CLI 가 `--help` 에 적은 것, Codex 는 모델마다 Codex 가 알려 준 것.
    func effortLevels(forModel modelID: String) -> [String] {
        switch ReviewEngineKind(model: modelID) {
        case .claude: return effortLevels
        case .codex: return CodexModels.effortLevels(choice: modelID, catalog: codexCatalog)
        }
    }
}
