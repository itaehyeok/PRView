import Foundation

/// OpenAI 구조화 출력(Codex `--output-schema`)은 스키마가 엄격하다.
/// - `properties` 의 **모든** 키가 `required` 에 있어야 한다.
/// - 선택 필드는 타입에 `null` 을 더해 표현한다.
/// - 객체마다 `additionalProperties: false` 가 있어야 한다.
/// Claude 의 `--json-schema` 는 이런 제약이 없으므로, 같은 스키마를 Codex 용으로만 변환해 쓴다.
public enum StrictSchema {
    public static func strictified(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let converted = convert(root)
        guard let output = try? JSONSerialization.data(withJSONObject: converted,
                                                       options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    private static func convert(_ node: [String: Any]) -> [String: Any] {
        var result = node

        if let properties = node["properties"] as? [String: Any] {
            let existingRequired = Set((node["required"] as? [String]) ?? [])
            var newProperties: [String: Any] = [:]
            for (key, value) in properties {
                guard var child = value as? [String: Any] else {
                    newProperties[key] = value
                    continue
                }
                child = convert(child)
                if !existingRequired.contains(key) {
                    child = nullable(child)
                }
                newProperties[key] = child
            }
            result["properties"] = newProperties
            result["required"] = properties.keys.sorted()
            result["additionalProperties"] = false
        }

        if let items = node["items"] as? [String: Any] {
            result["items"] = convert(items)
        }
        return result
    }

    /// 선택 필드를 nullable 로 만든다.
    private static func nullable(_ node: [String: Any]) -> [String: Any] {
        var result = node
        if let type = node["type"] as? String {
            result["type"] = type == "null" ? type : [type, "null"]
        } else if var types = node["type"] as? [String] {
            if !types.contains("null") { types.append("null") }
            result["type"] = types
        } else if node["enum"] != nil {
            // enum 만 있는 필드는 문자열 enum 이므로 타입을 명시하고 null 을 허용한다.
            result["type"] = ["string", "null"]
        }
        if var values = result["enum"] as? [Any] {
            let hasNull = values.contains { $0 is NSNull }
            if !hasNull {
                values.append(NSNull())
                result["enum"] = values
            }
        }
        return result
    }
}
