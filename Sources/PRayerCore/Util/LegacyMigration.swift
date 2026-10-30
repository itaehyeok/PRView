import Foundation

/// 앱 이름을 바꾸기 전(PRMap, 그 전엔 PRDeck)의 흔적을 새 이름으로 옮긴다.
///
/// 데이터 폴더와 번들 ID 가 앱 이름에서 나오기 때문에, 옮기지 않으면 설정·리뷰 초안·토큰 원장·
/// 필터가 통째로 사라진 것처럼 보인다(옛 자리에 그대로 있지만 앱이 찾지 않는다).
/// **여기 적힌 옛 이름은 지우지 마라** — 아직 한 번도 새 앱을 켜지 않은 맥이 있을 수 있다.
public enum LegacyMigration {
    /// 옛 앱 이름. 가장 최근 것부터 찾는다.
    static let appNames = ["PRMap", "PRDeck"]
    static let legacyLogNames = ["prmap.log"]
    /// 옛 번들 ID. UserDefaults(필터·탭·창 상태)가 이 이름으로 저장돼 있다.
    static let bundleIDs = ["dev.itaehyeok.PRMapApp"]
    static let bundleID = "dev.itaehyeok.PRayer"

    /// 앱이 켤 때 **다른 무엇보다 먼저** 한 번 부른다 — 폴더를 만들거나 로그를 쓰기 전에.
    ///
    /// 예전에는 `AppPaths.support` 를 읽을 때마다 알아서 옮겼다. 그러면 경로만 계산하는 테스트도
    /// 폴더를 옮겼고, 옛 앱이 떠 있는 채로 테스트를 돌리면 그 앱의 데이터 폴더가 발밑에서 사라졌다.
    public static func run(bundle: Bundle = .main) {
        var notes: [String] = []
        if let note = migrateDataFolder(base: AppPaths.applicationSupportBase, current: AppPaths.dataDirectoryName) {
            notes.append(note)
        }
        if let id = bundle.bundleIdentifier,
           let note = migrateDefaults(to: id, from: legacyBundleIDs(for: id)) {
            notes.append(note)
        }
        // 로그는 다 옮긴 뒤에 쓴다. 먼저 쓰면 로그가 새 폴더를 만들어 버린다.
        for note in notes { Log.info(note, "app") }
    }

    // MARK: - 데이터 폴더

    /// 지금 이름과 꼬리가 같은 옛 이름. `PRayer` → `PRMap`·`PRDeck`, 작업본 `PRayer-work` →
    /// `PRMap-work`·`PRDeck-work`. 꼬리를 맞추지 않으면 작업본이 먼저 켜졌을 때
    /// **실제 데이터 폴더를 작업본으로 가져간다.** 앱 이름으로 시작하지 않는 이름은 옮기지 않는다.
    static func legacyDirectoryNames(for current: String) -> [String] {
        guard current.hasPrefix(AppInfo.name) else { return [] }
        let suffix = current.dropFirst(AppInfo.name.count)
        return appNames.map { $0 + suffix }
    }

    /// 새 폴더가 없으면 통째로 옮긴다. 있어도 설정 파일이 없으면 안의 것을 옮겨 담는다 —
    /// 로그·테스트가 폴더부터 만들어 두는 일이 있어서, "새 폴더가 있으면 건너뛴다" 로 두면
    /// 데이터가 사라진 것처럼 보인다. 새 폴더에 설정이 이미 있으면 건드리지 않는다.
    static func migrateDataFolder(base: URL, current: String) -> String? {
        let fm = FileManager.default
        let target = base.appendingPathComponent(current, isDirectory: true)
        for name in legacyDirectoryNames(for: current) {
            let old = base.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: old.path) else { continue }
            do {
                if !fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: old, to: target)
                } else if !fm.fileExists(atPath: target.appendingPathComponent("settings.json").path) {
                    try mergeMove(from: old, into: target)
                } else {
                    return nil
                }
                renameLegacyLogs(in: target)
                return "데이터 폴더를 \(name) 에서 \(current) 로 옮겼다"
            } catch {
                return "데이터 폴더 이전 실패(\(name)): \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// `source` 안의 것을 `target` 으로 옮긴다. 같은 이름의 폴더는 안으로 들어가 합치고, 같은 이름의
    /// 파일은 **옛 쪽을 남긴다** — 여기 오는 건 새 폴더가 설정 파일도 없는 껍데기일 때라, 진짜 데이터는
    /// 옛 쪽에 있다(실측: 실측 리뷰 테스트가 먼저 만든 1건짜리 token-ledger.json 이 진짜 원장을 밀어낼 뻔했다).
    /// 다 옮겨 비면 옛 폴더를 지운다(못 옮긴 게 있으면 그대로 둔다).
    static func mergeMove(from source: URL, into target: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            var targetIsDirectory: ObjCBool = false
            var itemIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: destination.path, isDirectory: &targetIsDirectory) else {
                try fm.moveItem(at: item, to: destination)
                continue
            }
            let itemIsFolder = fm.fileExists(atPath: item.path, isDirectory: &itemIsDirectory) && itemIsDirectory.boolValue
            if targetIsDirectory.boolValue, itemIsFolder {
                try mergeMove(from: item, into: destination)
            } else if !targetIsDirectory.boolValue, !itemIsFolder {
                try fm.removeItem(at: destination)
                try fm.moveItem(at: item, to: destination)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fm.removeItem(at: source)
        }
    }

    /// `prmap.log` → `prayer.log`. 새 로그가 이미 있으면 옛 로그 뒤에 이어 붙여 하나로 만든다.
    static func renameLegacyLogs(in folder: URL) {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(AppPaths.logFileName)
        for name in legacyLogNames {
            let old = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path) else { continue }
            if let newer = try? Data(contentsOf: target), let handle = try? FileHandle(forWritingTo: old) {
                handle.seekToEndOfFile()
                handle.write(newer)
                try? handle.close()
                try? fm.removeItem(at: target)
            }
            try? fm.moveItem(at: old, to: target)
        }
    }

    // MARK: - UserDefaults

    /// `dev.itaehyeok.PRayer` → `dev.itaehyeok.PRMapApp`, 작업본 `….PRayer.work` → `….PRMapApp.work`.
    /// 작업본은 작업본끼리 잇는다 — 실제 앱의 필터를 작업본으로 가져가지 않게.
    static func legacyBundleIDs(for current: String) -> [String] {
        guard current.hasPrefix(bundleID) else { return [] }
        let suffix = current.dropFirst(bundleID.count)
        guard suffix.isEmpty || suffix.hasPrefix(".") else { return [] }
        return bundleIDs.map { $0 + suffix }
    }

    /// 번들 ID 가 바뀌면 UserDefaults 도 새 이름으로 갈린다. 새 쪽이 비어 있을 때만 옛 것을 통째로
    /// 옮겨 온다(샌드박스가 꺼져 있어 다른 앱의 도메인을 읽을 수 있다). 옛 쪽은 지우지 않는다.
    static func migrateDefaults(to current: String, from legacy: [String],
                                defaults: UserDefaults = .standard) -> String? {
        guard (defaults.persistentDomain(forName: current) ?? [:]).isEmpty else { return nil }
        for name in legacy {
            guard let values = defaults.persistentDomain(forName: name), !values.isEmpty else { continue }
            defaults.setPersistentDomain(values, forName: current)
            return "설정(UserDefaults \(values.count)개)을 \(name) 에서 옮겼다"
        }
        return nil
    }
}
