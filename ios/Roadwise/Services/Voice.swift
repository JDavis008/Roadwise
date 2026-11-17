import Foundation
import AVFoundation
import AudioToolbox

/// Spoken guidance (on-device text-to-speech, so it works with no signal) and the speeding chime.
@MainActor
final class Voice {
    private let synth = AVSpeechSynthesizer()
    var enabled = true

    init() {
        // Duck music and podcasts while speaking, and keep talking with the screen locked.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }

    func speak(_ text: String, interrupt: Bool = false) {
        guard enabled, !text.isEmpty else { return }
        if interrupt { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    func chime() {
        AudioServicesPlaySystemSound(1057)
    }
}
