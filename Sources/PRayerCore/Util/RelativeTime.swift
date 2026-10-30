import Foundation

/// 목록에서 쓰는 짧은 상대 시각. 리스트 폭이 좁아 "4 minutes ago" 같은 표기는 들어가지 않는다.
public enum RelativeTime {
    /// "now", "12m", "2h", "3d", "5w", "7mo", "1y"
    public static func compact(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        case ..<2_592_000: return "\(Int(seconds / 604_800))w"
        case ..<31_536_000: return "\(Int(seconds / 2_592_000))mo"
        default: return "\(Int(seconds / 31_536_000))y"
        }
    }

    /// "just now", "12m ago" — 한 줄로 보여주는 자리(Created …)에 쓴다.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let short = compact(date, now: now)
        return short == "now" ? "just now" : "\(short) ago"
    }
}
