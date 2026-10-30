import Foundation

/// 로컬 저장소. 초안은 여기에만 있고 GitHub 에는 올라가지 않는다.
public actor Store {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        AppPaths.ensureDirectories()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - 설정

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: AppPaths.settingsFile),
              let settings = try? decoder.decode(Settings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(settings: Settings) {
        do {
            try encoder.encode(settings).write(to: AppPaths.settingsFile, options: .atomic)
        } catch {
            Log.error("설정 저장 실패: \(error)", "store", problem: .storeFailed)
        }
    }

    // MARK: - 리뷰 기록

    /// PR 당 남겨 두는 리뷰 기록 수. 리뷰 1건이 수십 KB 짜리 JSON 이라 무제한이면 계속 쌓인다.
    public static let historyLimit = 10

    /// PR 키별 리뷰 기록 **전부**, 최신순.
    ///
    /// 옛 이름 규칙의 파일은 새 규칙으로 옮긴다(그대로 두면 편집 저장 때 새 파일이 하나 더 생겨
    /// 같은 리뷰가 두 건으로 보인다). 상한을 넘는 오래된 기록은 파일까지 지운다.
    public func loadRecords() -> [String: [ReviewRecord]] {
        let fm = FileManager.default
        var byPR: [String: [ReviewRecord]] = [:]
        guard let repoDirs = try? fm.contentsOfDirectory(at: AppPaths.draftsDirectory,
                                                         includingPropertiesForKeys: nil) else {
            return byPR
        }
        for repoDir in repoDirs {
            guard let files = try? fm.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let record = try? decoder.decode(ReviewRecord.self, from: data) else { continue }
                migrateIfLegacy(file: file, record: record)
                byPR[record.prKey, default: []].append(record)
            }
        }
        for (key, records) in byPR {
            // 최신순. 같은 시각이면 게시된 것을 앞에 둔다(게시 사실이 묻히지 않도록).
            let sorted = records.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                if $0.isPosted != $1.isPosted { return $0.isPosted }
                return $0.headSha > $1.headSha
            }
            let kept = Array(sorted.prefix(Store.historyLimit))
            for dropped in sorted.dropFirst(Store.historyLimit) {
                try? fm.removeItem(at: AppPaths.draftFile(repo: dropped.repo, number: dropped.number,
                                                          headSha: dropped.headSha, createdAt: dropped.createdAt))
            }
            byPR[key] = kept
        }
        return byPR
    }

    /// 옛 이름(`<번호>-<커밋12자>.json`)이면 새 이름으로 옮긴다.
    private func migrateIfLegacy(file: URL, record: ReviewRecord) {
        let legacy = AppPaths.legacyDraftFile(repo: record.repo, number: record.number, headSha: record.headSha)
        guard file.lastPathComponent == legacy.lastPathComponent else { return }
        let target = AppPaths.draftFile(repo: record.repo, number: record.number,
                                        headSha: record.headSha, createdAt: record.createdAt)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.moveItem(at: file, to: target)
    }

    /// 앱 종료 훅처럼 await 할 수 없는 자리에서 초안을 즉시 쓴다.
    public nonisolated static func writeSynchronously(record: ReviewRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let url = AppPaths.draftFile(repo: record.repo, number: record.number,
                                     headSha: record.headSha, createdAt: record.createdAt)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch {
            Log.error("종료 시 초안 저장 실패: \(error)", "store", problem: .storeFailed)
        }
    }

    /// 그 커밋의 기록 중 가장 최근 것.
    public func loadRecord(repo: RepoID, number: Int, headSha: String) -> ReviewRecord? {
        let directory = AppPaths.draftsDirectory.appendingPathComponent(repo.slug, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("\(number)-\(headSha.prefix(12))") }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(ReviewRecord.self, from: $0) }
            .max { $0.createdAt < $1.createdAt }
    }

    public func save(record: ReviewRecord) {
        let url = AppPaths.draftFile(repo: record.repo, number: record.number,
                                     headSha: record.headSha, createdAt: record.createdAt)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch {
            Log.error("초안 저장 실패: \(error)", "store", problem: .storeFailed)
        }
    }

    /// 리뷰 **1건**만 지운다.
    ///
    /// 예전에는 그 PR 의 초안 파일을 전부 지웠다. 파일이 커밋당 1개뿐이라 한 건만 지우면
    /// 다음 실행에서 옛 초안이 되살아났기 때문이다. 이제는 히스토리를 일부러 남기므로,
    /// 폐기는 고른 그 1건에만 적용한다.
    public func delete(record: ReviewRecord) {
        let url = AppPaths.draftFile(repo: record.repo, number: record.number,
                                     headSha: record.headSha, createdAt: record.createdAt)
        try? FileManager.default.removeItem(at: url)
        // 옛 이름으로 남아 있을 수도 있다(마이그레이션 전에 폐기하는 경우).
        try? FileManager.default.removeItem(at: AppPaths.legacyDraftFile(repo: record.repo,
                                                                        number: record.number,
                                                                        headSha: record.headSha))
    }

    /// 그 PR 의 초안을 전부 지운다(레포 목록에서 빼거나 정리할 때).
    public func deleteAll(repo: RepoID, number: Int) {
        let fm = FileManager.default
        let directory = AppPaths.draftsDirectory.appendingPathComponent(repo.slug, isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("\(number)-") {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - PR 스냅샷 (변화 알림용)

    /// 마지막으로 본 PR 목록. 앱을 켜면 이걸 먼저 그려 두고, 조회가 끝나면 달라진 부분만 바뀐다.
    /// 어느 탭의 목록인지 함께 담는다 — 탭이 다르면 엉뚱한 목록을 보여 주게 된다.
    public struct CachedList: Codable, Sendable {
        public var scope: String
        public var savedAt: Date
        public var prs: [PullRequestInfo]

        public init(scope: String, savedAt: Date, prs: [PullRequestInfo]) {
            self.scope = scope
            self.savedAt = savedAt
            self.prs = prs
        }
    }

    /// 탭마다 마지막으로 받은 목록.
    ///
    /// 예전에는 지금 탭 하나만 남겨서, 앱을 다시 켜면 다른 탭으로 갔을 때 지난 목록 없이 빈 화면에서 다 받을 때까지
    /// 기다렸다(실측 2026-10-28: 베타를 깔며 하루 27번 다시 켜졌고, 남은 목록은 매번 리뷰 대기 탭뿐이었다). 탭마다
    /// 파일을 따로 둔다 — 한 파일에 모으면 지금 탭을 2분마다 저장할 때 다른 탭(30일 탭은 수 MB)까지 매번 다시 쓴다.
    public func loadLists() -> [CachedList] {
        migrateLegacyList()
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.listCacheDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(CachedList.self, from: data)
        }
    }

    public func save(list: CachedList) {
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.listCacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: AppPaths.listCacheFile(scope: list.scope), options: .atomic)
    }

    /// 탭의 지난 목록을 지운다. nil 이면 모든 탭(옛 파일까지). 개발 빌드의 목록 비우기가 쓴다.
    public func removeLists(scopes: [String]?) {
        let fm = FileManager.default
        guard let scopes else {
            try? fm.removeItem(at: AppPaths.listCacheDirectory)
            try? fm.removeItem(at: AppPaths.legacyListCacheFile)
            return
        }
        for scope in scopes {
            try? fm.removeItem(at: AppPaths.listCacheFile(scope: scope))
        }
    }

    /// 옛 파일(지금 탭 하나)을 그 탭의 파일로 옮긴다. 그 탭의 파일이 이미 있으면 그쪽이 새것이라 옛 파일은 버린다.
    private func migrateLegacyList() {
        let legacy = AppPaths.legacyListCacheFile
        guard let data = try? Data(contentsOf: legacy) else { return }
        if let cached = try? decoder.decode(CachedList.self, from: data),
           !FileManager.default.fileExists(atPath: AppPaths.listCacheFile(scope: cached.scope).path) {
            save(list: cached)
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    public func loadSnapshots() -> [String: PRSnapshot]? {
        guard let data = try? Data(contentsOf: AppPaths.snapshotsFile),
              let snapshots = try? decoder.decode([String: PRSnapshot].self, from: data) else { return nil }
        return snapshots
    }

    public func save(snapshots: [String: PRSnapshot]) {
        try? encoder.encode(snapshots).write(to: AppPaths.snapshotsFile, options: .atomic)
    }

    // MARK: - 슬랙 리뷰 요청 기록 (키: PR id)

    public func loadSlackRequests() -> [String: SlackRequestEntry] {
        guard let data = try? Data(contentsOf: AppPaths.slackRequestsFile),
              let entries = try? decoder.decode([String: SlackRequestEntry].self, from: data) else { return [:] }
        return entries
    }

    public func save(slackRequests: [String: SlackRequestEntry]) {
        try? encoder.encode(slackRequests).write(to: AppPaths.slackRequestsFile, options: .atomic)
    }

    // MARK: - 모델 목록 (CLI 버전마다 한 번 묻는다)

    public func loadModelCatalog() -> ModelCatalog? {
        guard let data = try? Data(contentsOf: AppPaths.modelCatalogFile),
              let catalog = try? decoder.decode(ModelCatalog.self, from: data) else { return nil }
        return catalog
    }

    public func save(modelCatalog: ModelCatalog) {
        try? encoder.encode(modelCatalog).write(to: AppPaths.modelCatalogFile, options: .atomic)
    }

    public func loadCodexCatalog() -> CodexCatalog? {
        guard let data = try? Data(contentsOf: AppPaths.codexCatalogFile),
              let catalog = try? decoder.decode(CodexCatalog.self, from: data) else { return nil }
        return catalog
    }

    public func save(codexCatalog: CodexCatalog) {
        try? encoder.encode(codexCatalog).write(to: AppPaths.codexCatalogFile, options: .atomic)
    }

    /// 계열이 새 버전으로 넘어간 앞 모델과 직접 입력한 이름(`ClaudeModels.remembering`).
    public func loadRememberedModels() -> [String] {
        guard let data = try? Data(contentsOf: AppPaths.rememberedModelsFile),
              let ids = try? decoder.decode([String].self, from: data) else { return [] }
        return ids
    }

    public func save(rememberedModels: [String]) {
        try? encoder.encode(rememberedModels).write(to: AppPaths.rememberedModelsFile, options: .atomic)
    }

    // MARK: - 토큰 원장

    // MARK: - 코멘트 설명 (한 번 만들면 다시 만들지 않는다)

    public func loadExplanations() -> [String: CommentExplanation] {
        guard let data = try? Data(contentsOf: AppPaths.explanationsFile),
              let list = try? decoder.decode([CommentExplanation].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    }

    public func loadRechecks() -> [String: ItemRecheck] {
        guard let data = try? Data(contentsOf: AppPaths.rechecksFile),
              let list = try? decoder.decode([ItemRecheck].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    }

    @discardableResult
    public func save(recheck: ItemRecheck) -> [String: ItemRecheck] {
        var all = loadRechecks()
        all[recheck.key] = recheck
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        all = all.filter { $0.value.createdAt >= cutoff }
        if let data = try? encoder.encode(Array(all.values)) {
            try? data.write(to: AppPaths.rechecksFile, options: .atomic)
        }
        return all
    }

    public func loadRelevances() -> [String: DiscussionRelevance] {
        guard let data = try? Data(contentsOf: AppPaths.relevancesFile),
              let list = try? decoder.decode([DiscussionRelevance].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    }

    @discardableResult
    public func save(relevance: DiscussionRelevance) -> [String: DiscussionRelevance] {
        var all = loadRelevances()
        all[relevance.key] = relevance
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        all = all.filter { $0.value.createdAt >= cutoff }
        if let data = try? encoder.encode(Array(all.values)) {
            try? data.write(to: AppPaths.relevancesFile, options: .atomic)
        }
        return all
    }

    @discardableResult
    public func save(explanation: CommentExplanation) -> [String: CommentExplanation] {
        var all = loadExplanations()
        all[explanation.key] = explanation
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        all = all.filter { $0.value.createdAt >= cutoff }
        if let data = try? encoder.encode(Array(all.values)) {
            try? data.write(to: AppPaths.explanationsFile, options: .atomic)
        }
        return all
    }

    public func loadLedger() -> TokenLedger {
        guard let data = try? Data(contentsOf: AppPaths.ledgerFile),
              let ledger = try? decoder.decode(TokenLedger.self, from: data) else { return TokenLedger() }
        return ledger
    }

    public func append(entry: LedgerEntry) -> TokenLedger {
        var ledger = loadLedger()
        ledger.add(entry)
        try? encoder.encode(ledger).write(to: AppPaths.ledgerFile, options: .atomic)
        return ledger
    }

    // MARK: - diff 캐시 (headSha 키)

    private nonisolated func diffCacheURL(repo: RepoID, number: Int, sha: String) -> URL {
        AppPaths.diffCacheDirectory.appendingPathComponent("\(repo.slug)-\(number)-\(sha.prefix(12)).diff")
    }

    public func cachedDiff(repo: RepoID, number: Int, sha: String) -> String? {
        try? String(contentsOf: diffCacheURL(repo: repo, number: number, sha: sha), encoding: .utf8)
    }

    public func cacheDiff(_ text: String, repo: RepoID, number: Int, sha: String) {
        try? text.write(to: diffCacheURL(repo: repo, number: number, sha: sha), atomically: true, encoding: .utf8)
    }

    /// head 는 그대로인데 base 가 바뀌면 diff 가 달라진다 — 키에 base 가 없어 옛 diff 가 그대로 읽힌다. 그때 지운다.
    /// 바로 뒤의 diff 읽기보다 먼저 지워져야 해서 actor 차례를 기다리지 않는다(파일 하나 지우기라 겹쳐도 된다).
    public nonisolated func forgetDiff(repo: RepoID, number: Int, sha: String) {
        try? FileManager.default.removeItem(at: diffCacheURL(repo: repo, number: number, sha: sha))
    }

    // MARK: - 커밋 탭 diff 캐시 (커밋 oid 키 — 내용이 바뀌지 않는다)

    private func commitDiffCacheURL(repo: RepoID, spec: CommitDiffSpec) -> URL {
        AppPaths.diffCacheDirectory.appendingPathComponent("commit-\(repo.slug)-\(spec.cacheKey).diff")
    }

    public func cachedCommitDiff(repo: RepoID, spec: CommitDiffSpec) -> String? {
        try? String(contentsOf: commitDiffCacheURL(repo: repo, spec: spec), encoding: .utf8)
    }

    public func cacheCommitDiff(_ text: String, repo: RepoID, spec: CommitDiffSpec) {
        try? text.write(to: commitDiffCacheURL(repo: repo, spec: spec), atomically: true, encoding: .utf8)
    }

    /// 오래된 캐시 정리(7일).
    public func pruneDiffCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.diffCacheDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }
}
