import AppKit
import SwiftUI

/// The app icon: Mail's icon geometry (measured from a 360 px copy of it) in pink.
/// Drawn in code and set at launch; `MAIL_ICON_EXPORT=/path/icon.png` writes it as a 1024 px PNG and quits.
struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width, b = s * 0.805   // macOS icon grid: 824 pt body inside a 1024 pt canvas
            ZStack {
                // Saturated at the top, lighter at the bottom, like Mail's blue (#1D6FF2 → #1AC8FB).
                RoundedRectangle(cornerRadius: b * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.11, blue: 0.49), Color(red: 1.0, green: 0.42, blue: 0.71)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: b, height: b)
                Envelope()
                    .frame(width: b * 0.71, height: b * 0.455)
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

/// White envelope whose lines are cut out, so the background shows through them.
private struct Envelope: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, e = w * 0.05
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.06).fill(.white)
                // Flap: 45° from the top corners, rounded where the two sides meet.
                Path { p in
                    p.move(to: CGPoint(x: -e, y: -e))
                    p.addArc(tangent1End: CGPoint(x: w / 2, y: w / 2), tangent2End: CGPoint(x: w + e, y: -e), radius: w * 0.147)
                    p.addLine(to: CGPoint(x: w + e, y: -e))
                    // Bottom folds: 45° from the bottom corners up to the flap.
                    p.move(to: CGPoint(x: -e, y: h + e))
                    p.addLine(to: CGPoint(x: h / 2, y: h / 2))
                    p.move(to: CGPoint(x: w + e, y: h + e))
                    p.addLine(to: CGPoint(x: w - h / 2, y: h / 2))
                }
                .stroke(style: StrokeStyle(lineWidth: w * 0.033))
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
