import Foundation

/// 내가 승인한 커밋부터 지금 head 까지 무엇이 바뀌었나. 승인한 PR 에 붙는 이유 칩(`PRBadgeFollowUp.sinceApproval`)이
/// 이걸로 갈린다(2026-11-02 사용자 결정 — 예전에는 모두 "+N commits" 하나였다).
public struct SinceApproval: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 내가 코멘트를 단 파일이 바뀌었다 — 내 지적을 반영했을 가능성이 크다.
        case commentedFile
        /// 코드가 바뀌었다(내 코멘트가 걸린 파일은 아니다).
        case code
        /// 문서만 바뀌었다.
        case docsOnly
        /// 강제 푸시로 승인한 커밋이 브랜치에서 사라졌다 — 무엇이 바뀌었는지 셀 수 없다.
        case forcePushed
        /// base 브랜치를 받아온 머지뿐이다 — 작성자가 바꾼 것이 없다.
        case baseMergeOnly
    }

    public var kind: Kind
    /// 승인 뒤 커밋 수(머지 포함). 강제 푸시면 모른다.
    public var commits: Int?
    /// 작성자가 바꾼 파일(base 를 받아온 머지는 뺀다).
    public var files: [String]
    public var additions: Int
    public var deletions: Int
    /// 그중 내가 코멘트를 단 파일.
    public var commentedFiles: [String]

    public init(kind: Kind, commits: Int?, files: [String] = [], additions: Int = 0, deletions: Int = 0,
                commentedFiles: [String] = []) {
        self.kind = kind
        self.commits = commits
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.commentedFiles = commentedFiles
    }

    /// 바뀐 파일 한 개.
    public struct FileChange: Sendable, Equatable, Decodable {
        public var filename: String
        public var additions: Int
        public var deletions: Int

        public init(filename: String, additions: Int, deletions: Int) {
            self.filename = filename
            self.additions = additions
            self.deletions = deletions
        }
    }

    /// 승인한 커밋...head 비교(GitHub compare API 를 추린 것).
    public struct Comparison: Sendable, Equatable, Decodable {
        public struct Commit: Sendable, Equatable, Decodable {
            public var sha: String
            /// 부모 수 — 2 이상이면 머지 커밋.
            public var parents: Int

            public init(sha: String, parents: Int) {
                self.sha = sha
                self.parents = parents
            }
        }
        /// ahead · behind · diverged · identical.
        public var status: String
        public var commits: [Commit]
        public var files: [FileChange]

        public init(status: String, commits: [Commit], files: [FileChange]) {
            self.status = status
            self.commits = commits
            self.files = files
        }

        /// 작성자가 만든 커밋(머지가 아닌 것).
        public var authorCommits: [Commit] { commits.filter { $0.parents < 2 } }
        /// 머지와 작성자 커밋이 섞였나. 그러면 compare 의 파일 목록에 base 에서 받아온 변경까지 들어 있어서, 작성자
        /// 커밋마다 파일을 따로 받아야 한다.
        public var needsAuthorFiles: Bool { !authorCommits.isEmpty && authorCommits.count < commits.count }
    }

    /// 비교 결과로 가른다.
    /// - Parameters:
    ///   - authorFiles: 머지와 작성자 커밋이 섞였을 때 작성자 커밋들의 파일. nil 이면 compare 의 파일을 쓴다.
    ///   - commentedPaths: 내가 코멘트를 단 파일들.
    public static func classify(_ comparison: Comparison?, authorFiles: [FileChange]? = nil,
                                commentedPaths: Set<String>) -> SinceApproval {
        // 승인한 커밋이 head 의 조상이 아니면(강제 푸시) diverged 나 behind 로 온다. 커밋이 아예 없어진 것은 nil 로 온다.
        guard let comparison, comparison.status == "ahead" || comparison.status == "identical" else {
            return SinceApproval(kind: .forcePushed, commits: nil)
        }
        let count = comparison.commits.count
        if comparison.authorCommits.isEmpty, count > 0 {
            return SinceApproval(kind: .baseMergeOnly, commits: count)
        }
        var byPath: [String: (Int, Int)] = [:]
        var order: [String] = []
        for file in authorFiles ?? comparison.files {
            if byPath[file.filename] == nil { order.append(file.filename) }
            let old = byPath[file.filename] ?? (0, 0)
            byPath[file.filename] = (old.0 + file.additions, old.1 + file.deletions)
        }
        let additions = byPath.values.reduce(0) { $0 + $1.0 }
        let deletions = byPath.values.reduce(0) { $0 + $1.1 }
        let commented = order.filter { commentedPaths.contains($0) }
        let kind: Kind
        if !commented.isEmpty {
            kind = .commentedFile
        } else if !order.isEmpty, order.allSatisfy(isDocument) {
            kind = .docsOnly
        } else {
            kind = .code
        }
        return SinceApproval(kind: kind, commits: count, files: order, additions: additions, deletions: deletions,
                             commentedFiles: commented)
    }

    /// 문서 파일인가. 확장자가 .md 여도 에이전트 지시 파일(SKILL.md·CLAUDE.md, .claude 의 agents·commands·rules)은
    /// 동작을 바꾸므로 코드로 친다 — 그걸 "문서만" 이라 하면 지시가 바뀐 것을 놓친다.
    public static func isDocument(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard ["md", "markdown", "txt", "rst", "adoc"].contains((name as NSString).pathExtension) else { return false }
        if ["skill.md", "claude.md", "agents.md", "gemini.md"].contains(name) { return false }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(".claude"), parts.contains(where: { ["agents", "commands", "rules"].contains($0) }) {
            return false
        }
        return true
    }

    /// 칩에 마우스를 올렸을 때 셋째 줄 — "2 commits · 2 files · +123 −41 since approval".
    public var numbersLine: String? {
        guard let commits else { return nil }
        let commitText = commits == 1 ? "1 commit" : "\(commits) commits"
        guard kind != .baseMergeOnly else { return "\(commitText) since approval" }
        let fileText = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(commitText) · \(fileText) · +\(additions) −\(deletions) since approval"
    }
}
