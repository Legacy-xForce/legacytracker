import XCTest
@testable import Runner

/// Replays the vectors the Android engine wrote (`TrackingVectorsTest.kt`) through the Swift
/// PathSampler and StopDetector: both engines must store the same points and stop at the same fix.
final class TrackingVectorsTests: XCTestCase {
    private struct Vectors: Decodable {
        let sampler: [SamplerCase]
        let stop: [StopCase]
    }

    private struct SamplerCase: Decodable {
        let name: String
        let anchor: [Double]?
        let stop_at_last_fix: Bool
        let fixes: [[Double]]
        let stored: [StoredPoint]
    }

    private struct StopCase: Decodable {
        let name: String
        let timeout_s: Double
        let fixes: [[Double]]
        let stop_index: Int?
        let stop: [Double]?
    }

    /// `[time_ms, lat, lon, source]`.
    private struct StoredPoint: Decodable {
        let time: Int64
        let lat: Double
        let lon: Double
        let source: String

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            time = try row.decode(Int64.self)
            lat = try row.decode(Double.self)
            lon = try row.decode(Double.self)
            source = try row.decode(String.self)
        }
    }

    /// The vectors live with the Flutter tests: src/client/test/fixtures/.
    private func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RunnerTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // src/client
            .appendingPathComponent("test/fixtures/tracking-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    /// `[time_ms, lat, lon, accuracy_m, speed_ms, bearing_deg]`.
    private func fix(_ row: [Double]) -> Fix {
        Fix(time: Int64(row[0]), lat: row[1], lon: row[2], accuracy: row[3], speed: row[4], bearing: row[5])
    }

    /// Stored coordinates are written with 7 decimals.
    private let tolerance = 1e-6

    func testSamplerMatchesAndroid() throws {
        for c in try load().sampler {
            let fixes = c.fixes.map(fix)
            let sampler = PathSampler()
            sampler.startTrip(departureAnchor: c.anchor.map(fix))
            var stored: [(Fix, String)] = []
            for f in fixes { stored += sampler.offer(f) }
            stored += sampler.finishTrip(stop: c.stop_at_last_fix ? fixes.last : nil)

            XCTAssertEqual(stored.count, c.stored.count, "\(c.name): stored point count")
            for (i, (got, want)) in zip(stored, c.stored).enumerated() {
                XCTAssertEqual(got.0.time, want.time, "\(c.name) #\(i): time")
                XCTAssertEqual(got.1, want.source, "\(c.name) #\(i): source")
                XCTAssertEqual(got.0.lat, want.lat, accuracy: tolerance, "\(c.name) #\(i): lat")
                XCTAssertEqual(got.0.lon, want.lon, accuracy: tolerance, "\(c.name) #\(i): lon")
            }
        }
    }

    func testStopDetectorMatchesAndroid() throws {
        for c in try load().stop {
            let detector = StopDetector()
            var index: Int?
            var stop: Fix?
            for (i, row) in c.fixes.enumerated() {
                if let found = detector.offer(fix(row), timeout: c.timeout_s) {
                    index = i
                    stop = found
                    break
                }
            }
            XCTAssertEqual(index, c.stop_index, "\(c.name): stop index")
            if let want = c.stop, let got = stop {
                XCTAssertEqual(got.time, Int64(want[0]), "\(c.name): stop time")
                XCTAssertEqual(got.lat, want[1], accuracy: tolerance, "\(c.name): stop lat")
                XCTAssertEqual(got.lon, want[2], accuracy: tolerance, "\(c.name): stop lon")
            }
        }
    }
}
