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
    steps: Int = 64
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
            at: startTime + Double(step) * 0.015
        )
    }
}
