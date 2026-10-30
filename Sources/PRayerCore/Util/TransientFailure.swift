import Foundation

/// 사용자가 고칠 것이 없고 **다시 누르면 되는** 실패인가.
///
/// GitHub 으로 가는 TCP 연결이 잠깐 끊기면 게시 직전 확인이 실패하고, 앱은 안전하게
/// 게시를 막는다. 그 자체는 맞는 동작인데, 화면에는 인증 실패·권한 부족 같은 진짜 문제와
/// 똑같이 빨간 에러로 떴다. 고칠 것이 없는 일에 같은 무게를 주면 진짜 에러도 같이 가벼워진다.
///
/// `gh` 는 Go 로 만들어져 네트워크 실패가 Go 런타임 문구로 나온다. 아래 표식은 그 문구들이다.
public enum TransientFailure {
    static let markers = [
        "operation timed out",
        "i/o timeout",
        "dial tcp",
        "connection refused",
        "connection reset",
        "no such host",
        "network is unreachable",
        "tls handshake timeout",
        "temporary failure in name resolution",
        "could not resolve host",
        "timeout awaiting response headers",
        "the request timed out",
        "요청이 시간 안에 끝나지 않았습니다",
    ]

    /// 연결이 안 돼서 실패한 것인가. 문구로 판정한다 — `gh` 는 종료 코드로 구분해 주지 않는다.
    public static func isNetwork(_ message: String) -> Bool {
        let haystack = message.lowercased()
        return markers.contains { haystack.contains($0.lowercased()) }
    }
}
