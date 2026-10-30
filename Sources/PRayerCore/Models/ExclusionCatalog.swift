import Foundation

/// 제외 규칙 자동완성의 재료 — 레포에 있는 파일(기본 브랜치)과 최근 PR 에서 바뀐 파일.
///
/// 설정 › 대상 제외의 칸에 `*.pl` 을 치면 `*.plist` 를 띄운다(사용자 요청, 2026-10-06). 제외 규칙이 실제로 힘을 쓰는
/// 건 PR 에 나오는 파일이라, 최근 PR 에서 자주 바뀐 것을 위로 올린다(사용자 결정). 베타 6 에서 직접 적는 칸을 없앴다가
/// (고르게 하면 귀찮다) 자동완성과 함께 되살렸다 — 잠금 파일 자동 제외(LockFiles)는 그대로다.
///
/// 후보는 `Glob` 이 읽는 꼴 그대로 만든다: 확장자 `*.plist`, 확장자 달린 폴더 `*.xcassets/*`, 폴더 `Pods/*`,
/// 파일 이름 `Package.resolved`. fnmatch 의 `*` 는 `/` 도 넘어서, 셋 다 경로 어디에 있든 걸린다.
public struct ExclusionCatalog: Sendable, Equatable {
    /// PR 에서 바뀐 파일 하나.
    public struct PRFile: Sendable, Equatable, Decodable {
        public var path: String
        public var additions: Int
        public var deletions: Int

        public init(path: String, additions: Int, deletions: Int) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
        }
    }

    public struct Suggestion: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case fileExtension
            case folder
            case fileName

            /// 화면의 작은 꼬리표.
            public var label: String {
                switch self {
                case .fileExtension: return "확장자"
                case .folder: return "폴더"
                case .fileName: return "파일 이름"
                }
            }
        }

        public var pattern: String
        public var kind: Kind
        /// 레포 파일 중 이 규칙에 걸리는 수(보는 레포를 합친 값).
        public var repoFiles: Int
        /// 최근 PR 중 이 규칙에 걸리는 파일을 바꾼 PR 수.
        public var prCount: Int
        /// 그 PR 들에서 걸리는 파일의 바뀐 줄 합.
        public var changedLines: Int
        /// 코드 파일을 빼는 규칙 — 빼면 리뷰가 그 코드를 못 본다. 화면이 경고를 붙인다.
        public var isCode: Bool
        /// 찾을 때 견주는 글자(확장자·이름). 소문자.
        var key: String

        public var id: String { pattern }
    }

    /// 레포 파일 경로(보는 레포를 합친 것).
    public let paths: [String]
    /// 최근 PR 마다 바뀐 파일.
    public let pullRequests: [[PRFile]]
    private let candidates: [Suggestion]

    public var prTotal: Int { pullRequests.count }
    public var isEmpty: Bool { paths.isEmpty && pullRequests.isEmpty }

    public init(paths: [String], pullRequests: [[PRFile]]) {
        self.paths = paths
        self.pullRequests = pullRequests
        self.candidates = Self.buildCandidates(paths: paths, pullRequests: pullRequests)
    }

    // MARK: 찾기

    /// 친 글자에 맞는 후보. 앞부분이 맞는 것 → 가운데가 맞는 것 순으로, 그 안에서는 최근 PR 에서 자주 바뀐 것 →
    /// 바뀐 줄이 많은 것 → 레포에 많은 것 순.
    ///
    /// `*.` 로 시작하면 확장자(와 확장자 달린 폴더)만 찾는다 — `*.pl` 에 `Podfile` 같은 이름이 끼면 헷갈린다.
    public func suggestions(for query: String, limit: Int = 7) -> [Suggestion] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = Self.normalized(raw)
        guard !needle.isEmpty else { return [] }
        let extensionsOnly = raw.hasPrefix("*.")
        var scored: [(tier: Int, suggestion: Suggestion)] = []
        for candidate in candidates {
            if extensionsOnly, candidate.kind == .fileName { continue }
            if extensionsOnly, candidate.kind == .folder, !candidate.pattern.hasPrefix("*.") { continue }
            if candidate.key.hasPrefix(needle) {
                scored.append((0, candidate))
            } else if needle.count >= 3, candidate.key.contains(needle) {
                scored.append((1, candidate))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let a = lhs.suggestion, b = rhs.suggestion
            if a.prCount != b.prCount { return a.prCount > b.prCount }
            if a.changedLines != b.changedLines { return a.changedLines > b.changedLines }
            if a.repoFiles != b.repoFiles { return a.repoFiles > b.repoFiles }
            return a.pattern < b.pattern
        }
        return Array(scored.prefix(limit).map(\.suggestion))
    }

    /// 이미 있는 규칙(아무 꼴이든)이 몇 개를 거는지 — 목록 옆 숫자. `Glob` 으로 그대로 잰다.
    public func stats(for pattern: String) -> (repoFiles: Int, prCount: Int) {
        let repoFiles = paths.reduce(0) { $0 + (Glob.matches(path: $1, pattern: pattern) ? 1 : 0) }
        let prCount = pullRequests.reduce(0) { count, files in
            count + (files.contains { Glob.matches(path: $0.path, pattern: pattern) } ? 1 : 0)
        }
        return (repoFiles, prCount)
    }

    /// `*.PL` → `pl`, `Pods/*` → `pods`, `xcass` → `xcass`. 꼴 표시는 떼고 견준다.
    static func normalized(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("*.") { text.removeFirst(2) } else if text.hasPrefix("*") { text.removeFirst() }
        if text.hasSuffix("/*") { text.removeLast(2) } else if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: 후보 만들기

    /// 언어 파일 확장자. 빼면 리뷰가 그 코드를 못 보니 경고한다.
    static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hh", "hpp", "c", "cc", "cpp", "cxx", "kt", "kts", "java", "js", "jsx", "mjs", "cjs",
        "ts", "tsx", "py", "rb", "go", "rs", "cs", "php", "scala", "sh", "bash", "zsh", "dart", "vue", "svelte",
        "lua", "sql", "gradle", "groovy",
    ]

    private struct Tally {
        var kind: Suggestion.Kind
        var key: String
        var repoFiles = 0
        var codeFiles = 0
        var prCount = 0
        var changedLines = 0
    }

    /// 한 경로가 걸리는 후보들(규칙 → 견줄 글자·종류). 같은 경로에서 같은 규칙은 한 번만.
    static func candidatePatterns(for path: String) -> [String: (key: String, kind: Suggestion.Kind)] {
        var out: [String: (key: String, kind: Suggestion.Kind)] = [:]
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.isEmpty else { return out }
        out[ExclusionPattern.escaped(name)] = (name.lowercased(), .fileName)
        if let pattern = ExclusionPattern.fileExtension(of: name) {
            out[pattern] = ((name as NSString).pathExtension.lowercased(), .fileExtension)
        }
        for folder in parts.dropLast() {
            let ext = (folder as NSString).pathExtension
            if !ext.isEmpty {
                out["*." + ExclusionPattern.escaped(ext) + "/*"] = (ext.lowercased(), .folder)
            } else {
                out[ExclusionPattern.escaped(folder) + "/*"] = (folder.lowercased(), .folder)
            }
        }
        return out
    }

    static func buildCandidates(paths: [String], pullRequests: [[PRFile]]) -> [Suggestion] {
        var tallies: [String: Tally] = [:]
        func isCode(_ path: String) -> Bool {
            codeExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        for path in paths {
            let code = isCode(path)
            for (pattern, info) in candidatePatterns(for: path) {
                tallies[pattern, default: Tally(kind: info.kind, key: info.key)].repoFiles += 1
                if code { tallies[pattern]?.codeFiles += 1 }
            }
        }
        for files in pullRequests {
            var lines: [String: Int] = [:]
            for file in files {
                for (pattern, info) in candidatePatterns(for: file.path) {
                    // 기본 브랜치에 없는 파일(새로 생긴 파일)도 PR 에 나오면 후보가 된다.
                    if tallies[pattern] == nil { tallies[pattern] = Tally(kind: info.kind, key: info.key) }
                    lines[pattern, default: 0] += file.additions + file.deletions
                }
            }
            for (pattern, changed) in lines {
                tallies[pattern]?.prCount += 1
                tallies[pattern]?.changedLines += changed
            }
        }
        return tallies.map { pattern, tally in
            let code: Bool
            switch tally.kind {
            case .fileExtension:
                code = codeExtensions.contains(tally.key)
            case .fileName:
                code = codeExtensions.contains((tally.key as NSString).pathExtension)
            case .folder:
                // 폴더는 안의 절반 넘게가 코드면 경고한다.
                code = tally.repoFiles > 0 && tally.codeFiles * 2 > tally.repoFiles
            }
            return Suggestion(pattern: pattern, kind: tally.kind, repoFiles: tally.repoFiles,
                              prCount: tally.prCount, changedLines: tally.changedLines, isCode: code, key: tally.key)
        }
    }
}
