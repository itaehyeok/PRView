import PRayerCore

/// 연결 상태 판정 — 툴바 "상태" 와 설정 › 연결이 같이 쓴다.
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
}
