import AppKit
import Foundation
import PRayerCore

/// 설정 가져오기 결과. 가져오기 창이 닫히기 전에 보여 주고, 되돌리기에 쓴다.
struct SettingsImportReport {
    /// 실제로 바뀐 항목(사람이 읽는 말).
    var applied: [String]
    /// 내 계정으로 볼 수 없어 넣지 않은 레포.
    var unreachableRepos: [String]
    /// 볼 수 있는지 확인하지 못했지만 넣은 레포(네트워크·로그인 문제).
    var uncheckedRepos: [String]
    var problems: [String]
    /// 가져오기 전 설정. "되돌리기" 가 이 값으로 돌아간다.
    var previous: Settings
    /// 가져오기 전 설정을 파일로도 남긴 자리. 창을 닫은 뒤에 되돌리고 싶을 때 쓴다.
    var backupFile: URL?
}

/// 설정 내보내기·가져오기. 무엇을 담고 어떻게 합치는지는 `SettingsTransfer`(Core)가 정하고,
/// 여기서는 파일 읽기·쓰기, GitHub 확인, 저장 뒤처리처럼 앱에서만 할 수 있는 일을 한다.
extension AppModel {
    func exportSections() -> [TransferSection] {
        SettingsTransfer.exportSections(settings, home: NSHomeDirectory())
    }

    var suggestedExportFileName: String {
        SettingsTransfer.suggestedFileName(exportedBy: githubAccount?.login, now: Date())
    }

    func writeSettingsExport(selected: Set<String>, to url: URL) throws {
        let file = SettingsTransfer.makeFile(settings, selected: selected,
                                             home: NSHomeDirectory(), exportedBy: githubAccount?.login,
                                             appVersion: UpdateCheck.currentVersion(), now: Date())
        try SettingsTransfer.encode(file).write(to: url, options: .atomic)
        Log.info("설정 내보내기 \(selected.count)개 항목 → \(url.lastPathComponent)", "settings")
    }

    func importSections(for file: SettingsTransferFile) -> [TransferSection] {
        SettingsTransfer.importSections(file.settings, current: settings,
                                        environment: importEnvironment(for: file.settings))
    }

    /// 받은 값이 이 맥에서 쓸 수 있는지 미리 재 둔다. 글꼴은 파일에 적힌 것만 보면 되니
    /// 여기서 한 번 확인한 결과를 넘긴다(글꼴 확인은 메인 액터에서만 할 수 있다).
    private func importEnvironment(for payload: SettingsTransferPayload) -> SettingsTransfer.ImportEnvironment {
        let home = NSHomeDirectory()
        let fontNames = payload.fonts.map { [$0.code, $0.comment, $0.ui] } ?? []
        let fonts = Set(fontNames.filter { FontTheme.isInstalled($0) })
        return .init(home: home,
                     loggedInHosts: githubHosts.map(\.name),
                     fontAvailable: { fonts.contains($0) })
    }

    /// 고른 항목을 내 설정에 들인다.
    ///
    /// 순서: 새 레포가 내 계정으로 보이는지 확인 → 지금 설정을 파일로 남김 → 적용·저장 → (기다리지 않고)
    /// 승인 기준을 다시 읽고 목록을 새로 받는다.
    func applySettingsImport(_ file: SettingsTransferFile, selected requested: Set<String>) async -> SettingsImportReport {
        let payload = file.settings
        var selected = requested
        var unreachable: [String] = []
        var unchecked: [String] = []
        var problems: [String] = []

        // 못 보는 레포를 넣어도 목록이 깨지지는 않는다 — 검색은 그 레포만 건너뛴다(2026-10-01 실측).
        // 대신 고른 레포가 영영 빈 채로 남아 "왜 이 레포 PR 이 안 뜨지" 가 된다. 그래서 넣기 전에 묻는다.
        // 호스트도 같이 가져오면 그 호스트에 묻는다.
        let host = (selected.contains(SettingsTransfer.ID.githubHost) ? payload.githubHost : nil) ?? settings.githubHost
        let client = GitHubClient(ghPath: settings.ghPath, host: host)
        for repo in SettingsTransfer.newRepos(payload, selected: selected, current: settings) {
            do {
                if try await client.repository(repo) == nil {
                    selected.remove(SettingsTransfer.ID.repo(repo.full))
                    unreachable.append(repo.full)
                }
            } catch {
                // 없는 레포·권한 없는 레포는 nil 이 아니라 GraphQL 오류로 온다(2026-10-01 실측:
                // "Could not resolve to a Repository with the name …").
                if error.localizedDescription.contains("Could not resolve to a Repository") {
                    selected.remove(SettingsTransfer.ID.repo(repo.full))
                    unreachable.append(repo.full)
                } else {
                    unchecked.append(repo.full)
                }
            }
        }

        let previous = settings
        let backup = AppPaths.settingsBeforeImportFile
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(previous).write(to: backup, options: .atomic)
        } catch {
            problems.append("가져오기 전 설정을 파일로 남기지 못했습니다: \(error.localizedDescription)")
        }

        let result = SettingsTransfer.apply(payload, selected: selected, to: settings,
                                            environment: importEnvironment(for: payload))
        let applied = result.applied
        settings = result.settings
        await save()
        Log.info("설정 가져오기 \(applied.count)개 바뀜 (보낸 사람 \(file.exportedBy ?? "모름")): \(applied.joined(separator: ", "))",
                 "settings")

        // 뒤처리는 기다리지 않는다. 목록을 새로 받는 데 몇 초 걸리는데, 그동안 결과 화면이 안 뜨면
        // 가져오기가 멈춘 것처럼 보인다. 결과는 이미 정해졌다.
        let reposToReload = result.addedRepos + result.updatedRepos
        let hostChanged = result.hostChanged
        Task {
            if hostChanged {
                await checkGitHub()
                await loadRepoOptions()
            }
            for repo in reposToReload {
                await refreshApprovalThreshold(for: repo)
            }
            await refresh()
        }

        return SettingsImportReport(applied: applied, unreachableRepos: unreachable, uncheckedRepos: unchecked,
                                    problems: problems, previous: previous,
                                    backupFile: FileManager.default.fileExists(atPath: backup.path) ? backup : nil)
    }

    /// 가져오기 직전으로 돌아간다.
    func undoSettingsImport(_ report: SettingsImportReport) async {
        let hostChanged = report.previous.githubHost != settings.githubHost
        settings = report.previous
        await save()
        Log.info("설정 가져오기 되돌림", "settings")
        Task {
            if hostChanged {
                await checkGitHub()
                await loadRepoOptions()
            }
            await refresh()
        }
    }
}
