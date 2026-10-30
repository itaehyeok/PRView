import Foundation

/// 팀 통계는 메인 창의 상세 칸에 뜬다(사용자 선택, 2026-10-28 — 별도 창으로 먼저 만들어 보고 바꿨다).
/// 목록은 그대로 두고, 통계를 여는 동안 PR 고른 것을 비운다. 그래야 어느 PR 을 눌러도(보던 PR 을 다시 눌러도)
/// 고른 것이 바뀌어 상세가 그 PR 로 돌아간다 — 고른 채로 두면 목록에 파랗게 칠해진 PR 과 상세 칸이 어긋나 보인다.
extension AppModel {
    func toggleTeamStats() {
        if showingTeamStats {
            closeTeamStats()
        } else {
            openTeamStats()
        }
    }

    func openTeamStats() {
        guard !showingTeamStats else { return }
        prBeforeTeamStats = selectedPRID
        showingTeamStats = true
        selectedPRID = nil
        clearListSelection()
    }

    /// 통계 버튼으로 닫으면 보던 PR 로 돌아간다. 그 PR 이 그새 목록에서 빠졌으면 빈 상세가 된다.
    func closeTeamStats() {
        guard showingTeamStats else { return }
        showingTeamStats = false
        if selectedPRID == nil { selectedPRID = prBeforeTeamStats }
        prBeforeTeamStats = nil
    }
}
