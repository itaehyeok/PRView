import XCTest
@testable import PRayerCore

/// 목록 행 ⌘·⇧ 클릭 고르기 — 내 PR(슬랙 요청)과 리뷰 목록(한꺼번에 리뷰)이 같이 쓴다.
final class RowSelectionTests: XCTestCase {
    private let list = ["a", "b", "c", "d", "e"]

    func testPlainClickPicksOnlyThatRow() {
        var selection = RowSelection(ids: ["a", "b"], anchor: "a")
        XCTAssertEqual(selection.click("c", in: list, current: "a", modifier: .none), "c")
        XCTAssertEqual(selection.ids, ["c"])
        XCTAssertEqual(selection.anchor, "c")
        XCTAssertFalse(selection.isMultiple)
    }

    /// 보고 있던 것도 같이 고른 것으로 친다 — ⌘ 클릭 한 번이 "둘" 이 된다.
    func testCommandClickAddsToTheRowBeingViewed() {
        var selection = RowSelection()
        XCTAssertEqual(selection.click("c", in: list, current: "a", modifier: .command), "c")
        XCTAssertEqual(selection.ids, ["a", "c"])
        XCTAssertTrue(selection.isMarked("a"))
        XCTAssertFalse(selection.isMarked("b"))
    }

    /// 보고 있던 것이 다른 목록(내 PR)에 있으면 같이 고르지 않는다.
    func testCommandClickIgnoresViewedRowFromAnotherList() {
        var selection = RowSelection()
        XCTAssertEqual(selection.click("c", in: list, current: "mine", modifier: .command), "c")
        XCTAssertEqual(selection.ids, ["c"])
    }

    func testCommandClickOnChosenRowRemovesItAndViewsAnother() {
        var selection = RowSelection(ids: ["a", "c", "e"], anchor: "e")
        XCTAssertEqual(selection.click("c", in: list, current: "c", modifier: .command), "a",
                       "보고 있던 것을 빼면 남은 것 중 위의 것을 본다")
        XCTAssertEqual(selection.ids, ["a", "e"])
        XCTAssertNil(selection.click("e", in: list, current: "a", modifier: .command),
                     "보고 있지 않은 것을 빼면 보는 것은 그대로")
        XCTAssertEqual(selection.ids, ["a"])
    }

    func testShiftClickSelectsRangeFromAnchorEitherWay() {
        var selection = RowSelection()
        _ = selection.click("b", in: list, current: nil, modifier: .none)
        XCTAssertEqual(selection.click("d", in: list, current: "b", modifier: .shift), "d")
        XCTAssertEqual(selection.ids, ["b", "c", "d"])
        XCTAssertEqual(selection.anchor, "b", "시작점은 그대로 — 다시 ⇧ 클릭하면 범위를 고쳐 잡는다")
        XCTAssertEqual(selection.click("a", in: list, current: "d", modifier: .shift), "a")
        XCTAssertEqual(selection.ids, ["a", "b"])
    }

    /// 시작점이 없으면 보고 있는 것부터, 그것도 이 목록에 없으면 그냥 클릭.
    func testShiftClickWithoutUsableAnchorFallsBack() {
        var fromCurrent = RowSelection()
        XCTAssertEqual(fromCurrent.click("c", in: list, current: "a", modifier: .shift), "c")
        XCTAssertEqual(fromCurrent.ids, ["a", "b", "c"])

        var plain = RowSelection()
        XCTAssertEqual(plain.click("c", in: list, current: "mine", modifier: .shift), "c")
        XCTAssertEqual(plain.ids, ["c"])
    }

    /// 우클릭 — 고른 것 안이면 고른 것 전부(목록 순서), 밖이면 그 하나.
    func testTargetsFollowFinderRule() {
        let selection = RowSelection(ids: ["d", "b"], anchor: "d")
        XCTAssertEqual(selection.targets(for: "d", in: list), ["b", "d"])
        XCTAssertEqual(selection.targets(for: "a", in: list), ["a"])
        XCTAssertEqual(RowSelection(ids: ["b"]).targets(for: "b", in: list), ["b"])
    }

    /// 고른 것이 필터·새로고침으로 목록에서 빠지면 남은 것만, 다 빠졌으면 누른 것 하나.
    func testTargetsDropRowsNoLongerListed() {
        let selection = RowSelection(ids: ["b", "x"])
        XCTAssertEqual(selection.targets(for: "b", in: list), ["b"])
        XCTAssertEqual(RowSelection(ids: ["x", "y"]).targets(for: "x", in: list), ["x"])
    }

    /// 방향키 — 한 칸씩 옮기며 그 하나만 고른다. 끝에서 더 가면 그대로.
    func testArrowMovesOneRowAndStopsAtEnds() {
        var selection = RowSelection(ids: ["a", "b"], anchor: "a")
        XCTAssertEqual(selection.move(by: 1, in: list, current: "b", extend: false), "c")
        XCTAssertEqual(selection.ids, ["c"])
        XCTAssertEqual(selection.anchor, "c")
        XCTAssertNil(selection.move(by: 1, in: list, current: "e", extend: false))
        XCTAssertNil(selection.move(by: -1, in: list, current: "a", extend: false))
        XCTAssertNil(selection.move(by: 1, in: list, current: "mine", extend: false), "다른 목록의 행에서는 움직이지 않는다")
    }

    /// ⇧ 방향키 — 시작점은 두고 늘였다가, 반대로 가면 줄고 시작점을 넘으면 반대쪽으로 늘어난다.
    func testShiftArrowGrowsAndShrinksFromAnchor() {
        var selection = RowSelection()
        _ = selection.click("c", in: list, current: nil, modifier: .none)
        XCTAssertEqual(selection.move(by: 1, in: list, current: "c", extend: true), "d")
        XCTAssertEqual(selection.move(by: 1, in: list, current: "d", extend: true), "e")
        XCTAssertEqual(selection.ids, ["c", "d", "e"])
        XCTAssertEqual(selection.move(by: -1, in: list, current: "e", extend: true), "d")
        XCTAssertEqual(selection.ids, ["c", "d"])
        _ = selection.move(by: -1, in: list, current: "d", extend: true)
        XCTAssertEqual(selection.move(by: -1, in: list, current: "c", extend: true), "b")
        XCTAssertEqual(selection.ids, ["b", "c"])
        XCTAssertEqual(selection.anchor, "c")
    }

    /// 시작점이 목록에서 빠졌으면 보고 있던 행에서 다시 시작한다.
    func testShiftArrowRestartsFromCurrentWhenAnchorIsGone() {
        var selection = RowSelection(ids: ["x"], anchor: "x")
        XCTAssertEqual(selection.move(by: 1, in: list, current: "b", extend: true), "c")
        XCTAssertEqual(selection.ids, ["b", "c"])
        XCTAssertEqual(selection.anchor, "b")
    }
}
