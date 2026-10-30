import Foundation

/// macOS 의 앱 격리 실행(App Translocation).
///
/// 브라우저로 받은 zip 을 풀어 그 자리(다운로드 폴더 등)에서 바로 열면, macOS 는 앱을
/// 읽기 전용 임시 위치(`/private/var/folders/…/AppTranslocation/…`)에 붙여 실행한다.
/// 그 앱의 `Bundle.main.bundleURL` 은 임시 위치라 옆에 새 버전을 놓을 수 없다 — 팀원의
/// 앱 업데이트가 "설치된 폴더에 쓸 수 없습니다" 로 막힌 원인이었다. Finder 로 다른 폴더에
/// 옮기면 풀리고, 설치 명령(curl)으로 받은 앱은 격리 딱지가 없어 애초에 해당하지 않는다.
///
/// 원래 위치를 알려 주는 공개 API 가 없어 Security.framework 의 SPI 를 쓴다(macOS 10.12 부터).
/// 심볼을 못 찾으면 nil 이고, 그때는 경로 모양으로 격리 실행인지만 알아본다.
public enum AppTranslocation {
    /// 격리 실행 중이면 원래 경로, 아니면(또는 알아낼 수 없으면) nil.
    public static func originalURL(of url: URL) -> URL? {
        typealias IsTranslocated = @convention(c) (
            CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        typealias OriginalPath = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        var translocated = false
        // 격리 실행이 아니어도 원래 경로 함수는 받은 경로를 그대로 돌려준다(실측) — 먼저 묻는다.
        guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(url as CFURL, &translocated, nil).boolValue,
              translocated,
              let original = unsafeBitCast(originalSymbol, to: OriginalPath.self)(url as CFURL, nil) else { return nil }
        return (original.takeRetainedValue() as URL).resolvingSymlinksInPath()
    }

    /// 경로 모양만 보고 격리 실행 중인지. 원래 위치를 못 찾았을 때 안내를 고르는 데만 쓴다.
    public static func looksTranslocated(_ url: URL) -> Bool {
        url.pathComponents.contains("AppTranslocation")
    }
}

/// 앱이 놓인 자리. 업데이트를 어디에 깔지, 켤 때 "응용 프로그램 폴더로 옮길까요?" 를 물을지 정한다.
///
/// 응용 프로그램 폴더(/Applications · ~/Applications) 밖에서 도는 앱 — 받은 zip 을 다운로드 폴더에서
/// 바로 연 경우가 거의 다다 — 은 응용 프로그램 폴더로 옮겨 깐다. 원래 자리에서 바꿔 끼우는 것(v0.4.7)도
/// 되지만, 앱이 다운로드 폴더에 계속 남아 정리하다 지워지거나 다시 받을 때 `PRayer 2.app` 같은 사본이 생긴다.
public enum AppPlacement: Equatable, Sendable {
    /// 응용 프로그램 폴더 안. 그 자리에서 바꿔 끼운다.
    case installed(URL)
    /// 그 밖. `original` 은 실제 파일 자리 — 격리 실행인데 원래 위치를 못 찾았으면 nil.
    case misplaced(original: URL?)

    public static let appName = "PRayer.app"

    public static func placement(
        of running: URL,
        home: URL,
        original: (URL) -> URL? = AppTranslocation.originalURL(of:)
    ) -> AppPlacement {
        let actual: URL?
        if let found = original(running) {
            actual = found
        } else if AppTranslocation.looksTranslocated(running) {
            actual = nil
        } else {
            actual = running
        }
        guard let actual else { return .misplaced(original: nil) }
        return isInApplicationsFolder(actual, home: home) ? .installed(actual) : .misplaced(original: actual)
    }

    /// /Applications 나 ~/Applications 아래인가(그 안의 하위 폴더도 포함).
    public static func isInApplicationsFolder(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return ["/Applications", userApplications(home: home).path].contains { path.hasPrefix($0 + "/") }
    }

    static func userApplications(home: URL) -> URL {
        home.appendingPathComponent("Applications").standardizedFileURL
    }

    /// 옮겨 깔 자리. ~/Applications 에 이미 깔린 PRayer 가 있으면 그 자리(사본을 늘리지 않는다),
    /// 아니면 /Applications, 거기에 쓸 수 없으면(관리자 계정이 아님) ~/Applications.
    public static func destination(
        home: URL,
        exists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        isWritable: (String) -> Bool = FileManager.default.isWritableFile(atPath:)
    ) -> URL {
        let user = userApplications(home: home).appendingPathComponent(appName)
        if exists(user.path) { return user }
        if isWritable("/Applications") { return URL(fileURLWithPath: "/Applications").appendingPathComponent(appName) }
        return user
    }

    /// 앱이 있던 자리를 사람에게 보일 말("다운로드 폴더" 처럼). 뒤에 "에서"·"에" 를 붙여 쓴다.
    public static func describe(_ original: URL?, home: URL) -> String {
        guard let original else { return "받은 자리(다운로드 폴더 등)" }
        let folder = original.deletingLastPathComponent().standardizedFileURL.path
        for (name, label) in [("Downloads", "다운로드 폴더"), ("Desktop", "데스크탑"), ("Documents", "문서 폴더")] {
            let base = home.appendingPathComponent(name).standardizedFileURL.path
            if folder == base || folder.hasPrefix(base + "/") { return label }
        }
        if folder.hasPrefix("/Volumes/") { return "디스크 이미지·외장 디스크" }
        let homePath = home.standardizedFileURL.path
        return folder.hasPrefix(homePath + "/") ? "~" + folder.dropFirst(homePath.count) : folder
    }

    /// 옮겨 갈 자리를 사람에게 보일 말.
    public static func destinationLabel(_ destination: URL, home: URL) -> String {
        let folder = destination.deletingLastPathComponent().standardizedFileURL.path
        return folder == userApplications(home: home).path ? "내 응용 프로그램 폴더(~/Applications)" : "응용 프로그램 폴더"
    }

    /// 옮길 자리에 이미 PRayer 가 있을 때 덮을지. 같거나 더 새 버전이면 덮지 않고 그걸 켠다 —
    /// 다운로드 폴더에 남은 옛 사본을 열었다고 깔려 있던 새 버전을 되돌리지 않는다.
    public static func shouldReplace(existingVersion: String?, with version: String) -> Bool {
        guard let existingVersion else { return true }
        return UpdateCheck.isNewer(version, than: existingVersion)
    }

    /// 옮겨 깐 뒤 원래 앱을 휴지통으로 보내도 되는가. 응용 프로그램 폴더 안의 것(깔린 앱)과
    /// 지금 도는 앱은 절대 치우지 않는다.
    public static func canDiscardLeftover(_ leftover: URL, running: URL, home: URL) -> Bool {
        guard leftover.pathExtension == "app",
              leftover.standardizedFileURL.path != running.standardizedFileURL.path else { return false }
        return !isInApplicationsFolder(leftover, home: home)
    }
}

/// 업데이트를 어디에 깔지.
public struct InstallPlan: Equatable, Sendable {
    /// 새 버전이 놓일 자리. 이미 있으면 바꿔 끼우고, 없으면 새로 놓는다.
    public var target: URL
    /// 응용 프로그램 폴더로 옮겨 까는가. 그러면 새 자리에서 켠 뒤 `leftover` 를 치운다.
    public var moves: Bool
    /// 옮겨 깐 뒤 치울 원래 앱. 격리 실행인데 원래 위치를 못 찾았으면 nil(사람이 지워야 한다).
    public var leftover: URL?

    public init(target: URL, moves: Bool, leftover: URL?) {
        self.target = target
        self.moves = moves
        self.leftover = leftover
    }
}

public enum UpdateInstallTarget {
    public enum Problem: Error, Equatable {
        /// 이 폴더에 쓸 수 없다.
        case notWritable(folder: String)
    }

    /// 응용 프로그램 폴더 안이면 그 자리, 밖이면(다운로드 폴더에서 바로 연 앱 등) 응용 프로그램 폴더로 옮겨 깐다.
    /// 업데이트로 받은 새 앱에는 격리 딱지가 없어, 새 자리에서는 그대로 실행된다.
    public static func plan(
        running: URL,
        home: URL,
        original: (URL) -> URL? = AppTranslocation.originalURL(of:),
        exists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        isWritable: (String) -> Bool = FileManager.default.isWritableFile(atPath:)
    ) -> Result<InstallPlan, Problem> {
        switch AppPlacement.placement(of: running, home: home, original: original) {
        case .installed(let app):
            let folder = app.deletingLastPathComponent().path
            guard isWritable(folder) else { return .failure(.notWritable(folder: folder)) }
            return .success(InstallPlan(target: app, moves: false, leftover: nil))
        case .misplaced(let original):
            let target = AppPlacement.destination(home: home, exists: exists, isWritable: isWritable)
            let folder = target.deletingLastPathComponent().path
            // ~/Applications 는 아직 없을 수 있다 — 그때는 만들 수 있는지(홈에 쓸 수 있는지)를 본다.
            guard isWritable(folder) || (!exists(folder) && isWritable(home.path)) else {
                return .failure(.notWritable(folder: folder))
            }
            return .success(InstallPlan(target: target, moves: true, leftover: original))
        }
    }
}
