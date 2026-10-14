import AVFoundation
import Foundation

/// Says the recorder's cues out loud over whatever the athlete is listening to (#118).
///
/// The words come from `CueText`; this file only owns the synthesizer and the audio session.
/// The recording service (#114) calls it: `speakSplit` when `CueText.splitToAnnounce` returns a
/// split, `speak(_: AutoPause.Decision)` for every auto-pause decision (#113), and
/// `speakRaceDistance` when `CueText.crossed` the race distance (#117). Each call is
/// fire-and-forget and never throws: a cue that can't be said is skipped, and the run goes on.
///
/// The audio session, and why each piece is there:
///
/// - **`.playback`, so the silent switch doesn't mute it.** Decided with David: runners keep the
///   ringer on silent, and a cue that only works with the switch off is a cue that never
///   plays. `.ambient` / `.soloAmbient` obey the switch; `.playback` doesn't. This is also the
///   category the `audio` background mode (#110) exists for, which is what lets a cue start
///   with the phone locked in a pocket.
/// - **`.duckOthers`**: Spotify or Apple Music drops in volume under the voice instead of
///   stopping, or the voice being lost under it.
/// - **`.mixWithOthers`**: never take over the music. Without it, activating the session
///   stops whatever else is playing.
/// - **`.voicePrompt` mode**: Apple's mode for short spoken prompts (navigation-style), tuned
///   for speech over other audio.
/// - **Deactivated after every cue, with `.notifyOthersOnDeactivation`.** A ducked app stays
///   ducked for as long as our session is active. Deactivating is what puts the music back at
///   full volume; the notify option is what tells the other app it can.
@MainActor
final class CueSpeaker: NSObject {

    /// The voice-cues setting (on unless switched off), in `UserDefaults` like the shoe
    /// retirement mileage: a device preference, not training data. The toggle on You waits for
    /// the recorder's Figma sign-off; until then, a missing key is on.
    static let enabledKey = "recorder.voiceCuesEnabled"

    /// `CueText` writes English, so the voice is English regardless of the phone's language.
    /// A German voice reading "Mile three. Seven forty-one." is worse than no cue.
    static let voiceLanguage = "en-US"

    /// How long after the last word before the session is let go. `didFinish` arrives slightly
    /// before the synthesizer's audio unit has stopped; deactivating inside it can fail as
    /// "busy" and leave the music ducked, which is exactly the failure this file exists to
    /// prevent.
    private static let releaseDelay: Duration = .milliseconds(300)

    private let synthesizer = AVSpeechSynthesizer()
    private let session: AVAudioSession
    private let defaults: UserDefaults
    /// Utterances handed to the synthesizer and not yet finished or cancelled. The session is
    /// only deactivated at zero, so back-to-back cues don't un-duck the music between them.
    private var inFlight = 0
    private var release: Task<Void, Never>?

    init(session: AVAudioSession = .sharedInstance(), defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        super.init()
        synthesizer.delegate = self
        // Speak through our session (configured below), not the synthesizer's own, so the
        // category, ducking and deactivation are ours to control.
        synthesizer.usesApplicationAudioSession = true
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - What #114 calls

    /// A finished split from `TrackMath`. The partial split in progress is never said.
    func speakSplit(_ split: TrackMath.Split, averagePaceS: Double?, units: Units) {
        guard let text = CueText.split(split, averagePaceS: averagePaceS, units: units) else { return }
        speak(text)
    }

    /// A split by number, for a caller that has the paces but not a `TrackMath.Split`.
    func speakSplit(index: Int, paceS: Double, averagePaceS: Double?, units: Units) {
        speak(CueText.split(index: index, paceS: paceS, averagePaceS: averagePaceS, units: units))
    }

    /// Every auto-pause decision is said (#113), so an auto pause is never silent.
    func speak(_ decision: AutoPause.Decision) {
        speak(CueText.autoPause(decision))
    }

    func speakAutoPause() { speak(CueText.autoPaused) }

    func speakAutoResume() { speak(CueText.autoResumed) }

    /// The race distance has been reached on GPS, which is before the mat (#117).
    func speakRaceDistance(meters: Double, elapsedS: Double, averagePaceS: Double?, units: Units) {
        speak(CueText.raceDistance(meters: meters, elapsedS: elapsedS, averagePaceS: averagePaceS, units: units))
    }

    /// Cut off anything being said and give the audio back: the run ended or was discarded.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        // `didCancel` brings `inFlight` to zero and schedules the release.
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        release?.cancel()
        release = nil
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true)
        } catch {
            // Most often a phone call holding the audio. Skip this cue rather than queue it:
            // a split pace said two minutes late, after the call, is a wrong number.
            Telemetry.error("recorder.cue_session_failed", error)
            if inFlight == 0 { scheduleRelease() }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage)
        inFlight += 1
        synthesizer.speak(utterance)
    }

    fileprivate func utteranceEnded() {
        inFlight = max(inFlight - 1, 0)
        if inFlight == 0 { scheduleRelease() }
    }

    private func scheduleRelease() {
        release?.cancel()
        release = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled, let self, self.inFlight == 0 else { return }
            do {
                try self.session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Telemetry.error("recorder.cue_release_failed", error)
            }
        }
    }
}

extension CueSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }
}
