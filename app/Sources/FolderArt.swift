import SwiftUI

// A folder that opens: its front tips back on a spring and three pages fan up out of it. A native take on
// uselayouts' folder-interaction (motion springs → SwiftUI springs; the front panel's outline is the same path).
// The pages show the folder's own latest files when there are some.

/// The front of the folder: a tab on the left, the body lower on the right, sides tapering a little towards the
/// bottom. Drawn in a 236 × 122 box, like the original SVG.
struct FolderFront: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 236, sy = r.height / 122
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        path.move(to: p(104.6, 0.35))
        path.addLine(to: p(9.9, 1))
        path.addQuadCurve(to: p(0.5, 11.3), control: p(0.6, 1.2))
        path.addLine(to: p(12.2, 114.4))
        path.addQuadCurve(to: p(21.3, 122), control: p(13.4, 122))
        path.addLine(to: p(215.4, 122))
        path.addQuadCurve(to: p(225.3, 114.35), control: p(224.2, 121.6))
        path.addLine(to: p(235.9, 53.4))
        path.addQuadCurve(to: p(226.6, 42.5), control: p(236.6, 42.5))
        path.addLine(to: p(146.7, 42.5))
        path.addQuadCurve(to: p(133.2, 35.2), control: p(138.3, 42.4))
        path.addLine(to: p(113.5, 5.06))
        path.addQuadCurve(to: p(104.6, 0.35), control: p(110.4, 0.6))
        path.closeSubpath()
        return path
    }
}

/// A sheet of paper, or a file's thumbnail.
struct FolderPage: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color(red: 0.81, green: 0.8, blue: 0.88)).frame(height: 3)
                    ForEach(0..<7, id: \.self) { _ in
                        HStack(spacing: 4) {
                            Capsule().fill(Color(red: 0.81, green: 0.8, blue: 0.88)).frame(height: 3)
                            Capsule().fill(Color(red: 0.81, green: 0.8, blue: 0.88)).frame(height: 3)
                        }
                    }
                }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(LinearGradient(colors: [Color(red: 0.91, green: 0.906, blue: 0.94), Color(red: 0.863, green: 0.855, blue: 0.91)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }
}

struct FolderArt: View {
    let open: Bool
    var pages: [NSImage] = []

    // where each page sits, closed and open: (rotation, x, y) in a 236 × 200 frame; nearly square, like a Finder folder
    private static let closed: [(Double, CGFloat, CGFloat)] = [(-3, -14, 10), (0, 0, 4), (3.5, 15, 10)]
    private static let opened: [(Double, CGFloat, CGFloat)] = [(-8, -46, -34), (1, 0, -50), (9, 48, -36)]

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / 236, w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                // the back
                RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.folderBack.mix(with: .white, by: 0.08), Theme.folderBack], startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.87, height: h * 0.9)
                // the pages: the middle one on top
                ForEach([0, 2, 1], id: \.self) { i in
                    let spot = open ? Self.opened[i] : Self.closed[i]
                    FolderPage(image: pages.indices.contains(i) ? pages[i] : nil)
                        .frame(width: 124 * k, height: 136 * k)
                        .rotationEffect(.degrees(spot.0))
                        .offset(x: spot.1 * k, y: spot.2 * k + 10 * k)
                        .animation(.spring(response: 0.42, dampingFraction: i == 1 ? 0.78 : 0.72), value: open)
                }
                // the front: frosted glass, so the pages show through it softly
                FolderFront()
                    .fill(.ultraThinMaterial)
                    .overlay(FolderFront().fill(LinearGradient(colors: [Theme.folderLid.mix(with: .white, by: 0.35).opacity(0.62), Theme.folderLid.opacity(0.86)],
                                                               startPoint: .top, endPoint: .bottom)))
                    .overlay(FolderFront().stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                                                  lineWidth: 1))
                    .frame(width: w + 2, height: h * 0.72)
                    .rotation3DEffect(.degrees(open ? -32 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.55)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .shadow(color: Theme.folderBack.opacity(0.28), radius: 10 * k, y: 6 * k)
                    .animation(.spring(response: 0.38, dampingFraction: 0.76), value: open)
            }
        }
        .aspectRatio(236 / 200, contentMode: .fit)
        .environment(\.colorScheme, .light) // a blue folder is the same blue folder in dark mode; its frost stays light
    }
}

/// A folder you can open: it fans its pages on hover and opens on click.
struct FolderCard: View {
    let title: String
    let subtitle: String
    let path: String?
    let action: () -> Void
    @State private var hover = false
    @State private var pages: [NSImage] = []

    var body: some View {
        VStack(spacing: 10) {
            FolderArt(open: hover, pages: pages).frame(width: 150)
                .padding(.top, 22) // room for the pages to rise
            VStack(spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .task(id: path) {
            guard let path else { return }
            // the three newest files inside, as thumbnails; the listing happens off the main thread
            let newest = await Task.detached {
                ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                              options: .skipsHiddenFiles)) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
                    .prefix(3).map(\.path)
            }.value
            var found: [NSImage] = []
            for file in newest { if let image = await Thumbs.image(file, size: 120) { found.append(image) } }
            pages = found
        }
    }
}
