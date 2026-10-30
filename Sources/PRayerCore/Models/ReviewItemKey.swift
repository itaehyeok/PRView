import Foundation

/// 리뷰 결과의 항목 하나를 가리키는 키.
///
/// 종류를 앞에 붙여 섞이지 않게 한다. 우려사항과 코멘트 초안은 모델이 준 `issue_key` 가
/// 서로 같을 수 있고(같은 사안의 두 표현), 그 둘을 한 사전에 담기 때문이다.
public enum ReviewItemKey {
    public static func draft(_ comment: DraftComment) -> String { "draft:\(comment.issueKey)" }
    public static func concern(_ concern: Concern) -> String { "concern:\(concern.issueKey)" }

    /// 작성자 질문에는 `issue_key` 가 없다(스키마에 없다). 본문에서 안정적인 키를 만든다.
    ///
    /// `hashValue` 를 쓰면 안 된다 — Swift 의 문자열 해시는 프로세스마다 시드가 달라서
    /// 앱을 다시 켜면 키가 바뀌고, 저장해 둔 정리 표시를 못 찾는다. FNV-1a 로 직접 계산한다.
    public static func question(_ question: AuthorQuestion) -> String {
        "question:\(stableHash(question.question))"
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
