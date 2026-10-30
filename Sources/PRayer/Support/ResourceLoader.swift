import Foundation
import PRayerCore

/// 리뷰 프롬프트와 출력 스키마 로딩 — 모두 앱 번들의 파일이다. `--system-prompt-file` 은 실제 파일 경로를
/// 요구하므로 경로와 내용을 같이 돌려준다.
enum ResourceLoader {
    struct Resource {
        var path: String
        var text: String
    }

    /// 리뷰 지침 — 앱 번들의 기본 리뷰 규칙(review.md)·앱 형식 규칙(review-format.md) 사이에 사용자 리뷰 규칙을 넣어
    /// 이은 글(`ReviewGuideText.compose`). 사용자에게는 우리 규칙을 보여 주지 않고, 사용자가 쓴 규칙만 받는다.
    ///
    /// 예전 팀 규칙 덧붙이기(0.4.27~)·통째 교체(~0.4.26)는 효과가 없어 뺐다(2026-10-06). 이번 것은 실측에서 말투·길이가
    /// 규칙대로 바뀌었다(2026-10-22). 예전 설정 파일의 그 두 칸은 여전히 읽지 않는다.
    static func guide(userRules: String) -> Resource? {
        guard let base = bundled(name: "review", extension: "md"),
              let format = bundled(name: "review-format", extension: "md") else { return nil }
        let text = ReviewGuideText.compose(base: base.text, format: format.text, userRules: userRules)
        let url = AppPaths.composedGuideFile
        // 내용이 같으면 다시 쓰지 않는다. 리뷰마다 엔진을 새로 만들어서, 쓰기만 하면 리뷰 수만큼 쓴다.
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // 기본 규칙만으로 돌리면 앱 형식 규칙이 빠진다. 리뷰를 막고 이유를 남긴다.
                Log.error("리뷰 지침 파일을 쓰지 못했습니다: \(error.localizedDescription)", "engine")
                return nil
            }
        }
        return Resource(path: url.path, text: text)
    }

    static func schema() -> Resource? {
        bundled(name: "schema", extension: "json")
    }

    /// 남의 코멘트를 쉬운 말로 푸는 통역 전용.
    static func explainGuide() -> Resource? { bundled(name: "explain", extension: "md") }
    static func explainSchema() -> Resource? { bundled(name: "explain-schema", extension: "json") }
    /// 이미 언급된 사안이 어디서 어떻게 오갔는지 대조하는 전용 프롬프트.
    static func relevanceGuide() -> Resource? { bundled(name: "relevance", extension: "md") }
    static func relevanceSchema() -> Resource? { bundled(name: "relevance-schema", extension: "json") }
    /// 리뷰 이후 커밋·코멘트로 그 지적이 처리됐는지 다시 확인하는 전용 프롬프트.
    static func recheckGuide() -> Resource? { bundled(name: "recheck", extension: "md") }
    static func recheckSchema() -> Resource? { bundled(name: "recheck-schema", extension: "json") }

    private static func bundled(name: String, extension ext: String) -> Resource? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Resource(path: url.path, text: text)
    }
}
