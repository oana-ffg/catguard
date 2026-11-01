#!/usr/bin/env python3
"""Count circle-detector work without launching the app or installing an event tap.

Optionally pass another PointerCircleDetector.swift to measure an older revision.
Only the temporary source copy is instrumented; production has no counters.
"""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "source", nargs="?", type=Path,
    default=ROOT / "Sources/CatGuardCore/PointerCircleDetector.swift",
)
parser.add_argument("--check", action="store_true", help="assert a linear operation budget")
args = parser.parse_args()
work = ROOT / ".build/runtime-costs"
work.mkdir(parents=True, exist_ok=True)
for name in ("home", "tmp", "module-cache"):
    (work / name).mkdir(exist_ok=True)
env = dict(
    os.environ, HOME=str(work / "home"), CFFIXED_USER_HOME=str(work / "home"),
    TMPDIR=str(work / "tmp"),
)
source = args.source.read_text()
original_sample = """        let x: Double
        let y: Double
        let timestamp: TimeInterval"""
instrumented_sample = """        private let storedX: Double
        private let storedY: Double
        let timestamp: TimeInterval
        var x: Double { CostCounts.coordinateReads += 1; return storedX }
        var y: Double { CostCounts.coordinateReads += 1; return storedY }
        init(x: Double, y: Double, timestamp: TimeInterval) {
            storedX = x
            storedY = y
            self.timestamp = timestamp
        }"""
assert source.count(original_sample) == 1, "Update Sample instrumentation after a source change"
source = source.replace(original_sample, instrumented_sample).replace("hypot(", "countedHypot(")
source += """
private enum CostCounts {
    nonisolated(unsafe) static var distances = 0
    nonisolated(unsafe) static var coordinateReads = 0
}
private func countedHypot(_ x: Double, _ y: Double) -> Double {
    CostCounts.distances += 1
    return hypot(x, y)
}
"""
main = """
import Foundation
for rate in [125, 1000] {
    let events = rate * 12
    var detector = PointerCircleDetector()
    CostCounts.distances = 0
    CostCounts.coordinateReads = 0
    var detections = 0
    for index in 0..<events {
        // A long diagonal path stays guarded and fills the rolling window.
        if detector.observe(deltaX: 1, deltaY: 1, at: Double(index) / Double(rate)) {
            detections += 1
        }
    }
    print("rate=\\(rate)Hz events=\\(events) distances=\\(CostCounts.distances) coordinateReads=\\(CostCounts.coordinateReads) detections=\\(detections)")
    precondition(detections == 0)
    if CommandLine.arguments.contains("--check") {
        precondition(CostCounts.distances <= events * 4, "Distance work must stay linear")
        precondition(CostCounts.coordinateReads <= events * 40, "Coordinate work must stay linear")
    }
}
"""
# Keep counters in the same source file so their private access remains local.
combined = source + main.replace("import Foundation\n", "")
(work / "main.swift").write_text(combined)
subprocess.run(
    ["xcrun", "swiftc", "-O", "-module-cache-path", str(work / "module-cache"),
     str(work / "main.swift"), "-o", str(work / "counts")],
    env=env, check=True,
)
subprocess.run([str(work / "counts")] + (["--check"] if args.check else []), env=env, check=True)
