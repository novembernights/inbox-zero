import AVFoundation
import SwiftUI
import UIKit

/// A restrained, native feedback vocabulary for inbox.Zer0.
///
/// The short synthesized cues are inspired by Cuelume's semantic sound roles,
/// but are generated locally at runtime so the iOS app has no Web Audio or
/// downloaded-asset dependency. Audio remains nonessential: every cue has a
/// matching haptic or visible state change.
@MainActor
final class InteractionFeedback {
    static let shared = InteractionFeedback()

    enum Cue {
        case expand
        case collapse
        case selection
        case page
        case beginWork
        case ready
        case success
        case settled
        case error
        case destructive
    }

    static let soundsKey = "inboxZeroInteractionSounds"
    static let hapticsKey = "inboxZeroHaptics"

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.soundsKey: true,
            Self.hapticsKey: true
        ])
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Keep the sonic layer quieter than system alerts and speech. These
        // cues should read as atmosphere, never as another notification.
        engine.mainMixerNode.outputVolume = 0.18
    }

    func perform(_ cue: Cue, sound: Bool = true) {
        if UserDefaults.standard.bool(forKey: Self.hapticsKey) {
            performHaptic(for: cue)
        }

        guard sound,
              UserDefaults.standard.bool(forKey: Self.soundsKey),
              !UIAccessibility.isVoiceOverRunning,
              let buffer = buffer(for: cue)
        else { return }

        do {
            player.stop()
            engine.stop()
            engine.reset()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
        } catch {
            // Feedback is intentionally best-effort and must never block an action.
        }
    }

    /// Stop the optional sound engine before Speech takes ownership of the
    /// shared audio session. Haptics remain available while recording.
    func suspendAudioForRecording() {
        player.stop()
        engine.stop()
        engine.reset()
    }

    private func performHaptic(for cue: Cue) {
        switch cue {
        case .selection, .page:
            UISelectionFeedbackGenerator().selectionChanged()
        case .expand, .collapse:
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.72)
        case .beginWork:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.68)
        case .ready, .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .settled:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.46)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .destructive:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        let recipe: Recipe
        switch cue {
        // Frequent navigation and manipulation remain haptic-only. Repeating a
        // synthesized click on every move makes the interface feel mechanical.
        case .expand, .collapse, .selection, .page, .beginWork:
            return nil
        case .ready:
            recipe = .init(duration: 0.42, tones: [
                .init(frequency: 293.66, endFrequency: 329.63, offset: 0, duration: 0.34, level: 0.030),
                .init(frequency: 440, offset: 0.13, duration: 0.27, level: 0.015)
            ])
        case .success:
            recipe = .init(duration: 0.48, tones: [
                .init(frequency: 261.63, endFrequency: 293.66, offset: 0, duration: 0.38, level: 0.030),
                .init(frequency: 392, endFrequency: 440, offset: 0.14, duration: 0.31, level: 0.015)
            ])
        case .settled:
            recipe = .init(duration: 0.58, tones: [
                .init(frequency: 220, endFrequency: 246.94, offset: 0, duration: 0.46, level: 0.028),
                .init(frequency: 329.63, endFrequency: 369.99, offset: 0.18, duration: 0.36, level: 0.014)
            ])
        case .error:
            recipe = .init(duration: 0.32, tones: [
                .init(frequency: 293.66, endFrequency: 246.94, offset: 0, duration: 0.28, level: 0.030)
            ])
        case .destructive:
            recipe = .init(duration: 0.28, tones: [
                .init(frequency: 329.63, endFrequency: 220, offset: 0, duration: 0.25, level: 0.032)
            ])
        }
        return render(recipe)
    }

    private func render(_ recipe: Recipe) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(ceil(recipe.duration * sampleRate))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames

        var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
        for frame in 0..<Int(frames) {
            let time = Double(frame) / sampleRate
            var sample = 0.0

            for tone in recipe.tones where time >= tone.offset && time <= tone.offset + tone.duration {
                let local = time - tone.offset
                let progress = min(1, local / tone.duration)
                let frequency = tone.frequency + ((tone.endFrequency ?? tone.frequency) - tone.frequency) * progress
                let phase = 2 * Double.pi * (tone.frequency * local + 0.5 * (frequency - tone.frequency) * local)
                sample += sin(phase) * envelope(progress) * tone.level
            }

            if recipe.noiseLevel > 0 {
                noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
                let random = Double(Int64(bitPattern: noiseState) >> 33) / Double(Int32.max)
                sample += random * recipe.noiseLevel * envelope(time / recipe.duration)
            }

            channel[frame] = Float(max(-0.9, min(0.9, sample)))
        }
        return buffer
    }

    private func envelope(_ progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        let attack = min(1, clamped / 0.08)
        let release = pow(1 - clamped, 2.4)
        return attack * release
    }
}

private struct Recipe {
    let duration: Double
    let tones: [Tone]
    var noiseLevel: Double = 0
}

private struct Tone {
    let frequency: Double
    var endFrequency: Double? = nil
    let offset: Double
    let duration: Double
    let level: Double
}
