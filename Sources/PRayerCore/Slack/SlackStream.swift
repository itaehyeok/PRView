import Foundation

/// `claude -p --output-format stream-json --verbose` 의 출력에서 이 기능이 보는 것만 추린다.
///
/// 결과는 **모델의 답이 아니라 도구가 돌려준 글**에서 읽는다. 모델이 채널 ID·메시지 주소를 옮겨 적다 틀려도
/// 앱이 그 값을 믿지 않게 하려는 것이다.
public struct SlackStreamSummary: Equatable, Sendable {
    public struct ToolCall: Equatable, Sendable {
        public var id: String
        public var name: String
    }

    public struct ToolResult: Equatable, Sendable {
        public var toolUseID: String
        public var isError: Bool
        public var text: String
    }

    /// 첫 줄(init)을 봤는가. 못 봤으면 claude 가 시작도 못 한 것이다.
    public var sawInit = false
    /// init 에 실린 Slack 서버의 상태(`connected`·`needs-auth`·`pending`·`failed`). nil 이면 서버가 아예 없다.
    public var serverStatus: String?
    public var calls: [ToolCall] = []
    public var results: [ToolResult] = []
    public var finalText: String?
    public var isError = false

    public static func parse(_ stdout: String) -> SlackStreamSummary {
        var summary = SlackStreamSummary()
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "system" where event["subtype"] as? String == "init":
                summary.sawInit = true
                let servers = event["mcp_servers"] as? [[String: Any]] ?? []
                summary.serverStatus = servers
                    .first { ($0["name"] as? String)?.localizedCaseInsensitiveContains("slack") == true }?["status"] as? String
            case "assistant":
                for item in content(of: event) where item["type"] as? String == "tool_use" {
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                    summary.calls.append(ToolCall(id: id, name: name))
                }
            case "user":
                for item in content(of: event) where item["type"] as? String == "tool_result" {
                    guard let id = item["tool_use_id"] as? String else { continue }
                    summary.results.append(ToolResult(toolUseID: id,
                                                      isError: item["is_error"] as? Bool ?? false,
                                                      text: text(of: item["content"])))
                }
            case "result":
                summary.finalText = event["result"] as? String
                summary.isError = event["is_error"] as? Bool ?? false
            default:
                continue
            }
        }
        return summary
    }

    private static func content(of event: [String: Any]) -> [[String: Any]] {
        (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// 도구 결과의 글. 문자열 하나이거나 `[{type: text, text}]` 배열이다.
    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return parts.joined(separator: "\n")
    }

    /// 커넥터가 붙지 않은 이유. 붙어 있으면 nil.
    public var connectorProblem: SlackConnectorError? {
        guard sawInit else { return nil }
        guard let serverStatus else { return .connectorMissing }
        switch serverStatus {
        case "connected": return nil
        case "needs-auth": return .needsAuth
        case "pending": return .connectorFailed("응답 없음")
        default: return .connectorFailed(serverStatus)
        }
    }

    func toolResults(for tool: SlackTool) -> [ToolResult] {
        let ids = Set(calls.filter { $0.name == tool.qualifiedName }.map(\.id))
        return results.filter { ids.contains($0.toolUseID) }
    }

    /// 그 도구의 성공한 결과 글. 없으면 nil.
    func successfulResultText(for tool: SlackTool) -> String? {
        toolResults(for: tool).first { !$0.isError }?.text
    }

    /// 훅(`SlackSendGuard`)이 막았으면 그 글.
    func blockedReason(for tool: SlackTool) -> String? {
        toolResults(for: tool).first { $0.isError && $0.text.contains("PRView:") }?.text
    }

    /// 성공하지 못한 까닭.
    func failure(for tool: SlackTool) -> SlackConnectorError {
        if let failed = toolResults(for: tool).first(where: \.isError) {
            return .toolFailed(SlackResultParser.errorText(failed.text))
        }
        if calls.contains(where: { $0.name == tool.qualifiedName }) {
            return .unreadable("Slack 도구가 결과를 돌려주지 않았습니다.")
        }
        return .toolNotCalled(finalText)
    }
}

/// Slack 커넥터 도구가 돌려준 글 읽기. 사람 읽으라고 쓴 글이라(2026-10-20 모양) 줄 단위로 맞춰 본다.
public enum SlackResultParser {
    /// 검색어 → 커넥터의 `keywords`. 낱말마다 AND 로 걸리므로 빈칸으로 나눈다.
    public static func keywords(_ query: String) -> [String] {
        Array(query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(5))
    }

    /// `{"result": "..."}`·`{"results": "..."}` 로 한 번 싸여 온다. 벗긴 글, 아니면 그대로.
    static func unwrap(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return text }
        return (object["result"] as? String) ?? (object["results"] as? String) ?? text
    }

    /// `User ID: U…` · `Real Name: 이름 [상태 …]` · `Display Name: …`
    public static func profile(from text: String) -> SlackPerson? {
        let body = unwrap(text)
        var fields: [String: String] = [:]
        for line in body.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil, !value.isEmpty { fields[key] = value }
        }
        guard let id = fields["User ID"], isMemberID(id) else { return nil }
        let name = [fields["Real Name"], fields["Display Name"], fields["Username"]]
            .compactMap { $0 }
            .map(stripStatus)
            .first { !$0.isEmpty } ?? id
        return SlackPerson(id: id, name: name)
    }

    /// `1. #채널 (C123) - public_channel - Creator: … - Not Archived`
    public static func channels(from text: String) -> [SlackDestination] {
        let pattern = #"^\s*\d+\.\s+#(.+?)\s+\(([A-Z][A-Z0-9]{6,})\)\s+-\s+(public_channel|private_channel)"#
        var found: [SlackDestination] = []
        for line in unwrap(text).components(separatedBy: "\n") {
            guard let groups = match(pattern, in: line), groups.count == 3 else { continue }
            // 보관된 채널에는 보낼 수 없다.
            if line.contains("- Archived") { continue }
            let kind: SlackDestination.Kind = groups[2] == "private_channel" ? .privateChannel : .channel
            let destination = SlackDestination(id: groups[1], name: groups[0], kind: kind)
            if !found.contains(where: { $0.id == destination.id }) { found.append(destination) }
        }
        return found
    }

    /// `1. Alex Kim [부재중] - U0AAAAAAAA - alex@example.com - Engineering`
    public static func people(from text: String) -> [SlackPerson] {
        let pattern = #"^\s*\d+\.\s+(.+?)\s+-\s+([UW][A-Z0-9]{6,})\b"#
        var found: [SlackPerson] = []
        for line in unwrap(text).components(separatedBy: "\n") {
            guard let groups = match(pattern, in: line), groups.count == 2 else { continue }
            let person = SlackPerson(id: groups[1], name: stripStatus(groups[0]))
            if !found.contains(where: { $0.id == person.id }) { found.append(person) }
        }
        return found
    }

    /// 메시지 검색(detailed) 결과의 `Channel: #이름 (ID: C…)` 줄. 공개·비공개는 이 줄로 알 수 없어 채널로 둔다.
    public static func channelsFromMessages(_ text: String) -> [SlackDestination] {
        let pattern = #"Channel:\s+#(.+?)\s+\(ID:\s+([A-Z][A-Z0-9]{6,})\)"#
        var found: [SlackDestination] = []
        for line in unwrap(text).components(separatedBy: "\n") {
            guard let groups = match(pattern, in: line), groups.count == 2 else { continue }
            let channel = SlackDestination(id: groups[1], name: groups[0], kind: .channel)
            if !found.contains(where: { $0.id == channel.id }) { found.append(channel) }
        }
        return found
    }

    /// `{"message_link":"https://…/archives/D…/p…", …}`
    public static func messageLink(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let link = object["message_link"] as? String, link.hasPrefix("https://") {
            return link
        }
        return match(#"(https://[A-Za-z0-9.-]+\.slack\.com/archives/[A-Za-z0-9/]+)"#, in: text)?.first
    }

    /// 도구 오류 글에서 사람이 읽을 부분. 커넥터는 `{"error": "not_in_channel"}` 꼴로도 준다.
    static func errorText(_ text: String) -> String {
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = (object["error"] as? String) ?? (object["message"] as? String) {
            return friendly(error)
        }
        return friendly(String(text.prefix(300)))
    }

    /// 슬랙 오류 코드 중 자주 겪을 것만 말로 바꾼다.
    static func friendly(_ code: String) -> String {
        if code.contains("not_in_channel") { return "그 채널에 들어가 있지 않습니다 — 채널에 먼저 들어가세요." }
        if code.contains("channel_not_found") { return "채널을 찾을 수 없습니다 — 지워졌거나 비공개일 수 있습니다." }
        if code.contains("is_archived") { return "보관된 채널입니다." }
        if code.contains("restricted_action") { return "이 채널에는 글을 쓸 수 없습니다(채널 권한)." }
        return code
    }

    static func isMemberID(_ id: String) -> Bool {
        match(#"^[UW][A-Z0-9]{6,}$"#, in: id) != nil
    }

    /// 이름 뒤의 상태 꼬리표(`[부재중]`)를 뗀다. 회사마다 붙이는 꼴이 달라 대괄호만 본다.
    static func stripStatus(_ name: String) -> String {
        guard let bracket = name.range(of: " [") else { return name.trimmingCharacters(in: .whitespaces) }
        return String(name[..<bracket.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(found.numberOfRanges, 1)).compactMap { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
