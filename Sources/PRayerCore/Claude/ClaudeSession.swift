import Foundation

/// 리뷰한 Claude 대화를 사용자가 이어 가는 데 필요한 것 — 붙여 넣을 명령과, 그 대화가 아직 남아 있는지.
///
/// 실측(CLI 2.1.284): `claude --resume <ID>` 는 대화를 만든 폴더가 아니어도 열리고, 리뷰 때 넘긴
/// 시스템 프롬프트도 대화에 남아 따라온다. 그래서 명령에 `cd` 를 넣지 않는다 — 전체 리뷰의 워크트리가
/// 정리된 뒤에도 이어 갈 수 있다.
public enum ClaudeSession {
    /// 터미널에 붙여 넣을 한 줄. CLI 결과 JSON 에서 읽은 값을 셸 명령에 넣는 것이라
    /// UUID 꼴이 아니면 만들지 않는다 — 다른 글자가 섞이면 붙여 넣는 순간 엉뚱한 명령이 된다.
    ///
    /// Codex 는 `codex resume <ID>` 다(0.149.0 — 대화를 만든 폴더가 아니어도 ID 로 연다).
    public static func resumeCommand(sessionID: String, engine: ReviewEngineKind = .claude) -> String? {
        normalizedID(sessionID).map { id in
            switch engine {
            case .claude: return "claude --resume \(id)"
            case .codex: return "codex resume \(id)"
            }
        }
    }

    /// CLI 가 대화 파일 이름에 쓰는 꼴(소문자 UUID). UUID 가 아니면 nil.
    public static func normalizedID(_ raw: String) -> String? {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString.lowercased()
    }

    /// Claude Code 가 대화를 두는 곳. 앱이 띄우는 claude 는 `CLAUDE_CONFIG_DIR` 없이 HOME 만 받으므로
    /// (`ProcessEnvironment.base`) 늘 여기다.
    public static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 대화 파일이 아직 있는지. Claude Code 는 오래된 대화를 스스로 지운다(`cleanupPeriodDays`).
    /// 하위 폴더 이름은 대화를 만든 작업 폴더에서 나오는데, 그 규칙을 따라 하지 않고 전부 훑는다 —
    /// CLI 가 규칙을 바꿔도 맞고, 전체 리뷰처럼 작업 폴더가 리뷰마다 다른 경우도 한 번에 찾는다.
    public static func transcriptExists(sessionID: String, engine: ReviewEngineKind) -> Bool {
        switch engine {
        case .claude: return transcriptExists(sessionID: sessionID)
        case .codex: return codexTranscriptExists(sessionID: sessionID)
        }
    }

    /// Codex 가 대화를 두는 곳. `~/.codex/sessions/<연>/<월>/<일>/rollout-<시각>-<ID>.jsonl`.
    public static var codexSessionsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Codex 대화 파일이 아직 있는지. 날짜 폴더 규칙을 따라 하지 않고 이름 끝의 ID 로 찾는다.
    public static func codexTranscriptExists(sessionID: String, in sessions: URL = codexSessionsDirectory) -> Bool {
        guard let id = normalizedID(sessionID),
              let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix("\(id).jsonl") {
            return true
        }
        return false
    }

    public static func transcriptExists(sessionID: String, in projects: URL = projectsDirectory) -> Bool {
        guard let id = normalizedID(sessionID) else { return false }
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return false
        }
        return folders.contains {
            fileManager.fileExists(atPath: $0.appendingPathComponent("\(id).jsonl").path)
        }
    }
}
