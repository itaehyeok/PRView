import Foundation

/// 리뷰용 워크트리 **풀**.
///
/// 매번 `worktree add` / `remove` 를 하면 1만여 개 파일을 새로 체크아웃한다(실측 2.5초, 219MB 쓰기).
/// 대신 저장소 옆에 `<repo>-review-1`, `-2`, … 를 만들어 두고 **재사용**한다.
/// 재사용은 `git checkout --detach <sha>` 라서 커밋 사이에 바뀐 파일만 갱신한다.
/// 워크트리는 객체 DB 를 원본과 공유한다. 원본은 PRayer 폴더의 PR 스냅샷(ReviewClone)이거나,
/// 예전 버전에서 연결한 사용자 클론이다.
public actor WorktreeManager {
    public struct Prepared: Sendable {
        public var path: URL
        /// 저장소 최상위(사용자가 고른 경로가 하위 디렉터리여도 여기로 정규화된다).
        public var repoRoot: String
        /// 풀에서 재사용한 것인가(새로 만든 것이 아닌가).
        public var reused: Bool
        var lockFile: URL { path.appendingPathComponent(".prayer-lock") }
    }

    /// 동시에 열어 둘 워크트리 수 상한.
    public static let poolLimit = 3
    /// 이 시간이 지난 락은 죽은 것으로 본다(앱이 리뷰 중 강제 종료된 경우).
    static let lockTTL: TimeInterval = 3 * 3600

    private let git: String
    private let runner: ProcessRunner
    private let progressRunner: GitProgressRunner

    public init(gitPath: String = "/usr/bin/git", runner: ProcessRunner = ProcessRunner()) {
        self.git = gitPath
        self.runner = runner
        self.progressRunner = GitProgressRunner(git: gitPath)
    }

    // MARK: - 검증

    /// 이 경로가 git 저장소인지 확인하고 최상위 경로를 돌려준다.
    /// `.git` 파일 존재 검사는 워크트리·서브모듈에서 틀리므로 git 에게 직접 묻는다.
    public func repositoryRoot(of path: String) async throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorktreeError.notADirectory(path)
        }
        let result = try await run(["rev-parse", "--show-toplevel"], in: path, timeout: 30)
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !root.isEmpty else {
            throw WorktreeError.notARepository(path)
        }
        return root
    }

    /// origin URL 원문. 어떤 저장소인지 사용자에게 그대로 보여 준다.
    public func originURL(root: String) async -> String? {
        guard let result = try? await run(["remote", "get-url", "origin"], in: root, timeout: 30),
              result.succeeded else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// origin 이 이 레포를 가리키는지. 호스트가 달라도 `owner/name` 이 같으면 같은 레포로 본다
    /// (https / ssh 형식 차이를 흡수).
    public func originMatches(root: String, repo: RepoID) async -> Bool {
        guard let url = await originURL(root: root) else { return false }
        return Self.origin(url, matches: repo)
    }

    static func origin(_ url: String, matches repo: RepoID) -> Bool {
        let needle = "\(repo.owner.lowercased())/\(repo.name.lowercased())"
        var haystack = url.lowercased()
        if haystack.hasSuffix(".git") { haystack.removeLast(4) }
        return haystack.hasSuffix(needle)
    }

    // MARK: - 준비

    /// `onProgress` — 파일 받기(PR 스냅샷)와 체크아웃의 진행. 처음 만드는 워크트리는 몇십 초 걸려서,
    /// 진행이 안 보이면 멈춘 것처럼 느껴진다.
    public func prepare(repoPath: String, number: Int, headSha: String,
                        repo: RepoID? = nil,
                        onPhase: (@Sendable (ReviewPhase) -> Void)? = nil,
                        onProgress: (@Sendable (GitProgress) -> Void)? = nil) async throws -> Prepared {
        let root = try await repositoryRoot(of: repoPath)

        // 다른 저장소를 골랐으면 여기서 멈춘다. 그 저장소에도 같은 번호의 PR 이 있으면
        // 엉뚱한 코드를 읽고 그럴듯한 리뷰를 내놓는다 — 조용히 진행하면 안 된다.
        if let repo {
            let url = await originURL(root: root)
            guard let url, Self.origin(url, matches: repo) else {
                throw WorktreeError.wrongRepository(expected: repo.full, found: url ?? "origin 없음", path: root)
            }
        }

        // head 커밋이 이미 로컬에 있으면 fetch 를 건너뛴다.
        // fetch 는 사용자 저장소의 .git 에 쓰는 유일한 동작이라 꼭 필요할 때만 한다
        // (작업 트리·브랜치·HEAD 는 어느 경우에도 바뀌지 않는다).
        let hasCommit = try await run(["cat-file", "-e", "\(headSha)^{commit}"], in: root, timeout: 60)
        if !hasCommit.succeeded {
            onPhase?(.fetchingCommit)
            let fetch = try await run(["fetch", "--quiet", "origin", "pull/\(number)/head"], in: root, timeout: 300)
            if !fetch.succeeded {
                _ = try await run(["fetch", "--quiet", "origin", headSha], in: root, timeout: 300)
            }
        }

        // PR 스냅샷(가벼운 클론)이면 이 커밋의 파일 중 아직 없는 것을 먼저 받는다. 체크아웃이 알아서 받게 두면
        // 그 사이 진행을 찍을 자리가 없어 처음 리뷰가 몇십 초 동안 멈춘 것처럼 보인다. 받는 방식은 git 이 체크아웃
        // 때 스스로 하는 것과 같다(빠진 객체 ID 를 표준 입력으로, `--filter` 를 붙인 fetch). 받을 게 없으면 건너뛴다.
        let missing = try await missingObjects(of: headSha, in: root)
        if !missing.isEmpty {
            onPhase?(.fetchingFiles)
            let fetch = try await progressRunner.run(
                ["-c", "fetch.negotiationAlgorithm=noop", "fetch", "--progress", "--no-tags", "--no-write-fetch-head",
                 "--recurse-submodules=no", "--filter=blob:none", "--stdin", "origin"],
                in: root, stdin: missing.joined(separator: "\n") + "\n", timeout: 1800, onProgress: onProgress)
            if fetch.cancelled || Task.isCancelled { throw CancellationError() }
            guard fetch.succeeded else {
                throw WorktreeError.fetchFilesFailed(ReviewCloneError.classify(stderr: fetch.stderr).localizedDescription)
            }
        }

        for index in 1...Self.poolLimit {
            let path = Self.poolPath(root: root, index: index)
            if isBusy(path) { continue }

            if FileManager.default.fileExists(atPath: path.path) {
                onPhase?(.preparingWorktree)
                lock(path)
                // 이미 체크아웃돼 있으니 바뀐 파일만 갱신된다.
                let checkout = try await progressRunner.run(["checkout", "--progress", "--detach", "--force", headSha],
                                                            in: path.path, timeout: 600, onProgress: onProgress)
                guard checkout.succeeded else {
                    unlock(path)
                    throw WorktreeError.checkoutFailed(checkout.stderr.isEmpty ? checkout.stdout : checkout.stderr)
                }
                Log.info("워크트리 재사용 #\(number) \(path.lastPathComponent)", "worktree")
                return Prepared(path: path, repoRoot: root, reused: true)
            }

            // 만들기와 파일 쓰기를 나눈다. `worktree add` 에는 진행을 켜는 옵션이 없어서, 파일 1만 개를 쓰는 동안
            // 아무것도 보이지 않았다. 체크아웃은 `--progress` 로 "n / 전체" 를 찍는다.
            onPhase?(.preparingWorktree)
            let add = try await run(["worktree", "add", "--no-checkout", "--detach", "--force", path.path, headSha],
                                    in: root, timeout: 300)
            guard add.succeeded else {
                throw WorktreeError.addFailed(add.stderr.isEmpty ? add.stdout : add.stderr)
            }
            lock(path)
            let checkout = try await progressRunner.run(["checkout", "--progress", "--force", "--detach", headSha],
                                                        in: path.path, timeout: 900, onProgress: onProgress)
            guard checkout.succeeded else {
                unlock(path)
                throw WorktreeError.checkoutFailed(checkout.stderr.isEmpty ? checkout.stdout : checkout.stderr)
            }
            Log.info("워크트리 생성 #\(number) \(path.lastPathComponent)", "worktree")
            return Prepared(path: path, repoRoot: root, reused: false)
        }
        throw WorktreeError.poolBusy(Self.poolLimit)
    }

    /// 이 커밋에 필요한데 아직 없는 객체(파일 내용). 가벼운 클론에서만 생긴다 — 사용자 클론(전체 클론)은
    /// 묻지도 않는다(가벼운 클론인지는 설정 한 줄로 안다).
    func missingObjects(of sha: String, in root: String) async throws -> [String] {
        let promisor = try await run(["config", "--get", "remote.origin.promisor"], in: root, timeout: 30)
        guard promisor.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return [] }
        // `--missing=print` 는 없는 객체를 받으러 가지 않고 `?<id>` 로 적기만 한다. 커밋 하나의 트리만 본다.
        let list = try await run(["rev-list", "--objects", "--missing=print", "--no-object-names", "--max-count=1", sha],
                                 in: root, timeout: 300)
        guard list.succeeded else { return [] }
        return Self.missingObjectIDs(fromRevList: list.stdout)
    }

    static func missingObjectIDs(fromRevList output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("?") else { return nil }
            let id = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
    }

    /// 리뷰가 끝나면 **락만 푼다.** 체크아웃은 남겨 두고 다음 리뷰에서 재사용한다.
    public func release(_ prepared: Prepared) {
        unlock(prepared.path)
        Log.info("워크트리 반납 \(prepared.path.lastPathComponent)", "worktree")
    }

    /// 사용자가 정리를 누르면 풀 전체를 지운다.
    public func removePool(repoPath: String) async -> Int {
        guard let root = try? await repositoryRoot(of: repoPath) else { return 0 }
        var removed = 0
        for index in 1...Self.poolLimit {
            let path = Self.poolPath(root: root, index: index)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            _ = try? await run(["worktree", "remove", "--force", path.path], in: root, timeout: 300)
            try? FileManager.default.removeItem(at: path)
            removed += 1
        }
        _ = try? await run(["worktree", "prune"], in: root, timeout: 60)
        return removed
    }

    /// 앱이 리뷰 중 죽으면 락이 남는다. 시작할 때 오래된 락을 걷어낸다.
    public func clearStaleLocks(repoPaths: [String]) async {
        for repoPath in repoPaths {
            guard let root = try? await repositoryRoot(of: repoPath) else { continue }
            for index in 1...Self.poolLimit {
                let path = Self.poolPath(root: root, index: index)
                guard isLocked(path), !isBusy(path) else { continue }
                unlock(path)
                Log.info("오래된 워크트리 락 정리 \(path.lastPathComponent)", "worktree")
            }
        }
    }

    // MARK: - 경로·락

    /// 저장소 옆 형제 폴더: `~/work/sample-ios` → `~/work/sample-ios-review-1`
    public static func poolPath(root: String, index: Int) -> URL {
        let rootURL = URL(fileURLWithPath: root)
        return rootURL.deletingLastPathComponent()
            .appendingPathComponent("\(rootURL.lastPathComponent)-review-\(index)", isDirectory: true)
    }

    private func lockFile(_ path: URL) -> URL { path.appendingPathComponent(".prayer-lock") }

    private func isLocked(_ path: URL) -> Bool {
        FileManager.default.fileExists(atPath: lockFile(path).path)
    }

    /// 지금 실제로 쓰이고 있는가. 락이 있고 아직 만료되지 않았으면 쓰는 중으로 본다.
    private func isBusy(_ path: URL) -> Bool {
        let file = lockFile(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < Self.lockTTL
    }

    private func lock(_ path: URL) {
        let text = "pid=\(ProcessInfo.processInfo.processIdentifier)\nat=\(Date())\n"
        try? text.write(to: lockFile(path), atomically: true, encoding: .utf8)
    }

    private func unlock(_ path: URL) {
        try? FileManager.default.removeItem(at: lockFile(path))
    }

    private func run(_ arguments: [String], in directory: String, timeout: TimeInterval) async throws -> ProcessResult {
        try await runner.run(ProcessSpec(executable: git,
                                         arguments: arguments,
                                         stdin: nil,
                                         currentDirectory: directory,
                                         environment: ProcessEnvironment.base(),
                                         timeout: timeout,
                                         gracePeriod: 5))
    }
}

public enum WorktreeError: LocalizedError {
    case notADirectory(String)
    case notARepository(String)
    case addFailed(String)
    case checkoutFailed(String)
    case fetchFilesFailed(String)
    case poolBusy(Int)
    case wrongRepository(expected: String, found: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path):
            return "폴더가 아닙니다: \(path)"
        case .notARepository(let path):
            // 클론 폴더를 고르는 칸은 0.5.0 에서 없앴다(PR 스냅샷). 예전에 연결한 폴더이거나 망가진 스냅샷이다.
            return "git 저장소가 아닙니다: \(path)\n설정 → 레포·팀 규칙에서 이 레포의 클론 연결을 끊거나 PR 스냅샷을 지우면, 다음 전체 리뷰 때 PR 스냅샷을 새로 받습니다."
        case .addFailed(let message):
            return "워크트리를 만들지 못했습니다: \(message)"
        case .checkoutFailed(let message):
            return "워크트리를 이 커밋으로 옮기지 못했습니다: \(message)"
        case .fetchFilesFailed(let message):
            return "리뷰할 커밋의 파일을 받지 못했습니다. \(message)"
        case .wrongRepository(let expected, let found, let path):
            return """
                다른 저장소를 가리키고 있어 전체 리뷰를 멈췄습니다.
                고른 폴더: \(path)
                그 폴더의 origin: \(found)
                필요한 저장소: \(expected)
                설정 → 레포·팀 규칙에서 이 레포의 연결을 끊으면 PR 스냅샷으로 리뷰합니다.
                """
        case .poolBusy(let limit):
            return "리뷰 워크트리 \(limit)개가 모두 리뷰 중입니다. 지금은 전체 리뷰를 시작할 수 없습니다 — 돌고 있는 리뷰가 끝나면 다시 시도하세요."
        }
    }
}
