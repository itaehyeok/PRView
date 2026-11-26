import PRayerCore
import SwiftUI

/// 툴바 "상태" 아이콘과 설정 › 연결의 상태 줄이 같은 심볼·같은 색을 쓰게 한 자리에 둔다.
/// 모양은 2026-11-06 사용자가 고른 시안 A(정상도 초록 체크) 그대로다.
extension ConnectionHealth {
    /// 채운 심볼에 색을 칠하면 체크·느낌표 자리가 비쳐 보인다(.monochrome).
    var symbolName: String {
        switch self {
        case .checking: return "circle.dashed"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .checking: return .secondary
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
