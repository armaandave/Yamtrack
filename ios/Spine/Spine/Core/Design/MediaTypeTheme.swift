import SwiftUI

struct MediaTypeTheme: Equatable {
    let slug: String
    let displayName: String
    let symbolName: String
    let accentColor = Color(red: 0.72, green: 0.74, blue: 0.78)
    let gradientColors = [Color(red: 0.31, green: 0.33, blue: 0.37), Color(red: 0.09, green: 0.10, blue: 0.12)]

    var symbolText: String? {
        slug == "anime" ? "オ" : nil
    }

    static func theme(for slug: String) -> MediaTypeTheme {
        let normalized = slug.lowercased()
        switch normalized {
        case "movie":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Movies",
                symbolName: "film"
            )
        case "tv":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "TV",
                symbolName: "tv"
            )
        case "anime":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Anime",
                symbolName: "sparkles"
            )
        case "manga":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Manga",
                symbolName: "book.closed"
            )
        case "game":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Games",
                symbolName: "gamecontroller.fill"
            )
        case "book":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Books",
                symbolName: "book.fill"
            )
        case "comic":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Comics",
                symbolName: "rectangle.3.group.bubble.left"
            )
        case "boardgame":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Board Games",
                symbolName: "dice.fill"
            )
        default:
            return MediaTypeTheme(
                slug: normalized,
                displayName: normalized.split(separator: "_").map { $0.capitalized }.joined(separator: " "),
                symbolName: "square.grid.2x2"
            )
        }
    }
}

struct MediaTypeGlyph: View {
    let theme: MediaTypeTheme
    let size: CGFloat

    var body: some View {
        if let symbolText = theme.symbolText {
            Text(symbolText)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        } else if theme.slug == "movie" {
            MovieReelShape()
                .fill(.white, style: FillStyle(eoFill: true))
                .frame(width: size * 1.34, height: size * 1.02)
        } else if theme.slug == "tv" {
            RetroTVShape()
                .fill(.white, style: FillStyle(eoFill: true))
                .frame(width: size * 1.44, height: size * 1.18)
        } else if theme.slug == "comic" {
            ComicBurstShape()
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.2, size * 0.08), lineCap: .round, lineJoin: .round))
                .frame(width: size * 1.35, height: size * 1.08)
        } else {
            Image(systemName: theme.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white, theme.accentColor)
        }
    }
}

private struct MovieReelShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let reelRect = CGRect(x: rect.minX, y: rect.minY, width: rect.height * 0.92, height: rect.height * 0.92)
        let center = CGPoint(x: reelRect.midX, y: reelRect.midY)
        let radius = min(reelRect.width, reelRect.height) / 2

        path.addEllipse(in: reelRect)

        let holeRadius = radius * 0.17
        for angle in stride(from: -CGFloat.pi / 2, to: CGFloat.pi * 1.5, by: CGFloat.pi * 2 / 5) {
            let holeCenter = CGPoint(
                x: center.x + cos(angle) * radius * 0.56,
                y: center.y + sin(angle) * radius * 0.56
            )
            path.addEllipse(in: CGRect(
                x: holeCenter.x - holeRadius,
                y: holeCenter.y - holeRadius,
                width: holeRadius * 2,
                height: holeRadius * 2
            ))
        }
        path.addEllipse(in: CGRect(x: center.x - radius * 0.06, y: center.y - radius * 0.06, width: radius * 0.12, height: radius * 0.12))

        let baseY = reelRect.maxY - radius * 0.08
        path.move(to: CGPoint(x: center.x + radius * 0.30, y: baseY))
        path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
        path.addLine(to: CGPoint(x: rect.maxX, y: baseY + radius * 0.07))
        path.addLine(to: CGPoint(x: center.x + radius * 0.20, y: baseY + radius * 0.07))
        path.closeSubpath()

        return path
    }
}

private struct RetroTVShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(
            x: rect.minX,
            y: rect.minY + rect.height * 0.24,
            width: rect.width,
            height: rect.height * 0.68
        )
        path.addRoundedRect(in: body, cornerSize: CGSize(width: rect.width * 0.07, height: rect.width * 0.07))

        let screen = CGRect(
            x: body.minX + body.width * 0.07,
            y: body.minY + body.height * 0.16,
            width: body.width * 0.66,
            height: body.height * 0.68
        )
        path.addRoundedRect(in: screen, cornerSize: CGSize(width: rect.width * 0.07, height: rect.width * 0.07))

        path.addEllipse(in: CGRect(x: body.maxX - body.width * 0.18, y: body.minY + body.height * 0.30, width: body.width * 0.10, height: body.width * 0.10))
        path.addEllipse(in: CGRect(x: body.maxX - body.width * 0.20, y: body.minY + body.height * 0.58, width: body.width * 0.14, height: body.width * 0.14))

        let antennaWidth = max(1, rect.width * 0.07)
        path.move(to: CGPoint(x: body.midX, y: body.minY + antennaWidth * 0.3))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28 + antennaWidth, y: rect.minY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: body.midX + antennaWidth * 0.55, y: body.minY + antennaWidth * 0.3))
        path.closeSubpath()

        path.move(to: CGPoint(x: body.midX, y: body.minY + antennaWidth * 0.3))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70 + antennaWidth, y: rect.minY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: body.midX + antennaWidth * 0.55, y: body.minY + antennaWidth * 0.3))
        path.closeSubpath()

        return path
    }
}

private struct ComicBurstShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [
            CGPoint(x: 0.03, y: 0.43),
            CGPoint(x: 0.21, y: 0.38),
            CGPoint(x: 0.14, y: 0.12),
            CGPoint(x: 0.33, y: 0.26),
            CGPoint(x: 0.40, y: 0.04),
            CGPoint(x: 0.50, y: 0.29),
            CGPoint(x: 0.68, y: 0.12),
            CGPoint(x: 0.63, y: 0.36),
            CGPoint(x: 0.94, y: 0.30),
            CGPoint(x: 0.75, y: 0.50),
            CGPoint(x: 0.92, y: 0.64),
            CGPoint(x: 0.69, y: 0.62),
            CGPoint(x: 0.72, y: 0.88),
            CGPoint(x: 0.54, y: 0.70),
            CGPoint(x: 0.48, y: 0.97),
            CGPoint(x: 0.40, y: 0.73),
            CGPoint(x: 0.29, y: 0.89),
            CGPoint(x: 0.26, y: 0.72),
            CGPoint(x: 0.08, y: 0.94),
            CGPoint(x: 0.20, y: 0.65),
            CGPoint(x: 0.04, y: 0.58),
            CGPoint(x: 0.21, y: 0.52)
        ]

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + points[0].x * rect.width, y: rect.minY + points[0].y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
        }
        path.closeSubpath()
        return path
    }
}
