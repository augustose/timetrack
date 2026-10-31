#!/usr/bin/env swift
//
// Draws the TimeTrack app icon and writes a 1024x1024 PNG.
//
//   swift scripts/make-icon.swift Resources/icon-1024.png
//
// make-icon.sh turns that PNG into AppIcon.icns.
//
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824pt squircle centred in the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1B1F4B))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: deep indigo to teal.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let bg = CGGradient(colorsSpace: space, colors: [color(0x2B2F77), color(0x0E8F9A)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY),
                       end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Gentle highlight along the top edge.
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY),
                       options: [])
ctx.restoreGState()

// Stopwatch.
let center = CGPoint(x: 512, y: 480)
let radius: CGFloat = 250
ctx.setLineCap(.round)

// Crown and side button.
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(46)
ctx.move(to: CGPoint(x: center.x, y: center.y + radius + 24))
ctx.addLine(to: CGPoint(x: center.x, y: center.y + radius + 84))
ctx.strokePath()
ctx.setLineWidth(40)
ctx.move(to: CGPoint(x: center.x - 60, y: center.y + radius + 92))
ctx.addLine(to: CGPoint(x: center.x + 60, y: center.y + radius + 92))
ctx.strokePath()
ctx.setLineWidth(36)
let a = CGFloat.pi / 4
ctx.move(to: CGPoint(x: center.x + cos(a) * (radius + 36), y: center.y + sin(a) * (radius + 36)))
ctx.addLine(to: CGPoint(x: center.x + cos(a) * (radius + 84), y: center.y + sin(a) * (radius + 84)))
ctx.strokePath()

// Dial: dim ring, bright progress arc from 12 o'clock clockwise (about 70%).
ctx.setLineWidth(52)
ctx.setStrokeColor(color(0xFFFFFF, 0.28))
ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

let top = CGFloat.pi / 2
ctx.setStrokeColor(color(0xFFD166))
ctx.addArc(center: center, radius: radius, startAngle: top, endAngle: top - .pi * 2 * 0.70, clockwise: true)
ctx.strokePath()

// Hand pointing at the end of the arc, plus hub.
let handAngle = top - .pi * 2 * 0.70
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(40)
ctx.move(to: center)
ctx.addLine(to: CGPoint(x: center.x + cos(handAngle) * (radius - 70),
                        y: center.y + sin(handAngle) * (radius - 70)))
ctx.strokePath()
ctx.setFillColor(color(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
