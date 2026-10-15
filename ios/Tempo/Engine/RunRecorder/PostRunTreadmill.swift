import Foundation

/// "Treadmill said…" on the save screen (#130, frame 8 of "04 · Post-run"): the console's
/// distance, typed in or stepped to, before an indoor run is saved. What it does with the
/// number is #116's (`TreadmillDistance`); what is decided here is the stepper.
///
/// The reading is held as **whole hundredths** of a mile or km, the stepper's own resolution,
/// so ±0.01 is integer arithmetic: a hundred taps up and a hundred down land exactly where
/// they started, which a `Double` stepped by 0.01 does not.
///
/// It is skippable by being left alone. The stepper opens on the phone's estimate, and Save on
/// an untouched stepper is no correction (`TreadmillDistance.correction` compares to the
/// hundredth), so the run is saved exactly as counted and never marked as edited.
extension PostRun {

    /// 0.00 to 99.99. Zero is "no reading" — the run keeps the step count; nobody's treadmill
    /// run is a hundred miles or km.
    static let consoleHundredths = 0...9_999

    /// Where the stepper opens: the step estimate, to the hundredth.
    static func consolePrefill(estimateM: Double, units: Units) -> Int {
        clampConsole(TreadmillDistance.hundredths(estimateM.isFinite ? max(0, estimateM) : 0, units))
    }

    /// One tap of − or +: `delta` hundredths, held inside the range.
    static func stepped(_ hundredths: Int, by delta: Int) -> Int {
        clampConsole(hundredths + delta)
    }

    /// Tap-to-type: what he typed, as hundredths, or nil to keep the value he had.
    ///
    /// Takes "5", "5.2", "5.25", ".8" and a comma for the decimal point ("5,25") — the decimal
    /// pad shows whichever his region uses. More decimals than two are rounded; the console
    /// shows two. Blank, not a number, negative or over the range keeps the old value rather
    /// than guessing what he meant.
    static func typedConsole(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              cleaned.filter({ $0 == "." }).count <= 1,
              let value = Double(cleaned.hasPrefix(".") ? "0" + cleaned : cleaned),
              value.isFinite
        else { return nil }
        let hundredths = Int((value * 100).rounded())
        return consoleHundredths.contains(hundredths) ? hundredths : nil
    }

    /// "5.00": the stepper's number. The unit sits beside it in its own type.
    static func consoleText(_ hundredths: Int) -> String {
        Units.fixed(Double(hundredths) / 100, decimals: 2)
    }

    /// What goes to `WorkoutRecorder.confirmSave(treadmillConsoleM:)`: the reading in metres,
    /// or nil for none. Untouched, it is the prefill, which `TreadmillDistance.correction`
    /// reads as no correction.
    static func consoleMeters(_ hundredths: Int?, units: Units) -> Double? {
        guard let hundredths, hundredths > 0 else { return nil }
        return units.meters(distance: Double(hundredths) / 100)
    }

    /// The distance the summary shows while he edits: the console's when it is a correction,
    /// else the step count — so the screen never shows a number the save would not write.
    static func shownDistanceM(estimateM: Double, consoleHundredths: Int?, units: Units) -> Double {
        let console = consoleMeters(consoleHundredths, units: units)
        guard let c = TreadmillDistance.correction(consoleM: console, estimateM: estimateM, units: units) else {
            return estimateM
        }
        return c.consoleM
    }

    /// The line under the stepper: what the phone counted, and what leaving it alone does.
    static func consoleHint(estimateM: Double, consoleHundredths: Int?, units: Units) -> String {
        let counted = estimateM > 0
            ? "Your phone counted " + units.formatDistance(meters: estimateM, decimals: 2) + " from your steps."
            : "Your phone didn't count any steps."
        let corrected = TreadmillDistance.correction(
            consoleM: consoleMeters(consoleHundredths, units: units), estimateM: estimateM, units: units) != nil
        if corrected { return counted + " The run will be saved at the treadmill's distance." }
        return estimateM > 0
            ? counted + " Set this to what the treadmill showed, or leave it."
            : counted + " Set this to what the treadmill showed, or the run is saved with no distance."
    }

    private static func clampConsole(_ hundredths: Int) -> Int {
        min(max(hundredths, consoleHundredths.lowerBound), consoleHundredths.upperBound)
    }
}
