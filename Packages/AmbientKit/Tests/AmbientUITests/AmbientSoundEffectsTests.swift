import XCTest
@testable import AmbientUI

@MainActor
final class AmbientSoundEffectsTests: XCTestCase {
    func testEveryCueIsBundledAndQuiet() {
        let effects = AmbientSoundEffects()
        XCTAssertEqual(Set(effects.sounds.keys), Set(AmbientSoundEffects.Cue.allCases))
        for (cue, sound) in effects.sounds {
            XCTAssertEqual(sound.volume, AmbientSoundEffects.volume, "\(cue)")
            XCTAssertLessThan(sound.duration, 0.6, "\(cue) should be brief")
        }
    }

    func testTurningSoundsOffStopsWhatIsPlaying() {
        let effects = AmbientSoundEffects()
        effects.sounds[.attention]?.volume = 0 // Keep the test silent; playback state is what matters.
        effects.play(.attention)
        effects.isEnabled = false
        XCTAssertFalse(effects.sounds[.attention]?.isPlaying ?? true)
    }
}
