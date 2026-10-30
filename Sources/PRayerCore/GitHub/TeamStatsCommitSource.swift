import Foundation

/// 팀 통계의 커밋 수 재료 — 레포의 **모든 원격 브랜치** 커밋.
///
/// GitHub API 로 브랜치마다 기록을 받으면 큰 레포(브랜치 524개)에서 두 달치에 2분 반이 걸렸다(실측: 호출
/// 153번). 브랜치마다 develop 기록을 다시 훑기 때문이다. 대신 커밋만 담은 클론(`--filter=tree:0`, 파일·폴더
/// 구조 없이 커밋만)을 앱 데이터 폴더에 두고 `git log` 로 센다 — 처음 받기 10초·19MB, 다음부터는 fetch 3초에
/// 읽기 0.1초. 결과는 사람이 받아 둔 클론의 `git log --remotes` 와 같다(1,796개, 차이 0).
///
/// 전체 리뷰의 PR 스냅샷(`ReviewClone`)과 따로 둔다 — 그쪽은 사람이 설정에서 받고 지우는 것이고, 이건 통계
/// 통계를 열면 앱이 알아서 받는 작은 것이다.
public enum TeamStatsClone {
    /// `~/Library/Application Support/PRayer/stats-clones`.
    public static var directory: URL {
        AppPaths.support.appendingPathComponent("stats-clones", isDirectory: true)
    }

    /// `stats-clones/<owner>/<name>.git` (작업 폴더가 없는 bare 클론).
    public static func path(for repo: RepoID, base: URL = directory) -> URL {
        base.appendingPathComponent(repo.owner, isDirectory: true)
            .appendingPathComponent("\(repo.name).git", isDirectory: true)
    }

    /// 받는 동안의 자리 — 받다 만 폴더가 다 받은 클론처럼 보이지 않게(ReviewClone 과 같은 까닭).
    static func stagingPath(for repo: RepoID, base: URL = directory) -> URL {
        base.appendingPathComponent(repo.owner, isDirectory: true)
            .appendingPathComponent("\(repo.name).git.cloning", isDirectory: true)
    }

    public static func exists(_ repo: RepoID, base: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: path(for: repo, base: base).appendingPathComponent("HEAD").path)
    }
}

public struct TeamStatsCommitSource: Sendable {
    public let ghPath: String
    public let host: String
    private let git: GitProgressRunner

    public init(ghPath: String, host: String, gitPath: String = "/usr/bin/git") {
        self.ghPath = ghPath
        self.host = host
        self.git = GitProgressRunner(git: gitPath)
    }

    /// 클론이 없으면 받고, 있으면 최신으로 맞춘 뒤 `since` 뒤의 커밋(머지 커밋 제외)을 읽는다.
    public func commits(_ repo: RepoID, since: Date, base: URL = TeamStatsClone.directory) async throws -> [TeamStatCommit] {
        guard FileManager.default.isExecutableFile(atPath: ghPath) else { throw ReviewCloneError.ghMissing }
        let clone = TeamStatsClone.path(for: repo, base: base)
        if TeamStatsClone.exists(repo, base: base) {
            try await fetch(clone)
        } else {
            try await cloneFresh(repo, base: base)
        }
        // `--since` 는 커밋한 시각 기준이다. 리베이스한 커밋은 커밋한 시각이 작성 시각보다 늦어 빠지지 않는다.
        // 시계가 어긋난 커밋을 위해 하루 넉넉히 읽고, 기간은 작성 시각으로 다시 거른다.
        let from = since.addingTimeInterval(-86_400)
        let result = try await git.run(["log", "--branches", "--no-merges",
                                        "--since=\(ISO8601DateFormatter().string(from: from))",
                                        "--format=\(TeamStats.commitLogFormat)"],
                                       in: clone.path, timeout: 120)
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard result.succeeded else { throw ReviewCloneError.other(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return TeamStats.parseCommitLog(result.stdout).filter { $0.authoredAt >= since }
    }

    private var credentialArguments: [String] {
        ["-c", "credential.helper=", "-c", "credential.helper=\(ReviewClone.credentialHelper(ghPath: ghPath))"]
    }

    private func cloneFresh(_ repo: RepoID, base: URL) async throws {
        let fm = FileManager.default
        let target = TeamStatsClone.path(for: repo, base: base)
        let staging = TeamStatsClone.stagingPath(for: repo, base: base)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let result = try await git.run(credentialArguments + ["clone", "--bare", "--filter=tree:0", "--quiet",
                                                                  ReviewClone.remoteURL(for: repo, host: host), staging.path],
                                           in: staging.deletingLastPathComponent().path, timeout: 600)
            if result.cancelled || Task.isCancelled { throw CancellationError() }
            guard result.succeeded else {
                Log.error("통계 클론 실패 \(repo.full): \(result.stderr.suffix(400))", "stats")
                throw ReviewCloneError.classify(stderr: result.stderr)
            }
            // bare 클론에는 fetch 규칙이 없어 다음 fetch 가 새 브랜치를 안 받는다. 브랜치를 그대로 비춘다.
            _ = try await git.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"],
                                  in: staging.path, timeout: 30)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
            Log.info("통계 클론 완료 \(repo.full)", "stats")
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// 지워진 브랜치는 `--prune` 으로 같이 지운다. 안 지우면 머지되고 지워진 브랜치의 리베이스 전 커밋이
    /// 계속 남아 같은 일을 두 번 센다.
    private func fetch(_ clone: URL) async throws {
        let result = try await git.run(credentialArguments + ["fetch", "--prune", "--quiet", "origin"],
                                       in: clone.path, timeout: 300)
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard result.succeeded else {
            Log.error("통계 클론 fetch 실패: \(result.stderr.suffix(400))", "stats")
            throw ReviewCloneError.classify(stderr: result.stderr)
        }
    }
}
