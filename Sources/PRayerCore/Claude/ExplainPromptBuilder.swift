import Foundation

/// 코멘트 1건 + 그 자리 코드만 보낸다. 리뷰의 1/10 도 안 되는 입력이다.
public enum ExplainPromptBuilder {
    public static let contextLines = 25
    public static let maxBodyChars = 2_000

    public static func build(pr: PullRequestInfo, target: ExplainTarget, diff: ParsedDiff?) -> String {
        var lines: [String] = []
        lines.append("<pr>")
        lines.append("title: \(PromptBuilder.sanitize(pr.title))")
        lines.append("branch: \(pr.headRefName) → \(pr.baseRefName)")
        lines.append("</pr>")

        if let path = target.path {
            lines.append("<location>")
            lines.append("file: \(path)")
            if let line = target.line { lines.append("line: \(line)") }
            lines.append("</location>")
        }

        if let snippet = snippet(for: target, diff: diff), !snippet.isEmpty {
            lines.append("<code>")
            lines.append(contentsOf: snippet)
            lines.append("</code>")
        } else {
            lines.append("<code>(이 커밋의 diff 에서 해당 줄을 찾지 못했습니다)</code>")
        }

        lines.append("<comment author=\"\(target.author)\">")
        lines.append(String(PromptBuilder.sanitize(target.body).prefix(maxBodyChars)))
        lines.append("</comment>")

        for reply in target.replies.prefix(3) {
            lines.append("<reply>")
            lines.append(String(PromptBuilder.sanitize(reply).prefix(600)))
            lines.append("</reply>")
        }
        return lines.joined(separator: "\n")
    }

    /// 코멘트가 달린 줄 주변. 새 코드(오른쪽) 기준이다.
    static func snippet(for target: ExplainTarget, diff: ParsedDiff?) -> [String]? {
        guard let diff, let path = target.path,
              let file = diff.files.first(where: { $0.path == path }) else { return nil }
        guard let line = target.line else {
            return file.lines.filter { $0.kind != .meta }.prefix(40).map { render($0) }
        }
        let snippet = file.snippet(around: line, side: .right, context: contextLines)
        return snippet.isEmpty ? nil : snippet.map { render($0) }
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

    public static func estimatedTokens(bodyChars: Int) -> Int {
        900 + min(bodyChars, maxBodyChars) / 3 + contextLines * 2 * 12
    }
}
