import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Fork.app 의 변경 파일 트리에서 실측한 값들.
/// 근거: `FileListViewController.nib` 의 `Fork.ChangedFileOutlineView` / `FileListFolderCellView`
/// / `FileListCellView` 아카이브 값. 폰트는 `.AppleSystemUIFont 13.0`(= `NSFont.systemFont(ofSize:13)`),
/// 들여쓰기 16, 아이콘 15pt, 선택은 좌우 10pt 인셋에 반경 6pt.
enum ForkTree {
    /// 행 높이. Fork 는 macOS 26 이상에서 20, 그 아래에서 18 을 쓴다.
    static let rowHeight: CGFloat = ProcessInfo.processInfo
        .isOperatingSystemAtLeast(.init(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 20 : 18
    static let rowSpacing: CGFloat = 2
    static let indentPerLevel: CGFloat = 16
    static let disclosureWidth: CGFloat = 13
    static let gutter: CGFloat = 2
    static let iconLeading: CGFloat = 6
    static let iconSize: CGFloat = 15
    static let statusSize: CGFloat = 14
    static let statusToIcon: CGFloat = 4
    static let iconToTextFolder: CGFloat = 4
    static let iconToTextFile: CGFloat = 6
    static let selectionInset: CGFloat = 10
    static let selectionRadius: CGFloat = 6

    static let font = Font.system(size: 13)
    /// 오른쪽 +144 −0 은 자릿수가 흔들리지 않게 monospaced digit 을 쓴다.
    static let statFont = Font.system(size: 13).monospacedDigit()
    /// diff 본문. Fork 기본값은 Menlo 11(설정에서 변경 가능)이라 같은 것을 쓴다.
    static let codeFont = Font.custom("Menlo", fixedSize: 11)
    @MainActor
    static var codeNSFont: NSFont { NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular) }
}

/// Finder 와 같은 실제 시스템 아이콘. Fork 도 SF Symbol 이 아니라 이것을 쓴다.
/// 확장자별 조회는 LaunchServices 를 타므로 반드시 캐시한다(행마다 부르면 스크롤이 끊긴다).
@MainActor
enum SystemIcon {
    private static var cache: [String: NSImage] = [:]

    static let folder: NSImage = {
        let image = NSWorkspace.shared.icon(for: .folder)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    static func file(_ path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        cache[ext] = image
        return image
    }
}

struct SystemIconView: View {
    let image: NSImage
    var side: CGFloat = ForkTree.iconSize

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
    }
}
