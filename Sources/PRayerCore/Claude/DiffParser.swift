import Foundation

public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case context, addition, deletion, hunk, meta
    }

    public var index: Int
    public var kind: Kind
    /// 원문 그대로(선행 +/-/공백 포함).
    public var raw: String
    /// 기호를 뗀 코드 본문.
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public var id: Int { index }

    public init(index: Int, kind: Kind, raw: String, text: String, oldLine: Int?, newLine: Int?) {
        self.index = index
        self.kind = kind
        self.raw = raw
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct DiffFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var oldPath: String?
    public var isBinary: Bool
    public var isNew: Bool
    public var isDeleted: Bool
    public var lines: [DiffLine]
    public var additions: Int
    public var deletions: Int

    public var id: String { path }
    public var changedLines: Int { additions + deletions }

    public init(path: String, oldPath: String?, isBinary: Bool, isNew: Bool, isDeleted: Bool,
                lines: [DiffLine], additions: Int, deletions: Int) {
        self.path = path
        self.oldPath = oldPath
        self.isBinary = isBinary
        self.isNew = isNew
        self.isDeleted = isDeleted
        self.lines = lines
        self.additions = additions
        self.deletions = deletions
    }
}

public struct ParsedDiff: Sendable {
    public var files: [DiffFile]
    /// 리뷰에서 빠진 파일 — 잠금 파일(`LockFiles`, 늘)과 제외 경로 규칙에 걸린 것.
    ///
    /// **내용까지 들고 있다.** 제외는 "모델에게 보내지 않는다" 는 뜻이지 "사람도 못 본다" 는
    /// 뜻이 아니다. 자동 생성 파일이라도 무엇이 바뀌었는지 눈으로 확인해야 할 때가 있다
    /// (프롬프트에는 `PromptBuilder` 가 경로와 줄 수만 적는다 — 이 배열의 `lines` 는 안 쓴다).
    public var excludedFiles: [DiffFile]

    public var changedLines: Int { files.reduce(0) { $0 + $1.changedLines } }
    public var excludedChangedLines: Int { excludedFiles.reduce(0) { $0 + $1.changedLines } }
    public var isEmpty: Bool { files.isEmpty }

    public func file(matching path: String) -> DiffFile? {
        if let exact = files.first(where: { $0.path == path }) { return exact }
        // 모델이 앞 디렉터리를 빼먹는 경우가 있어 접미 일치도 허용한다.
        let candidates = files.filter { $0.path.hasSuffix(path) || path.hasSuffix($0.path) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// 지금 제외 규칙으로 다시 나눈 사본. 앱은 받은 diff 를 규칙 없이 파싱해 두고 볼 때 이걸로 나눈다 —
    /// 규칙을 고치면(설정·변경 파일 탭 우클릭) diff 를 다시 받지 않아도 변경 파일 탭·예상 토큰이 바로 바뀐다.
    /// 규칙 없이 파싱한 것에 쓰면 원래 순서가 그대로 남는다.
    public func applyingExclusions(_ patterns: [String]) -> ParsedDiff {
        let all = files + excludedFiles
        var copy = self
        copy.files = all.filter { !DiffParser.isExcluded($0.path, patterns: patterns) }
        copy.excludedFiles = all.filter { DiffParser.isExcluded($0.path, patterns: patterns) }
        return copy
    }
}

public enum DiffParser {
    /// 리뷰에서 뺄 파일인가 — 잠금 파일은 늘, 그 밖에는 제외 경로 규칙에 걸리면.
    public static func isExcluded(_ path: String, patterns: [String]) -> Bool {
        LockFiles.isLockFile(path) || Glob.isExcluded(path: path, patterns: patterns)
    }

    /// `@@ -104,6 +104,19 @@ context` 를 나란히 보기용으로 좌우로 나눈다.
    ///
    /// 이 줄은 원래 양쪽 정보를 한 줄에 담고 있다 — `-104,6` 은 옛 파일, `+104,19` 는 새 파일.
    /// 나란히 보기에서 이걸 한 줄로 그리면 폭 전체를 먹어 **오른쪽 열을 덮는다**(실측).
    /// 뒤에 붙는 문맥(함수 이름)은 양쪽 공통이라 새 파일 쪽에 붙인다.
    ///
    /// 못 알아보는 모양이면 원문을 왼쪽에 그대로 둔다 — 정보를 잃는 것보다 낫다.
    public static func hunkDisplayParts(_ raw: String) -> (left: String, right: String) {
        let body = raw.drop(while: { $0 == "@" }).drop(while: { $0 == " " })
        guard let close = body.range(of: "@@") else { return (raw, "") }
        let ranges = body[body.startIndex..<close.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let old = ranges.first(where: { $0.hasPrefix("-") }),
              let new = ranges.first(where: { $0.hasPrefix("+") })
        else { return (raw, "") }
        let context = body[close.upperBound...].trimmingCharacters(in: .whitespaces)
        let right = context.isEmpty ? "@@ \(new) @@" : "@@ \(new) @@ \(context)"
        return ("@@ \(old) @@", right)
    }

    public static func parse(_ rawText: String, excluding patterns: [String] = []) -> ParsedDiff {
        // Swift 에서 "\r\n" 은 단일 Character 라 `split(separator: "\n")` 이 CRLF 줄을 자르지 못한다.
        // 먼저 정규화하지 않으면 CRLF 파일 하나가 뒤따르는 파일까지 한 줄로 삼킨다.
        let text = rawText.contains("\r\n") ? rawText.replacingOccurrences(of: "\r\n", with: "\n") : rawText
        var files: [DiffFile] = []
        var excluded: [DiffFile] = []

        var currentPath: String?
        var currentOldPath: String?
        var isBinary = false
        var isNew = false
        var isDeleted = false
        /// 첫 `@@` 이후에는 `--- `/`+++ ` 로 시작하는 줄도 코드(삭제/추가)일 수 있다.
        var sawHunk = false
        var lines: [DiffLine] = []
        var additions = 0
        var deletions = 0
        var oldCounter = 0
        var newCounter = 0
        var index = 0

        func flush() {
            guard let path = currentPath else { return }
            let file = DiffFile(path: path, oldPath: currentOldPath, isBinary: isBinary,
                                isNew: isNew, isDeleted: isDeleted, lines: lines,
                                additions: additions, deletions: deletions)
            if isExcluded(path, patterns: patterns) {
                excluded.append(file)
            } else {
                files.append(file)
            }
            currentPath = nil
            currentOldPath = nil
            isBinary = false
            isNew = false
            isDeleted = false
            sawHunk = false
            lines = []
            additions = 0
            deletions = 0
            oldCounter = 0
            newCounter = 0
            index = 0
        }

        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // diff 는 개행으로 끝나므로 마지막 원소가 빈 문자열이다. 그대로 두면 hunk 밖에
        // 유령 context 줄이 하나 생겨 줄 번호가 어긋난다.
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }
        for raw in rawLines {
            if raw.hasPrefix("diff --git ") {
                flush()
                let payload = String(raw.dropFirst("diff --git ".count))
                // git 은 공백이 든 경로를 따옴표로 감싸지 않는다. " b/" 를 기준으로 나눈다.
                if let separator = payload.range(of: " b/") {
                    currentOldPath = stripPrefix(String(payload[payload.startIndex..<separator.lowerBound]))
                    currentPath = String(payload[separator.upperBound...])
                } else {
                    let parts = payload.split(separator: " ")
                    if parts.count >= 2 {
                        currentOldPath = stripPrefix(String(parts[0]))
                        currentPath = stripPrefix(String(parts[parts.count - 1]))
                    }
                }
                continue
            }
            if currentPath == nil { continue }

            if !sawHunk, raw.hasPrefix("--- ") {
                let value = String(raw.dropFirst(4))
                if value == "/dev/null" { isNew = true } else { currentOldPath = stripPrefix(value) }
                continue
            }
            if !sawHunk, raw.hasPrefix("+++ ") {
                let value = String(raw.dropFirst(4))
                if value == "/dev/null" { isDeleted = true } else { currentPath = stripPrefix(value) }
                continue
            }
            if !sawHunk, raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") {
                isBinary = true
                continue
            }
            if raw.hasPrefix("@@") {
                if let header = parseHunkHeader(raw) {
                    oldCounter = header.oldStart
                    newCounter = header.newStart
                }
                sawHunk = true
                lines.append(DiffLine(index: index, kind: .hunk, raw: raw, text: raw, oldLine: nil, newLine: nil))
                index += 1
                continue
            }
            if !sawHunk, raw.hasPrefix("index ") || raw.hasPrefix("similarity index ")
                || raw.hasPrefix("rename ") || raw.hasPrefix("new file mode")
                || raw.hasPrefix("deleted file mode") || raw.hasPrefix("old mode")
                || raw.hasPrefix("new mode") {
                if raw.hasPrefix("new file mode") { isNew = true }
                if raw.hasPrefix("deleted file mode") { isDeleted = true }
                // hunk 가 없는 순수 rename 은 `---`/`+++` 줄이 없어 경로를 여기서 잡아야 한다.
                if raw.hasPrefix("rename from ") { currentOldPath = String(raw.dropFirst("rename from ".count)) }
                if raw.hasPrefix("rename to ") { currentPath = String(raw.dropFirst("rename to ".count)) }
                continue
            }
            if raw.hasPrefix("\\ No newline") { continue }

            if raw.hasPrefix("+") {
                lines.append(DiffLine(index: index, kind: .addition, raw: raw,
                                      text: String(raw.dropFirst()), oldLine: nil, newLine: newCounter))
                newCounter += 1
                additions += 1
                index += 1
            } else if raw.hasPrefix("-") {
                lines.append(DiffLine(index: index, kind: .deletion, raw: raw,
                                      text: String(raw.dropFirst()), oldLine: oldCounter, newLine: nil))
                oldCounter += 1
                deletions += 1
                index += 1
            } else if raw.hasPrefix(" ") || (sawHunk && raw.isEmpty) {
                lines.append(DiffLine(index: index, kind: .context, raw: raw,
                                      text: raw.isEmpty ? "" : String(raw.dropFirst()),
                                      oldLine: oldCounter, newLine: newCounter))
                oldCounter += 1
                newCounter += 1
                index += 1
            }
        }
        flush()
        return ParsedDiff(files: files, excludedFiles: excluded)
    }

    static func stripPrefix(_ value: String) -> String {
        var result = value
        if result.hasPrefix("a/") || result.hasPrefix("b/") {
            result = String(result.dropFirst(2))
        }
        if let tab = result.firstIndex(of: "\t") {
            result = String(result[result.startIndex..<tab])
        }
        return result
    }

    /// `@@ -12,7 +14,9 @@ func foo()` → (12, 14)
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        func number(_ token: Substring, sign: Character) -> Int? {
            guard token.first == sign else { return nil }
            let body = token.dropFirst()
            let head = body.split(separator: ",").first ?? body
            return Int(head)
        }
        guard let oldStart = number(parts[1], sign: "-"),
              let newStart = number(parts[2], sign: "+") else { return nil }
        return (oldStart, newStart)
    }
}
