import Foundation

// Part of the native tracking engine; see TrackingEngine.swift for the model.

// MARK: - Path sampler (mirrors PathSampler.kt — see there for the rationale)

struct SamplerTuning: Equatable {
    var tolerance: Double = 5
    var minSpacing: Double = 10
    var maxSpacingSeconds: Double = 8
    var maxSpacingMin: Double = 30
    var maxSpacingMax: Double = 200
    var speedDeltaMin: Double = 3
    var speedDeltaRatio: Double = 0.3

    static let standard = SamplerTuning()
    static let saver = SamplerTuning(tolerance: 12, minSpacing: 15, maxSpacingMax: 300)
}

final class PathSampler {
    static let sourceMove = "move"
    static let sourceTripStart = "trip_start"
    static let sourceTripEnd = "trip_end"

    private static let maxWindow = 400
    private static let maxDepartureGap: Double = 3000
    private static let assumedDepartureSpeed: Double = 1.5

    var tuning = SamplerTuning.standard
    private(set) var last: Fix?
    private var window: [Fix] = []
    private var departure: Fix?
    private var recordedInTrip = 0

    func startTrip(departureAnchor: Fix?) {
        last = nil
        window.removeAll()
        departure = departureAnchor
        recordedInTrip = 0
    }

    func resumeTrip(lastStored: Fix) {
        last = lastStored
        window.removeAll()
        departure = nil
        recordedInTrip = 1
    }

    func offer(_ fix: Fix) -> [(Fix, String)] {
        var out: [(Fix, String)] = []

        if let anchor = departure {
            departure = nil
            let gap = GeoMath.distance(anchor, fix)
            if gap >= tuning.minSpacing && gap <= PathSampler.maxDepartureGap && fix.time - anchor.time > 2 {
                let speed = fix.hasSpeed && fix.speed > 1 ? fix.speed : PathSampler.assumedDepartureSpeed
                let travelMs = Int64(gap / speed * 1000)
                let departedAt = clamp(fix.time - travelMs, anchor.time + 1, fix.time - 1)
                record(anchor.with(time: departedAt).stopped(), PathSampler.sourceTripStart, &out)
            } else {
                record(fix, PathSampler.sourceTripStart, &out)
                return out
            }
        }

        guard var reference = last else {
            record(fix, PathSampler.sourceTripStart, &out)
            return out
        }
        if fix.time <= (window.last ?? reference).time { return out }

        if !window.isEmpty && maxDeviation(reference, fix) > tuning.tolerance {
            let vertex = window[window.count - 1]
            if GeoMath.distance(reference, vertex) >= tuning.minSpacing {
                record(vertex, PathSampler.sourceMove, &out)
                reference = vertex
            } else {
                window.removeAll()
            }
        }

        let travelled = GeoMath.distance(reference, fix)
        if travelled >= maxSpacing(reference, fix, travelled) ||
            (travelled >= tuning.minSpacing && speedChanged(reference, fix)) {
            record(fix, PathSampler.sourceMove, &out)
        } else {
            window.append(fix)
            if window.count > PathSampler.maxWindow { decimateWindow() }
        }
        return out
    }

    func finishTrip(stop: Fix?) -> [(Fix, String)] {
        var out: [(Fix, String)] = []
        departure = nil
        if let reference = last {
            let tail = window.last(where: { stop == nil || $0.time < stop!.time })
            if let tail = tail,
               GeoMath.distance(reference, tail) >= tuning.minSpacing,
               stop == nil || GeoMath.distance(tail, stop!) >= tuning.minSpacing {
                record(tail, PathSampler.sourceMove, &out)
            }
        }
        if let stop = stop, recordedInTrip > 0, last == nil || stop.time > last!.time {
            record(stop.stopped(), PathSampler.sourceTripEnd, &out)
        }
        last = nil
        window.removeAll()
        recordedInTrip = 0
        return out
    }

    private func record(_ fix: Fix, _ source: String, _ out: inout [(Fix, String)]) {
        out.append((fix, source))
        last = fix
        window.removeAll()
        recordedInTrip += 1
    }

    private func maxDeviation(_ from: Fix, _ to: Fix) -> Double {
        var worst = 0.0
        for p in window {
            worst = max(worst, GeoMath.distanceToSegment(p, from, to))
        }
        return worst
    }

    private func maxSpacing(_ from: Fix, _ to: Fix, _ travelled: Double) -> Double {
        let seconds = max(1.0, Double(to.time - from.time) / 1000)
        let speed = to.hasSpeed ? to.speed : travelled / seconds
        return min(max(speed * tuning.maxSpacingSeconds, tuning.maxSpacingMin), tuning.maxSpacingMax)
    }

    private func speedChanged(_ from: Fix, _ to: Fix) -> Bool {
        guard from.hasSpeed && to.hasSpeed else { return false }
        let threshold = max(tuning.speedDeltaMin, tuning.speedDeltaRatio * from.speed)
        return abs(to.speed - from.speed) >= threshold
    }

    private func decimateWindow() {
        let lastIndex = window.count - 1
        window = window.enumerated()
            .filter { $0.offset % 2 == 1 || $0.offset == lastIndex }
            .map { $0.element }
    }

    private func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
        low > high ? high : min(max(value, low), high)
    }
}
