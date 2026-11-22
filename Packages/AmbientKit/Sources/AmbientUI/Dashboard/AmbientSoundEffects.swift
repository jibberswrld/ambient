import AppKit

@MainActor
public final class AmbientSoundEffects {
    public enum Cue: String, CaseIterable { case open, send, attention, complete, error }
    public var isEnabled = true {
        didSet { if !isEnabled { sounds.values.forEach { $0.stop() } } }
    }
    private var sounds: [String: NSSound] = [:]

    public init() {
        for cue in Cue.allCases {
            if let url = Bundle.module.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds"),
               let sound = NSSound(contentsOf: url, byReference: false) {
                sound.volume = 0.12
                sounds[cue.rawValue] = sound
            }
        }
    }

    public func play(_ cue: Cue) {
        guard isEnabled else { return }
        sounds.values.forEach { $0.stop() }
        sounds[cue.rawValue]?.play()
    }
}
