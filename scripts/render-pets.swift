import AppKit

// Authors all four aisland pets, renders a preview sheet, and exports
// each sprite as Swift string-art for embedding in NotchUI.
// Chars: # outline, W white, G gray, w bright, r maroon, R red, C canopy,
// A astromech, B blue, b pale blue, L rim light (animated), O orange,
// Y yellow, E eye green, P pink.

struct Art {
    let name: String
    var grid: [[Character]]
    var width: Int { grid[0].count }
    var height: Int { grid.count }

    init(name: String, width: Int, height: Int) {
        self.name = name
        grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
    }

    mutating func paint(_ part: Character, _ x: ClosedRange<Int>, _ y: ClosedRange<Int>) {
        for row in y where row >= 0 && row < height {
            for column in x where column >= 0 && column < width { grid[row][column] = part }
        }
    }
    /// Mirror across the vertical center line.
    mutating func mirrorH(_ part: Character, _ x: ClosedRange<Int>, _ y: ClosedRange<Int>, center: Int) {
        paint(part, x, y)
        paint(part, (2 * center - x.upperBound)...(2 * center - x.lowerBound), y)
    }
    /// Mirror across a horizontal center line (for the rocket fins).
    mutating func mirrorV(_ part: Character, _ x: ClosedRange<Int>, _ y: ClosedRange<Int>, center: Int) {
        paint(part, x, y)
        paint(part, x, (2 * center - y.upperBound)...(2 * center - y.lowerBound))
    }
}

// ============================== X-WING (35x34, nose up) ==============================
var xwing = Art(name: "xwing", width: 35, height: 34)
let xc = 17
for row in 15...28 {
    let lead = 1 + (row - 15)
    let trail = min(8 + (row - 15), 14)
    if lead < trail {
        xwing.mirrorH("#", lead...lead, row...row, center: xc)
        if lead + 1 <= trail - 1 {
            xwing.mirrorH("W", (lead + 1)...(trail - 1), row...row, center: xc)
        }
        xwing.mirrorH("#", trail...trail, row...row, center: xc)
    }
}
xwing.mirrorH("r", 2...6, 16...17, center: xc)
xwing.mirrorH("W", 2...7, 15...15, center: xc)
xwing.mirrorH("G", 4...8, 18...19, center: xc)
xwing.mirrorH("r", 7...11, 21...22, center: xc)
xwing.mirrorH("#", 1...6, 13...13, center: xc)
xwing.mirrorH("G", 1...6, 14...14, center: xc)
xwing.mirrorH("#", 1...1, 14...16, center: xc)
xwing.mirrorH("#", 6...6, 14...16, center: xc)
xwing.mirrorH("R", 5...5, 2...3, center: xc)
xwing.mirrorH("W", 5...5, 4...12, center: xc)
xwing.mirrorH("R", 2...2, 4...5, center: xc)
xwing.mirrorH("W", 2...2, 6...12, center: xc)
xwing.mirrorH("#", 7...13, 24...24, center: xc)
xwing.mirrorH("#", 7...7, 25...30, center: xc)
xwing.mirrorH("#", 10...10, 25...30, center: xc)
xwing.mirrorH("#", 13...13, 25...30, center: xc)
xwing.mirrorH("W", 8...9, 25...25, center: xc)
xwing.mirrorH("W", 11...12, 25...25, center: xc)
xwing.mirrorH("G", 8...9, 26...29, center: xc)
xwing.mirrorH("G", 11...12, 26...29, center: xc)
xwing.mirrorH("#", 8...9, 30...31, center: xc)
xwing.mirrorH("#", 11...12, 30...31, center: xc)
xwing.paint("w", 17...17, 0...0)
xwing.mirrorH("G", 16...16, 0...1, center: xc)
xwing.paint("W", 17...17, 1...1)
xwing.mirrorH("#", 15...15, 2...12, center: xc)
xwing.mirrorH("W", 16...16, 2...12, center: xc)
xwing.paint("r", 17...17, 2...12)
xwing.mirrorH("#", 13...13, 13...21, center: xc)
xwing.mirrorH("W", 14...14, 13...21, center: xc)
xwing.mirrorH("r", 15...15, 13...21, center: xc)
xwing.mirrorH("C", 16...17, 14...19, center: xc)
xwing.mirrorH("W", 16...16, 13...13, center: xc)
xwing.paint("C", 17...17, 13...13)
xwing.mirrorH("W", 16...16, 20...20, center: xc)
xwing.paint("C", 17...17, 20...20)
xwing.mirrorH("G", 16...17, 21...21, center: xc)
xwing.mirrorH("A", 16...17, 22...22, center: xc)
xwing.mirrorH("A", 15...17, 23...23, center: xc)
xwing.mirrorH("A", 16...17, 24...24, center: xc)
xwing.paint("w", 17...17, 23...23)
xwing.mirrorH("#", 13...13, 22...30, center: xc)
xwing.mirrorH("G", 14...14, 22...30, center: xc)
xwing.mirrorH("W", 15...15, 22...30, center: xc)
xwing.paint("W", 16...18, 25...30)
xwing.paint("r", 17...17, 26...30)
xwing.mirrorH("#", 14...14, 31...31, center: xc)
xwing.mirrorH("G", 15...15, 31...31, center: xc)
xwing.mirrorH("W", 16...17, 31...31, center: xc)
xwing.mirrorH("#", 15...15, 32...32, center: xc)
xwing.mirrorH("G", 16...17, 32...32, center: xc)
xwing.mirrorH("#", 15...17, 33...33, center: xc)

// ============================== SAUCER (27x8) ==============================
var saucer = Art(name: "saucer", width: 27, height: 8)
let sc = 13
saucer.mirrorH("G", 10...13, 0...0, center: sc)
saucer.mirrorH("G", 8...8, 1...1, center: sc)
saucer.mirrorH("W", 9...13, 1...1, center: sc)
saucer.mirrorH("#", 8...8, 2...2, center: sc)
saucer.mirrorH("W", 9...9, 2...2, center: sc)
saucer.mirrorH("C", 10...13, 2...2, center: sc)
saucer.mirrorH("#", 4...13, 3...3, center: sc)
saucer.mirrorH("#", 2...2, 4...4, center: sc)
saucer.mirrorH("W", 3...13, 4...4, center: sc)
saucer.mirrorH("#", 1...1, 5...5, center: sc)
saucer.mirrorH("G", 2...13, 5...5, center: sc)
for column in stride(from: 3, through: 23, by: 4) {
    saucer.paint("L", column...column, 5...5)
}
saucer.mirrorH("#", 3...13, 6...6, center: sc)
saucer.mirrorH("b", 6...6, 7...7, center: sc)
saucer.paint("b", 13...13, 7...7)

// ============================== ROCKET (30x13, nose right) ==============================
var rocket = Art(name: "rocket", width: 30, height: 13)
let rc = 6  // vertical center row
// Body tube (rows 3-9).
rocket.paint("#", 5...22, 3...3)
rocket.paint("#", 5...22, 9...9)
rocket.paint("W", 5...22, 4...8)
rocket.paint("G", 6...22, 7...8)
// Tail nozzle.
rocket.paint("#", 3...4, 4...8)
rocket.paint("G", 4...4, 5...7)
// Red band + nose cone tapering to the right.
rocket.paint("R", 20...22, 4...8)
rocket.paint("#", 23...23, 3...3)
rocket.paint("#", 23...23, 9...9)
rocket.paint("R", 23...25, 4...8)
rocket.paint("#", 26...26, 4...4)
rocket.paint("#", 26...26, 8...8)
rocket.paint("R", 26...27, 5...7)
rocket.paint("#", 28...28, 5...5)
rocket.paint("#", 28...28, 7...7)
rocket.paint("R", 28...28, 6...6)
rocket.paint("w", 29...29, 6...6)
// Porthole window.
rocket.paint("#", 13...14, 4...4)
rocket.paint("#", 12...12, 5...7)
rocket.paint("#", 15...15, 5...7)
rocket.paint("C", 13...14, 5...7)
rocket.paint("#", 13...14, 8...8)
rocket.paint("w", 13...13, 5...5)
// Back-swept fins above and below the tail (mirrored down).
rocket.mirrorV("#", 4...5, 0...0, center: rc)
rocket.mirrorV("#", 4...4, 1...1, center: rc)
rocket.mirrorV("R", 5...7, 1...1, center: rc)
rocket.mirrorV("#", 8...8, 1...1, center: rc)
rocket.mirrorV("#", 5...5, 2...2, center: rc)
rocket.mirrorV("R", 6...9, 2...2, center: rc)
rocket.mirrorV("#", 10...10, 2...2, center: rc)

// ============================== CAT (24x14, facing right) ==============================
var cat = Art(name: "cat", width: 24, height: 14)
// Tail: curls up on the left.
cat.paint("#", 0...0, 3...5)
cat.paint("G", 1...1, 3...6)
cat.paint("#", 1...1, 2...2)
cat.paint("G", 2...2, 6...7)
// Body.
cat.paint("#", 3...15, 5...5)
cat.paint("#", 3...3, 6...10)
cat.paint("G", 4...15, 6...10)
cat.paint("#", 4...15, 11...11)
cat.paint("W", 13...15, 8...10)
// Legs with white paws.
cat.paint("#", 5...6, 11...12)
cat.paint("W", 5...6, 13...13)
cat.paint("#", 9...10, 11...12)
cat.paint("W", 9...10, 13...13)
cat.paint("#", 13...14, 11...12)
cat.paint("W", 13...14, 13...13)
// Ears with pink inners.
cat.paint("#", 15...16, 0...1)
cat.paint("P", 16...16, 1...1)
cat.paint("#", 20...21, 0...1)
cat.paint("P", 20...20, 1...1)
// Head.
cat.paint("#", 14...14, 2...7)
cat.paint("#", 15...21, 2...2)
cat.paint("#", 22...22, 3...7)
cat.paint("G", 15...21, 3...7)
cat.paint("#", 15...21, 8...8)
// Muzzle, eyes, nose.
cat.paint("W", 19...21, 6...7)
cat.paint("E", 17...17, 4...4)
cat.paint("E", 20...20, 4...4)
cat.paint("P", 21...21, 5...5)

// ============================== RENDER SHEET ==============================
let palette: [Character: NSColor] = [
    "#": NSColor(white: 0.10, alpha: 1),
    "W": NSColor(white: 0.92, alpha: 1),
    "G": NSColor(white: 0.60, alpha: 1),
    "w": NSColor(white: 0.99, alpha: 1),
    "r": NSColor(red: 0.55, green: 0.17, blue: 0.13, alpha: 1),
    "R": NSColor(red: 0.88, green: 0.20, blue: 0.14, alpha: 1),
    "C": NSColor(red: 0.10, green: 0.14, blue: 0.20, alpha: 1),
    "A": NSColor(red: 0.45, green: 0.60, blue: 0.66, alpha: 1),
    "B": NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1),
    "b": NSColor(red: 0.75, green: 0.90, blue: 1.0, alpha: 1),
    "L": NSColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 1),
    "O": NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1),
    "Y": NSColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 1),
    "E": NSColor(red: 0.30, green: 0.90, blue: 0.40, alpha: 1),
    "P": NSColor(red: 0.95, green: 0.55, blue: 0.65, alpha: 1),
]

let arts = [xwing, saucer, rocket, cat]
let scale = 7
let pad = 3
let sheetW = arts.reduce(0) { $0 + $1.width + pad } + pad
let sheetH = (arts.map(\.height).max()! + 2 * pad)
let context = CGContext(data: nil, width: sheetW * scale, height: sheetH * scale,
    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for py in 0..<sheetH {
    for px in 0..<sheetW {
        let dark = (px + py).isMultiple(of: 2)
        context.setFillColor(NSColor(red: dark ? 0.05 : 0.08, green: dark ? 0.05 : 0.08, blue: dark ? 0.14 : 0.20, alpha: 1).cgColor)
        context.fill(CGRect(x: px * scale, y: py * scale, width: scale, height: scale))
    }
}
var cursorX = pad
for art in arts {
    let top = (sheetH - art.height) / 2
    for row in 0..<art.height {
        for column in 0..<art.width {
            guard let color = palette[art.grid[row][column]] else { continue }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(
                x: (cursorX + column) * scale,
                y: (sheetH - 1 - (top + row)) * scale,
                width: scale, height: scale))
        }
    }
    cursorX += art.width + pad
}
let dir = "build"
let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: dir + "/pets-preview.png"))

// Export string-art literals for all pets.
var out = ""
for art in arts {
    out += "// \(art.name) \(art.width)x\(art.height)\n"
    for row in art.grid { out += "        \"\(String(row))\",\n" }
    out += "\n"
}
try! out.write(toFile: dir + "/pet-art.txt", atomically: true, encoding: .utf8)
print("sheet \(sheetW)x\(sheetH)")
