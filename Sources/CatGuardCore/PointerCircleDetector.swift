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

    /// Two aggregate stacks form a FIFO window. Each sample is pushed,
    /// transferred and removed once, instead of rescanning the window per event.
    private struct PathSummary: Sendable {
        let first: Sample
        let last: Sample
        let count: Int
        let minimumX: Double
        let maximumX: Double
        let minimumY: Double
        let maximumY: Double
        let pathLength: Double
        let twiceSignedArea: Double

        init(_ sample: Sample) {
            first = sample
            last = sample
            count = 1
            minimumX = sample.x
            maximumX = sample.x
            minimumY = sample.y
            maximumY = sample.y
            pathLength = 0
            twiceSignedArea = 0
        }

        private init(first: PathSummary, second: PathSummary) {
            self.first = first.first
            last = second.last
            count = first.count + second.count
            minimumX = min(first.minimumX, second.minimumX)
            maximumX = max(first.maximumX, second.maximumX)
            minimumY = min(first.minimumY, second.minimumY)
            maximumY = max(first.maximumY, second.maximumY)
            pathLength =
                first.pathLength + second.pathLength
                + hypot(second.first.x - first.last.x, second.first.y - first.last.y)
            twiceSignedArea =
                first.twiceSignedArea + second.twiceSignedArea
                + first.last.x * second.first.y - second.first.x * first.last.y
        }

        func followed(by other: PathSummary) -> PathSummary {
            PathSummary(first: self, second: other)
        }
    }

    private struct PathWindow: Sendable {
        // The oldest sample is at outgoing.last. Incoming is in arrival order.
        private var incoming: [PathSummary] = []
        private var outgoing: [PathSummary] = []

        var summary: PathSummary? {
            switch (outgoing.last, incoming.last) {
            case (.some(let first), .some(let second)): first.followed(by: second)
            case (.some(let summary), .none), (.none, .some(let summary)): summary
            case (.none, .none): nil
            }
        }

        var isEmpty: Bool { incoming.isEmpty && outgoing.isEmpty }

        mutating func append(_ sample: Sample) {
            let next = PathSummary(sample)
            incoming.append(incoming.last.map { $0.followed(by: next) } ?? next)
        }

        mutating func discard(before cutoff: TimeInterval) {
            while true {
                if outgoing.isEmpty {
                    // Reverse once when the FIFO's front runs out. The new
                    // summaries exclude samples as they expire from the front.
                    while let entry = incoming.popLast() {
                        let next = PathSummary(entry.last)
                        outgoing.append(outgoing.last.map { next.followed(by: $0) } ?? next)
                    }
                }
                guard let first = outgoing.last, first.first.timestamp < cutoff else { return }
                outgoing.removeLast()
            }
        }

        mutating func removeAll() {
            incoming.removeAll(keepingCapacity: true)
            outgoing.removeAll(keepingCapacity: true)
        }
    }

    private let configuration: Configuration
    private var samples = PathWindow()
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
        samples.discard(before: timestamp - configuration.maximumDuration)
    }

    private func calculateMetrics() -> Metrics? {
        guard let path = samples.summary, path.count >= 3 else { return nil }
        let first = path.first
        let last = path.last
        let width = path.maximumX - path.minimumX
        let height = path.maximumY - path.minimumY
        guard width > 0, height > 0 else { return nil }
        let twiceSignedArea = path.twiceSignedArea + last.x * first.y - first.x * last.y

        let closureDistance = hypot(last.x - first.x, last.y - first.y)
        let smallerSpan = min(width, height)
        let boundingArea = width * height
        let spanSum = width + height

        return Metrics(
            sampleCount: path.count,
            duration: last.timestamp - first.timestamp,
            width: width,
            height: height,
            closureRatio: closureDistance / smallerSpan,
            areaRatio: abs(twiceSignedArea) / 2 / boundingArea,
            pathRatio: path.pathLength / spanSum
        )
    }

    private mutating func resetPath() {
        samples.removeAll()
        currentX = 0
        currentY = 0
        lastMotionAt = nil
    }
}
