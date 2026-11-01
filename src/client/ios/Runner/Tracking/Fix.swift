import CoreLocation
import Foundation

// Part of the native tracking engine; see TrackingEngine.swift for the model.

// MARK: - Fix and geometry

struct Fix {
    static let unknownAccuracy = Double.greatestFiniteMagnitude

    /// UTC epoch milliseconds of the observation.
    var time: Int64
    var lat: Double
    var lon: Double
    /// Metres (68% radius); [unknownAccuracy] when absent.
    var accuracy: Double
    /// m/s, negative when unknown.
    var speed: Double = -1
    /// Degrees, negative when unknown.
    var bearing: Double = -1
    var altitude: Double? = nil

    var hasSpeed: Bool { speed >= 0 }
    var hasAccuracy: Bool { accuracy < Fix.unknownAccuracy }
}

extension Fix {
    init(location: CLLocation) {
        self.init(
            time: Int64((location.timestamp.timeIntervalSince1970 * 1000).rounded()),
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : Fix.unknownAccuracy,
            speed: location.speed >= 0 ? location.speed : -1,
            bearing: location.course >= 0 ? location.course : -1,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
    }

    func with(time newTime: Int64) -> Fix {
        var copy = self
        copy.time = newTime
        return copy
    }

    func stopped() -> Fix {
        var copy = self
        copy.speed = 0
        copy.bearing = -1
        return copy
    }
}

enum GeoMath {
    private static let earthRadius = 6_371_008.8
    private static let metresPerDegree = earthRadius * Double.pi / 180

    static func distance(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * Double.pi / 180
        let dLon = (bLon - aLon) * Double.pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) +
            cos(aLat * Double.pi / 180) * cos(bLat * Double.pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(sqrt(min(max(h, 0), 1)))
    }

    static func distance(_ a: Fix, _ b: Fix) -> Double {
        distance(a.lat, a.lon, b.lat, b.lon)
    }

    /// Distance from p to the segment a→b (local equirectangular projection).
    static func distanceToSegment(_ p: Fix, _ a: Fix, _ b: Fix) -> Double {
        let cosLat = cos(a.lat * Double.pi / 180)
        let bx = (b.lon - a.lon) * cosLat * metresPerDegree
        let by = (b.lat - a.lat) * metresPerDegree
        let px = (p.lon - a.lon) * cosLat * metresPerDegree
        let py = (p.lat - a.lat) * metresPerDegree
        let lengthSq = bx * bx + by * by
        let t = lengthSq <= 0 ? 0 : min(max((px * bx + py * by) / lengthSq, 0), 1)
        let dx = px - t * bx
        let dy = py - t * by
        return sqrt(dx * dx + dy * dy)
    }
}
