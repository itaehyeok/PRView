import Foundation

/// 지적 1건 + 리뷰 이후에 생긴 것만 보낸다. 리뷰 전체 diff 는 다시 보내지 않는다.
public enum RecheckPromptBuilder {
    public static let contextLines = 25
    public static let maxItemChars = 1_200
    public static let maxCommits = 20
    public static let maxComments = 12
    /// 봇 코멘트는 길고 정형화돼 있어 더 많이 보내도 값이 있다.
    public static let botChars = 2_000
    public static let humanChars = 700

    /// 대조할 지적 하나.
    public struct Target: Sendable {
        public var kindLabel: String
        public var severity: String?
        public var path: String?
        public var line: Int?
        public var body: String
        public var rationale: String?

        public init(kindLabel: String, severity: String? = nil, path: String? = nil,
                    line: Int? = nil, body: String, rationale: String? = nil) {
            self.kindLabel = kindLabel
            self.severity = severity
            self.path = path
            self.line = line
            self.body = body
            self.rationale = rationale
        }
    }

    public static func build(pr: PullRequestInfo,
                             record: ReviewRecord,
                             target: Target,
                             delta: RecheckDelta,
                             reviewedDiff: ParsedDiff?,
                             newDiff: ParsedDiff?) -> String {
        var lines: [String] = []
        lines.append("<pr>")
        lines.append("title: \(PromptBuilder.sanitize(pr.title))")
        lines.append("branch: \(pr.headRefName) → \(pr.baseRefName)")
        lines.append("reviewed_commit: \(record.headSha.prefix(12))")
        lines.append("current_commit: \(pr.headRefOid.prefix(12))")
        lines.append("</pr>")

        lines.append("<item kind=\"\(target.kindLabel)\"\(target.severity.map { " severity=\"\($0)\"" } ?? "")>")
        if let path = target.path, !path.isEmpty {
            lines.append("file: \(path)\(target.line.map { ":\($0)" } ?? "")")
        }
        lines.append(String(PromptBuilder.sanitize(target.body).prefix(maxItemChars)))
        if let rationale = target.rationale, !rationale.isEmpty {
            lines.append("why: " + String(PromptBuilder.sanitize(rationale).prefix(maxItemChars)))
        }
        lines.append("</item>")

        appendCode(&lines, tag: "code", diff: reviewedDiff, path: target.path, line: target.line,
                   empty: "(리뷰 당시 diff 를 찾지 못했습니다)")

        lines.append("<new_commits>")
        if delta.newCommits.isEmpty {
            lines.append("없음")
        } else {
            if !delta.commitBoundaryExact {
                // 어림잡은 경계라는 사실을 숨기면 모델이 없는 확신을 갖는다.
                lines.append("(리뷰한 커밋을 목록에서 찾지 못해 시각으로 어림잡은 목록입니다)")
            }
            // **뒤에서** 자른다. 목록은 오래된 순인데 앞에서 자르면 정작 수정이 들어 있는
            // 최근 커밋이 빠진다.
            let keptCommits = delta.newCommits.suffix(maxCommits)
            if delta.newCommits.count > keptCommits.count {
                lines.append("(앞선 \(delta.newCommits.count - keptCommits.count)개는 생략했습니다)")
            }
            for commit in keptCommits {
                lines.append("- \(commit.abbreviatedOid) [\(commit.author)] \(PromptBuilder.sanitize(commit.messageHeadline))")
            }
        }
        lines.append("</new_commits>")

        appendCode(&lines, tag: "new_diff", diff: newDiff, path: target.path, line: nil,
                   empty: "없음")

        lines.append("<new_comments>")
        if delta.newComments.isEmpty {
            lines.append("없음")
        } else {
            // 대화의 결론은 끝에 나온다. "말씀하신 대로 고쳤습니다" 가 잘려 나가면
            // 모델은 남은 옛 코멘트만 보고 "그대로입니다" 를 확신 있게 내놓는다.
            let kept = delta.newComments.suffix(maxComments)
            if delta.newComments.count > kept.count {
                lines.append("(앞선 \(delta.newComments.count - kept.count)건은 생략했습니다. 다 보지 못했다면 cannot_tell 로 둡니다)")
            }
            for comment in kept {
                let limit = comment.author.hasSuffix("[bot]") || comment.author == "claude"
                    ? botChars : humanChars
                var head = "author=\"\(comment.author)\""
                if let path = comment.path {
                    head += " file=\"\(path)\(comment.line.map { ":\($0)" } ?? "")\""
                }
                if comment.isResolvedThread { head += " resolved=\"true\"" }
                lines.append("<comment \(head)>")
                lines.append(String(PromptBuilder.sanitize(comment.body).prefix(limit)))
                lines.append("</comment>")
            }
        }
        lines.append("</new_comments>")
        return lines.joined(separator: "\n")
    }

    /// diff 에서 이 항목과 관련된 부분만 잘라 넣는다. 전체를 넣으면 리뷰만큼 비싸진다.
    private static func appendCode(_ lines: inout [String], tag: String, diff: ParsedDiff?,
                                   path: String?, line: Int?, empty: String) {
        guard let diff else {
            lines.append("<\(tag)>\(empty)</\(tag)>")
            return
        }
        // 자리를 아는 항목은 그 파일만, 모르는 항목(질문 등)은 바뀐 파일 목록만 보여 준다.
        guard let path, !path.isEmpty, let file = diff.files.first(where: { $0.path == path }) else {
            let names = diff.files.prefix(20).map { "- \($0.path)" }
            lines.append("<\(tag)>")
            lines.append(names.isEmpty ? empty : (["(이 항목의 파일을 특정할 수 없어 바뀐 파일만 적습니다)"] + names).joined(separator: "\n"))
            lines.append("</\(tag)>")
            return
        }
        let rendered: [String]
        if let line {
            rendered = file.snippet(around: line, side: .right, context: contextLines).map { render($0) }
        } else {
            rendered = file.lines.filter { $0.kind != .meta }.prefix(80).map { render($0) }
        }
        lines.append("<\(tag)>")
        lines.append(rendered.isEmpty ? empty : rendered.joined(separator: "\n"))
        lines.append("</\(tag)>")
    }

    private static func render(_ line: DiffLine) -> String {
        let number = line.newLine.map { String(format: "R%03d", $0) } ?? "    "
        let marker: String
        switch line.kind {
        case .addition: marker = "+"
        case .deletion: marker = "-"
        default: marker = " "
        }
        return "\(number) \(marker)\(line.text)"
    }

    public static func estimatedTokens(delta: RecheckDelta, itemChars: Int) -> Int {
        let comments = delta.newComments.suffix(maxComments).reduce(0) { $0 + min($1.body.count, humanChars) }
        return 1_200 + min(itemChars, maxItemChars) / 3 + delta.newCommits.count * 20 + comments / 3
    }
}
