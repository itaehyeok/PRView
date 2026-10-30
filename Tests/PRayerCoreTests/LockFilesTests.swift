import XCTest
@testable import PRayerCore

/// 잠금 파일은 규칙 없이 늘 리뷰에서 빠진다(사용자가 고르지 않는다).
final class LockFilesTests: XCTestCase {
    func testKnownLockFilesAcrossEcosystems() {
        for path in ["package-lock.json", "web/yarn.lock", "pnpm-lock.yaml", "api/go.sum", "Cargo.lock",
                     "Gemfile.lock", "composer.lock", "poetry.lock", "android/gradle.lockfile",
                     "App.xcworkspace/xcshareddata/swiftpm/Package.resolved", "ios/Podfile.lock", "pubspec.lock",
                     "infra/.terraform.lock.hcl"] {
            XCTAssertTrue(LockFiles.isLockFile(path), path)
        }
    }

    /// 짝이 되는 선언 파일은 사람이 고친다 — 의존성이 바뀐 것은 여기서 리뷰한다.
    func testManifestsAreNotLockFiles() {
        for path in ["package.json", "go.mod", "Cargo.toml", "Gemfile", "Podfile", "Package.swift",
                     "build.gradle", "pubspec.yaml", "Sources/yarn.lock.swift", "docs/Package.resolved.md"] {
            XCTAssertFalse(LockFiles.isLockFile(path), path)
        }
    }

    func testParserExcludesLockFilesWithoutRules() {
        let text = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,1 +1,2 @@
         let a = 1
        +let b = 2
        diff --git a/web/package-lock.json b/web/package-lock.json
        --- a/web/package-lock.json
        +++ b/web/package-lock.json
        @@ -1,2 +1,2 @@
        -  "version": "1.0.0",
        +  "version": "1.0.1",
           "lockfileVersion": 3
        """
        let diff = DiffParser.parse(text)
        XCTAssertEqual(diff.files.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(diff.excludedFiles.map(\.path), ["web/package-lock.json"])
        XCTAssertEqual(diff.changedLines, 1, "예상 토큰·크기 상한은 잠금 파일을 뺀 줄 수로 센다")
        XCTAssertEqual(diff.applyingExclusions([]).excludedFiles.map(\.path), ["web/package-lock.json"],
                       "규칙을 비워도 잠금 파일은 빠진 채로 남는다")
        let prompt = PromptBuilder.numberedDiff(diff)
        XCTAssertFalse(prompt.contains("lockfileVersion"), "잠금 파일 내용은 보내지 않는다")
    }

    func testNewUsersStartWithNoExclusionRules() {
        XCTAssertEqual(Settings.default.excludedPathPatterns, [])
    }

    /// 기본값을 비운 뒤에도 이미 쓰던 사람의 목록은 그대로다(사용자 요구) — 저장된 설정에 목록이 있으면 그것을 쓴다.
    /// 예전 앱(v0.4.11 등)은 설정을 저장할 때 이 목록도 함께 썼다.
    func testExistingUsersKeepTheirExclusionRules() throws {
        let saved = #"{"excludedPathPatterns":["*.pbxproj","Package.resolved","*.xcassets/*"]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(saved.utf8))
        XCTAssertEqual(settings.excludedPathPatterns, ["*.pbxproj", "Package.resolved", "*.xcassets/*"])
        let empty = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.excludedPathPatterns, [], "목록을 저장한 적이 없을 때만 빈 목록")
        let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.excludedPathPatterns, settings.excludedPathPatterns, "다시 저장해도 그대로")
    }
}
