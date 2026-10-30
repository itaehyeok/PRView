import SwiftUI
import AppKit
import PRayerCore

/// 코멘트 속 인라인 코드(`이런 것`)의 모양 — 기본은 흰 바탕·회색 테두리의 둥근 상자에 파랑 글자(사용자 결정 2026-10-28).
/// 붉은 글자(시안 4번) → 회청(시안 10번)을 거쳐, 앱 안 조절 칸에서 사용자가 직접 바꿔 보고 종이 + 파랑으로 정했다(칸은 정한 뒤 뺐다).
///
/// SwiftUI 글자 바탕색(`backgroundColor`)은 모서리도 여백도 없이 글자에 딱 붙는다. 그래서 macOS 15 이상에서는
/// `TextRenderer` 로 인라인 코드 줄 조각 뒤에 둥근 상자를 직접 그린다. 앞뒤 여백은 글자를 끼워 넣지 않고 글자 간격(kern)으로
/// 띄운다 — 빈칸을 넣으면 복사한 코드에 빈칸이 묻어난다. macOS 14 는 평평한 바탕으로 대신한다.
///
/// 글자 선택(`textSelection(.enabled)`)이 켜진 Text 는 TextRenderer 를 쓰지 않는다(실측: 렌더러가 한 번도 불리지 않음).
/// 코멘트는 복사할 수 있어야 하므로, 같은 글을 선택이 꺼진 채 뒤에 한 겹 더 깔아 그 겹에서 상자만 그린다(InlineCodeText).
/// 두 겹은 같은 크기를 받고 같은 글꼴·줄 간격을 물려받아 똑같이 줄바꿈된다.
///
/// 색·굵기·여백 같은 값은 InlineCodeLook.standard 에 있다.
enum InlineCodeStyle {
    static let current = InlineCodeLook.standard
}

/// 인라인 코드 조각 표시. TextRenderer 가 이 표시가 붙은 줄 조각에만 상자를 그린다.
/// `link` 는 diff 에서 위치를 찾은 조각의 번호(InlineCodeText.links 의 자리)다.
struct InlineCodeAttribute: TextAttribute {
    var link: Int?
}

/// 누를 수 있는 코드 상자 하나. 줄을 넘는 코드는 줄마다 하나씩 생긴다.
struct CodeHotspot: Hashable {
    let link: Int
    let rect: CGRect
}

/// 올려 두면 코드가 뜨는 인라인 코드의 상자 오른쪽 끝에 다는 작은 눈 표식. diff 에서 찾은 코드만 미리 볼 수 있어서,
/// 상자 모양만으로는 어느 것의 코드를 볼 수 있는지 알 수 없었다(사용자 요청, 2026-10-28).
/// 자리는 코드 마지막 글자의 kern 으로 비워 두고(MarkdownText.inline), 그림은 상자 겹(InlineCodeBoxes)이 그린다.
enum CodeLinkMark {
    static let symbol = "eye"
    /// 코드 글자 크기에 대한 표식 크기.
    static let scale: CGFloat = 0.8
    /// 코드 끝과 표식 사이, 코드 글자 크기에 대한 비율.
    static let gap: CGFloat = 0.3
    static let opacity: Double = 0.7

    /// 표식 칸의 폭. 눈 기호는 글자 크기보다 넓다(약 1.3배) — 넉넉히 잡고 가운데에 그린다.
    static func width(codeSize: CGFloat) -> CGFloat { codeSize * scale * 1.4 }

    /// 코드 끝에 더 비울 폭.
    static func space(codeSize: CGFloat) -> CGFloat { codeSize * gap + width(codeSize: codeSize) }
}

/// 인라인 코드 줄 조각 뒤에 상자만 그린다. 글자는 앞 겹(선택되는 Text)이 그린다.
@available(macOS 15.0, *)
struct InlineCodeBoxes: TextRenderer {
    /// 기준 글자 크기 — 여백을 글자 크기에 비례해 잡는다.
    let size: CGFloat
    /// 그리는 쪽은 메인 액터 밖이라 모양을 값으로 받는다.
    let look: InlineCodeLook
    /// 누를 수 있는 코드 상자의 자리를 알린다. 글 배치는 그리는 이 자리에서만 알 수 있다.
    var onLayout: (([CodeHotspot]) -> Void)?

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let horizontal = size * look.horizontalPadding
        let vertical = size * look.verticalPadding
        let fillColor = look.fill
        let borderColor = look.hasBorder ? look.border : nil
        var hotspots: [CodeHotspot] = []
        // 누를 수 있는 코드마다 마지막 상자. 표식 자리는 코드 마지막 글자 뒤에만 비워 두었다 — 줄을 넘는 코드는 끝 줄 상자다.
        var lastBoxes: [Int: CGRect] = [:]

        /// 앞 여백은 앞 글자의 kern 으로, 뒤 여백은 코드 마지막 글자의 kern 으로 비워 두었다(MarkdownText.inline).
        /// 그래서 조각의 오른쪽 끝은 이미 여백을 품고, 왼쪽만 여백만큼 넓힌다.
        func fill(_ bounds: CGRect, link: Int?) {
            let box = CGRect(x: bounds.minX - horizontal, y: bounds.minY - vertical,
                             width: bounds.width + horizontal, height: bounds.height + vertical * 2)
            context.fill(Path(roundedRect: box, cornerRadius: look.cornerRadius), with: .color(fillColor))
            if let borderColor {
                let inset = look.borderWidth / 2
                context.stroke(Path(roundedRect: box.insetBy(dx: inset, dy: inset), cornerRadius: look.cornerRadius),
                               with: .color(borderColor), lineWidth: look.borderWidth)
            }
            if let link {
                hotspots.append(CodeHotspot(link: link, rect: box))
                lastBoxes[link] = box
            }
        }

        for line in layout {
            // 한글이 섞인 코드는 글꼴이 바뀌는 자리마다 줄 조각이 나뉜다. 이어진 코드 조각은 상자 하나로 합친다 —
            // 조각마다 그리면 `맨 앞 코드` 가 상자 셋으로 갈라졌다. 붙어 있어도 다른 코드 조각이면 나눈다.
            var pending: (bounds: CGRect, link: Int?)?
            for run in line {
                if let code = run[InlineCodeAttribute.self] {
                    let bounds = run.typographicBounds.rect
                    if let current = pending, current.link == code.link {
                        pending = (current.bounds.union(bounds), code.link)
                    } else {
                        if let current = pending { fill(current.bounds, link: current.link) }
                        pending = (bounds, code.link)
                    }
                } else if let current = pending {
                    fill(current.bounds, link: current.link)
                    pending = nil
                }
            }
            if let current = pending {
                fill(current.bounds, link: current.link)
            }
        }
        let codeSize = size * look.fontScale
        let markWidth = CodeLinkMark.width(codeSize: codeSize)
        for box in lastBoxes.values {
            let mark = Text(Image(systemName: CodeLinkMark.symbol))
                .font(.system(size: codeSize * CodeLinkMark.scale))
                .foregroundStyle(look.text.opacity(CodeLinkMark.opacity))
            context.draw(mark, at: CGPoint(x: box.maxX - horizontal - markWidth / 2, y: box.midY), anchor: .center)
        }
        onLayout?(hotspots)
    }
}

/// 줄 안 서식을 입힌 글 한 덩어리. 인라인 코드가 있으면 뒤에 상자 겹을 깐다.
///
/// diff 에서 위치를 찾은 코드(`links`)는 그 상자 자리에 투명한 단추를 얹고 상자 끝에 눈 표식(CodeLinkMark)을 단다 — 잠시
/// 올려 두면 그 자리 코드가 뜨고, 누르면 diff 로 간다(예전엔 같은 것을 코멘트 아래 칩으로 따로 모았다). 상자 자리는 뒤 겹의
/// TextRenderer 가 그리면서 알려 준다.
/// macOS 14 는 렌더러가 없어 상자도 단추도 없다.
struct InlineCodeText: View {
    let text: Text
    let hasCode: Bool
    let size: CGFloat
    var links: [CodeReference] = []
    var context: CodeLinkContext?
    @State private var hotspots: [CodeHotspot] = []

    var body: some View {
        if hasCode, #available(macOS 15.0, *) {
            text
                .background { boxes }
                .overlay(alignment: .topLeading) { buttons }
        } else {
            text
        }
    }

    @available(macOS 15.0, *)
    private var boxes: some View {
        let renderer = InlineCodeBoxes(size: size, look: InlineCodeStyle.current, onLayout: isLinked ? { report($0) } : nil)
        return text
            .textSelection(.disabled)
            .textRenderer(renderer)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var buttons: some View {
        if let context, isLinked {
            ForEach(hotspots, id: \.self) { spot in
                hotspotButton(spot, context: context)
            }
        }
    }

    private func hotspotButton(_ spot: CodeHotspot, context: CodeLinkContext) -> some View {
        CodeLink(reference: links[spot.link], context: context) { isHovering in
            // 이 단추는 글자 위 겹이다. 상자 바탕색으로 칠하면 코드 글자를 덮어 빈 상자가 됐다 — 비치는 글자색으로 살짝 덮는다.
            RoundedRectangle(cornerRadius: InlineCodeStyle.current.cornerRadius)
                .fill(isHovering ? InlineCodeStyle.current.text.opacity(0.14) : Color.clear)
                .frame(width: spot.rect.width, height: spot.rect.height)
        }
        // offset 은 그림만 옮겨 팝오버가 엉뚱한 자리에 붙는다 — 배치째 옮긴다.
        .padding(EdgeInsets(top: spot.rect.minY, leading: spot.rect.minX, bottom: 0, trailing: 0))
    }

    private var isLinked: Bool { context != nil && !links.isEmpty }

    /// 그리는 도중에는 상태를 바꿀 수 없어 다음 차례로 미룬다. 자리가 그대로면 건드리지 않는다 — 바꾸면 다시 그려 끝없이 돈다.
    private func report(_ spots: [CodeHotspot]) {
        let valid = spots.filter { links.indices.contains($0.link) }
        let binding = $hotspots
        DispatchQueue.main.async {
            if binding.wrappedValue != valid {
                binding.wrappedValue = valid
            }
        }
    }
}
