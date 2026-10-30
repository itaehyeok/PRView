import XCTest
@testable import PRayerCore

/// 앱이 놓인 자리와 업데이트를 어디에 깔지.
///
/// 브라우저로 받은 zip 을 풀고 그 자리에서 바로 연 앱은 macOS 가 읽기 전용 임시 위치에서
/// 실행한다(App Translocation). 그 위치를 그대로 쓰면 "설치된 폴더에 쓸 수 없습니다" 로
/// 업데이트가 막힌다 — 팀원 맥에서 실제로 그랬고, 응용 프로그램 폴더로 옮겨야만 됐다.
/// 그래서 응용 프로그램 폴더 밖이면 켤 때 옮길지 묻고, 안 옮긴 채 업데이트하면 옮겨 깐다.
final class UpdateInstallTargetTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me")
    private let translocated = URL(
        fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/0D5F-1234/d/PRayer.app")
    private let downloaded = URL(fileURLWithPath: "/Users/me/Downloads/PRayer.app")
    private let systemApp = URL(fileURLWithPath: "/Applications/PRayer.app")
    private let userApp = URL(fileURLWithPath: "/Users/me/Applications/PRayer.app")

    // MARK: - 업데이트를 깔 자리

    /// 다운로드 폴더에서 바로 연(격리 실행) 앱은 업데이트하면서 응용 프로그램 폴더로 옮겨 깐다.
    /// 원래 앱은 새 자리에서 켠 뒤 치운다.
    func testTranslocatedAppMovesToApplicationsOnUpdate() {
        let downloaded = downloaded
        let result = UpdateInstallTarget.plan(
            running: translocated, home: home,
            original: { _ in downloaded },
            exists: { _ in false },
            isWritable: { $0 == "/Applications" })
        XCTAssertEqual(result, .success(InstallPlan(target: systemApp, moves: true, leftover: downloaded)))
    }

    /// 원래 위치를 못 찾아도 옮겨 깐다 — 치울 원래 앱만 모른다(사람에게 지워 달라고 한다).
    func testTranslocatedWithoutOriginalStillMoves() {
        let result = UpdateInstallTarget.plan(
            running: translocated, home: home,
            original: { _ in nil },
            exists: { _ in false },
            isWritable: { $0 == "/Applications" })
        XCTAssertEqual(result, .success(InstallPlan(target: systemApp, moves: true, leftover: nil)))
    }

    /// 격리 딱지가 없어 격리 실행이 아니어도, 다운로드 폴더에 있으면 옮겨 깐다.
    func testDownloadsFolderWithoutTranslocationMoves() {
        let result = UpdateInstallTarget.plan(
            running: downloaded, home: home,
            original: { _ in nil },
            exists: { _ in false },
            isWritable: { _ in true })
        XCTAssertEqual(result, .success(InstallPlan(target: systemApp, moves: true, leftover: downloaded)))
    }

    /// 관리자 계정이 아니라 /Applications 에 쓸 수 없으면 ~/Applications(없으면 만든다).
    func testNonAdminMovesToUserApplications() {
        let result = UpdateInstallTarget.plan(
            running: downloaded, home: home,
            original: { _ in nil },
            exists: { _ in false },
            isWritable: { $0 == "/Users/me" })
        XCTAssertEqual(result, .success(InstallPlan(target: userApp, moves: true, leftover: downloaded)))
    }

    /// ~/Applications 에 이미 깔린 PRayer 가 있으면 그 자리 — 사본을 하나 더 만들지 않는다.
    func testExistingUserInstallIsReused() {
        let userApp = userApp
        let result = UpdateInstallTarget.plan(
            running: downloaded, home: home,
            original: { _ in nil },
            exists: { $0 == userApp.path || $0 == "/Users/me/Applications" },
            isWritable: { _ in true })
        XCTAssertEqual(result, .success(InstallPlan(target: userApp, moves: true, leftover: downloaded)))
    }

    /// 디스크 이미지 등 읽기 전용 자리에서 연 앱도 응용 프로그램 폴더로 옮겨 깐다.
    func testReadOnlyVolumeMovesToApplications() {
        let mounted = URL(fileURLWithPath: "/Volumes/PRayer/PRayer.app")
        let result = UpdateInstallTarget.plan(
            running: translocated, home: home,
            original: { _ in mounted },
            exists: { _ in false },
            isWritable: { $0 == "/Applications" })
        XCTAssertEqual(result, .success(InstallPlan(target: systemApp, moves: true, leftover: mounted)))
    }

    func testApplicationsFolderInstallsInPlace() {
        let result = UpdateInstallTarget.plan(
            running: systemApp, home: home,
            original: { _ in nil },
            exists: { _ in true },
            isWritable: { $0 == "/Applications" })
        XCTAssertEqual(result, .success(InstallPlan(target: systemApp, moves: false, leftover: nil)))
    }

    /// ~/Applications 아래 하위 폴더도 깔린 자리다(옮기라고 하지 않는다).
    func testUserApplicationsSubfolderInstallsInPlace() {
        let nested = URL(fileURLWithPath: "/Users/me/Applications/Tools/PRayer.app")
        let result = UpdateInstallTarget.plan(
            running: nested, home: home,
            original: { _ in nil },
            exists: { _ in true },
            isWritable: { _ in true })
        XCTAssertEqual(result, .success(InstallPlan(target: nested, moves: false, leftover: nil)))
    }

    /// 권한이 없는 응용 프로그램 폴더(관리자가 깔아 둔 앱 등)는 어느 폴더인지 알려 준다.
    func testUnwritableFolderNamesTheFolder() {
        let result = UpdateInstallTarget.plan(
            running: systemApp, home: home,
            original: { _ in nil },
            exists: { _ in true },
            isWritable: { _ in false })
        XCTAssertEqual(result, .failure(.notWritable(folder: "/Applications")))
    }

    /// 옮겨 깔 자리에도 쓸 수 없으면 그 자리를 알려 준다 — 임시 위치가 아니다.
    func testUnwritableDestinationNamesThatFolder() {
        let result = UpdateInstallTarget.plan(
            running: translocated, home: home,
            original: { _ in nil },
            exists: { _ in false },
            isWritable: { _ in false })
        XCTAssertEqual(result, .failure(.notWritable(folder: "/Users/me/Applications")))
    }

    // MARK: - 켤 때 옮길지

    func testPlacement() {
        let downloaded = downloaded
        XCTAssertEqual(AppPlacement.placement(of: systemApp, home: home, original: { _ in nil }), .installed(systemApp))
        XCTAssertEqual(AppPlacement.placement(of: userApp, home: home, original: { _ in nil }), .installed(userApp))
        XCTAssertEqual(AppPlacement.placement(of: downloaded, home: home, original: { _ in nil }),
                       .misplaced(original: downloaded))
        XCTAssertEqual(AppPlacement.placement(of: translocated, home: home, original: { _ in downloaded }),
                       .misplaced(original: downloaded))
        XCTAssertEqual(AppPlacement.placement(of: translocated, home: home, original: { _ in nil }),
                       .misplaced(original: nil))
        // 이름만 비슷한 폴더는 응용 프로그램 폴더가 아니다.
        let lookalike = URL(fileURLWithPath: "/Applications-old/PRayer.app")
        XCTAssertEqual(AppPlacement.placement(of: lookalike, home: home, original: { _ in nil }),
                       .misplaced(original: lookalike))
    }

    /// 격리 실행이어도 원래 자리가 응용 프로그램 폴더면(터미널로 복사해 딱지가 남은 경우) 그 자리다.
    func testTranslocatedFromApplicationsIsInstalled() {
        let systemApp = systemApp
        XCTAssertEqual(AppPlacement.placement(of: translocated, home: home, original: { _ in systemApp }),
                       .installed(systemApp))
    }

    func testDestinationPrefersExistingUserInstallThenSystem() {
        let userApp = userApp
        XCTAssertEqual(AppPlacement.destination(home: home, exists: { $0 == userApp.path }, isWritable: { _ in true }),
                       userApp)
        XCTAssertEqual(AppPlacement.destination(home: home, exists: { _ in false }, isWritable: { _ in true }),
                       systemApp)
        XCTAssertEqual(AppPlacement.destination(home: home, exists: { _ in false }, isWritable: { _ in false }),
                       userApp)
    }

    func testDescribeNamesTheFolder() {
        XCTAssertEqual(AppPlacement.describe(downloaded, home: home), "다운로드 폴더")
        XCTAssertEqual(AppPlacement.describe(URL(fileURLWithPath: "/Users/me/Downloads/PRayer-0.4.8/PRayer.app"), home: home),
                       "다운로드 폴더")
        XCTAssertEqual(AppPlacement.describe(URL(fileURLWithPath: "/Users/me/Desktop/PRayer.app"), home: home), "데스크탑")
        XCTAssertEqual(AppPlacement.describe(URL(fileURLWithPath: "/Volumes/PRayer/PRayer.app"), home: home),
                       "디스크 이미지·외장 디스크")
        XCTAssertEqual(AppPlacement.describe(URL(fileURLWithPath: "/Users/me/tools/PRayer.app"), home: home), "~/tools")
        XCTAssertEqual(AppPlacement.describe(nil, home: home), "받은 자리(다운로드 폴더 등)")
        XCTAssertEqual(AppPlacement.destinationLabel(systemApp, home: home), "응용 프로그램 폴더")
        XCTAssertEqual(AppPlacement.destinationLabel(userApp, home: home), "내 응용 프로그램 폴더(~/Applications)")
    }

    /// 옮길 자리에 같거나 더 새 버전이 있으면 덮지 않는다 — 다운로드 폴더에 남은 옛 사본을 열었다고
    /// 깔려 있던 새 버전을 되돌리면 안 된다.
    func testShouldReplaceOnlyOlderInstall() {
        XCTAssertTrue(AppPlacement.shouldReplace(existingVersion: nil, with: "0.4.8"))
        XCTAssertTrue(AppPlacement.shouldReplace(existingVersion: "0.4.6", with: "0.4.8"))
        XCTAssertFalse(AppPlacement.shouldReplace(existingVersion: "0.4.8", with: "0.4.8"))
        XCTAssertFalse(AppPlacement.shouldReplace(existingVersion: "0.4.10", with: "0.4.8"))
    }

    /// 옮긴 뒤 치우는 것은 응용 프로그램 폴더 밖의 원래 앱뿐이다. 깔린 앱·지금 도는 앱은 절대 치우지 않는다.
    func testOnlyMisplacedLeftoverCanBeDiscarded() {
        XCTAssertTrue(AppPlacement.canDiscardLeftover(downloaded, running: systemApp, home: home))
        XCTAssertFalse(AppPlacement.canDiscardLeftover(systemApp, running: userApp, home: home))
        XCTAssertFalse(AppPlacement.canDiscardLeftover(userApp, running: systemApp, home: home))
        XCTAssertFalse(AppPlacement.canDiscardLeftover(downloaded, running: downloaded, home: home))
        XCTAssertFalse(AppPlacement.canDiscardLeftover(URL(fileURLWithPath: "/Users/me/Downloads"), running: systemApp, home: home))
    }

    /// 실제 조회: 격리 실행이 아닌 경로는 nil — 평소 설치본을 다른 곳으로 돌리지 않는다.
    /// (원래 경로 함수는 격리 실행이 아니어도 받은 경로를 돌려주므로, 먼저 묻지 않으면 여기서 깨진다.)
    func testRealLookupIgnoresNormalPaths() {
        XCTAssertNil(AppTranslocation.originalURL(of: URL(fileURLWithPath: NSTemporaryDirectory())))
        XCTAssertNil(AppTranslocation.originalURL(of: Bundle.main.bundleURL))
        XCTAssertFalse(AppTranslocation.looksTranslocated(Bundle.main.bundleURL))
        XCTAssertTrue(AppTranslocation.looksTranslocated(translocated))
    }
}
