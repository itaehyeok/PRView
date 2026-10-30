import Foundation

/// 전체 리뷰용 클론 — 화면에서는 "PR 스냅샷" 이라 부른다.
///
/// 예전에는 사용자가 이 맥에 받아 둔 클론을 직접 골라야 전체 리뷰가 됐다. 처음 쓰는 사람은 클론부터 해 와야
/// 했고, 리뷰용 워크트리가 사용자 클론 옆에 생겨 그 저장소의 `git worktree list` 에 끼어들었다. 이제는 앱 데이터
/// 폴더에 레포마다 하나씩 가벼운 클론을 둔다(사용자 결정, 2026-10-06). 앱 자기 폴더라 macOS 가 권한을 묻지 않는다.
///
/// 가벼운 클론(`--filter=blob:none --no-checkout`): 커밋·폴더 구조는 다 받고 파일 내용은 리뷰할 커밋에 필요한
/// 것만 그때 받는다. 실측(큰 레포): 처음 클론 12초·64MB, 리뷰할 커밋의 파일 14초·63MB, 다음 PR 은 달라진
/// 파일만(77개 3초). 지난 버전들의 파일 내용(대부분의 용량)은 리뷰가 읽지 않아 받지 않는다. 받은 것은 지우지 않고
/// 쌓이지만 레포 전체 크기를 넘지는 않는다 — 자동으로 지우지 않고 설정에서 사람이 지운다(사용자 결정).
///
/// 예전 버전에서 내 클론을 연결해 둔 레포는 그 클론을 그대로 쓴다(`ReviewSource.linked`).
public enum ReviewClone {
    /// `~/Library/Application Support/PRayer/review-clones`.
    /// (`pr-snapshots.json` 은 목록 변화 감지용 파일이라 이름만 비슷하고 무관하다.)
    public static var directory: URL {
        AppPaths.support.appendingPathComponent("review-clones", isDirectory: true)
    }

    /// 레포 하나의 클론 자리: `review-clones/<owner>/<name>`. 리뷰용 워크트리는 그 옆
    /// `<name>-review-1`, `-2`, … 에 생긴다(WorktreeManager.poolPath).
    public static func path(for repo: RepoID, base: URL = directory) -> URL {
        base.appendingPathComponent(repo.owner, isDirectory: true)
            .appendingPathComponent(repo.name, isDirectory: true)
    }

    /// 받는 동안 쓰는 자리. 다 받은 뒤 `path(for:)` 로 이름을 바꾼다 — git 은 `.git` 을 맨 처음 만들어서,
    /// 받다가 앱이 죽으면 반쯤 받은 폴더가 완성된 클론처럼 보인다.
    static func stagingPath(for repo: RepoID, base: URL = directory) -> URL {
        base.appendingPathComponent(repo.owner, isDirectory: true)
            .appendingPathComponent("\(repo.name).cloning", isDirectory: true)
    }

    public static func exists(_ repo: RepoID, base: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: path(for: repo, base: base).appendingPathComponent(".git").path)
    }

    /// 이 레포 몫으로 앱이 만든 폴더 전부 — 클론, 리뷰용 워크트리, 받다 만 자리.
    public static func folders(for repo: RepoID, base: URL = directory) -> [URL] {
        let root = path(for: repo, base: base)
        let pools = (1...WorktreeManager.poolLimit).map { WorktreeManager.poolPath(root: root.path, index: $0) }
        return ([root] + pools + [stagingPath(for: repo, base: base)])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 받은 날 — 클론 폴더가 생긴 때.
    public static func createdAt(_ repo: RepoID, base: URL = directory) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path(for: repo, base: base).path)
        return attributes?[.creationDate] as? Date
    }

    /// 디스크에서 차지하는 크기(바이트). 파일이 수만 개라 메인 스레드에서 부르지 않는다.
    public static func size(of repo: RepoID, base: URL = directory) -> Int64 {
        folders(for: repo, base: base).reduce(0) { $0 + directorySize($1) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// 지운다. 앱이 만든 폴더만 — `base` 밖은 어떤 경우에도 건드리지 않는다.
    public static func delete(_ repo: RepoID, base: URL = directory) throws {
        for folder in folders(for: repo, base: base) where isInside(folder, base) {
            try FileManager.default.removeItem(at: folder)
        }
        // 오너 폴더가 비면 같이 치운다. 다른 레포가 남아 있으면 그대로 둔다.
        let owner = base.appendingPathComponent(repo.owner, isDirectory: true)
        if isInside(owner, base), (try? FileManager.default.contentsOfDirectory(atPath: owner.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: owner)
        }
    }

    static func isInside(_ url: URL, _ base: URL) -> Bool {
        let root = base.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target.hasPrefix(root.hasSuffix("/") ? root : root + "/") && !target.contains("/../")
    }

    /// 클론 주소. 토큰을 주소에 넣지 않는다 — 인증은 gh 가 git 에 직접 넘긴다(`credentialHelper`).
    public static func remoteURL(for repo: RepoID, host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return "https://\(trimmed.isEmpty ? GitHubHost.dotCom : trimmed)/\(repo.owner)/\(repo.name).git"
    }

    /// git 이 인증을 물으면 이 맥의 gh 로그인을 쓰게 한다. 앞에 빈 값을 두는 건 사용자 전역 설정의 다른
    /// 도우미(osxkeychain 등)를 끊으려는 것 — 그대로 두면 키체인 창이 뜨거나 다른 계정으로 붙는다.
    public static func credentialHelper(ghPath: String) -> String {
        "!'\(ghPath)' auth git-credential"
    }
}

/// 클론하지 못한 까닭. 화면에는 원인별로 다른 한 줄을 보인다(git 오류 원문은 로그에만).
public enum ReviewCloneError: LocalizedError, Equatable {
    case ghMissing
    case network
    case access
    case disk
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .ghMissing: return "gh 를 찾지 못했습니다. 설정 › 연결에서 GitHub 로그인을 확인하세요."
        case .network: return "네트워크 연결을 확인하고 다시 시도하세요."
        case .access: return "이 레포에 접근할 수 없습니다. GitHub 로그인을 확인하세요."
        case .disk: return "디스크 공간이 부족합니다."
        case .other(let detail): return detail.isEmpty ? "클론하지 못했습니다." : "클론하지 못했습니다: \(detail)"
        }
    }

    /// git 표준 오류로 원인을 가른다.
    static func classify(stderr: String) -> ReviewCloneError {
        let text = stderr.lowercased()
        if text.contains("no space left on device") { return .disk }
        if ["authentication failed", "could not read username", "repository not found",
            "terminal prompts disabled", "returned error: 403", "permission denied"].contains(where: text.contains) {
            return .access
        }
        if ["could not resolve host", "failed to connect", "timed out", "unable to access",
            "connection reset", "network is unreachable", "early eof"].contains(where: text.contains) {
            return .network
        }
        let line = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }) ?? ""
        return .other(line)
    }
}

/// PR 스냅샷을 처음 한 번 받는다.
public struct ReviewCloner: Sendable {
    public let ghPath: String
    public let host: String
    private let git: GitProgressRunner

    public init(ghPath: String, host: String, gitPath: String = "/usr/bin/git") {
        self.ghPath = ghPath
        self.host = host
        self.git = GitProgressRunner(git: gitPath)
    }

    /// 다 받으면 클론 자리를 돌려준다. 실패하거나 취소되면 받던 폴더를 지운다.
    public func clone(_ repo: RepoID, base: URL = ReviewClone.directory,
                      onProgress: (@Sendable (GitProgress) -> Void)? = nil) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: ghPath) else { throw ReviewCloneError.ghMissing }
        let fm = FileManager.default
        let target = ReviewClone.path(for: repo, base: base)
        let staging = ReviewClone.stagingPath(for: repo, base: base)
        // 받다 만 자리가 남아 있으면(앱이 죽었거나 끊겼을 때) 처음부터 다시 받는다.
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = ReviewClone.credentialHelper(ghPath: ghPath)
        do {
            let result = try await git.run(["-c", "credential.helper=", "-c", "credential.helper=\(helper)",
                                            "clone", "--progress", "--filter=blob:none", "--no-checkout",
                                            ReviewClone.remoteURL(for: repo, host: host), staging.path],
                                           in: staging.deletingLastPathComponent().path,
                                           timeout: 3600, onProgress: onProgress)
            if result.cancelled || Task.isCancelled { throw CancellationError() }
            guard result.succeeded else {
                Log.error("PR 스냅샷 클론 실패 \(repo.full): \(result.stderr.suffix(400))", "snapshot")
                throw ReviewCloneError.classify(stderr: result.stderr)
            }
            try await writeCredentialHelper(in: staging)
            // 혹시 예전 것이 남아 있으면(지우다 만 경우) 치우고 이름을 바꾼다.
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
            Log.info("PR 스냅샷 클론 완료 \(repo.full)", "snapshot")
            return target
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// 다음 fetch(리뷰마다 PR 받기·파일 받기)도 gh 로 인증하게 이 클론에 적어 둔다. gh 자리가 바뀌었을 수
    /// 있어 리뷰할 때마다 다시 적는다(같으면 그대로).
    public func writeCredentialHelper(in clone: URL) async throws {
        let helper = ReviewClone.credentialHelper(ghPath: ghPath)
        let current = try await git.run(["config", "--local", "--get-all", "credential.helper"],
                                        in: clone.path, timeout: 30)
        // 빈 값도 한 줄이라 빈 줄을 버리지 않고 센다.
        var lines = current.stdout.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines == ["", helper] { return }
        _ = try await git.run(["config", "--local", "--replace-all", "credential.helper", ""], in: clone.path, timeout: 30)
        _ = try await git.run(["config", "--local", "--add", "credential.helper", helper], in: clone.path, timeout: 30)
    }
}

/// 전체 리뷰가 어느 클론을 읽을지.
public enum ReviewSource: Equatable, Sendable {
    /// 예전 버전에서 연결한 내 클론 — 그대로 쓴다.
    case linked(path: String)
    /// PRayer 폴더의 PR 스냅샷.
    case snapshot(path: String)
    /// 아직 없다 — 처음 받는다(확인창). 연결해 둔 폴더가 사라졌으면 그 경로를 같이 알린다.
    case needsSnapshot(missingLinkedPath: String?)

    public static func resolve(linkedPath: String?, linkedExists: Bool,
                               snapshotPath: String, snapshotExists: Bool) -> ReviewSource {
        if let linkedPath, !linkedPath.isEmpty {
            if linkedExists { return .linked(path: linkedPath) }
            return snapshotExists ? .snapshot(path: snapshotPath) : .needsSnapshot(missingLinkedPath: linkedPath)
        }
        return snapshotExists ? .snapshot(path: snapshotPath) : .needsSnapshot(missingLinkedPath: nil)
    }

    /// 지금 이 맥의 상태로 판단한다.
    public static func current(for repo: RepoID, linkedPath: String?, base: URL = ReviewClone.directory) -> ReviewSource {
        let linkedExists = linkedPath.map { path -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        } ?? false
        return resolve(linkedPath: linkedPath, linkedExists: linkedExists,
                       snapshotPath: ReviewClone.path(for: repo, base: base).path,
                       snapshotExists: ReviewClone.exists(repo, base: base))
    }
}

/// 확인창에 보일 크기. GitHub 에 물어 1초 남짓이면 온다(실측: 트리 1.1~1.5초, 레포 0.7초).
public struct CodeSize: Equatable, Sendable {
    /// 그 커밋의 파일 수.
    public var files: Int
    /// 그 커밋의 파일 크기 합(압축 전).
    public var bytes: Int64
    /// GitHub 가 목록을 잘라 보냈는가(파일 10만 개 이상). 그러면 크기가 실제보다 작다.
    public var truncated: Bool

    public init(files: Int, bytes: Int64, truncated: Bool) {
        self.files = files
        self.bytes = bytes
        self.truncated = truncated
    }
}

/// 크기를 짧게 — `120MB`, `2.3GB`. 화면의 다른 숫자(측정값)와 맞추려고 1024 단위를 쓴다.
public enum ByteSizeText {
    public static func short(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1fGB", gb) }
        if mb >= 1 { return "\(Int(mb.rounded()))MB" }
        return "\(max(1, Int(kb.rounded())))KB"
    }
}
