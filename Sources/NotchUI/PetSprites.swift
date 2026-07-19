import SwiftUI

/// User-selectable island pets. The raw value is persisted in UserDefaults
/// under `PetKind.storageKey`.
enum PetKind: String, CaseIterable, Identifiable {
    case xwing
    case saucer
    case rocket
    case cat

    var id: String { rawValue }

    static let storageKey = "aisland.petKind"

    var displayName: String {
        switch self {
        case .xwing: "X-wing"
        case .saucer: "Saucer"
        case .rocket: "Rocket"
        case .cat: "Space Cat"
        }
    }
}

/// A pixel sprite parsed from string art: one character per pixel, `.` empty.
/// Sprites are drawn through `PetPalette` unless a per-pixel override applies.
struct PetSprite {
    let rows: [[Character]]

    var width: Int { rows.first?.count ?? 0 }
    var height: Int { rows.count }

    init(art: [String]) {
        rows = art.map(Array.init)
    }

    private init(rows: [[Character]]) {
        self.rows = rows
    }

    /// Rotate 90° clockwise, turning nose-up art into nose-right flight art.
    func rotatedNoseRight() -> PetSprite {
        let h = height
        let w = width
        var out = Array(repeating: Array(repeating: Character("."), count: h), count: w)
        for row in 0..<h {
            for column in 0..<w {
                out[column][h - 1 - row] = rows[row][column]
            }
        }
        return PetSprite(rows: out)
    }
}

enum PetPalette {
    /// nil means "leave the pixel empty".
    static func color(_ char: Character) -> Color? {
        switch char {
        case "#": Color(white: 0.10)
        case "W": Color(white: 0.92)
        case "G": Color(white: 0.60)
        case "w": Color(white: 0.99)
        case "r": Color(red: 0.55, green: 0.17, blue: 0.13)
        case "R": Color(red: 0.88, green: 0.20, blue: 0.14)
        case "C": Color(red: 0.10, green: 0.14, blue: 0.20)
        case "A": Color(red: 0.45, green: 0.60, blue: 0.66)
        case "B": Color(red: 0.45, green: 0.75, blue: 1.0)
        case "b": Color(red: 0.75, green: 0.90, blue: 1.0)
        case "L": Color(red: 1.0, green: 0.85, blue: 0.25)
        case "E": Color(red: 0.30, green: 0.90, blue: 0.40)
        case "P": Color(red: 0.95, green: 0.55, blue: 0.65)
        default: nil
        }
    }
}

/// String art authored nose-up (X-wing) or facing right (others).
/// Regenerate with scripts/render-pets.swift, which also writes a PNG preview.
enum PetArt {
    /// Reference-styled top-down X-wing: striped nose, red-tipped quad
    /// cannons, swept wings, astromech dome, four engines.
    static let xwing = [
        "................GwG................",
        "................GWG................",
        ".....R.........#WrW#.........R.....",
        ".....R.........#WrW#.........R.....",
        "..R..W.........#WrW#.........W..R..",
        "..R..W.........#WrW#.........W..R..",
        "..W..W.........#WrW#.........W..W..",
        "..W..W.........#WrW#.........W..W..",
        "..W..W.........#WrW#.........W..W..",
        "..W..W.........#WrW#.........W..W..",
        "..W..W.........#WrW#.........W..W..",
        "..W..W.........#WrW#.........W..W..",
        "..W..W.........#WrW#.........W..W..",
        ".######......#WrWCWrW#......######.",
        ".#GGGG#......#WrCCCrW#......#GGGG#.",
        ".#WWWW#W#....#WrCCCrW#....#W#WWWW#.",
        ".#rrrr#WW#...#WrCCCrW#...#WW#rrrr#.",
        "..rrrrrWWW#..#WrCCCrW#..#WWWrrrrr..",
        "....GGGGGWW#.#WrCCCrW#.#WWGGGGG....",
        "....GGGGGWWW##WrCCCrW##WWWGGGGG....",
        "......#WWWWWW#WrWCWrW#WWWWWW#......",
        ".......rrrrrW#WrGGGrW#Wrrrrr.......",
        ".......rrrrrW#GWAAAWG#Wrrrrr.......",
        ".........#WWW#GWAwAWG#WWW#.........",
        ".......#######GWAAAWG#######.......",
        ".......#WW#WW#GWWWWWG#WW#WW#.......",
        ".......#GG#GG#GWWrWWG#GG#GG#.......",
        ".......#GG#GG#GWWrWWG#GG#GG#.......",
        ".......#GG#GG#GWWrWWG#GG#GG#.......",
        ".......#GG#GG#GWWrWWG#GG#GG#.......",
        ".......#######GWWrWWG#######.......",
        "........##.##.#GWWWG#.##.##........",
        "...............#GGG#...............",
        "...............#####...............",
    ]

    static let saucer = [
        "..........GGGGGGG..........",
        "........GWWWWWWWWWG........",
        "........#WCCCCCCCW#........",
        "....###################....",
        "..#WWWWWWWWWWWWWWWWWWWWW#..",
        ".#GLGGGLGGGLGGGLGGGLGGGLG#.",
        "...#####################...",
        "......b......b......b......",
    ]

    static let rocket = [
        "....##........................",
        "....#RRR#.....................",
        ".....#RRRR#...................",
        ".....###################......",
        "...##WWWWWWWW##WWWWWRRRRRR#...",
        "...#GWWWWWWW#wC#WWWWRRRRRRRR#.",
        "...#GWWWWWWW#CC#WWWWRRRRRRRRRw",
        "...#GWGGGGGG#CC#GGGGRRRRRRRR#.",
        "...##WGGGGGGG##GGGGGRRRRRR#...",
        ".....###################......",
        ".....#RRRR#...................",
        "....#RRR#.....................",
        "....##........................",
    ]

    static let cat = [
        "...............##...##..",
        "...............#P...P#..",
        ".#............########..",
        "#G............#GGGGGGG#.",
        "#G............#GGEGGEG#.",
        "#G.############GGGGGGP#.",
        ".GG#GGGGGGGGGG#GGGGWWW#.",
        "..G#GGGGGGGGGG#GGGGWWW#.",
        "...#GGGGGGGGGWW#######..",
        "...#GGGGGGGGGWWW........",
        "...#GGGGGGGGGWWW........",
        "....############........",
        ".....##..##..##.........",
        ".....WW..WW..WW.........",
    ]

    static func art(for kind: PetKind) -> [String] {
        switch kind {
        case .xwing: xwing
        case .saucer: saucer
        case .rocket: rocket
        case .cat: cat
        }
    }
}
