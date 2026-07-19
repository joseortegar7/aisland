import AVFoundation
import Foundation

/// Events that can chirp. Patterns are original little square-wave motifs.
public enum SoundEvent: String, CaseIterable, Sendable {
    case sessionStart
    case needsPermission
    case approved
    case denied
    case done
    case question
}

/// 8-bit style synth: each event's motif is pre-rendered once into a PCM
/// buffer (square wave + decay envelope) and played through a single
/// AVAudioPlayerNode. No files, no render-thread state to race.
@MainActor
public final class SoundEngine {
    public private(set) var isMuted: Bool

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [SoundEvent: AVAudioPCMBuffer] = [:]
    private var started = false

    private static let sampleRate = 44_100.0
    private static let mutedDefaultsKey = "soundsMuted"

    public init() {
        isMuted = UserDefaults.standard.bool(forKey: Self.mutedDefaultsKey)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.35
        for event in SoundEvent.allCases {
            buffers[event] = Self.render(notes: Self.motif(for: event), format: format)
        }
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.mutedDefaultsKey)
    }

    public func play(_ event: SoundEvent) {
        guard !isMuted, let buffer = buffers[event] else { return }
        if !started {
            do {
                try engine.start()
                started = true
            } catch {
                NSLog("aisland sound: engine start failed: \(error.localizedDescription)")
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        NSLog("aisland sound: played %@", event.rawValue)
    }

    // MARK: - Synth

    /// (frequency Hz, duration seconds); 0 Hz = rest.
    private static func motif(for event: SoundEvent) -> [(Double, Double)] {
        // Original motifs on a C-major palette (Hz values for C4..C6 range).
        let c5 = 523.25, e5 = 659.25, g5 = 783.99, c6 = 1046.5
        let g4 = 392.0, e4 = 329.63, c4 = 261.63, a5 = 880.0
        switch event {
        case .sessionStart:
            return [(c5, 0.06), (e5, 0.06), (g5, 0.09)]
        case .needsPermission:
            return [(g4, 0.07), (0, 0.03), (c5, 0.07), (0, 0.03), (g4, 0.07), (0, 0.03), (c5, 0.10)]
        case .approved:
            return [(c5, 0.05), (g5, 0.05), (c6, 0.10)]
        case .denied:
            return [(e4, 0.09), (c4, 0.14)]
        case .done:
            return [(c5, 0.06), (e5, 0.06), (g5, 0.06), (c6, 0.12)]
        case .question:
            return [(e5, 0.06), (a5, 0.06), (e5, 0.06), (a5, 0.10)]
        }
    }

    private static func render(notes: [(Double, Double)], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let totalSeconds = notes.reduce(0) { $0 + $1.1 } + 0.05
        let frameCount = AVAudioFrameCount(totalSeconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let samples = buffer.floatChannelData?[0] else { return nil }

        var frame = 0
        for (frequency, duration) in notes {
            let noteFrames = Int(duration * sampleRate)
            for i in 0..<noteFrames where frame + i < Int(frameCount) {
                if frequency == 0 {
                    samples[frame + i] = 0
                    continue
                }
                let t = Double(i) / sampleRate
                // Square wave + quick decay envelope = the 8-bit chirp.
                let phase = (t * frequency).truncatingRemainder(dividingBy: 1.0)
                let square: Float = phase < 0.5 ? 0.6 : -0.6
                let envelope = Float(1.0 - (Double(i) / Double(noteFrames)) * 0.7)
                samples[frame + i] = square * envelope
            }
            frame += noteFrames
        }
        // Trailing silence pad.
        while frame < Int(frameCount) {
            samples[frame] = 0
            frame += 1
        }
        return buffer
    }
}
