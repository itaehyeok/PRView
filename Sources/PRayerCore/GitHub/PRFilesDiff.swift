import Foundation

/// GitHub 이 diff 를 통째로 주지 않는 큰 PR 을 "PR 파일 목록" API 로 받아 같은 unified diff 모양으로 다시 짠다.
///
/// `pulls/{n}` 을 diff 로 받으면 파일 300개나 2만 줄이 넘을 때 줄 수와 상관없이 거절한다. 실측: 파일
/// 천여 개를 옮긴 PR — 바뀐 줄은 수백 줄뿐인데 diff 도, 리뷰도, 요약도 실패했다. 거절 메시지가 권하는
/// 대로 파일 목록(`pulls/{n}/files`, 100개씩 최대 3,000개)을 받는다. 파일마다 patch 가 따로 오므로 git 과
/// 같은 머리 줄을 붙여 이으면 DiffParser·diff 탭·리뷰 프롬프트·코멘트 줄 검사가 그대로 동작한다.
public enum PRFilesDiff {
    public struct File: Decodable, Sendable {
        public var filename: String
        public var previous_filename: String?
        /// added · removed · modified · renamed · copied · changed · unchanged
        public var status: String
        /// 바이너리이거나 GitHub 이 주지 않을 만큼 큰 파일이면 없다.
        public var patch: String?
        public var changes: Int?

        public init(filename: String, previous_filename: String? = nil, status: String,
                    patch: String? = nil, changes: Int? = nil) {
            self.filename = filename
            self.previous_filename = previous_filename
            self.status = status
            self.patch = patch
            self.changes = changes
        }
    }

    public static let pageSize = 100
    /// 이 API 가 주는 최대 3,000개(100개 × 30쪽).
    public static let maxPages = 30

    /// "Sorry, the diff exceeded the maximum number of files (300)" · "…lines (20000)".
    public static func isTooLargeError(_ message: String) -> Bool {
        message.contains("exceeded the maximum number")
    }

    public static func unifiedDiff(from files: [File]) -> String {
        var out = ""
        for file in files {
            let new = file.filename
            let old = file.previous_filename ?? file.filename
            let isAdded = file.status == "added"
            let isRemoved = file.status == "removed"
            out += "diff --git a/\(old) b/\(new)\n"
            if isAdded { out += "new file mode 100644\n" }
            if isRemoved { out += "deleted file mode 100644\n" }
            if old != new { out += "rename from \(old)\nrename to \(new)\n" }

            guard let patch = file.patch, !patch.isEmpty else {
                // 내용이 그대로인 이름 변경은 머리 줄로 끝난다(git 도 그렇게 낸다).
                if old != new, (file.changes ?? 0) == 0 { continue }
                // 바이너리이거나 GitHub 이 내용을 주지 않을 만큼 큰 파일. 있다는 것만 남긴다.
                out += "Binary files \(isAdded ? "/dev/null" : "a/\(old)") and \(isRemoved ? "/dev/null" : "b/\(new)") differ\n"
                continue
            }
            out += "--- \(isAdded ? "/dev/null" : "a/\(old)")\n"
            out += "+++ \(isRemoved ? "/dev/null" : "b/\(new)")\n"
            out += patch
            if !patch.hasSuffix("\n") { out += "\n" }
        }
        return out
    }
}
