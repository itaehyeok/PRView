import Foundation

/// diff 에서 이미지로 다뤄야 할 파일. 코드로 보여 봐야 읽을 수 없다.
public enum ImageFiles {
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico",
    ]

    public static func isImage(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isVector(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "svg"
    }

    /// SVG 처럼 텍스트로 된 이미지는 diff 만으로 새 내용을 복원할 수 있다(추가 API 호출이 필요 없다).
    /// 추가된 파일이면 추가 줄이 곧 전체 내용이다.
    public static func reconstructedText(from file: DiffFile) -> String? {
        guard isVector(file.path), file.isNew else { return nil }
        let body = file.lines
            .filter { $0.kind == .addition }
            .map(\.text)
            .joined(separator: "\n")
        return body.isEmpty ? nil : body
    }

    /// 사람이 읽는 용량 표기.
    public static func byteSizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
    }
}
