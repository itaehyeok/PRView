import Foundation

/// PRayer 는 한 번에 하나만 켠다.
///
/// 두 앱이 같은 데이터 폴더를 쓰면 각자 메모리에 든 설정·초안·사용량 기록을 저장할 때마다 파일을
/// 통째로 다시 쓴다(Store 는 `.atomic` 으로 쓰기만 하고 잠그거나 합치지 않는다). 그래서 마지막에 쓴 쪽만
/// 남는다 — 한쪽에서 바꾼 설정이 되돌아가고, 한쪽에서 게시한 초안을 다른 쪽은 아직 게시 전으로 알아
/// 다시 올릴 수 있다. 베타 설치(beta.sh)가 다른 자리에서 돌던 Debug 빌드 옆에 새 앱을 하나 더 띄운 일이
/// 실제로 있었다. 옛 사본(예: /Applications 의 이전 버전)을 Spotlight 로 여는 것도 같은 길이다.
public enum SingleInstance {
    public struct Instance: Equatable, Sendable {
        public var pid: Int32
        /// 앱 번들 경로. 모르면 nil.
        public var path: String?
        public var version: String?

        public init(pid: Int32, path: String?, version: String?) {
            self.pid = pid
            self.path = path
            self.version = version
        }
    }

    /// 켤 때 다른 PRayer 가 떠 있으면 어느 쪽을 쓸지. 묻지 않고 정해 두는 자동화 탈출구다
    /// (`defaults write <번들 ID> instanceConflictAnswer existing|replace`).
    public enum Answer: String, Sendable {
        /// 켜져 있는 것을 쓴다 — 지금 연 쪽은 저장 없이 끝낸다.
        case existing
        /// 켜져 있는 것을 정상 종료시키고 지금 연 쪽을 켠다.
        case replace
    }

    public static let presetAnswerKey = "instanceConflictAnswer"

    /// 같은 데이터를 쓰는 다른 PRayer. 번들 ID 가 같은 실행 중 앱(`running`)에서 나를 뺀 첫째다.
    ///
    /// 작업본(install.sh)은 번들 ID 와 데이터 폴더를 함께 갈라 두므로 여기 들어오지 않는다.
    /// 환경 변수 `PRAYER_DATA_DIR` 로 데이터 폴더만 갈라 띄운 실행은 견주지 않는다 — 번들 ID 가 같아도
    /// 데이터가 다르다.
    public static func conflict(selfPID: Int32, running: [Instance], dataDirOverridden: Bool) -> Instance? {
        guard !dataDirOverridden else { return nil }
        return running.first { $0.pid != selfPID }
    }

    /// 어느 쪽을 쓸지 묻는 안내의 본문. 두 앱이 어디 있는 어느 버전인지부터 적는다 —
    /// 같은 이름이라 무엇이 무엇인지 모르면 고를 수가 없다.
    public static func explanation(existing: Instance, opened: Instance, home: String) -> String {
        """
        켜져 있는 것: \(describe(existing, home: home))
        지금 연 것: \(describe(opened, home: home))

        둘을 함께 켜면 같은 설정·초안·사용량 기록을 서로 덮어써서 한쪽에서 바꾼 것이 사라질 수 있어, 하나만 켭니다.
        """
    }

    static func describe(_ instance: Instance, home: String) -> String {
        let version = instance.version.map { "v\($0)" } ?? "버전 모름"
        guard let path = instance.path else { return version }
        let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return "\(version) · \(shown)"
    }
}
