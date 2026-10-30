// 창 캡처 PNG 의 바깥에 얇은 테두리를 두른다(shoot.sh 가 swiftc 로 빌드해 캡처 직후 부른다).
//   border <PNG> [두께 px, 기본 4]   — 그 파일을 바꿔 쓴다. 캔버스는 두께만큼 사방으로 커진다.
// 라이트 모드 창은 가장자리가 흰색이라 GitHub 흰 바탕 README 에서 경계가 안 보였다(사용자: "테두리가 살짝 있으면
// 보기 편할 것 같다"). 사각형이 아니라 불투명한 모양을 넓혀서 그리므로 창의 둥근 모서리를 그대로 따라간다.
// 색은 반투명 회색 하나 — 흰 바탕에서는 GitHub 구분선(#d0d7de)쯤, 어두운 바탕에서도 살짝 보인다.
// 두께 4px: README 는 3440px 그림을 약 880pt 로 줄여 보여서 2px(=1pt)는 0.5pt 로 거의 사라졌고, 6px 는 진했다(나란히 비교).
// 한 장에 두 번 돌리면 테두리가 두 겹이 된다. 새로 찍은 캡처에만 쓴다.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3 else {
    FileHandle.standardError.write(Data("사용법: border <PNG> [두께 px]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let width = args.count == 3 ? Double(args[2]) ?? 4 : 4

guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("❌ PNG 를 읽지 못했습니다: \(url.path)\n".utf8))
    exit(1)
}
let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

let image = CIImage(cgImage: cgImage)
let gray: CGFloat = 0.5
let opacity: CGFloat = 0.35
let border = image
    .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width])
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
        "inputBiasVector": CIVector(x: gray, y: gray, z: gray, w: 0),
    ])
let output = image.composited(over: border)
let rect = image.extent.insetBy(dx: -width, dy: -width)

let context = CIContext(options: [.workingColorSpace: colorSpace])
guard let rendered = context.createCGImage(output, from: rect, format: .RGBA8, colorSpace: colorSpace),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("❌ 테두리를 그리지 못했습니다: \(url.path)\n".utf8))
    exit(1)
}
// 해상도 표시(144 dpi)를 그대로 둔다 — 미리보기에서 Retina 원래 크기로 열린다.
var keep: [CFString: Any] = [:]
for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { keep[key] = properties[key] }
CGImageDestinationAddImage(destination, rendered, keep as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("❌ 저장하지 못했습니다: \(url.path)\n".utf8))
    exit(1)
}
