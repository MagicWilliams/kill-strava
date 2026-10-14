import CoreMotion
import Foundation

/// Step speed for auto-pause (#113): the real `RunMotionStreaming`, on `CMPedometer`.
///
/// GPS alone can't be trusted to say he has stopped: a fix stuck under a building reads as
/// standing still while he is running past it. `AutoPause` takes the fastest fresh reading
/// of GPS and the pedometer, so a pedometer still counting strides keeps the clock going.
/// On a treadmill it is the only speed there is.
///
/// Started only when auto-pause is on, so Motion & Fitness is only asked for by someone who
/// turned it on (`NSMotionUsageDescription`, project.yml). If it is denied or unavailable,
/// nothing arrives, and auto-pause works from GPS alone outdoors and not at all indoors —
/// it never pauses on a reading it doesn't have.
@MainActor
final class RunPedometerStream: RunMotionStreaming {
    var onSample: ((AutoPause.Sample) -> Void)?

    private let pedometer = CMPedometer()
    private var previous: (at: Date, meters: Double)?

    func start(from date: Date) {
        guard CMPedometer.isStepCountingAvailable() else { return }
        previous = nil
        pedometer.startUpdates(from: date) { [weak self] data, _ in
            guard let data else { return }
            let at = data.endDate
            let meters = data.distance?.doubleValue
            let pace = data.currentPace?.doubleValue   // seconds per metre
            Task { @MainActor in self?.receive(at: at, meters: meters, pace: pace) }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        previous = nil
    }

    private func receive(at: Date, meters: Double?, pace: Double?) {
        defer { if let meters { previous = (at, meters) } }
        let speed: Double
        if let pace, pace > 0 {
            speed = 1 / pace
        } else if let meters, let previous, at > previous.at {
            // No pace from Core Motion: the distance it counted since the last update.
            speed = max(0, meters - previous.meters) / at.timeIntervalSince(previous.at)
        } else {
            return
        }
        onSample?(AutoPause.Sample(at: at, speed: speed, source: .pedometer))
    }
}
