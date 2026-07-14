// Renders the app icon: a Kármán vortex street, reduced to its signature —
// two staggered rows of counter-rotating vortices shed behind a cylinder,
// ember-on-charcoal to match the instrument. Flat fills only, no gradients.
// Usage: swift scripts/make-icon.swift <out.png>   (renders 1024×1024)
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let ctx = CGContext(data: nil, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = CGFloat(size)

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let charcoal = rgba(0.090, 0.086, 0.082)
let slate    = rgba(0.300, 0.280, 0.250)
let amber    = rgba(0.960, 0.630, 0.220)
let ember    = rgba(0.760, 0.240, 0.110)

// Background: the macOS squircle (approximated by a rounded rect at the
// Big-Sur-era corner ratio ~0.2237) filled flat.
let corner = s * 0.2237
let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.setFillColor(charcoal)
ctx.fillPath()

// A vortex: an open spiral, stroked in short segments whose width grows from
// the core outward — the line itself carries the sense of circulation.
func vortex(cx: CGFloat, cy: CGFloat, r: CGFloat, clockwise: Bool, color: CGColor, lwMax: CGFloat) {
    let turns: CGFloat = 1.65
    let steps = 300
    var prev: CGPoint? = nil
    ctx.setStrokeColor(color)
    ctx.setLineCap(.round)
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let ang = t * turns * 2 * .pi * (clockwise ? -1 : 1) + (clockwise ? .pi * 0.9 : -.pi * 0.1)
        let rad = r * (0.10 + 0.90 * t * t * (3 - 2 * t))   // smoothstep opening
        let p = CGPoint(x: cx + rad * cos(ang), y: cy + rad * sin(ang))
        if let q = prev {
            ctx.setLineWidth(lwMax * (0.25 + 0.75 * t))
            ctx.move(to: q)
            ctx.addLine(to: p)
            ctx.strokePath()
        }
        prev = p
    }
}

// The cylinder that sheds the street.
let cylR = s * 0.085
ctx.setFillColor(slate)
ctx.addEllipse(in: CGRect(x: s * 0.185 - cylR, y: s * 0.50 - cylR, width: cylR * 2, height: cylR * 2))
ctx.fillPath()

// One counter-rotating pair, large enough to read at 16 px. Top spins one
// way (amber), bottom the other (ember) — the Kármán street's signature.
vortex(cx: s * 0.480, cy: s * 0.625, r: s * 0.205, clockwise: false, color: amber, lwMax: s * 0.052)
vortex(cx: s * 0.715, cy: s * 0.390, r: s * 0.205, clockwise: true,  color: ember, lwMax: s * 0.052)

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
