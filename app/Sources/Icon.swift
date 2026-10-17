import AppKit
import SwiftUI

/// An Iconsax icon: Linear, or Bold for what's selected, in the colour of the text around it.
struct Icon: View {
    let name: String
    var size: CGFloat = 18
    var bold = false

    init(_ name: String, size: CGFloat = 18, bold: Bool = false) {
        self.name = name
        self.size = size
        self.bold = bold
    }

    var body: some View {
        Image(nsImage: Iconsax.image(name, bold: bold)).resizable().renderingMode(.template).interpolation(.high)
            .frame(width: size, height: size)
    }
}

@MainActor enum Iconsax {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, bold: Bool = false) -> NSImage {
        let key = (bold ? "b:" : "l:") + name
        if let image = cache[key] { return image }
        let paths = (bold ? IconsaxPaths.bold[name] : nil) ?? IconsaxPaths.linear[name] ?? ""
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">"# + paths + "</svg>"
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// The icon for a kind of file.
    static func forFile(_ path: String, folder: Bool = false) -> String {
        if folder { return "Folder2" }
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp", "psd", "fig"].contains(ext) { return "Gallery" }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm", "fcpbundle"].contains(ext) { return "VideoPlay" }
        if ["mp3", "wav", "m4a", "aac", "flac", "aiff"].contains(ext) { return "Musicnote" }
        if ["zip", "dmg", "pkg", "tar", "gz", "rar", "7z", "xip"].contains(ext) { return "ArchiveBox" }
        if ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "rb", "java", "c", "h", "cpp", "css", "html", "json", "sh", "yml", "yaml", "toml", "md"].contains(ext) { return "Code" }
        if ext == "app" { return "Element3" }
        if ["pdf", "doc", "docx", "txt", "rtf", "pages", "key", "numbers", "csv", "xlsx", "pptx"].contains(ext) { return "DocumentText" }
        return "Document"
    }
}
