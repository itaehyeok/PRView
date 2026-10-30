import Foundation
import PRayerCore

/// 리뷰 제외 규칙(설정 › 대상 제외의 "리뷰에서 빼는 파일")을 더하고 지운다. 더하기는 설정의 칸(레포 파일 기준
/// 자동완성 — ExclusionCatalog)과 리뷰 전 확인 창의 "다음부터 묻지 않고 빼기"(다음 버전)가 쓴다. 베타 6 에서 칸을
/// 없앴다가(고르게 하면 귀찮다) 자동완성과 함께 되살렸다(사용자 결정, 2026-10-06).
/// 잠금 파일은 이 규칙과 상관없이 늘 빠진다(`LockFiles`).
///
/// 규칙은 모든 레포의 리뷰에 쓴다. 바꾸면 diff 를 다시 받지 않고도 변경 파일 탭이 바로 다시 나뉜다(parsedDiff(for:)).
/// 이미 만든 리뷰 초안은 그대로다 — 다음 리뷰부터 그 파일을 모델에 보내지 않는다.
extension AppModel {
    /// 더했으면 true. 비었거나 이미 있으면 false.
    @discardableResult
    func addExclusion(_ pattern: String, announce: Bool = false) -> Bool {
        let rule = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty, !settings.excludedPathPatterns.contains(rule) else { return false }
        settings.excludedPathPatterns.append(rule)
        Task { await save() }
        if announce {
            banner = Banner(kind: .info,
                            message: "리뷰 제외에 더했습니다: \(rule) — 다음 리뷰부터 모델에 보내지 않습니다. 설정 › 대상 제외에서 뺄 수 있습니다.",
                            actionTitle: "되돌리기",
                            action: { [weak self] in self?.removeExclusions([rule]) })
        }
        return true
    }

    /// 자동완성 재료를 받는다 — 보는 레포마다 기본 브랜치의 파일 목록과 최근 PR 50개의 바뀐 파일(레포당 2~3초,
    /// 레포끼리는 동시에). 10분 안에 다시 열면 받아 둔 것을 쓴다. 일부 레포를 못 받아도 받은 만큼으로 띄운다.
    func loadExclusionCatalog(force: Bool = false) async {
        guard !DemoMode.isOn else { return }
        if exclusionCatalogState == .loading { return }
        if !force, case .loaded(let at, _, _) = exclusionCatalogState, Date().timeIntervalSince(at) < 600 { return }
        let repos = settings.enabledRepos.map(\.repo)
        guard !repos.isEmpty else {
            exclusionCatalog = nil
            exclusionCatalogState = .idle
            return
        }
        exclusionCatalogState = .loading
        let github = github
        let results = await withTaskGroup(of: (paths: [String], prs: [[ExclusionCatalog.PRFile]])?.self) { group in
            for repo in repos {
                group.addTask {
                    async let tree = try? github.repositoryFilePaths(repo)
                    async let prs = try? github.recentPullRequestFiles(repo)
                    let (paths, files) = await (tree, prs)
                    guard paths != nil || files != nil else { return nil }
                    return (paths?.paths ?? [], files ?? [])
                }
            }
            var collected: [(paths: [String], prs: [[ExclusionCatalog.PRFile]])?] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let succeeded = results.compactMap { $0 }
        guard !succeeded.isEmpty else {
            exclusionCatalogState = .failed("레포 파일 목록을 받지 못했습니다 — 규칙은 그대로 적을 수 있습니다.")
            Log.info("제외 자동완성 재료를 못 받음(레포 \(repos.count)개)", "exclusion")
            return
        }
        let paths = succeeded.flatMap(\.paths)
        let prs = succeeded.flatMap(\.prs)
        // 후보를 세는 데 수만 개 경로를 훑는다. 메인 스레드 밖에서 만든다.
        exclusionCatalog = await Task.detached { ExclusionCatalog(paths: paths, pullRequests: prs) }.value
        exclusionCatalogState = .loaded(at: Date(), repos: repos.count, failed: repos.count - succeeded.count)
        Log.info("제외 자동완성 재료: 파일 \(paths.count)개 · PR \(prs.count)개(레포 \(repos.count)개)", "exclusion")
    }

    func removeExclusions(_ rules: [String]) {
        let before = settings.excludedPathPatterns
        settings.excludedPathPatterns.removeAll { rules.contains($0) }
        guard settings.excludedPathPatterns != before else { return }
        Task { await save() }
    }
}
