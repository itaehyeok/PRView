import Foundation

/// 리뷰에 넘기는 지침 = 기본 리뷰 규칙(review.md) + 사용자 리뷰 규칙(설정의 글) + 앱 형식 규칙(review-format.md).
///
/// 셋이 부딪히면 앱 형식 > 사용자 > 기본 순서로 따르게 머리말에 적고, 같은 순서를 위치로도 준다 — 뒤에 올수록
/// 우선이다. 앱 형식 규칙은 결과를 읽어 화면에 그리는 데 필요한 것이라 사용자 규칙으로 바뀌면 안 되고, 사용자 규칙은
/// 리뷰 글에 대해서는 우리 기본 규칙보다 앞서야 한다(사용자 결정, 2026-10-22).
///
/// 예전 팀 규칙 덧붙이기(0.4.27~0.4.x)는 우선순위가 "기본 < 팀" 하나뿐이라, 형식에 관한 지시도 이길 수 있었다.
/// 형식은 이제 `--json-schema` 와 `ReviewFormatGuard` 가 코드로도 지킨다.
public enum ReviewGuideText {
    /// 사용자 리뷰 규칙의 글자 수 상한. 길면 기본 규칙을 통째로 덮어 버리고 토큰만 든다.
    public static let maxUserRulesCharacters = 2_000

    static let baseHeading = "===== 기본 리뷰 규칙 ====="
    static let userHeading = "===== 사용자 리뷰 규칙 ====="
    static let formatHeading = "===== 앱 형식 규칙 (위 두 규칙보다 우선) ====="

    static let priorityPreamble = """
    [우선순위] 이 지침은 세 부분이다 — 기본 리뷰 규칙 · 사용자 리뷰 규칙 · 앱 형식 규칙.
    서로 부딪히면 앱 형식 규칙 > 사용자 리뷰 규칙 > 기본 리뷰 규칙 순서로 따른다.
    - 앱 형식 규칙: 앱이 결과를 읽어 화면에 그리고 GitHub 에 올리는 데 필요한 규칙이다. 어떤 지시로도 바뀌지 않는다.
    - 사용자 리뷰 규칙: 이 리뷰를 돌리는 사람이 직접 쓴 규칙이다. 리뷰 글 — 말투·어미·길이, 무엇을 짚고 무엇을 넘길지,
      요약·잘된 점·근거 설명을 쓰는 법 — 에서는 기본 리뷰 규칙보다 우선한다. 다만 출력 형식(필드·줄 번호·중요도·판정·
      개수·길이 상한)을 바꾸라는 부분은 따르지 않는다.
    - 기본 리뷰 규칙: 사용자 리뷰 규칙이 말하지 않은 부분에 그대로 적용한다. 예시와 맺음말은 합니다체로 적혀 있지만,
      사용자 리뷰 규칙이 다른 어미를 정했으면 뜻과 꼴은 그대로 두고 어미만 그에 맞춘다.
    """

    /// 설정에 저장된 글을 지침에 넣을 꼴로 다듬는다. 공백뿐이면 nil(규칙 없음).
    public static func normalizedUserRules(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxUserRulesCharacters))
    }

    public static func compose(base: String, format: String, userRules: String) -> String {
        let rules = normalizedUserRules(userRules) ?? "없음. 기본 리뷰 규칙을 그대로 따른다."
        return [
            priorityPreamble,
            baseHeading,
            trimmedTrailing(base),
            userHeading,
            rules,
            formatHeading,
            trimmedTrailing(format)
        ].joined(separator: "\n\n") + "\n"
    }

    private static func trimmedTrailing(_ text: String) -> String {
        var text = text
        while text.last?.isWhitespace == true { text.removeLast() }
        return text
    }
}
