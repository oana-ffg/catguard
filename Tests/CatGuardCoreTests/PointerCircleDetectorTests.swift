import Foundation
import Testing

@testable import CatGuardCore

@Test func detectsClockwiseAndCounterclockwiseCircles() {
    for direction in [-1.0, 1.0] {
        var detector = PointerCircleDetector()
        let results = feedArc(
            detector: &detector,
            radius: 150,
            radians: direction * 2 * .pi
        )

        #expect(results.contains(true))
    }
}

@Test func rejectsStraightAndBacktrackingSwipes() {
    var straightDetector = PointerCircleDetector()
    for index in 0..<40 {
        let detected = straightDetector.observe(
            deltaX: 10,
            deltaY: 0,
            at: Double(index) * 0.02
        )
        #expect(!detected)
    }

    var backtrackingDetector = PointerCircleDetector()
    for index in 0..<80 {
        let deltaX = index < 40 ? 10.0 : -10.0
        let detected = backtrackingDetector.observe(
            deltaX: deltaX,
            deltaY: 0,
            at: Double(index) * 0.02
        )
        #expect(!detected)
    }
}

@Test func rejectsAnOpenArc() {
    var detector = PointerCircleDetector()
    let results = feedArc(
        detector: &detector,
        radius: 150,
        radians: 1.5 * .pi
    )

    #expect(!results.contains(true))
}

@Test func idleGapStartsANewGesture() {
    var detector = PointerCircleDetector()
    _ = feedArc(
        detector: &detector,
        radius: 150,
        radians: .pi,
        startTime: 0
    )
    let secondHalfResults = feedArc(
        detector: &detector,
        radius: 150,
        radians: .pi,
        startTime: 2
    )

    #expect(!secondHalfResults.contains(true))
}

private func feedArc(
    detector: inout PointerCircleDetector,
    radius: Double,
    radians: Double,
    startTime: TimeInterval = 0,
    steps: Int = 64,
    sampleInterval: TimeInterval = 0.015
) -> [Bool] {
    var previousX = 0.0
    var previousY = 0.0

    return (1...steps).map { step in
        let angle = radians * Double(step) / Double(steps)
        let x = radius * cos(angle) - radius
        let y = radius * sin(angle)
        defer {
            previousX = x
            previousY = y
        }
        return detector.observe(
            deltaX: x - previousX,
            deltaY: y - previousY,
            at: startTime + Double(step) * sampleInterval
        )
    }
}

@Test("High-rate movement expires the whole rolling window without changing metrics")
func rollingWindowMatchesReference() throws {
    // Large minimum spans keep the detector tracking through many window rolls.
    var detector = PointerCircleDetector(
        configuration: .init(minimumWidth: 1_000_000, minimumHeight: 1_000_000)
    )
    var points: [(x: Double, y: Double, time: Double)] = [(0, 0, 0)]
    var x = 0.0
    var y = 0.0
    for index in 0..<12_000 {
        let time = Double(index) / 1_000
        let dx = Double(index % 11) - 4
        let dy = Double(index % 7) - 2
        if dx == 0 && dy == 0 { continue }
        x += dx
        y += dy
        points.append((x, y, time))
        let detected = detector.observe(deltaX: dx, deltaY: dy, at: time)
        #expect(!detected)
        // Compare an independent full-window calculation across transfers and
        // expiration boundaries, without making the test itself quadratic.
        if index % 137 == 0, index > 0 {
            let window = points.filter { $0.time >= time - 3 }
            let first = try #require(window.first)
            let last = try #require(window.last)
            let width = window.map(\.x).max()! - window.map(\.x).min()!
            let height = window.map(\.y).max()! - window.map(\.y).min()!
            let segments = zip(window, window.dropFirst())
            let length = segments.reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let area =
                segments.reduce(0.0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
                + last.x * first.y - first.x * last.y
            let metrics = try #require(detector.latestMetrics)
            #expect(metrics.sampleCount == window.count)
            #expect(metrics.duration == last.time - first.time)
            #expect(metrics.width == width)
            #expect(metrics.height == height)
            #expect(abs(metrics.pathRatio - length / (width + height)) < 1e-9)
            #expect(abs(metrics.areaRatio - abs(area) / 2 / (width * height)) < 1e-9)
            #expect(metrics.closureRatio == hypot(last.x - first.x, last.y - first.y) / min(width, height))
        }
    }
}

@Test("A detector copy owns its rolling window independently")
func copiedDetectorIsIndependent() {
    var original = PointerCircleDetector()
    _ = feedArc(detector: &original, radius: 150, radians: .pi)
    var copy = original
    for index in 0..<4_000 {
        _ = copy.observe(deltaX: 1, deltaY: 1, at: 1 + Double(index) / 1_000)
    }
    #expect(abs((original.latestMetrics?.duration ?? 0) - 0.945) < 1e-12)
    #expect(copy.latestMetrics?.duration != original.latestMetrics?.duration)
}

@Test("Circles remain detectable at high pointer report rates", arguments: [125, 1_000])
func highRateCircles(rate: Int) {
    for direction in [-1.0, 1.0] {
        var detector = PointerCircleDetector()
        let results = feedArc(
            detector: &detector,
            radius: 150,
            radians: direction * 2 * .pi,
            steps: rate,
            sampleInterval: 1 / Double(rate)
        )
        #expect(results.contains(true))
    }
}
