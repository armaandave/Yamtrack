import SwiftUI

struct MediaTypeTheme: Equatable {
    let slug: String
    let displayName: String
    let symbolName: String
    let gradientColors = [Color(red: 0.31, green: 0.33, blue: 0.37), Color(red: 0.09, green: 0.10, blue: 0.12)]

    var accentColor: Color {
        slug == "music" ? Self.musicColor : Color(red: 0.72, green: 0.74, blue: 0.78)
    }

    var artworkOrientation: PosterOrientation {
        slug == "music" ? .square : .portrait
    }

    var statsColor: Color {
        switch slug {
        case "movie": Color(red: 0.98, green: 0.49, blue: 0.24)
        case "tv": Color(red: 0.25, green: 0.70, blue: 0.96)
        case "anime": Color(red: 0.93, green: 0.39, blue: 0.67)
        case "manga": Color(red: 0.34, green: 0.82, blue: 0.58)
        case "game": Color(red: 0.50, green: 0.47, blue: 0.96)
        case "book": Color(red: 0.91, green: 0.69, blue: 0.25)
        case "comic": Color(red: 0.93, green: 0.34, blue: 0.35)
        case "music": Self.musicColor
        default: Color(red: 0.30, green: 0.77, blue: 0.95)
        }
    }

    var symbolText: String? {
        slug == "anime" ? "オ" : nil
    }

    private static let musicColor = Color(red: 0.20, green: 0.78, blue: 0.74)

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
        case "music":
            return MediaTypeTheme(
                slug: normalized,
                displayName: "Music",
                symbolName: "music.note.list"
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
            ClapperboardShape()
                .fill(.white, style: FillStyle(eoFill: true))
                .frame(width: size * 1.36, height: size * 1.14)
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

struct MediaLensCircleStyle: ViewModifier {
    let isSelected: Bool
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background {
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.155) : Color.black.opacity(0.36))
            }
            .overlay {
                Circle()
                    .stroke(.white.opacity(isSelected ? 0.0 : 0.065), lineWidth: 1)
            }
            .scaleEffect(isPressed ? 0.94 : 1)
    }
}

private struct ClapperboardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let body = CGRect(
            x: rect.minX + rect.width * 0.08,
            y: rect.minY + rect.height * 0.43,
            width: rect.width * 0.84,
            height: rect.height * 0.48
        )
        path.addRoundedRect(in: body, cornerSize: CGSize(width: rect.width * 0.045, height: rect.width * 0.045))

        path.addRect(CGRect(
            x: body.minX + body.width * 0.08,
            y: body.minY + body.height * 0.38,
            width: body.width * 0.84,
            height: body.height * 0.46
        ))

        let stripTop = body.minY + body.height * 0.08
        let stripBottom = body.minY + body.height * 0.33
        for index in 0 ..< 3 {
            let x = body.minX + body.width * (0.08 + CGFloat(index) * 0.31)
            let width = body.width * 0.20
            path.move(to: CGPoint(x: x, y: stripBottom))
            path.addLine(to: CGPoint(x: x + width * 0.54, y: stripTop))
            path.addLine(to: CGPoint(x: x + width, y: stripTop))
            path.addLine(to: CGPoint(x: x + width * 0.46, y: stripBottom))
            path.closeSubpath()
        }

        let slate = [
            CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.39),
            CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.06),
            CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.06),
            CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22),
            CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.56)
        ]
        path.move(to: slate[0])
        for point in slate.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        for cut in [
            [
                CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.33),
                CGPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.26),
                CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.43),
                CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.50)
            ],
            [
                CGPoint(x: rect.minX + rect.width * 0.48, y: rect.minY + rect.height * 0.20),
                CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.13),
                CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.30),
                CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.37)
            ],
            [
                CGPoint(x: rect.minX + rect.width * 0.69, y: rect.minY + rect.height * 0.09),
                CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.06),
                CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.23),
                CGPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.27)
            ]
        ] {
            path.move(to: cut[0])
            for point in cut.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }

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
