import XCTest
@testable import PRayerCore

/// 문제 기록과 보고 글.
///
/// 보고 글은 팀원이 슬랙 등으로 보내는 것이라, 이 맥에만 남아야 할 설명(파일 이름·PR 번호)이
/// 섞이면 회사 코드 정보가 밖으로 나간다. 그 조건을 테스트로 잠근다.
final class ProblemLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("problem-log-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent("problems.json") }

    func testRecordsAndReadsBackAcrossInstances() {
        ProblemLog(fileURL: file).record(.diffTooLarge, detail: "#1 diff 가 너무 큼")
        let entries = ProblemLog(fileURL: file).entries()
        XCTAssertEqual(entries.map(\.kind), [.diffTooLarge])
        XCTAssertEqual(entries.first?.detail, "#1 diff 가 너무 큼")
    }

    /// 테스트·개발 중에 쓰지 않게 끈 기록은 파일을 만들지 않는다.
    func testDisabledLogWritesNothing() {
        ProblemLog(fileURL: file, enabled: false).record(.other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 오래된 것(60일)과 넘치는 것(2000건)은 버린다 — 파일이 끝없이 커지지 않게.
    func testTrimsOldAndExcessEntries() {
        let now = Date()
        let old = ProblemEntry(at: now.addingTimeInterval(-61 * 86_400), kind: .other, appVersion: "0.1.0")
        let fresh = ProblemEntry(at: now, kind: .postFailed, appVersion: "0.4.5")
        XCTAssertEqual(ProblemLog.trimmed([old, fresh], now: now).map(\.kind), [.postFailed])

        let many = (0..<(ProblemLog.maxEntries + 5)).map { index in
            ProblemEntry(at: now.addingTimeInterval(Double(index)), kind: .other, appVersion: "0.4.5")
        }
        let kept = ProblemLog.trimmed(many, now: now)
        XCTAssertEqual(kept.count, ProblemLog.maxEntries)
        XCTAssertEqual(kept.last?.at, many.last?.at, "가장 최근 것을 남긴다")
    }

    /// 새 버전이 쓴 모르는 종류 때문에 기록 전체가 안 읽히면 모아 둔 것이 통째로 사라진다.
    func testUnknownKindReadsAsOther() throws {
        let json = #"[{"at":"2026-09-30T00:00:00Z","kind":"somethingNew","appVersion":"9.9.9"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([ProblemEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.kind, .other)
    }

    func testRefineNarrowsKnownCauses() {
        let tooMany = "gh 호출 실패: gh: Sorry, the diff exceeded the maximum number of files (300)."
        XCTAssertEqual(ProblemKind.refine(.reviewFailed, message: tooMany), .diffTooLarge)
        XCTAssertEqual(ProblemKind.refine(.diffLoadFailed, message: tooMany), .diffTooLarge)
        XCTAssertEqual(ProblemKind.refine(.reviewFailed, message: "Failed to authenticate: OAuth session expired"),
                       .claudeAuthExpired)
        // gh 의 "not logged in" 은 GitHub 쪽 문제다. Claude 로그인 만료로 세면 엉뚱한 것을 고치게 된다.
        XCTAssertEqual(ProblemKind.refine(.diffLoadFailed, message: "gh: not logged in"), .diffLoadFailed)
        XCTAssertEqual(ProblemKind.refine(.postFailed, message: "HTTP 422"), .postFailed)
    }

    /// 보고 글에는 종류·횟수·버전만 — 설명(detail)은 한 글자도 들어가지 않는다.
    func testReportCarriesNoDetails() {
        let now = Date()
        let entries = [
            ProblemEntry(at: now, kind: .multiLineRangeDropped, appVersion: "0.4.4",
                         detail: "#9999 SecretFile.swift:113 코멘트 — acme/secret-repo"),
            ProblemEntry(at: now.addingTimeInterval(-60), kind: .multiLineRangeDropped, appVersion: "0.4.5"),
            ProblemEntry(at: now, kind: .claudeAuthExpired, appVersion: "0.4.5", detail: "account someone@example.com"),
            ProblemEntry(at: now.addingTimeInterval(-40 * 86_400), kind: .postFailed, appVersion: "0.4.0"),
        ]
        let context = ProblemReport.Context(appVersion: "0.4.5", build: "93", channel: "베타", osVersion: "26.0.0",
                                            claudeVersion: "2.1.284", reviewModel: "Opus 5.5")
        let text = ProblemReport.text(entries: entries, context: context, days: 30, now: now)

        XCTAssertTrue(text.contains("여러 줄 범위를 떼고 한 줄로 게시 — 2회"))
        XCTAssertTrue(text.contains("v0.4.4·v0.4.5"), "어느 버전에서 났는지는 남긴다")
        XCTAssertTrue(text.contains("Claude 로그인 만료 — 1회"))
        XCTAssertFalse(text.contains("게시 실패"), "기간 밖(40일 전)은 넣지 않는다")
        for secret in ["9999", "SecretFile", "secret-repo", "someone@example.com", "코멘트 —"] {
            XCTAssertFalse(text.contains(secret), "보고 글에 설명이 샜다: \(secret)")
        }
    }

    func testEmptyReportSaysSo() {
        let context = ProblemReport.Context(appVersion: "0.4.5", build: "93", channel: nil, osVersion: "26.0.0",
                                            claudeVersion: nil, reviewModel: nil)
        XCTAssertTrue(ProblemReport.text(entries: [], context: context, days: 30).contains("기록된 문제가 없습니다"))
    }

    /// 검사기가 내는 경고마다 종류가 붙어야 문제 기록에서 "기타" 로 뭉치지 않는다.
    func testValidatorIssuesCarryKinds() {
        let output = ReviewOutput(verdict: .comment, summaryKo: "요약", concerns: [], strengths: [], draftComments: [])
        let diff = DiffParser.parse("")
        let result = DraftValidator.validate(output: output, diff: diff,
                                             limits: ReviewLimits(maxComments: 3, minBodyChars: 1,
                                                                  maxBodyChars: 400, maxSummaryChars: 300))
        XCTAssertEqual(result.issues.map(\.kind), [.verdictWithoutReason])
    }
}
