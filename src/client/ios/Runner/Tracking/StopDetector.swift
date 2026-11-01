import Foundation

// Part of the native tracking engine; see TrackingEngine.swift for the model.

// MARK: - Stop detector (mirrors StopDetector.kt)

final class StopDetector {
    static let movingSpeed: Double = 2.5

    private let radius: Double = 40
    private let maxRadius: Double = 100
    private var start: Fix?
    private var weightSum = 0.0
    private var latSum = 0.0
    private var lonSum = 0.0
    private var bestAccuracy = Fix.unknownAccuracy

    func reset() {
        start = nil
        weightSum = 0
        latSum = 0
        lonSum = 0
        bestAccuracy = Fix.unknownAccuracy
    }

    func offer(_ fix: Fix, timeout: TimeInterval) -> Fix? {
        let movingFast = fix.hasSpeed && fix.speed > StopDetector.movingSpeed
        guard let first = start, !movingFast, inside(fix, first: first) else {
            begin(fix)
            return nil
        }
        add(fix)
        return Double(fix.time - first.time) >= timeout * 1000 ? currentStop() : nil
    }

    func currentStop() -> Fix? {
        guard let first = start else { return nil }
        return Fix(time: first.time, lat: latSum / weightSum, lon: lonSum / weightSum, accuracy: bestAccuracy, speed: 0)
    }

    private func inside(_ fix: Fix, first: Fix) -> Bool {
        let r = max(radius, min(maxRadius, 1.5 * fix.accuracy))
        return GeoMath.distance(first, fix) <= r &&
            GeoMath.distance(latSum / weightSum, lonSum / weightSum, fix.lat, fix.lon) <= r
    }

    private func begin(_ fix: Fix) {
        reset()
        start = fix
        add(fix)
    }

    private func add(_ fix: Fix) {
        let accuracy = max(3.0, fix.hasAccuracy ? fix.accuracy : maxRadius)
        let weight = 1 / (accuracy * accuracy)
        weightSum += weight
        latSum += fix.lat * weight
        lonSum += fix.lon * weight
        bestAccuracy = min(bestAccuracy, fix.accuracy)
    }
}
