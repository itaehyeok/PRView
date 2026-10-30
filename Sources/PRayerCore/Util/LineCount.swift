import Foundation

/// 줄 수를 탭·칩처럼 좁은 자리에 쓰는 꼴.
///
/// 1만 줄이 넘으면 줄여 쓴다(12,345 → "12.3k") — 상세 탭 줄 변경 파일 칸 아래의 "파일 N개 · +추가 −삭제" 가
/// 길어지면 그 칸만 넓어져 세 칸이 한 줄에 안 들어간다. 그보다 작으면 그대로 쓴다(자릿수 구분 쉼표도 넣지 않는다 — 목록 행과 같은 꼴).
public enum LineCount {
    public static func compact(_ count: Int) -> String {
        guard count >= 10_000 else { return String(count) }
        let thousands = Double(count) / 1000
        if thousands >= 100 { return "\(Int(thousands.rounded()))k" }
        let text = String(format: "%.1f", thousands)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
    }
}
