import SwiftUI

/// Animated pixel pet for the island. Renders the user-selected `PetKind`
/// on a shared 78x52 starfield scene; `color` tints small status pixels so
/// the pet reflects session state (green ok, orange approval, purple question).
struct PetView: View {
    var kind: PetKind
    var color: Color
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sceneDuration = 18.0
    private static let approachStart = 9.0
    private static let trackingStart = 11.4
    private static let shotStart = 12.0
    private static let impactTime = 12.7
    private static let explosionEnd = 14.0
    private static let recoveryEnd = 15.4

    private static let xwingFlight = PetSprite(art: PetArt.xwing).rotatedNoseRight()
    private static let saucerSprite = PetSprite(art: PetArt.saucer)
    private static let rocketSprite = PetSprite(art: PetArt.rocket)
    private static let catSprite = PetSprite(art: PetArt.cat)

    private static let asteroidFrames: [[[Int]]] = [
        [
            [0, 1, 1, 0, 0],
            [1, 1, 1, 1, 0],
            [1, 0, 1, 1, 1],
            [1, 1, 1, 0, 1],
            [0, 1, 1, 1, 0],
        ],
        [
            [0, 1, 1, 1, 0],
            [1, 1, 0, 1, 1],
            [1, 1, 1, 0, 1],
            [0, 1, 1, 1, 1],
            [0, 0, 1, 1, 0],
        ],
    ]
    private static let enemyFrames: [[[Int]]] = [
        [
            [1, 0, 0, 0, 1],
            [0, 1, 0, 1, 0],
            [1, 1, 1, 1, 1],
            [0, 1, 1, 1, 0],
            [0, 0, 1, 0, 0],
        ],
        [
            [0, 1, 0, 1, 0],
            [1, 0, 1, 0, 1],
            [0, 1, 1, 1, 0],
            [1, 1, 1, 1, 1],
            [0, 0, 1, 0, 0],
        ],
    ]

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            scene(time: 0)
        } else if !isActive {
            scene(time: Date.now.timeIntervalSinceReferenceDate)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
                scene(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func scene(time: TimeInterval) -> some View {
        Canvas { context, size in
            let pixel = min(size.width / 78, size.height / 52)
            let origin = CGPoint(
                x: (size.width - 78 * pixel) / 2,
                y: (size.height - 52 * pixel) / 2
            )
            drawStars(time: time, context: &context, origin: origin, pixel: pixel)
            switch kind {
            case .xwing:
                drawXwingScene(time: time, context: &context, origin: origin, pixel: pixel)
            case .saucer:
                drawSaucerScene(time: time, context: &context, origin: origin, pixel: pixel)
            case .rocket:
                drawRocketScene(time: time, context: &context, origin: origin, pixel: pixel)
            case .cat:
                drawCatScene(time: time, context: &context, origin: origin, pixel: pixel)
            }
        }
    }

    // MARK: - X-wing combat scene

    private func drawXwingScene(
        time: TimeInterval,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let phase = time.truncatingRemainder(dividingBy: Self.sceneDuration)
        let cycle = Int(time / Self.sceneDuration)
        let isAsteroid = cycle.isMultiple(of: 2)

        let bob = sin(time * 2.1) * 0.35
        let trackingLift: CGFloat
        if (Self.approachStart..<Self.trackingStart).contains(phase) {
            let progress = normalized(phase, from: Self.approachStart, to: Self.trackingStart)
            trackingLift = -sin(progress * .pi) * 0.7
        } else if (Self.impactTime..<Self.recoveryEnd).contains(phase) {
            let progress = normalized(phase, from: Self.impactTime, to: Self.recoveryEnd)
            trackingLift = -sin(progress * .pi) * 0.8
        } else {
            trackingLift = 0
        }
        let shotProgress = normalized(phase, from: Self.shotStart, to: Self.impactTime)
        let recoil = (Self.shotStart..<Self.impactTime).contains(phase)
            ? sin(shotProgress * .pi) * 0.8
            : 0
        let fighterX = snap(4 - recoil)
        let fighterY = snap(8 + bob + trackingLift)

        drawSprite(
            Self.xwingFlight,
            x: fighterX, y: fighterY, unit: 1,
            context: &context, origin: origin, pixel: pixel
        )
        // Status pips on the wingtip blocks (top and bottom wings).
        drawPixel(x: fighterX + 18, y: fighterY + 2, color: color, context: &context, origin: origin, pixel: pixel)
        drawPixel(x: fighterX + 18, y: fighterY + 32, color: color, context: &context, origin: origin, pixel: pixel)

        // Four blue engine trails behind the nozzles.
        let exhaustFrame = Int(time * 20).quotientAndRemainder(dividingBy: 3).remainder
        let exhaustLength = CGFloat(exhaustFrame + 2)
        let exhaustColor: Color = exhaustFrame == 2
            ? Color(red: 0.75, green: 0.90, blue: 1.0)
            : Color(red: 0.45, green: 0.75, blue: 1.0)
        for trailY in [8.0, 11.0, 22.0, 25.0] {
            drawPixel(
                x: fighterX + 2 - exhaustLength,
                y: fighterY + trailY,
                width: exhaustLength,
                height: 2,
                color: exhaustColor,
                context: &context,
                origin: origin,
                pixel: pixel
            )
        }

        let targetX = targetPosition(for: phase)
        let targetY = fighterY + 15
        if phase >= Self.approachStart && phase < Self.impactTime {
            let animationFrame = Int(time * 6).quotientAndRemainder(dividingBy: 2).remainder
            let target = isAsteroid
                ? Self.asteroidFrames[animationFrame]
                : Self.enemyFrames[animationFrame]
            draw(
                target,
                x: targetX,
                y: targetY,
                color: isAsteroid ? .gray : .red,
                context: &context,
                origin: origin,
                pixel: pixel
            )
            if !isAsteroid {
                drawPixel(x: targetX + 2, y: targetY + 2, color: .yellow, context: &context, origin: origin, pixel: pixel)
            }
        }

        if (Self.shotStart - 0.08..<Self.shotStart + 0.16).contains(phase) {
            drawPixel(x: fighterX + 34, y: fighterY + 16, width: 2, height: 2, color: .white, context: &context, origin: origin, pixel: pixel)
        }

        if (Self.shotStart..<Self.impactTime).contains(phase) {
            let boltProgress = easeIn(normalized(phase, from: Self.shotStart, to: Self.impactTime))
            let boltX = lerp(fighterX + 35, targetX + 1, boltProgress)
            drawPixel(x: boltX, y: fighterY + 17, width: 4, color: .yellow, context: &context, origin: origin, pixel: pixel)
            drawPixel(x: boltX + 1, y: fighterY + 17, width: 2, color: .white, context: &context, origin: origin, pixel: pixel)
        }

        if (Self.impactTime..<Self.explosionEnd).contains(phase) {
            drawExplosion(
                progress: normalized(phase, from: Self.impactTime, to: Self.explosionEnd),
                isAsteroid: isAsteroid,
                context: &context,
                origin: origin,
                pixel: pixel
            )
        }
    }

    // MARK: - Saucer scene

    private func drawSaucerScene(
        time: TimeInterval,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let bob = sin(time * 1.7) * 1.2
        let drift = sin(time * 0.6) * 5
        let x = snap(12 + drift)
        let y = snap(16 + bob)
        let step = Int(time * 8)
        let glowVisible = Int(time * 4).isMultiple(of: 2)
        var lightIndex = -1
        drawSprite(
            Self.saucerSprite,
            x: x, y: y, unit: 2,
            context: &context, origin: origin, pixel: pixel
        ) { char, _, _ in
            switch char {
            case "L":
                lightIndex += 1
                return step % 6 == lightIndex % 6
                    ? Color(red: 1.0, green: 0.85, blue: 0.25)
                    : Color(white: 0.35)
            case "b":
                return glowVisible ? Color(red: 0.75, green: 0.90, blue: 1.0) : nil
            default:
                return nil
            }
        }
        // Status pips at the rim tips.
        drawPixel(x: x, y: y + 10, width: 2, height: 2, color: color, context: &context, origin: origin, pixel: pixel)
        drawPixel(x: x + 52, y: y + 10, width: 2, height: 2, color: color, context: &context, origin: origin, pixel: pixel)
    }

    // MARK: - Rocket scene

    private func drawRocketScene(
        time: TimeInterval,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let bob = sin(time * 2.0) * 1.0
        let boostPhase = time.truncatingRemainder(dividingBy: 9)
        let boost = boostPhase < 1.2 ? sin(boostPhase / 1.2 * .pi) * 5 : 0
        let x = snap(8 + boost)
        let y = snap(13 + bob)
        drawSprite(
            Self.rocketSprite,
            x: x, y: y, unit: 2,
            context: &context, origin: origin, pixel: pixel
        )
        // Flickering flame out of the tail nozzle.
        let frame = Int(time * 15).quotientAndRemainder(dividingBy: 3).remainder
        let flameLength = CGFloat([5, 8, 11][frame]) + boost
        let inner = max(flameLength - 3, 2)
        drawPixel(x: x + 6 - inner, y: y + 10, width: inner, height: 2, color: .yellow, context: &context, origin: origin, pixel: pixel)
        drawPixel(x: x + 6 - flameLength, y: y + 12, width: flameLength, height: 2, color: .orange, context: &context, origin: origin, pixel: pixel)
        drawPixel(x: x + 6 - inner, y: y + 14, width: inner, height: 2, color: .yellow, context: &context, origin: origin, pixel: pixel)
        // Status pips on the fin tips.
        drawPixel(x: x + 9, y: y - 1, width: 2, height: 2, color: color, context: &context, origin: origin, pixel: pixel)
        drawPixel(x: x + 9, y: y + 25, width: 2, height: 2, color: color, context: &context, origin: origin, pixel: pixel)
    }

    // MARK: - Cat scene

    private func drawCatScene(
        time: TimeInterval,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let bob = sin(time * 1.3) * 1.5
        let x = snap(15.0)
        let y = snap(11 + bob)
        let blinking = time.truncatingRemainder(dividingBy: 4.7) < 0.25
        drawSprite(
            Self.catSprite,
            x: x, y: y, unit: 2,
            context: &context, origin: origin, pixel: pixel
        ) { char, _, _ in
            char == "E" && blinking ? Color(white: 0.60) : nil
        }
        // Tail swish: an extra tip pixel alternating between two spots.
        let wagUp = Int(time * 1.6).isMultiple(of: 2)
        drawPixel(
            x: x - 2,
            y: wagUp ? y + 2 : y + 8,
            width: 2, height: 2,
            color: Color(white: 0.60),
            context: &context, origin: origin, pixel: pixel
        )
        // Status collar between head and body.
        drawPixel(x: x + 28, y: y + 16, width: 2, height: 2, color: color, context: &context, origin: origin, pixel: pixel)
    }

    // MARK: - Shared drawing

    private func drawStars(
        time: TimeInterval,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let stars: [(x: CGFloat, y: CGFloat, speed: CGFloat)] = [
            (7, 2, 1.3),
            (28, 17, 0.8),
            (58, 3, 1.8),
            (44, 18, 0.55),
        ]
        for (index, star) in stars.enumerated() {
            let travel = CGFloat(time) * star.speed
            let rawX = (star.x - travel).truncatingRemainder(dividingBy: 68)
            let x = floor(rawX >= 0 ? rawX : rawX + 68)
            let bright = (Int(time * 4) + index).isMultiple(of: 3)
            drawPixel(
                x: x,
                y: star.y,
                color: .white.opacity(bright ? 0.5 : 0.22),
                context: &context,
                origin: origin,
                pixel: pixel
            )
        }
    }

    /// Draw a sprite with each art pixel covering `unit` scene units.
    /// `override` may recolor a pixel; returning nil falls back to the palette
    /// (except for glow pixels "b", which an override may hide by returning nil).
    private func drawSprite(
        _ sprite: PetSprite,
        x: CGFloat,
        y: CGFloat,
        unit: CGFloat,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat,
        override: ((Character, Int, Int) -> Color?)? = nil
    ) {
        for (rowIndex, row) in sprite.rows.enumerated() {
            for (columnIndex, char) in row.enumerated() {
                guard char != "." else { continue }
                let overridden = override?(char, columnIndex, rowIndex)
                if override != nil, overridden == nil, char == "b" { continue }
                guard let color = overridden ?? PetPalette.color(char) else { continue }
                drawPixel(
                    x: x + CGFloat(columnIndex) * unit,
                    y: y + CGFloat(rowIndex) * unit,
                    width: unit,
                    height: unit,
                    color: color,
                    context: &context,
                    origin: origin,
                    pixel: pixel
                )
            }
        }
    }

    private func drawExplosion(
        progress: CGFloat,
        isAsteroid: Bool,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let center = CGPoint(x: 65, y: 25)
        let expansion = easeOut(progress) * 6
        let directions: [(x: CGFloat, y: CGFloat)] = [
            (-1, 0), (1, 0), (0, -1), (0, 1),
            (-0.7, -0.7), (0.7, -0.7), (-0.7, 0.7), (0.7, 0.7),
        ]
        if progress < 0.32 {
            let coreColor: Color = progress < 0.12 ? .white : .yellow
            drawPixel(x: center.x - 1, y: center.y - 1, width: 3, height: 3, color: coreColor, context: &context, origin: origin, pixel: pixel)
        }
        for (index, direction) in directions.enumerated() {
            let distance = 1 + expansion * (index.isMultiple(of: 2) ? 1 : 0.72)
            let debrisColor: Color
            if index.isMultiple(of: 3) {
                debrisColor = isAsteroid ? .gray.opacity(1 - progress) : .red.opacity(1 - progress)
            } else {
                debrisColor = (index.isMultiple(of: 2) ? Color.orange : Color.yellow).opacity(1 - progress)
            }
            drawPixel(
                x: snap(center.x + direction.x * distance),
                y: snap(center.y + direction.y * distance),
                color: debrisColor,
                context: &context,
                origin: origin,
                pixel: pixel
            )
        }
    }

    private func draw(
        _ bitmap: [[Int]],
        x: CGFloat,
        y: CGFloat,
        color: Color,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        for (rowIndex, row) in bitmap.enumerated() {
            for (columnIndex, bit) in row.enumerated() where bit == 1 {
                drawPixel(
                    x: x + CGFloat(columnIndex),
                    y: y + CGFloat(rowIndex),
                    color: color,
                    context: &context,
                    origin: origin,
                    pixel: pixel
                )
            }
        }
    }

    private func drawPixel(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 1,
        height: CGFloat = 1,
        color: Color,
        context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat
    ) {
        let rect = CGRect(
            x: origin.x + x * pixel,
            y: origin.y + y * pixel,
            width: width * pixel,
            height: height * pixel
        )
        context.fill(Path(rect), with: .color(color))
    }

    private func targetPosition(for phase: TimeInterval) -> CGFloat {
        guard phase < Self.trackingStart else { return 63 }
        let progress = easeOut(normalized(phase, from: Self.approachStart, to: Self.trackingStart))
        return lerp(76, 63, progress)
    }

    private func normalized(_ value: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> CGFloat {
        CGFloat(min(max((value - start) / (end - start), 0), 1))
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func easeIn(_ value: CGFloat) -> CGFloat {
        value * value
    }

    private func easeOut(_ value: CGFloat) -> CGFloat {
        1 - pow(1 - value, 3)
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
