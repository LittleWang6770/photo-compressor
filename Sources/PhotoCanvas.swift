import AppKit
import SwiftUI

struct PhotoCanvas: NSViewRepresentable {
    let image: CGImage
    var actualPixels = false
    @Binding var center: CGPoint
    func makeNSView(context: Context) -> CanvasView { CanvasView() }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.image = image; view.actualPixels = actualPixels; view.center = center
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(actualPixels ? "100% 照片细节" : "完整照片")
        view.setAccessibilityHelp("点击或拖动查看；方向键移动，Shift 加方向键快速移动。")
        view.changed = { center = $0 }; view.needsDisplay = true
    }
}

final class CanvasView: NSView {
    var image: CGImage?
    var actualPixels = false
    var center = CGPoint(x: 0.5,y: 0.5)
    var changed: ((CGPoint) -> Void)?
    private var start: CGPoint = .zero
    private var initialCenter: CGPoint = .zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.94,green:0.95,blue:0.95,alpha:1).setFill(); bounds.fill()
        guard let image, let c = NSGraphicsContext.current?.cgContext else { return }
        let scale = actualPixels ? 1 / (window?.backingScaleFactor ?? 2) : min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        let origin = actualPixels ? CGPoint(x:bounds.midX-center.x*size.width,y:bounds.midY-center.y*size.height) : CGPoint(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2)
        c.saveGState(); c.clip(to:bounds)
        c.translateBy(x:origin.x,y:origin.y+size.height); c.scaleBy(x:1,y:-1)
        c.interpolationQuality = actualPixels ? .none : .high
        c.draw(image,in:CGRect(origin:.zero,size:size)); c.restoreGState()
        if !actualPixels {
            let p = CGPoint(x:origin.x+center.x*size.width,y:origin.y+center.y*size.height)
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor); c.setLineWidth(1)
            c.stroke(CGRect(x:p.x-10,y:p.y-10,width:20,height:20))
        }
        if window?.firstResponder === self {
            c.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); c.setLineWidth(3)
            c.stroke(bounds.insetBy(dx:2,dy:2))
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow,from:nil); initialCenter = center
        if !actualPixels { setPoint(start) }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        guard let image else { return }
        if actualPixels {
            let backing = window?.backingScaleFactor ?? 2
            publish(CGPoint(x:initialCenter.x-(point.x-start.x)*backing/CGFloat(image.width),y:initialCenter.y-(point.y-start.y)*backing/CGFloat(image.height)))
        } else { setPoint(point) }
    }
    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.02
        switch event.keyCode {
        case 123: publish(CGPoint(x:center.x-step,y:center.y))
        case 124: publish(CGPoint(x:center.x+step,y:center.y))
        case 125: publish(CGPoint(x:center.x,y:center.y+step))
        case 126: publish(CGPoint(x:center.x,y:center.y-step))
        default: super.keyDown(with:event)
        }
    }
    private func setPoint(_ point: CGPoint) {
        guard let image else { return }
        let scale = min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height))
        let w = CGFloat(image.width)*scale,h = CGFloat(image.height)*scale
        publish(CGPoint(x:(point.x-(bounds.width-w)/2)/w,y:(point.y-(bounds.height-h)/2)/h))
    }
    private func publish(_ point: CGPoint) {
        center = CGPoint(x:min(1,max(0,point.x)),y:min(1,max(0,point.y))); changed?(center); needsDisplay = true
    }
}
