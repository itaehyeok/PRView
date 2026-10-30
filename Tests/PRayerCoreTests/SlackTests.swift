import XCTest
@testable import PRayerCore

/// 슬랙 리뷰 요청 — 고정 형식 글 만들기, 커넥터 결과 읽기, 보낼 글을 지키는 훅.
/// 슬랙 결과 글은 2026-10-20 커넥터가 실제로 돌려준 모양을 가공 이름으로 옮겼다.
final class SlackTemplateTests: XCTestCase {
    private let items = SlackTemplate.sampleItems

    /// 형식은 고정 — PR 주소 한 줄씩, 맨 끝에 "리뷰 부탁드립니다". 팀 채널에서 손으로 올리는 꼴 그대로다.
    func testMessageIsLinksThenRequest() {
        XCTAssertEqual(SlackTemplate.message(items: items), """
        https://github.com/acme/sample-ios/pull/128
        https://github.com/acme/sample-ios/pull/131
        리뷰 부탁드립니다
        """)
        XCTAssertEqual(SlackTemplate.message(items: [items[0]]),
                       "https://github.com/acme/sample-ios/pull/128\n리뷰 부탁드립니다")
        XCTAssertEqual(SlackTemplate.message(items: []), "")
    }

    /// 제목은 글에 넣지 않는다 — 대괄호·따옴표가 든 제목도 보낼 글을 바꾸지 않는다(제목은 링크 미리보기가 보인다).
    func testTitleNeverEntersTheMessage() {
        var item = items[0]
        item.title = "[APP-12][IOS] 짝 안 맞음 ]"
        let message = SlackTemplate.message(items: [item])
        XCTAssertFalse(message.contains("APP-12"), message)
        XCTAssertFalse(message.contains("\\"), message)
    }

    /// 주소를 못 만들었으면 무엇인지는 알게 레포·번호·제목.
    func testMissingURLFallsBackToRepoNumberTitle() {
        var item = items[1]
        item.url = ""
        XCTAssertEqual(SlackTemplate.message(items: [item]), "sample-ios#131 목록 새로고침 깜빡임 수정\n리뷰 부탁드립니다")
    }

    /// 짝이 안 맞는 대괄호만 전각으로 — 링크를 깨지 않고, 백슬래시도 없다. 짝이 맞는 것은 그대로.
    func testUnmatchedTitleBracketsBecomeFullWidth() {
        XCTAssertEqual(SlackTemplate.linkLabel("[APP-12] 고침 ]"), "[APP-12] 고침 ］")
        XCTAssertEqual(SlackTemplate.linkLabel("[WIP [APP-12] 고침"), "［WIP [APP-12] 고침")
        XCTAssertEqual(SlackTemplate.linkLabel("] 거꾸로 ["), "］ 거꾸로 ［")
        XCTAssertEqual(SlackTemplate.linkLabel("[[중첩]] 제목"), "[[중첩]] 제목")
        XCTAssertEqual(SlackTemplate.linkLabel("대괄호 없음"), "대괄호 없음")
        // 바꾼 글자도 마크다운에서 링크 하나로 읽힌다.
        let parsed = SlackMarkdownText.parse("[\(SlackTemplate.linkLabel("[APP-12] 고침 ]"))](https://example.com/pull/1)")
        XCTAssertEqual(parsed.string, "[APP-12] 고침 ］")
        XCTAssertNotNil(parsed.attribute(SlackMarkdownText.linkKey, at: 0, effectiveRange: nil))
    }

    /// 옛 설정 파일의 틀·멘션·링크 미리보기 칸은 읽을 때 버리고, 다시 저장하면 빠진다. 나머지는 그대로 읽힌다.
    func testOldTemplateKeysAreDropped() throws {
        var settings = SlackSettings.default
        settings.me = SlackPerson(id: "U0AAAAAAA", name: "나")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json["messageTemplate"] = "{멘션} 봐 주세요\n{PR목록}"
        json["lineTemplate"] = "- [{제목}]({링크})"
        json["mentions"] = [["id": "U0BBBBBBB", "name": "가나"]]
        json["unfurlLinks"] = false
        let decoded = try JSONDecoder().decode(SlackSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, settings)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        for key in ["messageTemplate", "lineTemplate", "mentions", "unfurlLinks"] {
            XCTAssertNil(saved[key], key)
        }
    }

    func testPreviewShowsNamesInsteadOfIDs() {
        let people = [SlackPerson(id: "U0AAAAAAA", name: "가나")]
        let preview = SlackTemplate.preview(#"<@U0AAAAAAA> <!here> [\[A\] b](u)"#, people: people)
        XCTAssertEqual(preview, "@가나 @here [[A] b](u)")
    }

    /// 나에게(DM)는 고르는 자리마다 "테스트용" 이 붙는다 — 남에게 가는 곳과 헷갈리지 않게.
    func testMeIsMarkedAsTest() {
        let me = SlackDestination.me(SlackPerson(id: "U0AAAAAAA", name: "나"))
        XCTAssertEqual(me.tag, "테스트용")
        XCTAssertEqual(me.pickerLabel, "나에게 (DM) · 테스트용")
        let channel = SlackDestination(id: "C0AAAAAAA", name: "ios-review", kind: .channel)
        XCTAssertNil(channel.tag)
        XCTAssertEqual(channel.pickerLabel, "#ios-review")
    }

    /// 치는 대로 거르기 — `#` 은 빼고, 대소문자는 가리지 않는다. 빈 칸이면 다 보인다.
    func testDestinationFilter() {
        let channel = SlackDestination(id: "C0AAAAAAA", name: "Mobile-iOS-PR", kind: .channel)
        XCTAssertTrue(channel.matches(""))
        XCTAssertTrue(channel.matches("ios"))
        XCTAssertTrue(channel.matches("#mobile"))
        XCTAssertTrue(channel.matches("  pr "))
        XCTAssertFalse(channel.matches("android"))
    }

    /// 두 갈래로 받은 채널 합치기 — 글을 쓴 채널이 앞, 같은 채널은 한 번.
    func testMergedChannelsKeepPostedFirst() {
        let a = SlackDestination(id: "C0AAAAAAA", name: "a", kind: .channel)
        let b = SlackDestination(id: "C0BBBBBBB", name: "b", kind: .channel)
        let c = SlackDestination(id: "C0CCCCCCC", name: "c", kind: .channel)
        XCTAssertEqual(SlackSettings.mergedChannels(posted: [b], member: [a, b, c]), [b, a, c])
    }

    /// 내 채널 칸이 생기기 전의 슬랙 설정도 읽힌다.
    func testOldSlackSettingsWithoutMyChannels() throws {
        var settings = SlackSettings.default
        settings.me = SlackPerson(id: "U0AAAAAAA", name: "나")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "myChannels")
        json.removeValue(forKey: "myChannelsFetchedAt")
        let decoded = try JSONDecoder().decode(SlackSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.myChannels, [])
        XCTAssertNil(decoded.myChannelsFetchedAt)
        XCTAssertEqual(decoded.me, settings.me)
    }

    func testKoreanAgo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SlackAgo.text(now.addingTimeInterval(-47), now: now), "방금")
        XCTAssertEqual(SlackAgo.text(now.addingTimeInterval(-3 * 60), now: now), "3분 전")
        XCTAssertEqual(SlackAgo.text(now.addingTimeInterval(-2 * 3600), now: now), "2시간 전")
        XCTAssertEqual(SlackAgo.text(now.addingTimeInterval(-30 * 3600), now: now), "어제")
        XCTAssertEqual(SlackAgo.text(now.addingTimeInterval(-5 * 86_400), now: now), "5일 전")
        // 시계가 어긋나 미래 시각이 와도 "방금" 으로 둔다.
        XCTAssertEqual(SlackAgo.text(now.addingTimeInterval(30), now: now), "방금")
    }

    /// 나에게(DM)는 받는 곳이 아니다 — 예전에 골라 둔 것은 읽을 때 비운다(채널을 다시 고르게).
    func testSavedMeDestinationIsDropped() throws {
        var settings = SlackSettings.default
        let me = SlackDestination.me(SlackPerson(id: "U0AAAAAAA", name: "나"))
        let channel = SlackDestination(id: "C0AAAAAAA", name: "ios-review", kind: .channel)
        settings.choose(channel)
        settings.choose(me)
        let decoded = try JSONDecoder().decode(SlackSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(decoded.destination)
        XCTAssertEqual(decoded.recentDestinations, [channel])
    }

    func testChoosingKeepsRecentDestinationsUniqueAndShort() {
        var settings = SlackSettings.default
        for index in 0..<7 {
            settings.choose(SlackDestination(id: "C0000000\(index)", name: "c\(index)", kind: .channel))
        }
        settings.choose(SlackDestination(id: "C00000003", name: "c3", kind: .channel))
        XCTAssertEqual(settings.destination?.id, "C00000003")
        XCTAssertEqual(settings.recentDestinations.map(\.name), ["c3", "c6", "c5", "c4", "c2"])
    }

    /// 슬랙 칸이 생기기 전의 설정 파일도 그대로 읽힌다.
    func testOldSettingsFileReadsWithDefaultSlack() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as! [String: Any]
        json.removeValue(forKey: "slack")
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.slack, .default)
        XCTAssertFalse(decoded.slack.isReady)
    }

    func testSlackSettingsSurviveSaving() throws {
        var settings = Settings.default
        settings.slack.me = SlackPerson(id: "U0AAAAAAA", name: "나")
        settings.slack.choose(SlackDestination(id: "C0AAAAAAA", name: "ios-review", kind: .channel))
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.slack, settings.slack)
        XCTAssertTrue(decoded.slack.isReady)
    }
}

final class SlackResultParserTests: XCTestCase {
    func testProfileUsesRealNameWithoutStatus() {
        let text = #"{"result":"User ID: U0AAAAAAA\nUsername: kim.dev\nDisplay Name: Kim 가나 / 앱개발\nReal Name: Kim 가나 [부재중]\nTitle: 앱개발팀"}"#
        XCTAssertEqual(SlackResultParser.profile(from: text), SlackPerson(id: "U0AAAAAAA", name: "Kim 가나"))
    }

    func testProfileWithoutIDIsNil() {
        XCTAssertNil(SlackResultParser.profile(from: #"{"result":"Username: nobody"}"#))
    }

    func testChannelsSkipArchivedAndKeepPrivacy() {
        let text = ##"{"results":"# Search Results for: \n\n## Channels (3 results)\n1. #app_dev (C011AAAAAAA) - public_channel - Creator: Kim 가나 [휴가]  - 2021-01-01 - Not Archived\n2. #앱-dev-pr (C022BBBBBBB) - private_channel - Creator: Lee 다라  - 2024-05-01 - Not Archived\n3. #old_dev (C01CCCCCCCC) - public_channel - Creator: Park 마바  - 2018-03-01 - Archived\n","pagination_info":"…"}"##
        let channels = SlackResultParser.channels(from: text)
        XCTAssertEqual(channels, [
            SlackDestination(id: "C011AAAAAAA", name: "app_dev", kind: .channel),
            SlackDestination(id: "C022BBBBBBB", name: "앱-dev-pr", kind: .privateChannel)
        ])
    }

    func testPeople() {
        let text = ##"{"results":"# Search Results for: \n\n## Users (2 results)\n1. Kim 가나 [부재중] - U02AAAAAAAA - kim@example.com - 앱개발팀\n2. Kim 다라 - W0222BBBBBB - kim2@example.com\n"}"##
        XCTAssertEqual(SlackResultParser.people(from: text), [
            SlackPerson(id: "U02AAAAAAAA", name: "Kim 가나"),
            SlackPerson(id: "W0222BBBBBB", name: "Kim 다라")
        ])
    }

    /// 내 채널 모으기 — 메시지 검색(detailed)의 `Channel: #이름 (ID: …)` 줄에서 읽는다.
    func testChannelsFromMessageSearch() {
        let text = ##"{"results":"# Search Results for: \n\n## Messages (2 results)\n### Result 1 of 2\nChannel: #앱-개발팀 (ID: C033AAAAAAA)\nFrom: Kim 가나 (ID: U02AAAAAAAA) \nText: \n안녕\n\n---\n\n### Result 2 of 2\nChannel: #앱-개발팀 (ID: C033AAAAAAA)\nText: \n또\n---\n### Result\nChannel: #old_team (ID: GQ9AAAAAA)\n"}"##
        XCTAssertEqual(SlackResultParser.channelsFromMessages(text), [
            SlackDestination(id: "C033AAAAAAA", name: "앱-개발팀", kind: .channel),
            SlackDestination(id: "GQ9AAAAAA", name: "old_team", kind: .channel)
        ])
    }

    func testMessageLink() {
        let text = #"{"message_link":"https:\/\/acme.slack.com\/archives\/D02AAAAAAAA\/p1792477145138539","message_context":{"message_ts":"1792477145.138539"}}"#
        XCTAssertEqual(SlackResultParser.messageLink(from: text),
                       "https://acme.slack.com/archives/D02AAAAAAAA/p1792477145138539")
    }

    func testFriendlyErrors() {
        XCTAssertTrue(SlackResultParser.errorText(#"{"error":"not_in_channel"}"#).contains("들어가 있지 않습니다"))
        XCTAssertEqual(SlackResultParser.errorText("something odd"), "something odd")
    }

    func testKeywordsSplitOnSpaces() {
        XCTAssertEqual(SlackResultParser.keywords("  ios   review "), ["ios", "review"])
        XCTAssertEqual(SlackResultParser.keywords(""), [])
    }
}

final class SlackStreamTests: XCTestCase {
    private func stream(server: String?, toolResult: String? = nil, isError: Bool = false,
                        tool: SlackTool = .sendMessage) -> String {
        var lines: [String] = []
        let servers = server.map { #"[{"name":"claude.ai Slack","status":"\#($0)"}]"# } ?? "[]"
        lines.append(#"{"type":"system","subtype":"init","tools":[],"mcp_servers":\#(servers)}"#)
        if let toolResult {
            lines.append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"\#(tool.qualifiedName)","input":{}}]}}"#)
            let content = try! String(data: JSONSerialization.data(withJSONObject: [["type": "text", "text": toolResult]]), encoding: .utf8)!
            lines.append(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":\#(isError),"content":\#(content)}]}}"#)
        }
        lines.append(#"{"type":"result","is_error":false,"result":"DONE"}"#)
        return lines.joined(separator: "\n")
    }

    func testSuccessfulSend() {
        let summary = SlackStreamSummary.parse(stream(server: "connected", toolResult: #"{"message_link":"https://acme.slack.com/archives/C1/p1"}"#))
        XCTAssertNil(summary.connectorProblem)
        XCTAssertEqual(summary.successfulResultText(for: .sendMessage).flatMap(SlackResultParser.messageLink(from:)),
                       "https://acme.slack.com/archives/C1/p1")
        XCTAssertNil(summary.blockedReason(for: .sendMessage))
    }

    func testMissingConnector() {
        XCTAssertEqual(SlackStreamSummary.parse(stream(server: nil)).connectorProblem, .connectorMissing)
        XCTAssertEqual(SlackStreamSummary.parse(stream(server: "needs-auth")).connectorProblem, .needsAuth)
    }

    func testGuardBlockIsRecognised() {
        let summary = SlackStreamSummary.parse(stream(server: "connected",
                                                      toolResult: "PreToolUse hook error: PRView: message or channel differs",
                                                      isError: true))
        XCTAssertNil(summary.successfulResultText(for: .sendMessage))
        XCTAssertNotNil(summary.blockedReason(for: .sendMessage))
    }

    /// 다른 도구의 결과를 이 도구의 것으로 읽지 않는다.
    func testResultsAreMatchedToTheirTool() {
        let summary = SlackStreamSummary.parse(stream(server: "connected", toolResult: "x", tool: .searchUsers))
        XCTAssertNil(summary.successfulResultText(for: .sendMessage))
        XCTAssertEqual(summary.failure(for: .sendMessage), .toolNotCalled("DONE"))
    }

    /// 로그인이 끊기면 커넥터도 안 실린다 — "Slack 을 연결하세요" 가 아니라 로그인을 권해야 한다.
    func testLoginFailureWinsOverMissingConnector() {
        var summary = SlackStreamSummary.parse(stream(server: nil))
        summary.isError = true
        summary.finalText = "Invalid API key · Please run /login"
        XCTAssertEqual(SlackConnector.problem(in: summary, stderr: ""), .loginRequired)
        XCTAssertEqual(SlackConnector.problem(in: SlackStreamSummary.parse(stream(server: nil)),
                                               stderr: "OAuth session expired"), .loginRequired)
        XCTAssertEqual(SlackConnector.problem(in: SlackStreamSummary.parse(stream(server: nil)), stderr: ""),
                       .connectorMissing)
        // 정상으로 끝난 답에 우연히 같은 말이 있어도 로그인 실패로 보지 않는다.
        var fine = SlackStreamSummary.parse(stream(server: "connected"))
        fine.finalText = "please log in later"
        XCTAssertNil(SlackConnector.problem(in: fine, stderr: ""))
    }

    func testNothingFromClaudeIsUnreadable() {
        guard case .unreadable = SlackConnector.problem(in: SlackStreamSummary(), stderr: "boom") else {
            return XCTFail("claude 가 init 도 못 냈으면 읽지 못한 것이다")
        }
    }

    /// 실패를 사람이 할 일로 나눈다 — 화면이 이것으로 안내를 고른다.
    func testFailureKinds() {
        XCTAssertEqual(SlackConnectorError.connectorMissing.failureKind, .connector)
        XCTAssertEqual(SlackConnectorError.needsAuth.failureKind, .connector)
        XCTAssertEqual(SlackConnectorError.connectorFailed("failed").failureKind, .connector)
        XCTAssertEqual(SlackConnectorError.loginRequired.failureKind, .claudeLogin)
        XCTAssertEqual(SlackConnectorError.claudeMissing("/x").failureKind, .claudeMissing)
        XCTAssertEqual(SlackConnectorError.timedOut.failureKind, .other)
    }

    func testToolErrorBecomesToolFailed() {
        let summary = SlackStreamSummary.parse(stream(server: "connected", toolResult: #"{"error":"channel_not_found"}"#, isError: true))
        guard case .toolFailed(let message) = summary.failure(for: .sendMessage) else {
            return XCTFail("\(summary.failure(for: .sendMessage))")
        }
        XCTAssertTrue(message.contains("찾을 수 없습니다"))
    }
}

final class SlackInvocationTests: XCTestCase {
    /// 쓸 도구 하나만 열고, Slack 서버만 남기고, MCP 를 끄는 플래그는 쓰지 않는다.
    func testArgumentsOpenOnlyTheOneTool() throws {
        let args = SlackInvocation.arguments(tool: .searchChannels, model: "haiku", hookCommand: nil)
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).map { args[args.index(after: $0)] }
        }
        XCTAssertEqual(value(after: "--allowedTools"), SlackTool.searchChannels.qualifiedName)
        let disallowed = try XCTUnwrap(value(after: "--disallowedTools")).split(separator: ",").map(String.init)
        XCTAssertFalse(disallowed.contains(SlackTool.searchChannels.qualifiedName))
        XCTAssertTrue(disallowed.contains(SlackTool.sendMessage.qualifiedName))
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--setting-sources"), "")
        XCTAssertFalse(args.contains("--safe-mode"))
        XCTAssertFalse(args.contains("--strict-mcp-config"))
        let settings = try XCTUnwrap(value(after: "--settings"))
        XCTAssertTrue(settings.contains(#""serverUrl":"https://mcp.slack.com/*""#), settings)
        XCTAssertFalse(settings.contains("hooks"))
    }

    /// 되풀이 검색(내 채널)만 쓸 돈에 상한을 둔다 — 모델이 멈추지 않아도 거기서 끊긴다.
    func testBudgetOnlyWhenAsked() {
        let looped = SlackInvocation.arguments(tool: .searchMessages, model: "haiku", hookCommand: nil, budgetUSD: 0.5)
        XCTAssertEqual(looped.firstIndex(of: "--max-budget-usd").map { looped[$0 + 1] }, "0.50")
        XCTAssertEqual(looped.firstIndex(of: "--allowedTools").map { looped[$0 + 1] }, SlackTool.searchMessages.qualifiedName)
        let single = SlackInvocation.arguments(tool: .sendMessage, model: "haiku", hookCommand: nil)
        XCTAssertFalse(single.contains("--max-budget-usd"))
    }

    func testSendCarriesTheGuardHook() throws {
        let args = SlackInvocation.arguments(tool: .sendMessage, model: "haiku", hookCommand: "/bin/sh \"/x y/guard.sh\"")
        let settings = try XCTUnwrap(args.firstIndex(of: "--settings").map { args[$0 + 1] })
        let object = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as! [String: Any]
        let pre = ((object["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first
        XCTAssertEqual(pre?["matcher"] as? String, SlackTool.sendMessage.qualifiedName)
        let command = ((pre?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        XCTAssertEqual(command, "/bin/sh \"/x y/guard.sh\"")
    }
}

/// 보낼 글을 지키는 훅을 실제 `/bin/sh` 로 돌린다. 이 훅이 틀리면 모델이 바꾼 글이 사용자 이름으로 나간다.
final class SlackSendGuardTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        // 경로에 빈칸을 넣는다 — 실제 경로("Application Support")처럼.
        base = FileManager.default.temporaryDirectory.appendingPathComponent("slack guard \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private let message = "<@U0AAAAAAA> 리뷰 부탁드립니다 🙏\n• [\\[APP-1\\] \"따옴표\" 제목](https://example.com/pull/1) +1 \u{2212}2"

    private func hook(_ dir: URL, message: String, channel: String) throws -> Int32 {
        let input = try JSONSerialization.data(withJSONObject: [
            "tool_name": SlackTool.sendMessage.qualifiedName,
            "tool_input": ["channel_id": channel, "message": message, "unfurl_app_links": false]
        ])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SlackSendGuard.hookCommand(directory: dir)]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testSameMessagePassesOnlyOnce() throws {
        let dir = try SlackSendGuard.prepare(message: message, channelID: "C0AAAAAAA", in: base)
        XCTAssertEqual(try hook(dir, message: message, channel: "C0AAAAAAA"), 0)
        XCTAssertTrue(SlackSendGuard.passed(dir))
        // 같은 글을 또 보내려 하면 막는다 — 같은 요청이 두 번 가지 않게.
        XCTAssertEqual(try hook(dir, message: message, channel: "C0AAAAAAA"), 2)
    }

    func testChangedMessageIsBlocked() throws {
        let dir = try SlackSendGuard.prepare(message: message, channelID: "C0AAAAAAA", in: base)
        XCTAssertEqual(try hook(dir, message: message + " ", channel: "C0AAAAAAA"), 2)
        XCTAssertEqual(try hook(dir, message: message.replacingOccurrences(of: "\\[", with: "["), channel: "C0AAAAAAA"), 2)
        XCTAssertFalse(SlackSendGuard.passed(dir))
    }

    func testOtherChannelIsBlocked() throws {
        let dir = try SlackSendGuard.prepare(message: message, channelID: "C0AAAAAAA", in: base)
        XCTAssertEqual(try hook(dir, message: message, channel: "C0BBBBBBB"), 2)
        XCTAssertFalse(SlackSendGuard.passed(dir))
    }
}

/// 미리보기를 눌러 고치는 칸의 되돌림 — 보낼 글이 이것으로 만들어진다. 고치지 않은 글은 원래 글과 같아야 한다.
final class SlackMarkdownTextTests: XCTestCase {
    private func roundTrip(_ markdown: String) -> String {
        SlackMarkdownText.markdown(from: SlackMarkdownText.parse(markdown))
    }

    /// 고정 형식 글 — 주소가 링크 글자(`[주소](주소)`)로 바뀌지 않고 그대로 남는다.
    func testMessageRoundTripsUnchanged() {
        let message = SlackTemplate.message(items: SlackTemplate.sampleItems)
        XCTAssertEqual(roundTrip(message), message)
        XCTAssertEqual(roundTrip(message + " 마감이 오늘이라 부탁드려요"), message + " 마감이 오늘이라 부탁드려요")
    }

    func testEmphasisAndCodeRoundTrip() {
        XCTAssertEqual(roundTrip("**굵게** 와 _기울임_ 과 `코드` 그리고 <@U0AAAAAAA>"),
                       "**굵게** 와 _기울임_ 과 `코드` 그리고 <@U0AAAAAAA>")
    }

    /// 맨 주소는 고치는 칸에서 링크가 아니라 글자다 — 번호를 고치면 고친 주소가 그대로 간다.
    func testEditingBareURLKeepsItBare() {
        let text = NSMutableAttributedString(attributedString: SlackMarkdownText.parse("https://example.com/pull/1\n리뷰 부탁드립니다"))
        XCTAssertNil(text.attribute(SlackMarkdownText.linkKey, at: 0, effectiveRange: nil))
        let one = (text.string as NSString).range(of: "1\n")
        text.replaceCharacters(in: NSRange(location: one.location, length: 1), with: "2")
        XCTAssertEqual(SlackMarkdownText.markdown(from: text), "https://example.com/pull/2\n리뷰 부탁드립니다")
    }

    /// 링크 글자를 고쳐도 링크(주소)는 남는다.
    func testEditingLinkLabelKeepsTheLink() {
        let text = NSMutableAttributedString(attributedString: SlackMarkdownText.parse("• [옛 제목](https://example.com/pull/1) +1"))
        let range = (text.string as NSString).range(of: "옛")
        text.replaceCharacters(in: range, with: "새")
        XCTAssertEqual(SlackMarkdownText.markdown(from: text), "• [새 제목](https://example.com/pull/1) +1")
    }
}
