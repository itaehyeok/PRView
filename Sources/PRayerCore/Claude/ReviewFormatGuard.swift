import Foundation

/// 리뷰 결과 가운데 화면·게시가 기대는 꼴을 코드로 맞춘다.
///
/// 판정과 코멘트 앞말은 프롬프트로만 지키던 규칙이다. 사용자 리뷰 규칙("웬만하면 승인해 줘", "앞말은 빼 줘")이
/// 들어오면 모델이 거기에 끌려 필수 코멘트를 두고 approve 를 내거나 앞말을 떨어뜨릴 수 있다. 그러면 게시 버튼의
/// 기본값과 받는 사람이 읽는 뜻이 어긋난다. 그래서 이 둘은 모델이 뭐라 쓰든 앱이 같은 규칙으로 다시 정한다.
public enum ReviewFormatGuard {
    public static let nonBlockerPrefix = "(비블로커)"
    public static let questionPrefix = "[질문]"

    /// 판정은 코멘트 중요도에서 나온다 — 필수가 하나라도 있으면 변경 요청, 권장이 있으면 코멘트, 그 밖에는 승인.
    /// 프롬프트 [출력 형식] 의 판정 규칙과 같다.
    public static func verdict(for output: ReviewOutput) -> Verdict {
        let severities = output.draftComments.map(\.severity) + output.concerns.map(\.severity)
        if severities.contains(.blocker) { return .requestChanges }
        if severities.contains(where: { $0 == .major || $0 == .minor }) { return .comment }
        return .approve
    }

    /// 코드 코멘트 카드 입력 칸에 보일 글 — 앞말 "(비블로커)" 를 뗀다. 중요도 칩이 같은 말을 해서 카드마다 되풀이됐다.
    /// 올라가는 글은 그대로다: 고친 글은 `restoringNonBlockerPrefix` 로 앞말을 다시 붙여 둔다.
    public static func withoutNonBlockerPrefix(_ body: String) -> String {
        let trimmed = body.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix(nonBlockerPrefix) else { return body }
        return String(trimmed.dropFirst(nonBlockerPrefix.count).drop(while: \.isWhitespace))
    }

    /// 칸에서 고친 글을 저장할 꼴로 — 원래 글에 앞말이 있었으면 다시 붙인다. 글을 다 지웠으면 앞말만 남기지 않는다.
    /// 사용자가 앞말을 직접 쳐 넣었으면 두 번 붙이지 않는다.
    public static func restoringNonBlockerPrefix(_ edited: String, from stored: String) -> String {
        guard stored.drop(while: \.isWhitespace).hasPrefix(nonBlockerPrefix),
              !edited.allSatisfy(\.isWhitespace),
              !edited.drop(while: \.isWhitespace).hasPrefix(nonBlockerPrefix) else { return edited }
        return "\(nonBlockerPrefix) \(edited)"
    }

    /// 필수가 아닌 코멘트는 "(비블로커)" 나 "[질문]" 으로 시작한다. 필수 코멘트에서는 "(비블로커)" 를 뗀다 —
    /// 머지를 막는 지적에 비블로커라고 붙어 있으면 받는 사람이 넘겨도 되는 말로 읽는다.
    public static func prefixedBody(_ body: String, severity: Severity) -> String {
        let trimmed = body.drop(while: \.isWhitespace)
        if severity == .blocker {
            guard trimmed.hasPrefix(nonBlockerPrefix) else { return body }
            return String(trimmed.dropFirst(nonBlockerPrefix.count).drop(while: \.isWhitespace))
        }
        if trimmed.hasPrefix(nonBlockerPrefix) || trimmed.hasPrefix(questionPrefix) { return body }
        return "\(nonBlockerPrefix) \(trimmed)"
    }

    public static func conform(_ output: ReviewOutput) -> ReviewOutput {
        var copy = output
        copy.draftComments = output.draftComments.map { comment in
            var comment = comment
            comment.body = prefixedBody(comment.body, severity: comment.severity)
            return comment
        }
        copy.verdict = verdict(for: copy)
        return copy
    }
}
