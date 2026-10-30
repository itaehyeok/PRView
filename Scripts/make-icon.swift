// PRView 앱 아이콘(코드 문서 + 돋보기 라인 아트)을 그린다.
//
//   swift Scripts/make-icon.swift
//
// 크림 바탕에 검은 선으로 그린 흰 코드 문서 하나와, 그 오른쪽 아래를 덮은 복숭아색 렌즈의 돋보기.
// 문서 가운데 줄과 렌즈 안 "+ ──" 만 주황이다 — 렌즈가 추가된 줄을 키워 보는 그림(사용자가 고른 시안
// "C-6 흰 종이 + 주황 줄", 2026-10-20). 이름을 PRayer → PRView 로 바꾸면서 촛불(기도 말장난, 2026-10-19)을
// 갈아 끼웠다. 선 굵기·색·바탕은 촛불 때 그대로 두어 그림체를 잇는다.
// 그 전 아이콘은 🙏 이모지(애플 그림)라 공개 배포에 쓰기 곤란해서 직접 그린 그림으로 바꿨었다.
//
// macOS 아이콘 격자를 따른다: 1024 캔버스 안에 824 짜리 둥근 사각형(모서리 반지름 185)을
// 가운데 둔다. 캔버스 가장자리까지 채우면 Dock 에서 다른 앱보다 크게 보인다.
// 그림은 100 단위 격자(시안 SVG 와 같은 좌표)로 적고, 824 몸통에 맞춰 늘린다.
//
// 세 벌을 만든다(사용자 결정, 2026-10-19):
// - AppIcon      정식 — 띠 없는 그림. 베타도 같은 파일이라(승격은 zip 을 그대로 옮긴다) 앱 파일 아이콘은 이것이다.
// - AppIconDev   개발 빌드(Debug) — 오른쪽 위 모서리에 노란 DEV 띠(위아래 가장자리 공사 줄무늬).
//                project.yml 이 Debug 구성에서 이 세트를 앱 아이콘으로 쓴다.
// - AppIconBeta  베타 — 오른쪽 위 보라 BETA 띠. 앱 파일 아이콘으로는 못 쓰고, 앱이 켜져 있을 때
//                베타로 판정되면(AppModel.buildKind) Dock·⌘Tab 아이콘으로 바꿔 끼운다(이미지 애셋).
import AppKit

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let cream = rgb(0xFBF5EA)
let paper = rgb(0xFFFFFF)
let ink = rgb(0x2A2A2A)
let accent = rgb(0xE8743B)
let accentFill = rgb(0xFFD9B8)

enum Ribbon { case beta, dev }

func drawIcon(size S: CGFloat, ribbon: Ribbon?, into ctx: CGContext) {
    let k = S / 1024                       // 1024 기준으로 그리고 배율만 곱한다
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let radius = 185 * k

    // 바탕. 다른 Mac 아이콘처럼 아래로 옅은 그림자를 둔다(크림색이 흰 화면에서 떠 보이게).
    let bg = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(bg)
    ctx.setFillColor(cream)
    ctx.fillPath()
    ctx.restoreGState()

    // 100 단위 격자 → 몸통. 시안 SVG 는 y 가 아래로 자라므로 뒤집는다.
    let unit = 824 * k / 100
    var grid = CGAffineTransform(translationX: body.minX, y: body.maxY).scaledBy(x: unit, y: -unit)
    func path(_ build: (CGMutablePath) -> Void) -> CGPath {
        let p = CGMutablePath()
        build(p)
        return p.copy(using: &grid) ?? p
    }
    ctx.setLineWidth(3 * unit)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    func stroke(_ p: CGPath, _ color: CGColor) {
        ctx.addPath(p)
        ctx.setStrokeColor(color)
        ctx.strokePath()
    }
    func fill(_ p: CGPath, _ color: CGColor) {
        ctx.addPath(p)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    // 코드 문서 — 흰 종이에 검은 테
    let paperPath = path { p in
        p.addRoundedRect(in: CGRect(x: 24, y: 16, width: 40, height: 54), cornerWidth: 4, cornerHeight: 4)
    }
    fill(paperPath, paper)
    stroke(paperPath, ink)

    // 코드 줄. 가운데 줄만 주황 — 렌즈가 키워 보여 주는 "추가된 줄" 이다.
    stroke(path { p in
        p.move(to: CGPoint(x: 32, y: 28)); p.addLine(to: CGPoint(x: 56, y: 28))
        p.move(to: CGPoint(x: 32, y: 44)); p.addLine(to: CGPoint(x: 44, y: 44))
    }, ink)
    stroke(path { p in
        p.move(to: CGPoint(x: 32, y: 36)); p.addLine(to: CGPoint(x: 50, y: 36))
    }, accent)

    // 돋보기 — 복숭아색 렌즈와 45° 로 뻗은 손잡이. 렌즈가 문서 오른쪽 아래를 덮는다.
    let lens = path { p in
        p.addEllipse(in: CGRect(x: 47, y: 47, width: 30, height: 30))
    }
    fill(lens, accentFill)
    stroke(lens, ink)
    stroke(path { p in
        p.addRoundedRect(in: CGRect(x: 17, y: -4.5, width: 15, height: 9), cornerWidth: 4.5, cornerHeight: 4.5,
                         transform: CGAffineTransform(translationX: 62, y: 62).rotated(by: .pi / 4))
    }, ink)

    // 렌즈 안: "+ ──" 추가된 줄
    stroke(path { p in
        p.move(to: CGPoint(x: 55.5, y: 58.5)); p.addLine(to: CGPoint(x: 55.5, y: 65.5))
        p.move(to: CGPoint(x: 52, y: 62)); p.addLine(to: CGPoint(x: 59, y: 62))
        p.move(to: CGPoint(x: 63, y: 62)); p.addLine(to: CGPoint(x: 70, y: 62))
    }, accent)

    if let ribbon {
        drawRibbon(ribbon, clip: bg, grid: grid, into: ctx)
    }
}

/// 오른쪽 위 모서리를 45° 로 가로지르는 띠. 몸통 밖으로 나간 부분은 잘라 낸다.
/// 좌표는 띠 가운데(격자 82,18)를 원점으로, 띠 방향을 x 로 둔다(y 는 아래로).
func drawRibbon(_ ribbon: Ribbon, clip body: CGPath, grid: CGAffineTransform, into ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.concatenate(grid)
    ctx.translateBy(x: 82, y: 18)
    ctx.rotate(by: .pi / 4)

    let text: String
    let textColor: CGColor
    switch ribbon {
    case .beta:
        ctx.setFillColor(rgb(0x6E56CF))
        ctx.fill(CGRect(x: -30, y: -7, width: 60, height: 14))
        text = "BETA"
        textColor = rgb(0xFFFFFF)
    case .dev:
        // 위아래 가장자리만 공사 줄무늬, 가운데는 노란 띠.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -30, y: -9, width: 60, height: 18))
        ctx.setFillColor(rgb(0xF5C518))
        ctx.fill(CGRect(x: -30, y: -9, width: 60, height: 18))
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.butt)
        for offset in stride(from: -50.0, through: 50.0, by: 5.0) {
            ctx.move(to: CGPoint(x: offset - 10, y: 10))
            ctx.addLine(to: CGPoint(x: offset + 10, y: -10))
        }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xF5C518))
        ctx.fill(CGRect(x: -30, y: -6, width: 60, height: 12))
        text = "DEV"
        textColor = ink
    }

    // 글자는 y 가 위로 자라야 바로 선다. 띠 가운데에 놓는다(시안의 기준선: 가운데에서 3.2 아래).
    let font = NSFont.systemFont(ofSize: 9, weight: .bold)
    let string = NSAttributedString(string: text, attributes: [
        .font: font, .kern: 0.6, .foregroundColor: NSColor(cgColor: textColor) ?? .white,
    ])
    let line = CTLineCreateWithAttributedString(string)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: -width / 2, y: -3.2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func png(size: Int, ribbon: Ribbon? = nil) -> Data {
    let S = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("컨텍스트를 만들지 못했다")
    }
    ctx.interpolationQuality = .high
    drawIcon(size: S, ribbon: ribbon, into: ctx)
    guard let image = ctx.makeImage() else { fatalError("이미지를 만들지 못했다") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: S, height: S)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 인코딩 실패") }
    return data
}

let fm = FileManager.default
let work = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("PRayerIcon-\(ProcessInfo.processInfo.processIdentifier)")
try? fm.removeItem(at: work)
try fm.createDirectory(at: work, withIntermediateDirectories: true)

// Xcode 가 애셋 카탈로그에서 최종 .icns 를 만든다.
let catalog = URL(fileURLWithPath: "Resources/Assets.xcassets").standardizedFileURL
try #"{"info":{"author":"xcode","version":1}}"#
    .write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

/// 앱 아이콘 세트(크기별 PNG 10장).
func writeAppIconSet(_ name: String, ribbon: Ribbon?) throws {
    let set = catalog.appendingPathComponent("\(name).appiconset")
    try? fm.removeItem(at: set)
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [String] = []
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try png(size: base * scale, ribbon: ribbon).write(to: set.appendingPathComponent(file))
            images.append("""
                {"idiom":"mac","size":"\(base)x\(base)","scale":"\(scale)x","filename":"\(file)"}
            """)
        }
    }
    try """
    {"images":[\(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}
    """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

try writeAppIconSet("AppIcon", ribbon: nil)
try writeAppIconSet("AppIconDev", ribbon: .dev)

// 베타 아이콘은 실행 중에 Dock 에 바꿔 끼우는 그림이라 이미지 애셋 한 장(1024)이면 된다.
let beta = catalog.appendingPathComponent("AppIconBeta.imageset")
try? fm.removeItem(at: beta)
try fm.createDirectory(at: beta, withIntermediateDirectories: true)
try png(size: 1024, ribbon: .beta).write(to: beta.appendingPathComponent("AppIconBeta.png"))
try #"{"images":[{"idiom":"universal","filename":"AppIconBeta.png"}],"info":{"author":"xcode","version":1}}"#
    .write(to: beta.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// 미리보기용 큰 PNG 도 함께 남긴다(문서·확인용).
for (label, ribbon) in [("release", nil), ("beta", Ribbon.beta), ("dev", Ribbon.dev)] as [(String, Ribbon?)] {
    try png(size: 512, ribbon: ribbon).write(to: work.appendingPathComponent("preview-\(label).png"))
}
print("카탈로그: \(catalog.path)")
print("미리보기: \(work.path)")
