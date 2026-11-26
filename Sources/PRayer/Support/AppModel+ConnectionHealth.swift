import PRayerCore

/// 연결 상태 판정과 다시 확인 — 툴바 "상태" 와 설정 › 연결이 같이 쓴다.
///
/// 예전에는 두 곳이 따로 판정했다. 툴바는 목록 갱신이 실패하면 주황인데, 설정의 GitHub 칸은 계정만 보고 초록
/// "사용 가능" 을 그렸다(2026-11-26 사용자 제보: "상태 이상인데 연결에서는 정상"). 판정은 `ConnectionHealth` 하나로 낸다.
extension AppModel {
    /// 켜고 아직 한 번도 확인하지 않았으면 계정도 오류도 없다.
    var githubChecked: Bool { githubAccount != nil || githubError != nil }

    /// 툴바 아이콘의 단계 — 지켜보는 엔진·GitHub·목록 갱신을 합친 것.
    var connectionHealth: ConnectionHealth {
        ConnectionHealth.level(primary: settings.primaryEngine,
                               watched: settings.watchedEngines,
                               status: { self.engineStatus($0) },
                               githubChecked: githubChecked,
                               githubConnected: githubAccount != nil,
                               refreshFailing: consecutiveRefreshFailures > 0)
    }

    /// GitHub 한 줄(툴바 팝오버·설정 › 연결)의 단계.
    var githubHealth: ConnectionHealth {
        ConnectionHealth.github(checked: githubChecked,
                                connected: githubAccount != nil,
                                refreshFailing: consecutiveRefreshFailures > 0)
    }

    /// 엔진 한 줄의 단계. nil 이면 지켜보지 않는 엔진이 안 되는 것이다(선택 사항 — 경고색 없이).
    func engineHealth(_ engine: ReviewEngineKind) -> ConnectionHealth? {
        ConnectionHealth.engine(engine,
                                primary: settings.primaryEngine,
                                watched: settings.watchedEngines,
                                status: engineStatus(engine))
    }

    /// GitHub 계정을 다시 보고, 계정은 되는데 목록 갱신이 실패 중이면 목록도 다시 받아 본다.
    /// 계정 확인만으로는 "갱신 실패"(툴바 주황)가 걷히지 않는다 — 실패 횟수는 목록을 받아야 0 이 된다.
    func recheckGitHub() async {
        await checkGitHub()
        if githubAccount != nil, consecutiveRefreshFailures > 0, settings.onboardingCompleted {
            await refresh()
        }
    }

    /// 엔진·GitHub·목록을 한 번에 다시 본다 — 상태 팝오버를 열 때, 설정 › 연결을 열 때, 문제 줄의 "다시 시도".
    /// 두 곳이 같은 함수로 같은 값을 고치므로 어느 쪽에서 열어도 툴바 아이콘과 설정 칸이 같이 바뀐다.
    func recheckConnections() async {
        guard !DemoMode.isOn, !isRecheckingConnections else { return }
        isRecheckingConnections = true
        defer { isRecheckingConnections = false }
        // 엔진(`claude auth status` 등)과 GitHub(`gh api user`)은 서로 기다릴 이유가 없다.
        async let engines: Void = checkEngines()
        async let github: Void = recheckGitHub()
        _ = await (engines, github)
    }
}
