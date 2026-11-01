import Foundation

public struct PointerCircleDetector: Sendable {
    public struct Configuration: Sendable {
        public var minimumWidth: Double
        public var minimumHeight: Double
        public var minimumDuration: TimeInterval
        public var maximumDuration: TimeInterval
        public var maximumIdleGap: TimeInterval
        public var maximumClosureRatio: Double
        public var minimumAreaRatio: Double
        public var minimumPathRatio: Double
        public var maximumPathRatio: Double
        public var minimumSampleCount: Int

        public init(
            minimumWidth: Double = 120,
            minimumHeight: Double = 120,
            minimumDuration: TimeInterval = 0.2,
            maximumDuration: TimeInterval = 3,
            maximumIdleGap: TimeInterval = 0.35,
            maximumClosureRatio: Double = 0.4,
            minimumAreaRatio: Double = 0.2,
            minimumPathRatio: Double = 1.2,
            maximumPathRatio: Double = 6,
            minimumSampleCount: Int = 12
        ) {
            precondition(minimumWidth > 0)
            precondition(minimumHeight > 0)
            precondition(minimumDuration >= 0)
            precondition(maximumDuration > minimumDuration)
            precondition(maximumIdleGap > 0)
            precondition(maximumClosureRatio > 0)
            precondition(minimumAreaRatio > 0)
            precondition(minimumPathRatio > 0)
            precondition(maximumPathRatio > minimumPathRatio)
            precondition(minimumSampleCount >= 3)

            self.minimumWidth = minimumWidth
            self.minimumHeight = minimumHeight
            self.minimumDuration = minimumDuration
            self.maximumDuration = maximumDuration
            self.maximumIdleGap = maximumIdleGap
            self.maximumClosureRatio = maximumClosureRatio
            self.minimumAreaRatio = minimumAreaRatio
            self.minimumPathRatio = minimumPathRatio
            self.maximumPathRatio = maximumPathRatio
            self.minimumSampleCount = minimumSampleCount
        }
    }

    public struct Metrics: Sendable {
        public let sampleCount: Int
        public let duration: TimeInterval
        public let width: Double
        public let height: Double
        public let closureRatio: Double
        public let areaRatio: Double
        public let pathRatio: Double
    }

    private struct Sample: Sendable {
        let x: Double
        let y: Double
        let timestamp: TimeInterval
    }

    private let configuration: Configuration
    private var samples: [Sample] = []
    private var currentX = 0.0
    private var currentY = 0.0
    private var lastMotionAt: TimeInterval?
    public private(set) var latestMetrics: Metrics?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func observe(
        deltaX: Double,
        deltaY: Double,
        at timestamp: TimeInterval
    ) -> Bool {
        guard deltaX != 0 || deltaY != 0 else { return false }

        if let lastMotionAt,
            timestamp < lastMotionAt || timestamp - lastMotionAt > configuration.maximumIdleGap
        {
            resetPath()
        }

        if samples.isEmpty {
            samples.append(Sample(x: currentX, y: currentY, timestamp: timestamp))
        }

        currentX += deltaX
        currentY += deltaY
        lastMotionAt = timestamp
        samples.append(Sample(x: currentX, y: currentY, timestamp: timestamp))
        discardExpiredSamples(at: timestamp)

        guard let metrics = calculateMetrics() else { return false }
        latestMetrics = metrics

        let isCircle =
            metrics.sampleCount >= configuration.minimumSampleCount
            && metrics.duration >= configuration.minimumDuration
            && metrics.width >= configuration.minimumWidth
            && metrics.height >= configuration.minimumHeight
            && metrics.closureRatio <= configuration.maximumClosureRatio
            && metrics.areaRatio >= configuration.minimumAreaRatio
            && metrics.pathRatio >= configuration.minimumPathRatio
            && metrics.pathRatio <= configuration.maximumPathRatio

        if isCircle {
            resetPath()
        }
        return isCircle
    }

    private mutating func discardExpiredSamples(at timestamp: TimeInterval) {
        let cutoff = timestamp - configuration.maximumDuration
        if let firstValidIndex = samples.firstIndex(where: { $0.timestamp >= cutoff }),
            firstValidIndex > 0
        {
            samples.removeFirst(firstValidIndex)
        }
    }

    private func calculateMetrics() -> Metrics? {
        guard samples.count >= 3,
            let first = samples.first,
            let last = samples.last
        else {
            return nil
        }

        let minimumX = samples.lazy.map(\.x).min() ?? 0
        let maximumX = samples.lazy.map(\.x).max() ?? 0
        let minimumY = samples.lazy.map(\.y).min() ?? 0
        let maximumY = samples.lazy.map(\.y).max() ?? 0
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width > 0, height > 0 else { return nil }

        var pathLength = 0.0
        var twiceSignedArea = 0.0
        for (start, end) in zip(samples, samples.dropFirst()) {
            pathLength += hypot(end.x - start.x, end.y - start.y)
            twiceSignedArea += start.x * end.y - end.x * start.y
        }
        twiceSignedArea += last.x * first.y - first.x * last.y

        let closureDistance = hypot(last.x - first.x, last.y - first.y)
        let smallerSpan = min(width, height)
        let boundingArea = width * height
        let spanSum = width + height

        return Metrics(
            sampleCount: samples.count,
            duration: last.timestamp - first.timestamp,
            width: width,
            height: height,
            closureRatio: closureDistance / smallerSpan,
            areaRatio: abs(twiceSignedArea) / 2 / boundingArea,
            pathRatio: pathLength / spanSum
        )
    }

    private mutating func resetPath() {
        samples.removeAll(keepingCapacity: true)
        currentX = 0
        currentY = 0
        lastMotionAt = nil
    }
}
