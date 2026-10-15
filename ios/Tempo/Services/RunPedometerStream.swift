import CoreMotion
import Foundation

/// Step speed for auto-pause (#113): the real `RunMotionStreaming`, on `CMPedometer`.
///
/// GPS alone can't be trusted to say he has stopped: a fix stuck under a building reads as
/// standing still while he is running past it. `AutoPause` takes the fastest fresh reading
/// of GPS and the pedometer, so a pedometer still counting strides keeps the clock going.
/// On a treadmill it is the only speed there is.
///
/// Started only when auto-pause is on, so outdoors Motion & Fitness is only asked for by
/// someone who turned it on (`NSMotionUsageDescription`, project.yml); a treadmill run asks
/// for it regardless, for its distance (`RunStepDistanceStream`). If it is denied or unavailable,
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

/// A treadmill run's distance (#116): the real `RunStepDistanceStreaming`, on `CMPedometer`.
///
/// Core Motion's cumulative step distance since `start(from:)`, handed up as it arrives;
/// `TreadmillDistance.Steps` turns it into the curve. Its own pedometer, apart from
/// `RunPedometerStream`'s, because the two start and stop on different rules: this one runs
/// for every treadmill run, that one only when auto-pause is on.
///
/// Needs Motion & Fitness. Denied or unavailable, nothing arrives, the live distance stays
/// at zero, and the console's figure on the save screen is the run's whole distance
/// (`TreadmillDistance.evenly`).
@MainActor
final class RunStepDistanceStream: RunStepDistanceStreaming {
    var onDistance: ((Double, Date) -> Void)?

    private let pedometer = CMPedometer()

    func start(from date: Date) {
        guard CMPedometer.isDistanceAvailable() else { return }
        pedometer.startUpdates(from: date) { [weak self] data, _ in
            guard let data, let meters = data.distance?.doubleValue else { return }
            let at = data.endDate
            Task { @MainActor in self?.onDistance?(meters, at) }
        }
    }

    func stop() {
        pedometer.stopUpdates()
    }
}
