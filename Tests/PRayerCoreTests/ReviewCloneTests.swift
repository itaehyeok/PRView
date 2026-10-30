import XCTest
@testable import PRayerCore

/// PR 스냅샷(전체 리뷰용 가벼운 클론) — 어느 클론을 읽을지, 어디에 두는지, 무엇을 지우는지, git 진행을 어떻게 읽는지.
final class ReviewCloneTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    // MARK: 어느 클론을 읽는가

    /// 예전 버전에서 연결해 둔 클론이 그대로 있으면 그것을 쓴다(사용자 결정 — 잘 쓰는 사람은 바꾸지 않는다).
    func testLinkedCloneWinsWhileItExists() {
        XCTAssertEqual(ReviewSource.resolve(linkedPath: "/w/sample-ios", linkedExists: true,
                                            snapshotPath: "/s", snapshotExists: true),
                       .linked(path: "/w/sample-ios"))
    }

    /// 연결한 폴더가 지워졌으면 PR 스냅샷으로 넘어간다. 스냅샷도 없으면 처음 받기 — 확인 창에 사라진 경로를 알린다.
    func testMissingLinkedFolderFallsBackToSnapshot() {
        XCTAssertEqual(ReviewSource.resolve(linkedPath: "/w/gone", linkedExists: false,
                                            snapshotPath: "/s", snapshotExists: true),
                       .snapshot(path: "/s"))
        XCTAssertEqual(ReviewSource.resolve(linkedPath: "/w/gone", linkedExists: false,
                                            snapshotPath: "/s", snapshotExists: false),
                       .needsSnapshot(missingLinkedPath: "/w/gone"))
    }

    func testNoLinkUsesSnapshotOrAsksFirst() {
        XCTAssertEqual(ReviewSource.resolve(linkedPath: nil, linkedExists: false, snapshotPath: "/s", snapshotExists: true),
                       .snapshot(path: "/s"))
        XCTAssertEqual(ReviewSource.resolve(linkedPath: "", linkedExists: false, snapshotPath: "/s", snapshotExists: false),
                       .needsSnapshot(missingLinkedPath: nil))
    }

    // MARK: 자리

    /// 레포마다 `review-clones/<owner>/<name>`, 리뷰용 워크트리는 그 옆 `<name>-review-N`.
    func testLayoutUnderAppFolder() {
        let base = URL(fileURLWithPath: "/tmp/prayer-test/review-clones")
        XCTAssertEqual(ReviewClone.path(for: repo, base: base).path, "/tmp/prayer-test/review-clones/acme/sample-ios")
        XCTAssertEqual(WorktreeManager.poolPath(root: ReviewClone.path(for: repo, base: base).path, index: 1).path,
                       "/tmp/prayer-test/review-clones/acme/sample-ios-review-1")
    }

    /// 받다 만 클론은 완성된 클론으로 보이면 안 된다 — git 은 `.git` 을 맨 처음 만든다. 그래서 다른 이름으로 받고 끝에 바꾼다.
    func testHalfClonedFolderIsNotASnapshot() throws {
        let base = try temporaryBase()
        let staging = ReviewClone.stagingPath(for: repo, base: base)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertFalse(ReviewClone.exists(repo, base: base))
        try FileManager.default.createDirectory(at: ReviewClone.path(for: repo, base: base).appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(ReviewClone.exists(repo, base: base))
    }

    /// 지우기는 앱이 만든 폴더(클론·리뷰용 워크트리·받다 만 자리)만, 그 레포 몫만 지운다.
    func testDeleteRemovesOnlyThisRepoFolders() throws {
        let base = try temporaryBase()
        let fm = FileManager.default
        let root = ReviewClone.path(for: repo, base: base)
        let pool = WorktreeManager.poolPath(root: root.path, index: 2)
        let other = ReviewClone.path(for: RepoID(owner: "acme", name: "sample-sdk"), base: base)
        for folder in [root.appendingPathComponent(".git"), pool, other.appendingPathComponent(".git")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: pool.appendingPathComponent("file.swift"))
        XCTAssertGreaterThan(ReviewClone.size(of: repo, base: base), 0)

        try ReviewClone.delete(repo, base: base)
        XCTAssertFalse(fm.fileExists(atPath: root.path))
        XCTAssertFalse(fm.fileExists(atPath: pool.path))
        XCTAssertTrue(ReviewClone.exists(RepoID(owner: "acme", name: "sample-sdk"), base: base))
        XCTAssertEqual(ReviewClone.size(of: repo, base: base), 0)
    }

    /// 오너 폴더는 비면 같이 치운다.
    func testDeleteLastRepoRemovesEmptyOwnerFolder() throws {
        let base = try temporaryBase()
        try FileManager.default.createDirectory(at: ReviewClone.path(for: repo, base: base).appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try ReviewClone.delete(repo, base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("acme").path))
    }

    func testIsInsideRejectsEscapes() {
        let base = URL(fileURLWithPath: "/tmp/x/review-clones")
        XCTAssertTrue(ReviewClone.isInside(URL(fileURLWithPath: "/tmp/x/review-clones/a/b"), base))
        XCTAssertFalse(ReviewClone.isInside(URL(fileURLWithPath: "/tmp/x/review-clones-other/a"), base))
        XCTAssertFalse(ReviewClone.isInside(URL(fileURLWithPath: "/tmp/x"), base))
    }

    // MARK: 주소·인증

    /// 주소에 토큰을 넣지 않는다. 엔터프라이즈는 호스트만 바뀐다.
    func testRemoteURLPerHost() {
        XCTAssertEqual(ReviewClone.remoteURL(for: repo, host: "github.com"), "https://github.com/acme/sample-ios.git")
        XCTAssertEqual(ReviewClone.remoteURL(for: repo, host: "github.acme.dev"), "https://github.acme.dev/acme/sample-ios.git")
        XCTAssertEqual(ReviewClone.remoteURL(for: repo, host: " "), "https://github.com/acme/sample-ios.git")
    }

    func testCredentialHelperUsesGhLogin() {
        XCTAssertEqual(ReviewClone.credentialHelper(ghPath: "/opt/homebrew/bin/gh"), "!'/opt/homebrew/bin/gh' auth git-credential")
    }

    /// 화면에는 git 원문 대신 원인별 한 줄을 보인다.
    func testCloneErrorsAreClassified() {
        XCTAssertEqual(ReviewCloneError.classify(stderr: "fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com"),
                       .network)
        XCTAssertEqual(ReviewCloneError.classify(stderr: "remote: Repository not found.\nfatal: repository 'https://github.com/a/b.git/' not found"),
                       .access)
        XCTAssertEqual(ReviewCloneError.classify(stderr: "fatal: could not read Username for 'https://github.com': terminal prompts disabled"),
                       .access)
        XCTAssertEqual(ReviewCloneError.classify(stderr: "error: unable to write file: No space left on device"), .disk)
        XCTAssertEqual(ReviewCloneError.classify(stderr: "fatal: something odd"), .other("fatal: something odd"))
    }

    // MARK: 크기

    func testShortByteSize() {
        XCTAssertEqual(ByteSizeText.short(192_262_360), "183MB")
        XCTAssertEqual(ByteSizeText.short(1_769_996_288), "1.6GB")
        XCTAssertEqual(ByteSizeText.short(323_481), "316KB")
        XCTAssertEqual(ByteSizeText.short(10), "1KB")
    }

    /// gh 안에서 센 결과(`--jq`)를 읽는다.
    func testParseCodeSize() {
        XCTAssertEqual(GitHubClient.parseCodeSize(#"{"b":192262360,"n":13807,"t":false}"#),
                       CodeSize(files: 13807, bytes: 192_262_360, truncated: false))
        XCTAssertEqual(GitHubClient.parseCodeSize(#"{"b":null,"n":0,"t":true}"#), CodeSize(files: 0, bytes: 0, truncated: true))
        XCTAssertNil(GitHubClient.parseCodeSize("not json"))
    }

    // MARK: 빠진 파일

    /// `rev-list --missing=print` 는 없는 객체를 `?<id>` 로 적는다. 그것만 받으러 간다.
    func testMissingObjectIDs() {
        let output = """
            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            ?0a1b2c3d4e5f60718293a4b5c6d7e8f901234567
            4b825dc642cb6eb9a060e54bf8d69288fbee4904
            ?ffeeddccbbaa99887766554433221100ffeeddcc
            """
        XCTAssertEqual(WorktreeManager.missingObjectIDs(fromRevList: output),
                       ["0a1b2c3d4e5f60718293a4b5c6d7e8f901234567", "ffeeddccbbaa99887766554433221100ffeeddcc"])
        XCTAssertTrue(WorktreeManager.missingObjectIDs(fromRevList: "").isEmpty)
    }

    private func temporaryBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("prayer-review-clones-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
}

/// git 진행 줄 읽기. 실측한 줄을 그대로 넣었다(2026-10-06, 1.7GB 레포 클론·파일 받기·체크아웃).
final class GitProgressTests: XCTestCase {
    func testReceivingWithSizeAndSpeed() {
        let progress = GitProgress.parse(line: "Receiving objects:  99% (479892/484739), 44.71 MiB | 7.83 MiB/s")
        XCTAssertEqual(progress, GitProgress(stage: .receiving, percent: 99, done: 479_892, total: 484_739,
                                             transferred: "44.71 MiB", speed: "7.83 MiB/s"))
        XCTAssertEqual(GitProgress.parse(line: "Receiving objects: 100% (77/77), 315.90 KiB | 572.00 KiB/s, done.")?.speed,
                       "572.00 KiB/s")
    }

    func testResolvingAndUpdating() {
        XCTAssertEqual(GitProgress.parse(line: "Resolving deltas: 100% (351376/351376), done.")?.stage, .resolving)
        let updating = GitProgress.parse(line: "Updating files:  40% (5557/13807)")
        XCTAssertEqual(updating?.stage, .updating)
        XCTAssertEqual(updating?.done, 5557)
        XCTAssertEqual(updating?.total, 13807)
        XCTAssertNil(updating?.transferred)
    }

    /// 서버 쪽 줄(remote:)·안내 줄은 진행이 아니다.
    func testIgnoresOtherLines() {
        XCTAssertNil(GitProgress.parse(line: "remote: Compressing objects: 100% (431/431), done."))
        XCTAssertNil(GitProgress.parse(line: "Cloning into 'sample-ios'..."))
        XCTAssertNil(GitProgress.parse(line: "HEAD is now at aaaaaaaaaa fix: 수정"))
    }

    /// 파일에는 갱신이 `\r` 로 이어 붙는다. 마지막 진행 줄을 찾는다.
    func testLastProgressAcrossCarriageReturns() {
        let text = "Cloning into 'x'...\nremote: Enumerating objects: 10, done.\n"
            + "Receiving objects:  10% (1/10)\rReceiving objects:  50% (5/10), 1.00 MiB | 2.00 MiB/s\r"
            + "Receiving objects: 100% (10/10), 2.00 MiB | 2.00 MiB/s, done.\nResolving deltas:  30% (3/10)\r"
        let last = GitProgress.last(in: text)
        XCTAssertEqual(last?.stage, .resolving)
        XCTAssertEqual(last?.percent, 30)
        XCTAssertNil(GitProgress.last(in: "Cloning into 'x'...\n"))
    }

    func testFractionPrefersCounts() {
        XCTAssertEqual(GitProgress(stage: .updating, percent: 40, done: 5557, total: 13807).fraction, 5557.0 / 13807.0, accuracy: 0.0001)
        XCTAssertEqual(GitProgress(stage: .receiving, percent: 50, done: 0, total: 0).fraction, 0.5)
    }
}
