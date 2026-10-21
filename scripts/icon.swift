import AppKit
let root = URL(fileURLWithPath:CommandLine.arguments[1])
let iconSet = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at:iconSet,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        NSColor(calibratedRed:0.918,green:0.941,blue:0.957,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:52,y:52,width:920,height:920),xRadius:205,yRadius:205).fill()
        let symbol = NSImage(systemSymbolName:"photo",accessibilityDescription:nil)!.withSymbolConfiguration(.init(paletteColors:[NSColor(calibratedRed:0.239,green:0.392,blue:0.478,alpha:1)]))!
        symbol.draw(in:NSRect(x:200,y:255,width:625,height:560))
        NSColor(calibratedRed:0.918,green:0.941,blue:0.957,alpha:1).setFill()
        NSBezierPath(ovalIn:NSRect(x:660,y:155,width:235,height:235)).fill()
        let arrows = NSImage(systemSymbolName:"arrow.down.right.and.arrow.up.left",accessibilityDescription:nil)!.withSymbolConfiguration(.init(paletteColors:[NSColor(calibratedRed:0.239,green:0.392,blue:0.478,alpha:1)]))!
        arrows.draw(in:NSRect(x:693,y:190,width:165,height:165))
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using:.png,properties:[:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to:iconSet.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024 { try data.write(to:root.appendingPathComponent("Resources/AppIcon.png")) }
    }
}
