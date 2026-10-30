import XCTest
@testable import PRayerCore

final class AuthorQuestionDecodingTests: XCTestCase {
    func testDecodesLegacyStringForm() throws {
        let json = Data(#"["예전 기록의 질문"]"#.utf8)
        let questions = try JSONDecoder().decode([AuthorQuestion].self, from: json)
        XCTAssertEqual(questions.first?.question, "예전 기록의 질문")
        XCTAssertNil(questions.first?.rationaleKo)
    }

    func testDecodesObjectFormWithRationaleAndEvidence() throws {
        let json = Data("""
        [{"question": "왜?", "rationale_ko": "이래서요",
          "evidence": [{"path": "A/B.swift", "line": 12, "note": "여기서 취소한다"}]}]
        """.utf8)
        let questions = try JSONDecoder().decode([AuthorQuestion].self, from: json)
        XCTAssertEqual(questions.first?.rationaleKo, "이래서요")
        XCTAssertEqual(questions.first?.evidence?.first?.line, 12)
        XCTAssertEqual(questions.first?.evidence?.first?.fileName, "B.swift")
    }

    func testDraftCommentCarriesRationale() throws {
        let json = Data("""
        {"issue_key": "k", "path": "A.swift", "line": 3, "side": "RIGHT",
         "body": "본문입니다 본문입니다 본문입니다", "severity": "major", "anchor_text": "x",
         "rationale_ko": "왜냐하면", "evidence": [{"path": "A.swift", "note": "여기"}]}
        """.utf8)
        let comment = try JSONDecoder().decode(DraftComment.self, from: json)
        XCTAssertEqual(comment.rationaleKo, "왜냐하면")
        XCTAssertNil(comment.evidence?.first?.line)
    }
}

final class SwiftSyntaxTests: XCTestCase {
    private func kinds(_ source: String) -> [(String, SyntaxKind)] {
        let characters = Array(source)
        return SwiftSyntax.spans(in: source).map {
            (String(characters[$0.start..<($0.start + $0.length)]), $0.kind)
        }
    }

    func testKeywordsTypesAndStrings() {
        let result = kinds(#"let name: String = "hi""#)
        XCTAssertEqual(result[0].0, "let")
        XCTAssertEqual(result[0].1, .keyword)
        XCTAssertTrue(result.contains { $0.0 == "String" && $0.1 == .type })
        XCTAssertTrue(result.contains { $0.0 == "\"hi\"" && $0.1 == .string })
    }

    func testLineAndBlockComments() {
        XCTAssertTrue(kinds("// 설명\nlet x = 1").contains { $0.0 == "// 설명" && $0.1 == .comment })
        let nested = kinds("/* a /* b */ c */ let")
        XCTAssertEqual(nested.first?.1, .comment)
        XCTAssertEqual(nested.first?.0, "/* a /* b */ c */")
    }

    func testAttributeAndNumber() {
        XCTAssertTrue(kinds("@MainActor func f() { let n = 42 }").contains { $0.0 == "@MainActor" && $0.1 == .attribute })
        XCTAssertTrue(kinds("let n = 42").contains { $0.0 == "42" && $0.1 == .number })
    }

    func testUnterminatedStringStopsAtLineEnd() {
        let result = kinds("let s = \"oops\nlet t = 1")
        XCTAssertEqual(result.first(where: { $0.1 == .string })?.0, "\"oops")
        // 다음 줄이 문자열에 삼켜지지 않아야 한다.
        XCTAssertTrue(result.contains { $0.0 == "let" && $0.1 == .keyword })
    }

    func testLanguageTagDetection() {
        XCTAssertTrue(SwiftSyntax.isSwift("swift"))
        XCTAssertTrue(SwiftSyntax.isSwift(" Swift "))
        XCTAssertFalse(SwiftSyntax.isSwift("objc"))
        XCTAssertFalse(SwiftSyntax.isSwift(nil))
    }

    /// `Character.isNumber` 가 참인데 16진 숫자가 아닌 글자(①·½·²·三·Ⅷ·٣)에서 스캐너가 멈추지 않아야 한다.
    /// 실측: 마크다운 줄 "응답 순서(① → ⑤)" 를 그리다 앱이 멈췄다. 이 테스트가 멈추면 그 버그가 돌아온 것이다.
    func testNonASCIINumeralsDoNotStallTheScanner() {
        for numeral in ["①", "½", "²", "三", "Ⅷ", "٣"] {
            let source = "- [ ] 응답 순서(\(numeral) → 2)를 지킨다 let n = 42"
            for profile in [CodeSyntax.swift, CodeSyntax.cLike, CodeSyntax.script, CodeSyntax.json, CodeSyntax.markup] {
                let spans = CodeSyntax.spans(in: source, profile: profile)
                XCTAssertFalse(spans.contains { $0.length == 0 }, "\(numeral) · \(profile.id): 빈 구간이 생기면 스캐너가 제자리를 돈 것이다")
                XCTAssertLessThan(spans.count, source.count)
            }
        }
        // ASCII 숫자는 그대로 숫자로 칠한다.
        XCTAssertTrue(kinds("let n = 42").contains { $0.0 == "42" && $0.1 == .number })
    }

    func testSpansStayInBounds() {
        let source = "@objc class A { /* 안 닫힌 주석 let x = \"열린 문자열"
        for span in SwiftSyntax.spans(in: source) {
            XCTAssertGreaterThanOrEqual(span.start, 0)
            XCTAssertLessThanOrEqual(span.start + span.length, source.count)
        }
    }
}

final class FileTreeFlattenTests: XCTestCase {
    private func file(_ path: String) -> DiffFile {
        DiffFile(path: path, oldPath: nil, isBinary: false, isNew: false, isDeleted: false,
                 lines: [], additions: 1, deletions: 0)
    }

    func testFlattenFollowsExpandedFoldersOnly() {
        let tree = FileTreeBuilder.build(files: [file("A/B/c.swift"), file("A/d.swift")])
        let collapsed = FileTreeBuilder.flatten(tree, expanded: [])
        XCTAssertEqual(collapsed.map(\.node.name), ["A"])

        let all = FileTreeBuilder.allDirectoryIDs(tree)
        let expandedRows = FileTreeBuilder.flatten(tree, expanded: all)
        XCTAssertEqual(expandedRows.map(\.node.name), ["A", "B", "c.swift", "d.swift"])
        XCTAssertEqual(expandedRows.map(\.depth), [0, 1, 2, 1])
        // 파일 행은 선택 키로 전체 경로를 쓴다.
        XCTAssertEqual(expandedRows.last?.node.id, "A/d.swift")
    }

    /// 폴더 하나만 든 폴더는 한 줄로 합친다 — 갈라지는 곳까지만.
    func testSingleFolderChainsCollapseIntoOneRow() {
        let tree = FileTreeBuilder.build(files: [file("App/Sources/Login/a.swift"), file("App/Sources/Login/b.swift"),
                                                 file("App/Tests/Unit/c.swift")])
        let rows = FileTreeBuilder.flatten(tree, expanded: FileTreeBuilder.allDirectoryIDs(tree))
        XCTAssertEqual(rows.map(\.node.name), ["App", "Sources/Login", "a.swift", "b.swift", "Tests/Unit", "c.swift"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 1, 2])
        XCTAssertEqual(rows[1].node.id, "App/Sources/Login", "합친 줄은 가장 깊은 폴더의 경로로 펼친다")
        XCTAssertEqual(rows[1].node.additions, 2)

        let single = FileTreeBuilder.build(files: [file("App/Sources/Login/a.swift")])
        XCTAssertEqual(FileTreeBuilder.flatten(single, expanded: FileTreeBuilder.allDirectoryIDs(single)).map(\.node.name),
                       ["App/Sources/Login", "a.swift"])
    }
}

final class TokenLedgerTests: XCTestCase {
    func testLedgerSeparatesAuxiliaryCallsFromReview() {
        let now = Date()
        var ledger = TokenLedger()
        ledger.add(LedgerEntry(date: now, repo: "o/r", number: 1, tokens: 20_000, costUSD: 0.2, model: "s"))
        ledger.add(LedgerEntry(date: now, repo: "o/r", number: 2, tokens: 3_000, costUSD: 0.02,
                               model: "s", kind: .explain))
        XCTAssertEqual(ledger.tokens(inLast: TokenLedger.fiveHours, now: now), 23_000)
        XCTAssertEqual(ledger.tokens(ofKind: .explain, inLast: TokenLedger.fiveHours, now: now), 3_000)
        XCTAssertEqual(ledger.tokens(ofKind: .review, inLast: TokenLedger.fiveHours, now: now), 20_000)
    }

    func testLegacyLedgerEntriesCountAsReview() throws {
        let json = Data("""
        {"entries":[{"id":"3AF822A6-EEC1-40B3-9A2C-D41E9EE90A89","date":"2026-09-03T15:25:02Z",
          "repo":"o/r","number":1,"tokens":100,"costUSD":0.1,"model":"sonnet"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(TokenLedger.self, from: json)
        XCTAssertEqual(ledger.entries.first?.kind, .review)
    }

}

final class CodeSyntaxProfileTests: XCTestCase {
    func testProfileByExtension() {
        XCTAssertEqual(CodeSyntax.profile(forPath: "A/B.swift")?.id, "swift")
        XCTAssertEqual(CodeSyntax.profile(forPath: "A/B.m")?.id, "clike")
        XCTAssertEqual(CodeSyntax.profile(forPath: "ci/deploy.sh")?.id, "script")
        XCTAssertEqual(CodeSyntax.profile(forPath: "a/b.yml")?.id, "script")
        XCTAssertEqual(CodeSyntax.profile(forPath: "a/Info.plist")?.id, "markup")
        XCTAssertEqual(CodeSyntax.profile(forPath: "Podfile")?.id, "script")
        XCTAssertNil(CodeSyntax.profile(forPath: "README.md"))
        XCTAssertNil(CodeSyntax.profile(forPath: "assets/logo.png"))
    }

    func testShellUsesHashComments() {
        let source = "# 설명\necho \"hi\""
        let spans = CodeSyntax.spans(in: source, profile: CodeSyntax.script)
        let characters = Array(source)
        let comment = spans.first { $0.kind == .comment }
        XCTAssertNotNil(comment)
        XCTAssertEqual(String(characters[comment!.start..<(comment!.start + comment!.length)]), "# 설명")
    }

    func testSwiftDoubleSlashIsNotAShellComment() {
        // clike 프로파일에서 # 은 주석이 아니다(전처리기·매크로).
        let spans = CodeSyntax.spans(in: "#import <Foundation/Foundation.h>", profile: CodeSyntax.cLike)
        XCTAssertFalse(spans.contains { $0.kind == .comment })
    }

    func testBlockCommentCarriesAcrossLines() {
        let lines = ["/* 시작", "가운데", "끝 */ let x = 1"]
        let perLine = CodeSyntax.highlight(lines: lines, profile: CodeSyntax.swift)
        XCTAssertEqual(perLine[0].first?.kind, .comment)
        XCTAssertEqual(perLine[1].first?.kind, .comment)      // 이어지는 줄도 주석
        XCTAssertEqual(perLine[1].first?.length, lines[1].count)
        XCTAssertTrue(perLine[2].contains { $0.kind == .keyword })  // 닫힌 뒤는 코드
    }

    func testJSONHasNoComments() {
        let spans = CodeSyntax.spans(in: #"{"a": 1, "b": true} // not a comment"#, profile: CodeSyntax.json)
        XCTAssertFalse(spans.contains { $0.kind == .comment })
        XCTAssertTrue(spans.contains { $0.kind == .string })
        XCTAssertTrue(spans.contains { $0.kind == .keyword })   // true
    }
}

final class PRTimelineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(offset))
    }

    private func pr(threads: [PRReviewThread] = [], reviews: [PRReviewEvent] = [],
                    comments: [PRIssueComment] = [], commits: [PRCommit] = []) -> PullRequestInfo {
        PullRequestInfo(repo: RepoID(owner: "o", name: "r"), number: 1, nodeID: "n", title: "t",
                        bodyText: "", author: "liam", isDraft: false, state: "OPEN", createdAt: base,
                        updatedAt: base, headRefOid: "abc", headRefName: "f", baseRefName: "develop",
                        additions: 1, deletions: 0, changedFiles: 1, mergeable: .mergeable,
                        mergeStateStatus: nil, reviewDecision: nil, approvals: [], labels: [],
                        viewerDidAuthor: false, viewerHasReviewRequest: true, viewerLatestReviewState: nil,
                        viewerLatestReviewCommit: nil, checkState: nil, threads: threads, commits: commits,
                        reviewEvents: reviews, issueComments: comments)
    }

    func testOldestFirstAcrossAllKinds() {
        let info = pr(threads: [PRReviewThread(id: "t1", path: "A.swift", line: 3, isResolved: false,
                                               isOutdated: false,
                                               comments: [ReviewThreadComment(author: "kai", body: "여기요",
                                                                              createdAt: iso(120))])],
                      reviews: [PRReviewEvent(author: "nova", state: "APPROVED",
                                              submittedAt: base.addingTimeInterval(300), body: "")],
                      comments: [PRIssueComment(author: "claude", body: "요약",
                                                createdAt: base.addingTimeInterval(60))],
                      commits: [PRCommit(oid: "c1", abbreviatedOid: "c1", messageHeadline: "첫 커밋",
                                         committedDate: base, author: "liam")])
        let entries = PRTimelineBuilder.build(from: info)
        XCTAssertEqual(entries.map(\.author), ["liam", "claude", "kai", "nova"])
        XCTAssertEqual(entries.first?.id, "commit:c1")
    }

    func testEmptyCommentedReviewIsFoldedIntoItsThread() {
        let info = pr(threads: [PRReviewThread(id: "t1", path: "A.swift", line: 3, isResolved: false,
                                               isOutdated: false,
                                               comments: [ReviewThreadComment(author: "kai", body: "여기요",
                                                                              createdAt: iso(0))])],
                      reviews: [PRReviewEvent(author: "kai", state: "COMMENTED", submittedAt: base, body: "")])
        XCTAssertEqual(PRTimelineBuilder.build(from: info).count, 1)
    }

    func testEmptyReviewWrappingAReplyIsFoldedToo() {
        // 남(kai)이 연 스레드에 liam 이 10분 뒤 답글 — GitHub 은 그 답글을 본문 없는 COMMENTED 리뷰로 감싼다.
        let thread = PRReviewThread(id: "t1", path: "A.swift", line: 3, isResolved: false, isOutdated: false,
                                    comments: [ReviewThreadComment(author: "kai", body: "여기요", createdAt: iso(0)),
                                               ReviewThreadComment(author: "liam", body: "고쳤습니다", createdAt: iso(600))])
        let info = pr(threads: [thread],
                      reviews: [PRReviewEvent(author: "liam", state: "COMMENTED",
                                              submittedAt: base.addingTimeInterval(600), body: "")])
        XCTAssertEqual(PRTimelineBuilder.build(from: info).count, 1)
        XCTAssertEqual(thread.latestReply?.author, "liam")
        XCTAssertNil(PRReviewThread(id: "t2", path: nil, line: nil, isResolved: false, isOutdated: false,
                                    comments: [ReviewThreadComment(author: "kai", body: "a", createdAt: iso(0))]).latestReply)
    }

    func testReviewWithBodyIsKeptEvenWithAThread() {
        let info = pr(threads: [PRReviewThread(id: "t1", path: "A.swift", line: 3, isResolved: false,
                                               isOutdated: false,
                                               comments: [ReviewThreadComment(author: "kai", body: "여기요",
                                                                              createdAt: iso(0))])],
                      reviews: [PRReviewEvent(author: "kai", state: "COMMENTED", submittedAt: base,
                                              body: "총평입니다")])
        XCTAssertEqual(PRTimelineBuilder.build(from: info).count, 2)
    }
}

final class CodeReferenceScannerTests: XCTestCase {
    private func file(_ path: String, lines: [(String, Int?)]) -> DiffFile {
        DiffFile(path: path, oldPath: nil, isBinary: false, isNew: false, isDeleted: false,
                 lines: lines.enumerated().map { index, entry in
                     DiffLine(index: index, kind: .addition, raw: "+" + entry.0, text: entry.0,
                              oldLine: nil, newLine: entry.1)
                 },
                 additions: lines.count, deletions: 0)
    }

    private var diff: ParsedDiff {
        ParsedDiff(files: [file("App/Gallery/GalleryViewController.swift",
                                lines: [("self?.loadTask?.cancel()", 247), ("func reloadItems() {", 250)]),
                           file("App/Gallery/GalleryService.swift",
                                lines: [("RequestGroup(requests: [request])", 106)])],
                   excludedFiles: [])
    }

    private func reference(_ code: String) -> CodeReference? {
        CodeReferenceScanner.reference(forCode: code, in: diff)
    }

    func testFileNameWithLineNumber() {
        let ref = reference("GalleryViewController.swift:516")
        XCTAssertEqual(ref?.path, "App/Gallery/GalleryViewController.swift")
        XCTAssertEqual(ref?.line, 516)
        XCTAssertEqual(ref?.label, "GalleryViewController.swift:516")
    }

    func testGitHubStyleAnchor() {
        XCTAssertEqual(reference("GalleryService.swift#L106")?.line, 106)
    }

    func testFullPathAndBareFileName() {
        XCTAssertEqual(reference("App/Gallery/GalleryService.swift")?.path, "App/Gallery/GalleryService.swift")
        XCTAssertNil(reference("GalleryService.swift")?.line)
        // 다른 파일 이름의 꼬리만 같은 것은 그 파일이 아니다.
        XCTAssertNil(reference("OldGalleryService.swift"))
    }

    func testSymbolResolvesToDiffLocation() {
        let ref = reference("RequestGroup")
        XCTAssertEqual(ref?.path, "App/Gallery/GalleryService.swift")
        XCTAssertEqual(ref?.line, 106)
    }

    func testSymbolWithArgumentsUsesItsName() {
        XCTAssertEqual(reference("reloadItems()")?.line, 250)
        XCTAssertEqual(reference("reloadItems()")?.label, "reloadItems()")
    }

    func testSymbolMatchesWholeWordsOnly() {
        // `loadTask` 안의 `load` 로 가면 엉뚱한 줄이다.
        XCTAssertNil(reference("load"))
        XCTAssertEqual(reference("loadTask")?.line, 247)
    }

    func testUnknownMentionsAreDropped() {
        // diff 에 없는 파일·심볼은 눌러도 갈 곳이 없으므로 링크로 만들지 않는다.
        XCTAssertNil(reference("SomeOtherThing"))
        XCTAssertNil(reference("Other.swift"))
    }

    func testShortSymbolsKeywordsAndValuesAreIgnored() {
        XCTAssertNil(reference("if"))
        XCTAssertNil(reference("self"))
        XCTAssertNil(reference("2026-10-21"))
        XCTAssertNil(reference("a b c d"))
    }
}

final class ClaudeModelsTests: XCTestCase {
    /// 기본값 모델은 그 별칭의 계열이어야 한다 — 어긋나면 CLI 에 묻기 전 목록이 엉뚱한 이름을 보인다.
    func testAllModelsHaveDistinctIDsInTheirFamily() {
        XCTAssertEqual(Set(ClaudeModels.all.map(\.id)).count, ClaudeModels.all.count)
        for option in ClaudeModels.all {
            XCTAssertEqual(ClaudeModels.family(ofModelID: option.apiID), option.id)
            XCTAssertEqual(ClaudeModels.displayName(forModelID: option.apiID), option.label)
        }
    }
}

final class ImageFilesTests: XCTestCase {
    func testExtensionDetection() {
        XCTAssertTrue(ImageFiles.isImage("a/b/SVG Image 2.svg"))
        XCTAssertTrue(ImageFiles.isImage("Assets/icon@3x.PNG"))
        XCTAssertFalse(ImageFiles.isImage("Assets/icon.json"))
        XCTAssertFalse(ImageFiles.isImage("A.swift"))
        XCTAssertTrue(ImageFiles.isVector("a.svg"))
        XCTAssertFalse(ImageFiles.isVector("a.png"))
    }

    func testReconstructAddedSVGFromDiffOnly() {
        // 추가된 SVG 는 추가 줄이 곧 전체 내용이라 API 를 부르지 않아도 그릴 수 있다.
        let lines = ["<svg width=\"10\" height=\"10\">", "<rect/>", "</svg>"].enumerated().map {
            DiffLine(index: $0.offset, kind: .addition, raw: "+" + $0.element, text: $0.element,
                     oldLine: nil, newLine: $0.offset + 1)
        }
        let file = DiffFile(path: "a/b.svg", oldPath: nil, isBinary: false, isNew: true, isDeleted: false,
                            lines: lines, additions: 3, deletions: 0)
        XCTAssertEqual(ImageFiles.reconstructedText(from: file),
                       "<svg width=\"10\" height=\"10\">\n<rect/>\n</svg>")
    }

    func testReconstructOnlyForAddedVectors() {
        let file = DiffFile(path: "a/b.png", oldPath: nil, isBinary: true, isNew: true, isDeleted: false,
                            lines: [], additions: 0, deletions: 0)
        XCTAssertNil(ImageFiles.reconstructedText(from: file))
        let modified = DiffFile(path: "a/b.svg", oldPath: nil, isBinary: false, isNew: false,
                                isDeleted: false, lines: [], additions: 1, deletions: 1)
        XCTAssertNil(ImageFiles.reconstructedText(from: modified))
    }

    func testByteSizeText() {
        XCTAssertEqual(ImageFiles.byteSizeText(900), "900 B")
        XCTAssertEqual(ImageFiles.byteSizeText(1434), "1.4 KB")
        XCTAssertEqual(ImageFiles.byteSizeText(3_500_000), "3.34 MB")
    }
}

final class WorktreeOriginTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    func testMatchesHttpsAndSshForms() {
        XCTAssertTrue(WorktreeManager.origin("git@github.com:acme/sample-ios.git", matches: repo))
        XCTAssertTrue(WorktreeManager.origin("https://github.com/acme/sample-ios.git", matches: repo))
        XCTAssertTrue(WorktreeManager.origin("https://github.com/ACME/Sample-iOS", matches: repo))
    }

    func testRejectsDifferentRepository() {
        // 실제로 겪은 케이스: 사설 GitHub Enterprise 의 다른 레포를 골랐다.
        XCTAssertFalse(WorktreeManager.origin("git@github.example.com:legacy-org/sample-ios-old.git",
                                              matches: repo))
        // 이름이 접미사로만 겹치는 경우도 막아야 한다.
        XCTAssertFalse(WorktreeManager.origin("git@github.com:someone/not-sample-ios.git", matches: repo))
        XCTAssertFalse(WorktreeManager.origin("git@github.com:acme/sample-ios-fork.git", matches: repo))
        XCTAssertFalse(WorktreeManager.origin("", matches: repo))
    }
}

final class UnlimitedLimitsTests: XCTestCase {
    /// 예산 상한 설정을 걷어냈다 — `--max-budget-usd` 를 다시 붙이면 잡는다.
    /// 상한에 걸려 끊긴 리뷰는 이미 쓴 토큰만 버리고 결과는 못 얻는다.
    func testBudgetFlagIsNeverPassed() {
        let invocation = ClaudeInvocation(claudePath: "/bin/echo", systemPromptPath: "g", schemaJSON: "{}",
                                          model: "sonnet", timeout: 60,
                                          workingDirectory: "/tmp")
        XCTAssertFalse(invocation.arguments.contains("--max-budget-usd"))
    }

    /// 타임아웃도 설정이 아니라 고정값이다. 0 이면 프로세스가 영원히 워커를 막는다.
    func testReviewTimeoutIsAFixedLongWait() {
        XCTAssertEqual(Settings.reviewTimeout, 24 * 3600)
    }
}
