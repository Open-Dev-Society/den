// Draws the DMG window's background (660 × 400, plus @2x):  cd app/Release && swift background.swift
// Den sits at (170, 190) and Applications at (490, 190), as dmg.py places them; the arrow runs between the two.
import AppKit
import SwiftUI

let blue = Color(red: 0.2, green: 0.5, blue: 0.97)

struct Arrow: Shape {
    var head = false
    func path(in _: CGRect) -> Path {
        let start = CGPoint(x: 264, y: 192), end = CGPoint(x: 396, y: 192), bend = CGPoint(x: 330, y: 158)
        var p = Path()
        guard head else {
            p.move(to: start)
            p.addQuadCurve(to: end, control: bend)
            return p
        }
        let a = atan2(end.y - bend.y, end.x - bend.x) // the head follows the curve's direction where it lands
        for turn in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
            p.move(to: end)
            p.addLine(to: CGPoint(x: end.x + 12 * cos(a + turn), y: end.y + 12 * sin(a + turn)))
        }
        return p
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.988, green: 0.991, blue: 0.998), Color(red: 0.933, green: 0.946, blue: 0.97)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [blue.opacity(0.09), .clear], center: UnitPoint(x: 0.5, y: 0.46), startRadius: 0, endRadius: 250)
            Arrow().stroke(blue.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.1, 7]))
            Arrow(head: true).stroke(blue.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            VStack(spacing: 9) {
                Text("Drag Den into Applications")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 0.11, green: 0.14, blue: 0.2).opacity(0.85))
                HStack(spacing: 7) {
                    Text("ALPHA").font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(blue)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(blue.opacity(0.12)))
                    Text("Not a public release · please don't redistribute")
                        .font(.system(size: 11.5)).foregroundStyle(Color(red: 0.45, green: 0.49, blue: 0.56))
                }
            }
            .position(x: 330, y: 330)
        }
        .frame(width: 660, height: 400)
        .environment(\.colorScheme, .light)
    }
}

MainActor.assumeIsolated {
    for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
        let r = ImageRenderer(content: Background())
        r.scale = scale
        let rep = NSBitmapImageRep(cgImage: r.cgImage!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
    }
}
