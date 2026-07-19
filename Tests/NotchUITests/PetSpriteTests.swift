import XCTest
@testable import NotchUI

final class PetSpriteTests: XCTestCase {
    func testEveryPetHasConsistentArt() {
        for kind in PetKind.allCases {
            let art = PetArt.art(for: kind)
            XCTAssertFalse(art.isEmpty, "\(kind) has no art")
            let widths = Set(art.map(\.count))
            XCTAssertEqual(widths.count, 1, "\(kind) rows differ in width: \(widths)")
            let sprite = PetSprite(art: art)
            XCTAssertGreaterThan(sprite.width, 0)
            XCTAssertGreaterThan(sprite.height, 0)
        }
    }

    func testEveryArtCharacterHasAColor() {
        for kind in PetKind.allCases {
            for row in PetArt.art(for: kind) {
                for char in row where char != "." {
                    XCTAssertNotNil(
                        PetPalette.color(char),
                        "\(kind) art uses unmapped character '\(char)'"
                    )
                }
            }
        }
    }

    func testXwingArtIsHorizontallySymmetric() {
        for (index, row) in PetArt.xwing.enumerated() {
            XCTAssertEqual(String(row.reversed()), row, "xwing row \(index) is not symmetric")
        }
    }

    func testRotationSwapsDimensionsAndPreservesPixels() {
        let sprite = PetSprite(art: PetArt.xwing)
        let rotated = sprite.rotatedNoseRight()
        XCTAssertEqual(rotated.width, sprite.height)
        XCTAssertEqual(rotated.height, sprite.width)
        let count = { (s: PetSprite) in
            s.rows.reduce(0) { $0 + $1.filter { $0 != "." }.count }
        }
        XCTAssertEqual(count(rotated), count(sprite))
    }

    func testPetKindRoundTripsThroughStorageRawValue() {
        for kind in PetKind.allCases {
            XCTAssertEqual(PetKind(rawValue: kind.rawValue), kind)
        }
        XCTAssertNil(PetKind(rawValue: "not-a-pet"))
    }
}
