import Foundation
import PRayerCore

/// "이미 언급됨" 패널이 대조할 항목 하나.
///
/// 초안 코멘트·우려사항·작성자 질문은 생김새가 다르지만 패널 입장에서 필요한 것은 같다 —
/// 어디를 가리키는지, 무슨 말을 하는지, 그리고 결과를 어디에 저장할지. 셋을 이 모양으로
/// 맞춰 같은 화면과 같은 대조 경로를 쓴다.
struct DiscussionSubject: Equatable {
    /// 항목을 가리키는 이름. 저장 열쇠의 일부가 된다.
    let itemKey: String
    /// 자리. 질문처럼 자리가 없으면 빈 문자열이다.
    let path: String
    let line: Int?
    let anchorText: String?
    /// 낱말을 뽑고 모델에게 보여 줄 본문.
    let body: String
    let rationale: String?

    /// - Parameter body: 사용자가 고친 본문. 주지 않으면 모델이 처음 준 본문을 쓴다.
    ///   대조는 **올릴 글** 기준이어야 하므로 편집본이 있으면 그쪽을 넘긴다.
    static func of(_ comment: DraftComment, body: String? = nil) -> Self {
        Self(itemKey: "draft:\(comment.issueKey)",
             path: comment.path,
             line: comment.line,
             anchorText: comment.anchorText,
             body: body ?? comment.body,
             rationale: comment.rationaleKo)
    }

    static func of(_ concern: Concern) -> Self {
        Self(itemKey: "concern:\(concern.issueKey)",
             path: concern.path,
             line: concern.line,
             anchorText: concern.anchorText,
             body: concern.title,
             rationale: nil)
    }

    static func of(_ question: AuthorQuestion) -> Self {
        // 질문에는 자리가 없을 수 있다. 근거로 든 코드가 있으면 그 자리를 쓴다.
        let evidence = question.evidence?.first
        return Self(itemKey: "question:\(question.stableKey)",
                    path: evidence?.path ?? "",
                    line: evidence?.line,
                    anchorText: nil,
                    body: question.question,
                    rationale: question.rationaleKo)
    }
}
