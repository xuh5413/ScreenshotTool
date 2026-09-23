public struct LongScreenshotFrameSignature: Sendable {
    public let rows: [[Int]]

    public init(rows: [[Int]]) {
        self.rows = rows
    }
}

public enum LongScreenshotScrollDirection: Sendable, Hashable {
    case down
    case up
}

public struct LongScreenshotMatch: Sendable {
    public let direction: LongScreenshotScrollDirection
    public let scrollDistance: Int
    public let fixedTopRows: Int
    public let fixedBottomRows: Int
    public let confidence: Double

    public init(
        direction: LongScreenshotScrollDirection,
        scrollDistance: Int,
        fixedTopRows: Int,
        fixedBottomRows: Int,
        confidence: Double
    ) {
        self.direction = direction
        self.scrollDistance = scrollDistance
        self.fixedTopRows = fixedTopRows
        self.fixedBottomRows = fixedBottomRows
        self.confidence = confidence
    }
}

public struct LongScreenshotSegmentPlan: Sendable {
    public let initialFrameRows: Range<Int>
    public let newFrameRows: Range<Int>
    public let finalFixedRows: Range<Int>
}

public struct LongScreenshotStitchingAnchor: Sendable {
    public let fixedTopRows: Int
    public let fixedBottomRows: Int
    public let trailingGuardRows: Int

    public init(frameHeight: Int, firstMatch: LongScreenshotMatch, trailingGuardRows: Int) {
        let top = max(0, min(firstMatch.fixedTopRows, frameHeight))
        let bottom = max(0, min(firstMatch.fixedBottomRows, frameHeight - top))
        let bodyHeight = max(0, frameHeight - top - bottom)
        self.fixedTopRows = top
        self.fixedBottomRows = bottom
        self.trailingGuardRows = max(0, min(trailingGuardRows, max(0, bodyHeight - 1)))
    }
}

public enum LongScreenshotSegmentPlanner {
    public static func plan(
        frameHeight: Int,
        match: LongScreenshotMatch,
        anchor: LongScreenshotStitchingAnchor
    ) -> LongScreenshotSegmentPlan? {
        plan(
            frameHeight: frameHeight,
            match: LongScreenshotMatch(
                direction: match.direction,
                scrollDistance: match.scrollDistance,
                fixedTopRows: anchor.fixedTopRows,
                fixedBottomRows: anchor.fixedBottomRows,
                confidence: match.confidence
            ),
            trailingGuardRows: anchor.trailingGuardRows
        )
    }

    public static func plan(
        frameHeight: Int,
        match: LongScreenshotMatch,
        trailingGuardRows: Int = 0
    ) -> LongScreenshotSegmentPlan? {
        let top = max(0, min(match.fixedTopRows, frameHeight))
        let bottom = max(0, min(match.fixedBottomRows, frameHeight - top))
        let bodyEnd = frameHeight - bottom
        let bodyHeight = bodyEnd - top
        let guardRows = max(0, min(trailingGuardRows, max(0, bodyHeight - 1)))
        let distance = match.scrollDistance
        guard distance > 0, distance <= bodyHeight - guardRows else { return nil }

        switch match.direction {
        case .down:
            let safeBodyEnd = bodyEnd - guardRows
            return LongScreenshotSegmentPlan(
                initialFrameRows: 0..<safeBodyEnd,
                newFrameRows: (safeBodyEnd - distance)..<safeBodyEnd,
                finalFixedRows: safeBodyEnd..<frameHeight
            )
        case .up:
            let safeBodyStart = top + guardRows
            return LongScreenshotSegmentPlan(
                initialFrameRows: safeBodyStart..<frameHeight,
                newFrameRows: safeBodyStart..<(safeBodyStart + distance),
                finalFixedRows: 0..<safeBodyStart
            )
        }
    }
}

public struct LongScreenshotMatcher: Sendable {
    public init() {}

    public func match(
        previous: LongScreenshotFrameSignature,
        current: LongScreenshotFrameSignature,
        expectedDistance: Int? = nil
    ) -> LongScreenshotMatch? {
        let height = previous.rows.count
        guard height == current.rows.count,
              height >= 6,
              let blockCount = previous.rows.first?.count,
              blockCount > 0,
              previous.rows.allSatisfy({ $0.count == blockCount }),
              current.rows.allSatisfy({ $0.count == blockCount }) else {
            return nil
        }

        let minimumOverlap = min(40, max(3, height / 10))
        let maximumDistance = height - minimumOverlap
        if let expectedDistance,
           (1...maximumDistance).contains(expectedDistance),
           let fastMatch = matchNearExpectedDistance(
               previous: previous.rows,
               current: current.rows,
               expectedDistance: expectedDistance,
               maximumDistance: maximumDistance
           ) {
            return fastMatch
        }

        var coarseCandidates: [(direction: LongScreenshotScrollDirection, distance: Int, score: Double)] = []
        coarseCandidates.reserveCapacity(maximumDistance * 2)
        for distance in 1...maximumDistance {
            for direction in [LongScreenshotScrollDirection.down, .up] {
                let rawScore = quickOverlapScore(
                    previous: previous.rows,
                    current: current.rows,
                    distance: distance,
                    direction: direction,
                    maximumRowSamples: 24
                )
                coarseCandidates.append((direction, distance, regularized(rawScore, distance: distance, height: height)))
            }
        }

        coarseCandidates.sort { lhs, rhs in
            if lhs.score == rhs.score, let expectedDistance {
                let lhsDistance = abs(lhs.distance - expectedDistance)
                let rhsDistance = abs(rhs.distance - expectedDistance)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            }
            if lhs.score == rhs.score { return lhs.distance < rhs.distance }
            return lhs.score < rhs.score
        }

        var finalists = Array(coarseCandidates.prefix(64))
        if let expectedDistance {
            for distance in max(1, expectedDistance - 16)...min(maximumDistance, expectedDistance + 16) {
                for direction in [LongScreenshotScrollDirection.down, .up]
                where !finalists.contains(where: { $0.direction == direction && $0.distance == distance }) {
                    finalists.append((direction, distance, 0))
                }
            }
        }

        for sparseTextFallback in [false, true] {
            var candidates = finalists.map { candidate in
                let rawScore = overlapScore(
                    previous: previous.rows,
                    current: current.rows,
                    distance: candidate.distance,
                    direction: candidate.direction,
                    maximumRowSamples: 512,
                    sparseTextFallback: sparseTextFallback
                )
                return (
                    direction: candidate.direction,
                    distance: candidate.distance,
                    score: regularized(rawScore, distance: candidate.distance, height: height)
                )
            }

            candidates.sort { lhs, rhs in
                if lhs.score == rhs.score, let expectedDistance {
                    let lhsDistance = abs(lhs.distance - expectedDistance)
                    let rhsDistance = abs(rhs.distance - expectedDistance)
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                }
                if lhs.score == rhs.score { return lhs.distance < rhs.distance }
                return lhs.score < rhs.score
            }
            guard let best = candidates.first, best.score <= 12 else { continue }

            let secondDistinct = candidates.dropFirst().first {
                $0.direction != best.direction || abs($0.distance - best.distance) > 1
            }
            let separation = max(0, (secondDistinct?.score ?? 255) - best.score)
            // Sparse scores are smaller, so require a real score gap without
            // imposing the dense signature's one-point normalization floor.
            let scoreFloor = sparseTextFallback ? 0.5 : 1.0
            let confidence = min(1, separation / max(scoreFloor, best.score))
            guard confidence >= 0.2 else { continue }

            return LongScreenshotMatch(
                direction: best.direction,
                scrollDistance: best.distance,
                fixedTopRows: fixedTopRows(
                    previous: previous.rows,
                    current: current.rows,
                    distance: best.distance,
                    direction: best.direction
                ),
                fixedBottomRows: fixedBottomRows(
                    previous: previous.rows,
                    current: current.rows,
                    distance: best.distance,
                    direction: best.direction
                ),
                confidence: confidence
            )
        }
        return nil
    }

    // Most adjacent accepted frames move by roughly the same amount. A clearly
    // unique nearby alignment avoids scanning every possible displacement;
    // uncertain results still use the exhaustive search above.
    private func matchNearExpectedDistance(
        previous: [[Int]],
        current: [[Int]],
        expectedDistance: Int,
        maximumDistance: Int
    ) -> LongScreenshotMatch? {
        let height = previous.count
        let radius = max(24, expectedDistance / 4)
        let lower = max(1, expectedDistance - radius)
        let upper = min(maximumDistance, expectedDistance + radius)
        var nearby: [(direction: LongScreenshotScrollDirection, distance: Int, score: Double)] = []
        nearby.reserveCapacity((upper - lower + 1) * 2)
        for distance in lower...upper {
            for direction in [LongScreenshotScrollDirection.down, .up] {
                let rawScore = quickOverlapScore(
                    previous: previous,
                    current: current,
                    distance: distance,
                    direction: direction,
                    maximumRowSamples: 24
                )
                nearby.append((direction, distance, regularized(rawScore, distance: distance, height: height)))
            }
        }
        nearby.sort { $0.score < $1.score }
        guard let coarseBest = nearby.first,
              coarseBest.distance > lower,
              coarseBest.distance < upper,
              coarseBest.score <= 3 else { return nil }

        let finalists = nearby.prefix(12).map { candidate in
            (
                direction: candidate.direction,
                distance: candidate.distance,
                score: regularized(
                    overlapScore(
                        previous: previous,
                        current: current,
                        distance: candidate.distance,
                        direction: candidate.direction,
                        maximumRowSamples: 512,
                        sparseTextFallback: false
                    ),
                    distance: candidate.distance,
                    height: height
                )
            )
        }.sorted { $0.score < $1.score }
        guard let best = finalists.first,
              best.distance > lower,
              best.distance < upper,
              best.score <= 3,
              let secondDistinct = finalists.dropFirst().first(where: {
                  $0.direction != best.direction || abs($0.distance - best.distance) > 1
              }),
              secondDistinct.score - best.score >= 3 else { return nil }

        return LongScreenshotMatch(
            direction: best.direction,
            scrollDistance: best.distance,
            fixedTopRows: fixedTopRows(
                previous: previous,
                current: current,
                distance: best.distance,
                direction: best.direction
            ),
            fixedBottomRows: fixedBottomRows(
                previous: previous,
                current: current,
                distance: best.distance,
                direction: best.direction
            ),
            confidence: min(1, (secondDistinct.score - best.score) / max(1, best.score))
        )
    }

    private func regularized(_ score: Double, distance: Int, height: Int) -> Double {
        score + Double(distance) / Double(height) * 0.5
    }

    private func quickOverlapScore(
        previous: [[Int]],
        current: [[Int]],
        distance: Int,
        direction: LongScreenshotScrollDirection,
        maximumRowSamples: Int
    ) -> Double {
        let count = previous.count - distance
        let rowStep = max(1, count / max(1, maximumRowSamples))
        let blockCount = previous[0].count
        var total = 0
        var samples = 0
        for row in stride(from: 0, to: count, by: rowStep) {
            let previousRow = direction == .down ? row + distance : row
            let currentRow = direction == .down ? row : row + distance
            for block in 0..<blockCount {
                total += abs(previous[previousRow][block] - current[currentRow][block])
                samples += 1
            }
        }
        return samples > 0 ? Double(total) / Double(samples) : .infinity
    }

    private func overlapScore(
        previous: [[Int]],
        current: [[Int]],
        distance: Int,
        direction: LongScreenshotScrollDirection,
        maximumRowSamples: Int,
        sparseTextFallback: Bool
    ) -> Double {
        let count = previous.count - distance
        var rowScores: [Double] = []
        rowScores.reserveCapacity(count)

        let rowStep = max(1, count / max(1, maximumRowSamples))
        for row in stride(from: 0, to: count, by: rowStep) {
            let previousRow = direction == .down ? row + distance : row
            let currentRow = direction == .down ? row : row + distance
            rowScores.append(sparseTextFallback
                ? sparseTextRowDifference(previous[previousRow], current[currentRow])
                : rowDifference(previous[previousRow], current[currentRow]))
        }

        rowScores.sort()
        let keepCount = min(rowScores.count, max(3, Int(Double(rowScores.count) * 0.7)))
        if sparseTextFallback {
            // Retain occasional text lines that the 70% trimmed mean discards.
            return rowScores.reduce(0) { $0 + min($1, 24) } / Double(rowScores.count)
        }
        let kept = rowScores.prefix(keepCount)
        return kept.reduce(0, +) / Double(kept.count)
    }

    private func fixedTopRows(
        previous: [[Int]],
        current: [[Int]],
        distance: Int,
        direction: LongScreenshotScrollDirection
    ) -> Int {
        let limit = min(previous.count / 3, previous.count - distance)
        var lastEvidenceRow: Int?
        for row in 0..<limit {
            let shiftedPrevious = direction == .down ? row + distance : row
            let shiftedCurrent = direction == .down ? row : row + distance
            let same = rowDifference(previous[row], current[row])
            let shifted = rowDifference(previous[shiftedPrevious], current[shiftedCurrent])
            guard same <= 6 else { break }
            if shifted >= same + 12 {
                lastEvidenceRow = row
            }
        }
        return lastEvidenceRow.map { $0 + 1 } ?? 0
    }

    private func fixedBottomRows(
        previous: [[Int]],
        current: [[Int]],
        distance: Int,
        direction: LongScreenshotScrollDirection
    ) -> Int {
        let height = previous.count
        let limit = min(height / 3, height - distance)
        var lastEvidenceOffset: Int?
        for offset in 0..<limit {
            let row = height - 1 - offset
            let shiftedPrevious = direction == .down ? row : row - distance
            let shiftedCurrent = direction == .down ? row - distance : row
            guard shiftedPrevious >= 0, shiftedCurrent >= 0 else { break }
            let same = rowDifference(previous[row], current[row])
            let shifted = rowDifference(previous[shiftedPrevious], current[shiftedCurrent])
            guard same <= 6 else { break }
            if shifted >= same + 12 {
                lastEvidenceOffset = offset
            }
        }
        return lastEvidenceOffset.map { $0 + 1 } ?? 0
    }

    private func rowDifference(_ lhs: [Int], _ rhs: [Int]) -> Double {
        var blockScores: [Int] = []
        blockScores.reserveCapacity(lhs.count)
        for index in lhs.indices {
            blockScores.append(abs(lhs[index] - rhs[index]))
        }
        blockScores.sort()
        let keepCount = max(1, Int(Double(blockScores.count) * 0.75))
        return Double(blockScores.prefix(keepCount).reduce(0, +)) / Double(keepCount)
    }

    private func sparseTextRowDifference(_ lhs: [Int], _ rhs: [Int]) -> Double {
        var total = 0
        for index in lhs.indices {
            total += min(abs(lhs[index] - rhs[index]), 64)
        }
        return Double(total) / Double(lhs.count)
    }
}
