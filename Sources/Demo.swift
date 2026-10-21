import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

enum DemoFactory {
    // Entirely synthetic; UI checks never touch the user's photo library.
    static func make(at url: URL, width: Int = 2400, height: Int = 1600, type: UTType = .jpeg, orientation: Int = 1) throws {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AppFailure("示例画布创建失败") }
        c.scaleBy(x: CGFloat(width) / 2400, y: CGFloat(height) / 1600)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { c.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)) }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.79, green: 0.85, blue: 0.85, alpha: 1), CGColor(red: 0.30, green: 0.48, blue: 0.57, alpha: 1)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1600), options: [])
        func polygon(_ points: [CGPoint], _ shade: (CGFloat, CGFloat, CGFloat)) {
            color(shade.0, shade.1, shade.2); c.beginPath(); c.addLines(between: points); c.closePath(); c.fillPath()
        }
        polygon([.init(x:0,y:450),.init(x:0,y:1000),.init(x:350,y:1320),.init(x:730,y:890),.init(x:1080,y:1380),.init(x:1590,y:810),.init(x:2100,y:1240),.init(x:2400,y:980),.init(x:2400,y:400)], (0.45,0.57,0.58))
        polygon([.init(x:0,y:180),.init(x:0,y:720),.init(x:550,y:1030),.init(x:1030,y:630),.init(x:1580,y:1080),.init(x:2400,y:600),.init(x:2400,y:180)], (0.23,0.38,0.38))
        color(0.66,0.68,0.57); c.fill(CGRect(x:0,y:0,width:2400,height:400))
        polygon([.init(x:600,y:0),.init(x:1150,y:0),.init(x:1650,y:520),.init(x:1540,y:560)], (0.81,0.78,0.67))
        // Window frames, brick detail and foliage provide high-frequency comparison material.
        color(0.82,0.77,0.64); c.fill(CGRect(x:620,y:350,width:1060,height:650))
        polygon([.init(x:530,y:1000),.init(x:1150,y:1290),.init(x:1780,y:1000)], (0.32,0.35,0.34))
        c.setStrokeColor(CGColor(red:0.67,green:0.62,blue:0.52,alpha:1)); c.setLineWidth(1)
        for y in stride(from: 360, through: 995, by: 17) {
            c.move(to:.init(x:620,y:y)); c.addLine(to:.init(x:1680,y:y)); c.strokePath()
            for x in stride(from: 625 + (y % 34 == 0 ? 18 : 0), through: 1670, by: 36) {
                c.move(to:.init(x:x,y:y)); c.addLine(to:.init(x:x,y:y+17)); c.strokePath()
            }
        }
        for y in [460, 730] { for x in [710, 940, 1270, 1500] {
            color(0.91,0.88,0.77); c.fill(CGRect(x:x-12,y:y-12,width:148,height:210))
            color(0.20,0.29,0.31); c.fill(CGRect(x:x,y:y,width:124,height:186))
            color(0.53,0.64,0.63); c.fill(CGRect(x:x+6,y:y+96,width:52,height:82))
            color(0.74,0.74,0.62); c.fill(CGRect(x:x+60,y:y,width:4,height:186)); c.fill(CGRect(x:x,y:y+90,width:124,height:4))
        } }
        color(0.34,0.29,0.23); c.fill(CGRect(x:1100,y:350,width:110,height:230))
        var state: UInt64 = 73
        func random() -> CGFloat { state = state &* 6364136223846793005 &+ 1; return CGFloat((state >> 33) % 10000) / 10000 }
        for side in [0,1] {
            color(0.23,0.25,0.18); c.fill(CGRect(x:side == 0 ? 250 : 2040,y:220,width:40,height:850))
            for _ in 0..<4600 {
                let x = (side == 0 ? CGFloat(60) : CGFloat(1830)) + random()*450
                let y = 500 + random()*840
                let r = random()*0.12
                color(0.17+r,0.27+r,0.19+r*0.5)
                c.fillEllipse(in:CGRect(x:x,y:y,width:4+random()*16,height:3+random()*10))
            }
        }
        for _ in 0..<14000 {
            let x = random()*2400, y = random()*360
            color(0.39+random()*0.22,0.45+random()*0.17,0.29+random()*0.16)
            c.fill(CGRect(x:x,y:y,width:1+random()*3,height:2+random()*6))
        }
        let label = NSAttributedString(string: "山间来信  /  SYNTHETIC SAMPLE", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Medium" as CFString, 27, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red:0.95,green:0.95,blue:0.9,alpha:1)])
        c.textPosition = .init(x:75,y:75); CTLineDraw(CTLineCreateWithAttributedString(label), c)
        guard let image = c.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil) else { throw AppFailure("示例生成失败") }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.99, kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Synthetic", kCGImagePropertyTIFFModel: "Sample Camera", kCGImagePropertyTIFFDateTime: "2024:06:15 14:30:00"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Sample 35mm f/2", kCGImagePropertyExifDateTimeOriginal: "2024:06:15 14:30:00", kCGImagePropertyExifFNumber: 5.6, kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifUserComment: "Original user comment — 保留测试"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.23, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 121.47, kCGImagePropertyGPSLongitudeRef: "E"]]
        CGImageDestinationAddImage(d,image,props as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw AppFailure("示例编码失败") }
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_718_432_000), .modificationDate: Date(timeIntervalSince1970: 1_718_436_000)], ofItemAtPath: url.path)
    }
}
