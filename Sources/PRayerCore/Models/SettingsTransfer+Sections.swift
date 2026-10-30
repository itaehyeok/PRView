import Foundation

// 화면에 그릴 묶음·설명과, 받은 값의 검사. 무엇을 담고 어떻게 합치는지는 SettingsTransfer.swift.

extension SettingsTransfer {
    // MARK: - 설명 문구

    /// 묶음 설명. 설정 창의 어느 탭에 있는 값인지 같이 적는다 — 가져온 뒤 고치러 갈 자리다.
    enum Summary {
        static let repos = "어느 레포의 PR 을 볼지와 레포마다 정한 규칙입니다. 설정 → ‘레포·팀 규칙’ 탭의 값입니다."
        static let hiding = "'To review' 목록에서 뺄 PR 의 조건입니다. PR 목록 위 필터 메뉴의 ‘특정 라벨 숨기기’·‘특정 사람의 PR 숨기기’에서 고치는 값입니다."
        static let members = "PR 목록에서 팀원의 GitHub 아이디를 짧게 보여 주는 규칙입니다. ‘레포·팀 규칙’ 탭 아래쪽의 값입니다."
        static let review = "Claude 로 리뷰를 돌리는 방식과 초안의 모양입니다. ‘리뷰’ 탭의 값입니다."
        static let scope = "리뷰에서 뺄 파일과 PR 크기 기준입니다. ‘대상 제외’ 탭의 값입니다."
        static let notifications = "어떤 일에 알림을 받을지와 PR 목록을 다시 받는 주기입니다. 사람마다 취향이 달라 가져올 때 기본으로는 고르지 않습니다. ‘알림·기타’ 탭의 값입니다."
        static let appearance = "코드·코멘트·화면 글자의 글꼴과 크기입니다. 취향이라 가져올 때 기본으로는 고르지 않습니다."
    }

    /// 항목 설명 — 무엇을 하는 설정이고, 가져오면 내 값이 어떻게 되는지.
    enum Detail {
        static let repos = "PR 목록에 띄울 레포입니다. 레포마다 머지에 필요한 Approve 수와 그 수를 읽어 올 브랜치가 함께 옵니다. 내 목록에 없는 레포는 더하고, 이미 있는 레포는 그 두 가지만 바꿉니다. 내 목록에서 빠지는 레포는 없습니다."
        static let githubHost = "앱이 PR 을 물어볼 GitHub 주소입니다(github.com, 또는 회사 GitHub Enterprise 주소). gh 가 그 호스트에 로그인돼 있어야 합니다. 바꿀 일이 드물어 가져올 때 기본으로는 고르지 않습니다."
        static let hiddenLabels = "이 라벨이 붙은 PR 은 'To review' 에서 빠집니다(대소문자는 가리지 않습니다). 가져오면 내 목록에 없는 라벨만 더하고, 있던 라벨은 그대로 둡니다."
        static let ignoredAuthors = "이 사람이 올린 PR 은 'To review' 에서 빠집니다. 각자 사정으로 정하는 값이라 내보낼 때도 가져올 때도 기본으로는 고르지 않습니다. 가져오면 내 목록에 없는 사람만 더합니다."
        static let abbreviateMemberNames = "아이디를 첫 하이픈 앞까지만 보여 줍니다(riley-park-acme → riley)."
        static let memberNicknames = "기본 규칙이 맞지 않는 사람에게 직접 붙인 이름입니다. 같은 사람은 받은 이름으로 바꾸고, 내가 붙여 둔 다른 사람의 이름은 그대로 둡니다."
        static let reviewModel = "리뷰에 쓰는 Claude 모델과 effort(생각하는 깊이)입니다 — diff 리뷰와 전체 리뷰가 같이 씁니다. effort 가 높을수록 꼼꼼하지만 시간과 토큰을 더 씁니다."
        static let excludedPathPatterns = "리뷰와 크기 계산에서 빼는 자동 생성 파일의 패턴입니다(*.pbxproj 같은). 가져오면 내 목록에 없는 패턴만 더합니다."
        static let sizeLimits = "변경 줄 수가 앞의 값을 넘으면 목록에 ‘큼’ 표시를 붙이고, 뒤의 값을 넘으면 리뷰를 돌리기 전에 한 번 더 묻습니다."
        static let fiveHourTokenCap = "자동으로 도는 리뷰가 5시간 동안 쓸 수 있는 토큰 상한입니다. 쓰는 요금제에 따라 맞는 값이 달라 가져올 때 기본으로는 고르지 않습니다."
        static let reviewNotifications = "내가 돌린 AI 리뷰가 끝났을 때, 그리고 실패하거나 사용 한도에 걸렸을 때 알림을 띄울지입니다."
        static let prChangeNotifications = "새 PR·리뷰어 지정 같은 리뷰할 PR 의 변화와, 내 PR 의 새 코멘트·머지 가능·충돌·CI 실패 같은 변화 중 무엇을 알릴지입니다."
        static let pollSeconds = "PR 목록을 몇 초마다 다시 받을지입니다."
        static let fonts = "diff 와 코드 블록, 코멘트 본문, 나머지 화면 글자에 쓰는 글꼴과 크기입니다."
    }

    enum Note {
        static let reposImport = "가져올 때 내 계정으로 볼 수 있는 레포인지 확인하고, 볼 수 없는 레포는 넣지 않습니다. Approve 수는 GitHub 에서 다시 읽습니다."
        static let hostNotLoggedIn = "이 맥의 gh 는 이 호스트에 로그인돼 있지 않습니다. 가져와도 로그인된 호스트로 되돌아갑니다."
    }

    // MARK: - 묶음 만들기

    /// 내보내기(`current == nil`)와 가져오기 화면이 같은 목록을 쓴다. 가져오기에서는 지금 값과 견준다.
    static func sections(_ p: SettingsTransferPayload, current: Settings?,
                         environment env: ImportEnvironment?) -> [TransferSection] {
        let exporting = current == nil

        func status(same: Bool, added: Bool = false) -> TransferItem.Status {
            if exporting { return .export }
            if same { return .same }
            return added ? .added : .changed
        }
        func item(_ id: String, _ detail: String, value: String, current: String?, status: TransferItem.Status,
                  note: String? = nil,
                  importDefault: Bool = true, exportDefault: Bool = true) -> TransferItem {
            let selected: Bool
            switch status {
            case .export: selected = exportDefault
            case .same: selected = false
            case .added, .changed: selected = importDefault
            }
            return TransferItem(id: id, title: title(forKey: id), detail: detail, value: value, current: current,
                                status: status, note: note, selectedByDefault: selected,
                                children: [])
        }
        func leaf(_ id: String, title: String, value: String, current: String?, status: TransferItem.Status,
                  note: String? = nil, selected: Bool) -> TransferItem {
            TransferItem(id: id, title: title, detail: "", value: value, current: current, status: status,
                         note: note, selectedByDefault: status != .same && selected, children: [])
        }
        func group(_ id: String, _ detail: String, note: String?, children: [TransferItem]) -> TransferItem {
            let value: String
            if exporting {
                value = "\(children.count)개"
            } else {
                let added = children.filter { $0.status == .added }.count
                let changed = children.filter { $0.status == .changed }.count
                let same = children.filter { $0.status == .same }.count
                value = [added > 0 ? "새로 \(added)" : nil,
                         changed > 0 ? "바뀜 \(changed)" : nil,
                         same > 0 ? "같음 \(same)" : nil].compactMap { $0 }.joined(separator: " · ")
            }
            let state: TransferItem.Status = exporting
                ? .export
                : (children.allSatisfy { $0.status == .same } ? .same : .changed)
            return TransferItem(id: id, title: title(forKey: id), detail: detail, value: value, current: nil,
                                status: state, note: note, selectedByDefault: false, children: children)
        }

        var sections: [TransferSection] = []
        func add(_ id: String, _ title: String, _ summary: String, _ items: [TransferItem]) {
            guard !items.isEmpty else { return }
            sections.append(TransferSection(id: id, title: title, summary: summary, items: items))
        }

        // 레포
        var repoItems: [TransferItem] = []
        if let repos = p.repos, !repos.isEmpty {
            let children = repos.map { repo -> TransferItem in
                let mine = current?.repos.first { sameRepo($0.repo.full, repo.repo) }
                // 내가 꺼 둔 레포는 "같음" 이 아니다 — 가져오면 켠다. 같음으로 두면 잠겨서 켤 수가 없다.
                let same = mine.map {
                    $0.enabled
                        && $0.prTargetBranch == repo.prTargetBranch
                        && (repo.approvalThresholdFromGitHub || $0.approvalThreshold == repo.approvalThreshold)
                } ?? false
                return leaf(ID.repo(repo.repo), title: repo.repo,
                            value: Describe.repo(branch: repo.prTargetBranch, threshold: repo.approvalThreshold,
                                                 fromGitHub: repo.approvalThresholdFromGitHub),
                            current: mine.map {
                                Describe.repo(branch: $0.prTargetBranch, threshold: $0.approvalThreshold,
                                              fromGitHub: $0.approvalThresholdFromAPI)
                                    + ($0.enabled ? "" : " · 꺼 둠")
                            },
                            status: status(same: same, added: mine == nil), selected: true)
            }
            repoItems.append(group(ID.repos, Detail.repos, note: exporting ? nil : Note.reposImport, children: children))
        }
        if let host = p.githubHost {
            let mine = current?.githubHost
            let same = mine.map { $0.caseInsensitiveCompare(host) == .orderedSame } ?? false
            var note: String?
            if !same, let env, !env.loggedInHosts.isEmpty,
               !env.loggedInHosts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
                note = Note.hostNotLoggedIn
            }
            repoItems.append(item(ID.githubHost, Detail.githubHost, value: host, current: mine,
                                  status: status(same: same), note: note, importDefault: false))
        }
        add("repos", "레포", Summary.repos, repoItems)

        // 목록에서 숨기기
        func listItem(_ id: String, _ detail: String, _ values: [String], mine: [String]?, caseInsensitive: Bool,
                      addedLabel: String, importDefault: Bool = true, exportDefault: Bool = true) -> TransferItem {
            guard let mine else {
                return item(id, detail, value: Describe.list(values), current: nil, status: .export,
                            exportDefault: exportDefault)
            }
            let added = additions(values, to: mine, caseInsensitive: caseInsensitive)
            return item(id, detail,
                        value: added.isEmpty ? Describe.list(values) : "\(addedLabel): \(Describe.list(added))",
                        current: Describe.list(mine), status: status(same: added.isEmpty, added: true),
                        importDefault: importDefault)
        }
        var hidingItems: [TransferItem] = []
        if let labels = p.hiddenLabels {
            hidingItems.append(listItem(ID.hiddenLabels, Detail.hiddenLabels, labels, mine: current?.hiddenLabels,
                                        caseInsensitive: true, addedLabel: "더할 라벨"))
        }
        if let authors = p.ignoredAuthors {
            hidingItems.append(listItem(ID.ignoredAuthors, Detail.ignoredAuthors, authors, mine: current?.ignoredAuthors,
                                        caseInsensitive: true, addedLabel: "더할 사람",
                                        importDefault: false, exportDefault: false))
        }
        add("hiding", "목록에서 숨기기", Summary.hiding, hidingItems)

        // 팀원 이름
        var memberItems: [TransferItem] = []
        if let value = p.abbreviateMemberNames {
            memberItems.append(item(ID.abbreviateMemberNames, Detail.abbreviateMemberNames,
                                    value: Describe.onOff(value), current: current.map { Describe.onOff($0.abbreviateMemberNames) },
                                    status: status(same: current?.abbreviateMemberNames == value)))
        }
        if let names = p.memberNicknames, !names.isEmpty {
            if let current {
                let changed = names.filter { current.memberNicknames[$0.key] != $0.value }
                memberItems.append(item(ID.memberNicknames, Detail.memberNicknames,
                                        value: Describe.nicknames(changed.isEmpty ? names : changed),
                                        current: current.memberNicknames.isEmpty
                                            ? "없음" : "직접 붙인 이름 \(current.memberNicknames.count)명",
                                        status: status(same: changed.isEmpty,
                                                       added: changed.keys.allSatisfy { current.memberNicknames[$0] == nil })))
            } else {
                memberItems.append(item(ID.memberNicknames, Detail.memberNicknames, value: Describe.nicknames(names),
                                        current: nil, status: .export))
            }
        }
        add("members", "팀원 이름", Summary.members, memberItems)

        // 리뷰
        var reviewItems: [TransferItem] = []
        if let m = p.reviewModel {
            let mine = current.map { SettingsTransferPayload.ReviewModel(model: $0.model, effort: $0.effort) }
            reviewItems.append(item(ID.reviewModel, Detail.reviewModel, value: Describe.model(m.model, m.effort),
                                    current: mine.map { Describe.model($0.model, $0.effort) },
                                    status: status(same: mine == m)))
        }
        add("review", "리뷰", Summary.review, reviewItems)

        // 대상·크기
        var scopeItems: [TransferItem] = []
        if let patterns = p.excludedPathPatterns {
            scopeItems.append(listItem(ID.excludedPathPatterns, Detail.excludedPathPatterns, patterns,
                                       mine: current?.excludedPathPatterns, caseInsensitive: false,
                                       addedLabel: "더할 패턴"))
        }
        if let l = p.sizeLimits {
            let mine = current.map {
                SettingsTransferPayload.SizeLimits(largeLines: $0.autoSizeCapLines, warnLines: $0.manualSizeWarnLines)
            }
            scopeItems.append(item(ID.sizeLimits, Detail.sizeLimits, value: Describe.sizeLimits(l),
                                   current: mine.map(Describe.sizeLimits), status: status(same: mine == l)))
        }
        if let cap = p.fiveHourTokenCap {
            scopeItems.append(item(ID.fiveHourTokenCap, Detail.fiveHourTokenCap, value: Describe.tokens(cap),
                                   current: current.map { Describe.tokens($0.fiveHourTokenCap) },
                                   status: status(same: current?.fiveHourTokenCap == cap), importDefault: false))
        }
        add("scope", "대상·크기", Summary.scope, scopeItems)

        // 알림·갱신
        var notificationItems: [TransferItem] = []
        if let n = p.reviewNotifications {
            let mine = current.map {
                SettingsTransferPayload.ReviewNotifications(done: $0.notifyOnReviewDone, failure: $0.notifyOnFailure)
            }
            notificationItems.append(item(ID.reviewNotifications, Detail.reviewNotifications,
                                          value: Describe.reviewNotifications(n),
                                          current: mine.map(Describe.reviewNotifications),
                                          status: status(same: mine == n), importDefault: false))
        }
        if let prefs = p.prChangeNotifications {
            notificationItems.append(item(ID.prChangeNotifications, Detail.prChangeNotifications,
                                          value: Describe.prChanges(prefs),
                                          current: current.map { Describe.prChanges($0.prChangeNotifications) },
                                          status: status(same: current?.prChangeNotifications == prefs),
                                          importDefault: false))
        }
        if let poll = p.pollSeconds {
            notificationItems.append(item(ID.pollSeconds, Detail.pollSeconds, value: "\(poll)초마다",
                                          current: current.map { "\($0.pollSeconds)초마다" },
                                          status: status(same: current?.pollSeconds == poll), importDefault: false))
        }
        add("notifications", "알림·갱신", Summary.notifications, notificationItems)

        // 글꼴
        if let f = p.fonts {
            let mine = current.map(fonts(of:))
            let missing = env.map { env in
                [f.code, f.comment, f.ui].filter { !$0.isEmpty && !env.fontAvailable($0) }
            } ?? []
            let note = missing.isEmpty
                ? nil
                : "이 맥에 없는 글꼴: \(Describe.list(Array(Set(missing)).sorted())) — 가져오면 그 자리는 시스템 글꼴로 보입니다."
            add("appearance", "글꼴", Summary.appearance, [
                item(ID.fonts, Detail.fonts, value: Describe.fonts(f), current: mine.map(Describe.fonts),
                     status: status(same: mine == f), note: mine == f ? nil : note, importDefault: false)
            ])
        }

        return sections
    }

    // MARK: - 받은 값 검사

    /// 화면에서 고를 수 있는 범위. 설정 창의 Stepper·글자 크기 조절과 같은 값이다.
    enum Limit {
        static let repos = 200
        static let listItems = 500
        static let nicknames = 1000
        static let approvals = 0...20
        static let largeLines = 100...5000
        static let warnLines = 200...10_000
        static let tokenCap = 50_000...2_000_000
        static let pollSeconds = 30...600
        static let codeFontSize = 9.0...20.0
        static let textFontSize = 11.0...22.0
    }

    static func sanitized(_ p: SettingsTransferPayload, skipped: inout [String]) -> SettingsTransferPayload {
        var out = SettingsTransferPayload()
        func skip(_ id: String, _ reason: String) { skipped.append("\(title(forKey: id)) — \(reason)") }
        func clamp(_ value: Int, _ range: ClosedRange<Int>, _ id: String, unit: String) -> Int {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != value {
                // 숫자 뒤 조사(은/는, 로/으로)는 읽는 소리에 따라 갈려서 화살표로 쓴다.
                skip(id, "고를 수 있는 범위 밖이라 맞춥니다: \(value)\(unit) → \(clamped)\(unit) (범위 \(range.lowerBound)~\(range.upperBound)\(unit))")
            }
            return clamped
        }
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }

        if let host = p.githubHost {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Check.host(trimmed) {
                out.githubHost = trimmed
            } else {
                skip(ID.githubHost, "호스트 이름이 아닙니다: \(Check.excerpt(host))")
            }
        }

        if let repos = p.repos {
            var seen = Set<String>()
            var kept: [SettingsTransferPayload.Repo] = []
            for repo in repos.prefix(Limit.repos) {
                let name = repo.repo.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = Check.repoID(name) else {
                    skip(ID.repos, "owner/name 꼴이 아닙니다: \(Check.excerpt(repo.repo))")
                    continue
                }
                guard seen.insert(id.full.lowercased()).inserted else { continue }
                let branch = repo.prTargetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Check.branch(branch) else {
                    skip(ID.repos, "\(id.full) 의 대상 브랜치 이름이 올바르지 않습니다")
                    continue
                }
                kept.append(.init(repo: id.full, prTargetBranch: branch,
                                  approvalThreshold: clamp(repo.approvalThreshold, Limit.approvals, ID.repos, unit: "명"),
                                  approvalThresholdFromGitHub: repo.approvalThresholdFromGitHub))
            }
            if repos.count > Limit.repos {
                skip(ID.repos, "\(Limit.repos)개가 넘어 뒤의 \(repos.count - Limit.repos)개는 건너뜁니다")
            }
            if !kept.isEmpty { out.repos = kept }
        }

        // 로컬 클론 경로(clonePaths)는 들이지 않는다 — 예전 파일에 있어도 건너뛴다(SettingsTransferPayload.clonePaths 주석).

        func list(_ values: [String]?, _ id: String, valid: (String) -> Bool, caseInsensitive: Bool) -> [String]? {
            guard let values else { return nil }
            let trimmed = values.prefix(Limit.listItems).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let good = trimmed.filter(valid)
            if good.count < trimmed.count { skip(id, "꼴이 틀린 값 \(trimmed.count - good.count)개") }
            if values.count > Limit.listItems {
                skip(id, "\(Limit.listItems)개가 넘어 뒤의 \(values.count - Limit.listItems)개는 건너뜁니다")
            }
            let unique = additions(good, to: [], caseInsensitive: caseInsensitive)
            return unique.isEmpty ? nil : unique
        }
        out.hiddenLabels = list(p.hiddenLabels, ID.hiddenLabels, valid: Check.label, caseInsensitive: true)
        out.ignoredAuthors = list(p.ignoredAuthors, ID.ignoredAuthors, valid: Check.login, caseInsensitive: true)
        out.excludedPathPatterns = list(p.excludedPathPatterns, ID.excludedPathPatterns, valid: Check.pattern,
                                        caseInsensitive: false)

        out.abbreviateMemberNames = p.abbreviateMemberNames
        if let names = p.memberNicknames {
            var kept: [String: String] = [:]
            var bad = 0
            for (login, name) in names.sorted(by: { $0.key < $1.key }).prefix(Limit.nicknames) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if Check.login(login), Check.nickname(trimmed) {
                    kept[login] = trimmed
                } else {
                    bad += 1
                }
            }
            if bad > 0 { skip(ID.memberNicknames, "꼴이 틀린 이름 \(bad)개") }
            if !kept.isEmpty { out.memberNicknames = kept }
        }

        if let m = p.reviewModel {
            if Check.model(m.model), Check.effort(m.effort) {
                out.reviewModel = m
            } else {
                skip(ID.reviewModel, "모델 이름이나 effort 값이 올바르지 않습니다")
            }
        }
        if let l = p.sizeLimits {
            out.sizeLimits = .init(largeLines: clamp(l.largeLines, Limit.largeLines, ID.sizeLimits, unit: "줄"),
                                   warnLines: clamp(l.warnLines, Limit.warnLines, ID.sizeLimits, unit: "줄"))
        }
        if let cap = p.fiveHourTokenCap {
            out.fiveHourTokenCap = clamp(cap, Limit.tokenCap, ID.fiveHourTokenCap, unit: "")
        }
        out.reviewNotifications = p.reviewNotifications
        out.prChangeNotifications = p.prChangeNotifications
        if let poll = p.pollSeconds {
            out.pollSeconds = clamp(poll, Limit.pollSeconds, ID.pollSeconds, unit: "초")
        }
        if let f = p.fonts {
            if [f.code, f.comment, f.ui].allSatisfy(Check.fontName) {
                out.fonts = .init(code: f.code, codeSize: clamp(f.codeSize, Limit.codeFontSize),
                                  comment: f.comment, commentSize: clamp(f.commentSize, Limit.textFontSize),
                                  ui: f.ui, uiSize: clamp(f.uiSize, Limit.textFontSize))
            } else {
                skip(ID.fonts, "글꼴 이름이 올바르지 않습니다")
            }
        }
        return out
    }
}

/// 받은 값의 꼴 검사. 남이 만든 파일이라 화면이 다룰 수 있는 꼴인지만 본다(gh·claude 에 그대로 넘기는 값도 있다).
enum Check {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// 줄바꿈·NUL 같은 제어 문자. 이모지를 잇는 글자(ZWJ)는 제어 문자가 아니라 막지 않는다.
    static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func host(_ value: String) -> Bool {
        value.count <= 253 && value.contains(".") && matches(value, #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#)
    }

    static func repoPart(_ value: String) -> Bool {
        value.count <= 100 && value != "." && value != ".." && matches(value, #"^[A-Za-z0-9_.-]+$"#)
    }

    static func repoID(_ full: String) -> RepoID? {
        guard let id = RepoID(full: full), repoPart(id.owner), repoPart(id.name),
              full.split(separator: "/", omittingEmptySubsequences: false).count == 2 else { return nil }
        return id
    }

    static func branch(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && !value.hasPrefix("-") && !hasControl(value)
            && !value.contains(where: \.isWhitespace)
    }

    /// GitHub 로그인. 봇(`name[bot]`)과 엔터프라이즈 계정(`name_corp`)도 받는다.
    static func login(_ value: String) -> Bool {
        value.count <= 60 && matches(value, #"^[A-Za-z0-9][A-Za-z0-9_.\[\]-]*$"#)
    }

    static func label(_ value: String) -> Bool { !value.isEmpty && value.count <= 100 && !hasControl(value) }
    static func pattern(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 && !hasControl(value) }
    static func nickname(_ value: String) -> Bool { !value.isEmpty && value.count <= 40 && !hasControl(value) }
    /// `claude --model` 에 그대로 넘긴다. 별칭(`opus`)·전체 이름·`[1m]` 꼴까지.
    static func model(_ value: String) -> Bool { matches(value, #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,79}$"#) }
    static func effort(_ value: String) -> Bool { value.isEmpty || EffortLevel.argument(for: value) == value }
    static func fontName(_ value: String) -> Bool { value.count <= 100 && !hasControl(value) }

    static func path(_ value: String) -> Bool {
        (value.hasPrefix("/") || value == "~" || value.hasPrefix("~/")) && value.count <= 1024 && !hasControl(value)
    }

    static func version(_ value: String) -> Bool {
        value.count <= 40 && matches(value, #"^\d+\.\d+\.\d+([.-][0-9A-Za-z.-]+)?$"#)
    }

    static func excerpt(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }
}

/// 값을 화면에 한 줄로.
enum Describe {
    static func list(_ values: [String], limit: Int = 8) -> String {
        guard !values.isEmpty else { return "없음" }
        let head = values.prefix(limit).joined(separator: ", ")
        return values.count > limit ? "\(head) 외 \(values.count - limit)개" : head
    }

    static func onOff(_ value: Bool) -> String { value ? "켬" : "끔" }

    static func effort(_ value: String) -> String { value.isEmpty ? "effort 기본값" : "effort \(value)" }

    static func model(_ model: String, _ effort: String) -> String { "\(model) · \(Self.effort(effort))" }

    static func repo(branch: String, threshold: Int, fromGitHub: Bool) -> String {
        "Approve \(threshold)명 필요 · \(branch) 기준" + (fromGitHub ? "" : " (직접 정한 값)")
    }


    static func sizeLimits(_ l: SettingsTransferPayload.SizeLimits) -> String {
        "‘큼’ \(l.largeLines)줄 · 경고 \(l.warnLines)줄"
    }

    static func tokens(_ count: Int) -> String { "\(count / 1000)k" }

    static func reviewNotifications(_ n: SettingsTransferPayload.ReviewNotifications) -> String {
        "완료 \(onOff(n.done)) · 실패·한도 \(onOff(n.failure))"
    }

    /// 이름은 설정 화면의 스위치·알림에 뜨는 말과 같게. '머지 가능' 처럼 혼자 두면 누구 PR 인지 모를 것만 "내 PR" 을 붙인다.
    static func prChanges(_ p: PRChangeNotificationPrefs) -> String {
        var on: [String] = []
        if p.newPR { on.append(p.newPROnlyWhenReviewRequested ? "새 PR(나에게 요청 온 것만)" : "새 PR") }
        if p.reviewRequested { on.append("리뷰어 지정") }
        if p.reReviewRequested { on.append("재리뷰 요청") }
        if p.newCommitsOnReviewed { on.append("리뷰한 PR 새 커밋") }
        if p.commentsOnMyPR { on.append("내 PR 새 코멘트") }
        if p.approvalsReached { on.append("내 PR 머지 가능") }
        if p.conflict { on.append("내 PR 충돌") }
        if p.checksFailed { on.append("내 PR CI 실패") }
        if p.merged { on.append("내 PR 머지 완료") }
        return on.isEmpty ? "모두 끔" : "켬: " + list(on, limit: 10)
    }

    static func nicknames(_ names: [String: String], limit: Int = 4) -> String {
        let sorted = names.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let head = sorted.prefix(limit).map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
        return sorted.count > limit ? "\(head) 외 \(sorted.count - limit)명" : head
    }

    static func fonts(_ f: SettingsTransferPayload.Fonts) -> String {
        func one(_ name: String, _ size: Double) -> String {
            let point = size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
            return "\(name.isEmpty ? "시스템" : name) \(point)pt"
        }
        return "코드 \(one(f.code, f.codeSize)) · 코멘트 \(one(f.comment, f.commentSize)) · 화면 \(one(f.ui, f.uiSize))"
    }
}
