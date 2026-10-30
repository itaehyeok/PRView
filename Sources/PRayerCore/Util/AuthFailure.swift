import Foundation

/// 리뷰 엔진(`claude`)이 **로그인이 끊겨서** 실패한 것인가.
///
/// 앱은 엔진 로그인 상태를 켤 때 한 번만 확인했다. 그래서 몇 시간 뒤 세션이 만료되면
/// 리뷰는 인증 오류로 죽는데 툴바의 상태 표시등은 계속 초록이었다(실측). 표시등이
/// 거짓말을 하면 다음번에도 그 불을 믿고 눌렀다가 또 실패한다.
/// 실패 문구에서 이 상황을 알아보고 **그 자리에서 상태를 다시 확인**하는 데 쓴다.
///
/// 네트워크 끊김(`TransientFailure`)과 나누는 이유는 사람이 할 일이 다르기 때문이다 —
/// 그쪽은 다시 누르면 되고, 이쪽은 로그인을 해야 한다.
public enum AuthFailure {
    static let markers = [
        "oauth session expired",
        "could not be refreshed",
        "failed to authenticate",
        "authentication_error",
        "authentication failed",
        "not logged in",
        "session expired",
        "invalid api key",
        "please log in",
        "please run `claude auth login`",
        "로그인이 필요합니다",
    ]

    /// 로그인이 끊겨서 실패한 것인가. 문구로 판정한다 — 엔진이 종료 코드로 구분해 주지 않는다.
    ///
    /// `401`·`unauthorized` 같은 일반적인 표식은 일부러 넣지 않았다. GitHub 쪽 오류에도
    /// 흔히 나오는 말이라, 그것까지 잡으면 엉뚱한 실패에 "다시 로그인" 을 권하게 된다.
    public static func isExpired(_ message: String) -> Bool {
        let haystack = message.lowercased()
        return markers.contains { haystack.contains($0.lowercased()) }
    }

    /// 로그아웃으로 **확인됐던** 엔진이 다시 로그인됐는가. 터미널에서 로그인하고 돌아온 순간이다.
    ///
    /// - Parameter lastKnown: `auth status` 가 마지막으로 **실제로 답한** 로그인 여부(`EngineStatus.loginKnown`).
    ///   명령이 돌지 못한 확인은 여기에 넣지 않는다 — 그걸 로그아웃으로 치면, 로그인하지 않았는데도
    ///   한 번 삐끗한 다음 정상 확인에서 "다시 로그인했다" 고 판정한다.
    ///
    /// 지금 로그인돼 있다는 것만으로는 판정하지 않는다. 처음 확인(이전 값 없음)이나 계속 로그인돼
    /// 있던 경우까지 잡으면, `auth status` 가 만료를 못 알아본 맥에서 실패 직후 "다시 로그인했다" 고
    /// 말해 버린다. 실측(10-20)에서는 실패 직후 `false`, 로그인하고 돌아오니 `true` 였다.
    public static func loginRecovered(lastKnown: Bool?, current: EngineStatus) -> Bool {
        lastKnown == false && current.loginKnown && current.isReady
    }
}
