import AppKit
import SwiftUI

/// The app icon: a pink rounded square with a white envelope, in the spirit of Mail's icon (our own drawing).
/// Drawn in code and set at launch; `MAIL_ICON_EXPORT=/path/icon.png` writes it as a 1024 px PNG and quits.
struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                // macOS icon grid: 824 pt body inside a 1024 pt canvas, continuous corners.
                RoundedRectangle(cornerRadius: s * 0.185, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.78), Color(red: 0.89, green: 0.12, blue: 0.50)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.805, height: s * 0.805)
                    .shadow(color: .black.opacity(0.25), radius: s * 0.012, y: s * 0.01)
                Envelope()
                    .frame(width: s * 0.56, height: s * 0.39)
                    .offset(y: s * 0.01)
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @MainActor static func image(size: CGFloat = 1024) -> NSImage? {
        let r = ImageRenderer(content: AppIcon().frame(width: size, height: size))
        r.scale = 1
        return r.nsImage
    }

    /// Sets the Dock icon, or exports the PNG when asked.
    @MainActor static func install() {
        guard let img = image() else { return }
        if let out = ProcessInfo.processInfo.environment["MAIL_ICON_EXPORT"],
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
        NSApp.applicationIconImage = img
    }
}

private struct Envelope: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, r = w * 0.06
            ZStack {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.93)], startPoint: .top, endPoint: .bottom))
                // The flap: a V from the top corners to just below the middle.
                Path { p in
                    p.move(to: CGPoint(x: r * 0.8, y: r * 0.8))
                    p.addLine(to: CGPoint(x: w / 2, y: h * 0.58))
                    p.addLine(to: CGPoint(x: w - r * 0.8, y: r * 0.8))
                }
                .stroke(Color(red: 0.93, green: 0.45, blue: 0.68).opacity(0.55),
                        style: StrokeStyle(lineWidth: w * 0.022, lineCap: .round, lineJoin: .round))
            }
            .shadow(color: .black.opacity(0.18), radius: w * 0.02, y: w * 0.015)
        }
    }
}
