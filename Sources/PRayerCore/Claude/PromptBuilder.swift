import Foundation
import CryptoKit

public enum PromptVersion {
    /// 프롬프트 템플릿 자체의 버전. 템플릿을 바꾸면 올린다.
    public static let templateVersion = "1"

    public static func compute(guide: String, schema: String) -> String {
        let payload = guide + "\u{1}" + schema + "\u{1}" + templateVersion
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }
}

public struct PromptInput: Sendable {
    public var pr: PullRequestInfo
    public var diff: ParsedDiff
    public var maxCharacters: Int
    /// 리뷰 전 창에서 사용자가 체크를 푼 파일 — `diff.excludedFiles` 중 일부다. 잠금 파일·제외 경로와 이유가 달라서
    /// 따로 알린다(그대로 두면 "자동 생성 파일이라 뺐다" 로 읽힌다).
    public var skippedFiles: [DiffFile]

    public init(pr: PullRequestInfo, diff: ParsedDiff, maxCharacters: Int = 600_000, skippedFiles: [DiffFile] = []) {
        self.pr = pr
        self.diff = diff
        self.maxCharacters = maxCharacters
        self.skippedFiles = skippedFiles
    }

    /// 사용자가 모든 파일의 체크를 풀었다 — 코드 없이 PR 설명과 파일 목록만으로 리뷰한다.
    public var isListOnly: Bool { diff.isListOnly(skippedFiles: skippedFiles) }
}

public enum PromptBuilder {
    /// 토큰 추정치. 실측(147줄 변경 PR) 기준:
    /// 입력(캐시 생성) 10,769 + 출력 12,480 = 23,251 토큰 / 135초 / list $0.175.
    /// 고정분은 review.md + 스키마 + safe-mode 시스템 프롬프트이고, 출력은 사고 토큰이 대부분이다.
    public static let tokensPerChangedLine = 14
    public static let fixedPromptTokens = 6_000
    public static let averageOutputTokens = 12_000

    public static func estimatedTokens(changedLines: Int) -> Int {
        fixedPromptTokens + changedLines * tokensPerChangedLine + averageOutputTokens
    }

    public static func build(_ input: PromptInput) -> String {
        let pr = input.pr
        var out = "<pr_data>\n"
        out += "<pr_meta repo=\"\(pr.repo.full)\" number=\"\(pr.number)\" head=\"\(pr.shortHead)\" base=\"\(pr.baseRefName)\""
        if let jira = jiraKey(title: pr.title, branch: pr.headRefName) {
            out += " jira=\"\(jira)\""
        }
        out += ">\n"
        out += "제목: \(sanitize(pr.title))\n"
        out += "작성자: \(pr.author)\n"
        out += "변경: +\(pr.additions) -\(pr.deletions), 파일 \(pr.changedFiles)개\n"
        let body = sanitize(pr.bodyText).trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            out += "본문:\n\(String(body.prefix(4000)))\n"
        }
        out += "</pr_meta>\n"

        // 봇 스레드도 넣는다. 리뷰 봇이 PR 마다 리뷰를 남기는 레포에서 그걸 안 보내면
        // 같은 지적을 또 하게 된다(중복 방지가 이 블록의 목적이다).
        let threads = pr.threads.filter { !$0.isOutdated }
        if threads.isEmpty {
            out += "<existing_threads>없음</existing_threads>\n"
        } else {
            out += "<existing_threads 안내=\"이미 지적된 사안은 다시 코멘트하지 않는다\">\n"
            for thread in threads.prefix(20) {
                guard let first = thread.comments.first else { continue }
                let location = [thread.path, thread.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
                let status = thread.isResolved ? "해결됨" : "미해결"
                let summary = sanitize(first.body).replacingOccurrences(of: "\n", with: " ")
                out += "- [\(first.author)] \(location) (\(status)): \(String(summary.prefix(400)))\n"
                // 작성자 답글(반영 여부)까지 넘겨야 "이미 고쳤다" 를 다시 지적하지 않는다.
                for reply in thread.comments.dropFirst().prefix(2) {
                    let replyText = sanitize(reply.body).replacingOccurrences(of: "\n", with: " ")
                    out += "  ↳ [\(reply.author)] \(String(replyText.prefix(200)))\n"
                }
            }
            out += "</existing_threads>\n"
        }

        // PR 대화 코멘트(claude[bot] 총평 포함)와 리뷰 제출 총평. 여기 있는 지적을 또 하면 안 된다.
        let conversation = pr.issueComments.suffix(8)
        let reviewBodies = pr.reviewEvents.filter {
            !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.suffix(6)
        if conversation.isEmpty, reviewBodies.isEmpty {
            out += "<existing_comments>없음</existing_comments>\n"
        } else {
            out += "<existing_comments 안내=\"PR 대화·리뷰 총평. 여기서 이미 지적된 사안은 다시 코멘트하지 않는다\">\n"
            for review in reviewBodies {
                let text = sanitize(review.body).replacingOccurrences(of: "\n", with: " ")
                out += "- [리뷰 \(review.state)] \(review.author): \(String(text.prefix(700)))\n"
            }
            for comment in conversation {
                let text = sanitize(comment.body).replacingOccurrences(of: "\n", with: " ")
                // 봇 총평은 길다. 지적 목록을 담을 만큼만 넘긴다.
                let limit = comment.author.hasSuffix("[bot]") || comment.author == "claude" ? 2_000 : 700
                out += "- [\(comment.author)] \(String(text.prefix(limit)))\n"
            }
            out += "</existing_comments>\n"
        }

        let skippedPaths = Set(input.skippedFiles.map(\.path))
        let ruleExcluded = input.diff.excludedFiles.filter { !skippedPaths.contains($0.path) }
        if !ruleExcluded.isEmpty {
            out += "<excluded_files 이유=\"잠금 파일·자동 생성 파일이라 리뷰 범위에서 제외됨(내용은 보내지 않음)\">\n"
            for file in ruleExcluded.prefix(30) {
                out += "- \(file.path) (\(file.changedLines)줄\(LockFiles.isLockFile(file.path) ? ", 잠금 파일" : ""))\n"
            }
            out += "</excluded_files>\n"
        }
        if !input.skippedFiles.isEmpty {
            out += "<files_without_content 이유=\"리뷰 전에 사용자가 내용을 빼고 파일명과 바뀐 줄 수만 보냈다. "
                + "이 파일들의 코드는 보지 못했으니 추측해 지적하지 않는다\">\n"
            for file in input.skippedFiles.prefix(listedSkippedFiles) {
                out += "- \(file.path) (+\(file.additions) -\(file.deletions))\(file.isNew ? " 신규" : file.isDeleted ? " 삭제" : "")\n"
            }
            if input.skippedFiles.count > listedSkippedFiles {
                let rest = input.skippedFiles.dropFirst(listedSkippedFiles)
                out += "- … 외 \(rest.count)개 (+\(rest.reduce(0) { $0 + $1.additions }) -\(rest.reduce(0) { $0 + $1.deletions }))\n"
            }
            out += "</files_without_content>\n"
        }
        if input.isListOnly {
            // 답 형식(review-format.md)은 코멘트를 바뀐 줄에 달게 한다. 달 줄이 없으니 이번만 다르게 쓰라고 알린다 —
            // 안 알리면 파일 이름만 보고 코드를 짐작해 줄 코멘트를 지어낸다.
            out += "<review_scope>이번 리뷰는 코드 내용 없이 PR 제목·본문·기존 코멘트와 파일명·줄 수만 받았다. "
                + "달 수 있는 코드 줄이 없으니 code_comments 는 비워 둔다. PR 설명과 바뀐 파일이 서로 맞는지, 빠진 것은 없는지, "
                + "작성자에게 확인할 점을 summary_ko 에 쓴다. 코드를 보지 못했으니 verdict 는 comment 로 둔다.</review_scope>\n"
        }

        let numbered = numberedDiffDetail(input.diff, maxCharacters: input.maxCharacters)
        if !numbered.shortened.isEmpty {
            out += "<shortened_lines 이유=\"\(DiffElision.characterLimit.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))))자 넘는 줄은 "
                + "앞 \(DiffElision.promptHead)자·끝 \(DiffElision.promptTail)자만 보냈다. 가운데 내용은 추측해 지적하지 않는다\">\n"
            for place in numbered.shortened.prefix(30) {
                out += "- \(place)\n"
            }
            if numbered.shortened.count > 30 {
                out += "- … 외 \(numbered.shortened.count - 30)줄\n"
            }
            out += "</shortened_lines>\n"
        }
        out += "<diff files=\(input.diff.files.count) lines=\(input.diff.changedLines)>\n"
        out += numbered.text
        out += "\n</diff>\n</pr_data>\n\n"
        out += "위 PR 을 리뷰한다. 지정된 JSON 스키마로만 답한다."
        return out
    }

    /// 줄 접두어 `R123`(새 파일, side=RIGHT) / `L045`(옛 파일, side=LEFT)를 붙인 diff.
    /// 모델이 hunk 헤더에서 줄을 직접 세면 자주 틀리므로 앱이 번호를 제공한다.
    public static func numberedDiff(_ diff: ParsedDiff, maxCharacters: Int = 600_000) -> String {
        numberedDiffDetail(diff, maxCharacters: maxCharacters).text
    }

    /// `numberedDiff` 와 함께, 줄여서 보낸 긴 줄의 자리(`파일 R054`)를 돌려준다. 상한에 걸려 보내지 않은 줄은 빠진다.
    static func numberedDiffDetail(_ diff: ParsedDiff, maxCharacters: Int) -> (text: String, shortened: [String]) {
        var out = ""
        // 보낸 글자 수. 상한을 넘을지 줄을 붙이기 전에 재려고 따로 센다 — `out.count` 는 매번 처음부터 센다.
        var length = 0
        var shortened: [String] = []
        // 내용이 없는 파일(바이너리·이름만 바뀜)은 파일마다 머리 줄을 쓰지 않고 끝에 묶는다. 파일 천여 개를
        // 옮긴 PR 에서 거의 다 이런 파일이라(실측), 하나씩 쓰면 볼 것 없는 머리 줄에 수만 토큰을 쓴다.
        let binaries = diff.files.filter { $0.isBinary }
        // 이름이 바뀐 파일만 옛 경로가 다르다(나머지는 diff --git 머리 줄의 a/·b/ 가 같다).
        let renamedOnly = diff.files.filter { file in
            guard !file.isBinary, file.lines.isEmpty, let oldPath = file.oldPath, !oldPath.isEmpty else { return false }
            return oldPath != file.path
        }
        func appendContentless() {
            if !binaries.isEmpty {
                out += "\n--- 내용을 볼 수 없는 파일 \(binaries.count)개(바이너리이거나 GitHub 이 diff 를 주지 않을 만큼 큼) ---\n"
                for file in binaries.prefix(listedContentlessFiles) {
                    out += "- \(file.path)\(file.isNew ? " (신규)" : file.isDeleted ? " (삭제)" : "")\n"
                }
                if binaries.count > listedContentlessFiles {
                    let rest = binaries.dropFirst(listedContentlessFiles)
                    out += "- … 외 \(rest.count)개 (\(extensionSummary(rest)))\n"
                }
            }
            if !renamedOnly.isEmpty {
                out += "\n--- 내용 변경 없이 이름만 바뀐 파일 \(renamedOnly.count)개 ---\n"
                for file in renamedOnly.prefix(listedContentlessFiles) {
                    out += "- \(file.oldPath ?? "") → \(file.path)\n"
                }
                if renamedOnly.count > listedContentlessFiles {
                    out += "- … 외 \(renamedOnly.count - listedContentlessFiles)개\n"
                }
            }
        }
        let contentless = Set((binaries + renamedOnly).map(\.path))
        for file in diff.files where !contentless.contains(file.path) {
            var header = "\n--- FILE: \(file.path)"
            if file.isNew { header += " (신규 파일)" }
            if file.isDeleted { header += " (삭제됨)" }
            header += " ---\n"
            out += header
            length += header.count
            for line in file.lines {
                let place: String
                switch line.kind {
                case .hunk:
                    place = ""
                case .addition, .context:
                    guard let newLine = line.newLine else { continue }
                    place = String(format: "R%03d", newLine)
                case .deletion:
                    guard let oldLine = line.oldLine else { continue }
                    place = String(format: "L%03d", oldLine)
                case .meta:
                    continue
                }
                let short = line.kind == .hunk ? nil : DiffElision.shortenedForPrompt(line.text)
                let piece: String
                if place.isEmpty {
                    piece = "\(line.raw)\n"
                } else if let short {
                    // 기호(+/-/공백)는 두고 본문만 줄인다. anchor_text 는 기호를 뗀 본문으로 돌아온다.
                    piece = "\(place) |\(line.raw.prefix(1))\(short)\n"
                } else {
                    piece = "\(place) |\(line.raw)\n"
                }
                // 붙이기 전에 잰다. 붙인 뒤에 재면 한 줄이 상한을 통째로 넘겨 들어간다.
                if length + piece.count > maxCharacters {
                    out += "\n(diff 가 너무 길어 이후 내용은 생략됨)\n"
                    // 잘렸어도 무엇이 더 있었는지(내용 없는 파일)는 알린다 — 짧은 목록이다.
                    appendContentless()
                    return (out, shortened)
                }
                out += piece
                length += piece.count
                if short != nil {
                    shortened.append("\(file.path) \(place)")
                }
            }
        }
        appendContentless()
        return (out, shortened)
    }

    /// 내용 없는 파일(바이너리·이름만 바뀜)은 이만큼만 이름을 적고 나머지는 개수로 묶는다.
    static let listedContentlessFiles = 20

    /// 사용자가 체크를 푼 파일은 이만큼 적는다. 목록만으로 리뷰할 때는 이 목록이 리뷰 재료의 전부라 넉넉히 둔다
    /// (파일 150개 남짓인 PR 이 다 들어가고, 한 줄이 짧아 300개여도 2만 자 안팎이다).
    static let listedSkippedFiles = 300

    /// "png 12 · svg 3" — 이름을 다 적지 않은 파일에 무엇이 섞였는지만 알린다.
    static func extensionSummary<S: Sequence>(_ files: S) -> String where S.Element == DiffFile {
        var counts: [String: Int] = [:]
        for file in files {
            let ext = (file.path as NSString).pathExtension.lowercased()
            counts[ext.isEmpty ? "확장자 없음" : ext, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }

    /// PR 제목이나 브랜치명에서 이슈 키를 뽑는다(본문은 넣지 않는다).
    public static func jiraKey(title: String, branch: String) -> String? {
        for source in [title, branch] {
            var current = ""
            var candidate: String?
            for character in source + " " {
                if character.isUppercase || character == "-" || character.isNumber {
                    current.append(character)
                } else {
                    if let found = validKey(current) { candidate = found; break }
                    current = ""
                }
            }
            if let candidate { return candidate }
        }
        return nil
    }

    private static func validKey(_ token: String) -> String? {
        let parts = token.split(separator: "-")
        guard parts.count == 2,
              parts[0].count >= 2,
              parts[0].allSatisfy({ $0.isUppercase }),
              parts[1].allSatisfy({ $0.isNumber }) else { return nil }
        // `PROJ-420-fix` 처럼 뒤가 더 붙어 있어도 키만 돌려준다.
        return "\(parts[0])-\(parts[1])"
    }

    /// 프롬프트가 구조를 나타내는 데 쓰는 토큰과 그 무력화 형태.
    /// 치환 결과가 원본을 부분 문자열로 포함하면 무력화되지 않으므로 쌍으로 명시한다.
    static let structuralReplacements: [(token: String, replacement: String)] = [
        ("<pr_data>", "(pr_data)"), ("</pr_data>", "(/pr_data)"),
        ("<pr_meta", "(pr_meta"), ("</pr_meta>", "(/pr_meta)"),
        ("<existing_threads>", "(existing_threads)"), ("</existing_threads>", "(/existing_threads)"),
        ("<excluded_files", "(excluded_files"), ("</excluded_files>", "(/excluded_files)"),
        ("<shortened_lines", "(shortened_lines"), ("</shortened_lines>", "(/shortened_lines)"),
        ("<files_without_content", "(files_without_content"), ("</files_without_content>", "(/files_without_content)"),
        ("<review_scope>", "(review_scope)"), ("</review_scope>", "(/review_scope)"),
        ("<diff", "(diff"), ("</diff>", "(/diff)"),
        ("<prior_review", "(prior_review"), ("</prior_review>", "(/prior_review)"),
        ("--- FILE:", "··· 파일 표기 제거 ···")
    ]

    /// PR 본문·코멘트는 신뢰할 수 없는 입력이다. 숨은 지시와 구조 위조 수단을 제거한다.
    public static func sanitize(_ text: String) -> String {
        var result = text
        // 닫힌 HTML 주석 제거
        while let start = result.range(of: "<!--"),
              let end = result.range(of: "-->", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // 닫히지 않은 주석은 GitHub 에서 사람에게 보이지 않으므로 그 이후를 버린다.
        if let start = result.range(of: "<!--") {
            result = String(result[result.startIndex..<start.lowerBound])
        }
        for scalar in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2028}", "\u{2029}"] {
            result = result.replacingOccurrences(of: scalar, with: "")
        }
        for entry in structuralReplacements {
            result = result.replacingOccurrences(of: entry.token, with: entry.replacement)
        }
        // 앱이 붙이는 줄 접두어(R123 |, L045 |)를 위조해 다른 줄을 가리키는 것을 막는다.
        result = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 3, let first = trimmed.first, first == "R" || first == "L" else { return String(line) }
                let afterMarker = trimmed.dropFirst()
                let digits = afterMarker.prefix(while: { $0.isNumber })
                guard !digits.isEmpty,
                      afterMarker.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).hasPrefix("|") else {
                    return String(line)
                }
                // 접두어 형태를 깨뜨려야 한다. 그냥 앞에 문자를 붙이면 "R001 |" 이 그대로 남는다.
                let head = trimmed.prefix(while: { $0 != "|" })
                let rest = trimmed.dropFirst(head.count).dropFirst()
                return "· " + head + "·" + rest
            }
            .joined(separator: "\n")
        return result
    }
}
