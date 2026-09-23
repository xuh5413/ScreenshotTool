import LongScreenshotCore

@main
struct LongScreenshotCoreChecks {
    static func main() {
        testDetectsDownwardScrollWhileIgnoringFixedHeaderAndFooter()
        testRejectsAmbiguousRepeatedContent()
        testPlansDownwardSegmentsWithoutRepeatingFixedRegions()
        testIncludesNeutralEdgeRowsInFixedHeader()
        testDelaysBottomGuardBandToAvoidRepeatingFloatingControls()
        testIgnoresChangingSideBlocksDuringMatching()
        testDetectsUpwardScroll()
        testMatchesRetinaSizedBrowserFrame()
        testFindsLargeScrollAfterSmallExpectedDistance()
        testKeepsFirstFrameAnchorAcrossLaterMatches()
        testMatchesSparseTextAcrossNarrowColumn()
        testMatchesSparseTextBetweenCoarseSampledBlocks()
        testMatchesSparseTextLinesAcrossWideColumn()
        testFrameBufferPreservesIntermediateFramesDuringBurst()
        testCapturePolicyBoundsMemoryAndSlowsWhenIdle()
        testUnresolvedAlignmentCannotBeExported()
        print("✅ LongScreenshotCoreChecks passed")
    }

    static func testDetectsDownwardScrollWhileIgnoringFixedHeaderAndFooter() {
        let previousRows: [[Int]] = [
            [900, 901, 902],
            [910, 911, 912],
            [100, 101, 102],
            [200, 201, 202],
            [300, 301, 302],
            [400, 401, 402],
            [500, 501, 502],
            [600, 601, 602],
            [700, 701, 702],
            [990, 991, 992],
        ]
        let currentRows: [[Int]] = [
            [900, 901, 902],
            [910, 911, 912],
            [400, 401, 402],
            [500, 501, 502],
            [600, 601, 602],
            [700, 701, 702],
            [800, 801, 802],
            [810, 811, 812],
            [820, 821, 822],
            [990, 991, 992],
        ]
        let previous = LongScreenshotFrameSignature(rows: previousRows)
        let current = LongScreenshotFrameSignature(rows: currentRows)

        let result = LongScreenshotMatcher().match(previous: previous, current: current)

        expect(result?.direction == .down, "expected downward scroll")
        expect(result?.scrollDistance == 3, "expected a 3-row scroll")
        expect(result?.fixedTopRows == 2, "expected the 2-row fixed header to be ignored")
        expect(result?.fixedBottomRows == 1, "expected the 1-row fixed footer to be ignored")
    }

    static func testRejectsAmbiguousRepeatedContent() {
        let repeatedRows = Array(repeating: [120, 120, 120, 120], count: 12)
        let frame = LongScreenshotFrameSignature(rows: repeatedRows)

        let result = LongScreenshotMatcher().match(previous: frame, current: frame)

        expect(result == nil, "expected ambiguous repeated content to be rejected")
    }

    static func testPlansDownwardSegmentsWithoutRepeatingFixedRegions() {
        let match = LongScreenshotMatch(
            direction: .down,
            scrollDistance: 3,
            fixedTopRows: 2,
            fixedBottomRows: 1,
            confidence: 1
        )

        let plan = LongScreenshotSegmentPlanner.plan(frameHeight: 10, match: match)

        expect(plan?.initialFrameRows == 0..<9, "expected initial frame without its fixed footer")
        expect(plan?.newFrameRows == 6..<9, "expected only newly revealed body rows")
        expect(plan?.finalFixedRows == 9..<10, "expected footer to be appended exactly once at completion")
    }

    static func testIncludesNeutralEdgeRowsInFixedHeader() {
        let previous = LongScreenshotFrameSignature(rows: [
            [255, 255, 255],
            [20, 80, 140],
            [255, 255, 255],
            [30, 40, 50],
            [60, 70, 80],
            [90, 100, 110],
            [120, 130, 140],
            [150, 160, 170],
            [180, 190, 200],
            [210, 220, 230],
        ])
        let current = LongScreenshotFrameSignature(rows: [
            [255, 255, 255],
            [20, 80, 140],
            [60, 70, 80],
            [90, 100, 110],
            [120, 130, 140],
            [150, 160, 170],
            [180, 190, 200],
            [210, 220, 230],
            [15, 25, 35],
            [45, 55, 65],
        ])

        let result = LongScreenshotMatcher().match(previous: previous, current: current)

        expect(result?.scrollDistance == 2, "expected a 2-row scroll")
        expect(result?.fixedTopRows == 2, "expected neutral top padding to remain part of the fixed header")
    }

    static func testDelaysBottomGuardBandToAvoidRepeatingFloatingControls() {
        let match = LongScreenshotMatch(
            direction: .down,
            scrollDistance: 3,
            fixedTopRows: 2,
            fixedBottomRows: 1,
            confidence: 1
        )

        let plan = LongScreenshotSegmentPlanner.plan(
            frameHeight: 10,
            match: match,
            trailingGuardRows: 2
        )

        expect(plan?.initialFrameRows == 0..<7, "expected initial frame to defer the bottom guard band")
        expect(plan?.newFrameRows == 4..<7, "expected new rows to come from above the floating-control band")
        expect(plan?.finalFixedRows == 7..<10, "expected the final guard band and footer exactly once")
    }

    static func testIgnoresChangingSideBlocksDuringMatching() {
        let header = signatureRow(230)
        let footer = signatureRow(245)
        let body = stride(from: 20, through: 110, by: 10).map(signatureRow)
        let previous = LongScreenshotFrameSignature(rows: [header] + Array(body[0...7]) + [footer])
        var currentRows = [header] + Array(body[2...9]) + [footer]
        for index in currentRows.indices {
            currentRows[index][6] = index.isMultiple(of: 2) ? 0 : 255
            currentRows[index][7] = index.isMultiple(of: 2) ? 255 : 0
        }

        let result = LongScreenshotMatcher().match(
            previous: previous,
            current: LongScreenshotFrameSignature(rows: currentRows)
        )

        expect(result?.direction == .down, "expected side animation not to change scroll direction")
        expect(result?.scrollDistance == 2, "expected side animation not to change scroll distance")
    }

    static func testDetectsUpwardScroll() {
        let rows = stride(from: 10, through: 120, by: 10).map(signatureRow)
        let later = LongScreenshotFrameSignature(rows: Array(rows[2...11]))
        let earlier = LongScreenshotFrameSignature(rows: Array(rows[0...9]))

        let result = LongScreenshotMatcher().match(previous: later, current: earlier)

        expect(result?.direction == .up, "expected upward scroll direction")
        expect(result?.scrollDistance == 2, "expected a 2-row upward scroll")
    }

    static func testMatchesRetinaSizedBrowserFrame() {
        let header = (0..<80).map { signatureRow(180 + $0 % 30, blockCount: 32) }
        let footer = (0..<40).map { signatureRow(210 + $0 % 20, blockCount: 32) }
        let document = (0..<1_300).map { row in
            (0..<32).map { block in
                (row * 37 + block * 17 + (row / 7) * 11) % 256
            }
        }
        let previous = LongScreenshotFrameSignature(
            rows: header + Array(document[0..<1_080]) + footer
        )
        var currentRows = header + Array(document[140..<1_220]) + footer
        for row in currentRows.indices {
            for block in 24..<32 {
                currentRows[row][block] = (row * 19 + block * 23) % 256
            }
        }

        let result = LongScreenshotMatcher().match(
            previous: previous,
            current: LongScreenshotFrameSignature(rows: currentRows)
        )

        expect(
            result?.direction == .down,
            "expected downward direction for Retina-sized frame, got \(String(describing: result))"
        )
        expect(result?.scrollDistance == 140, "expected exact distance after coarse-to-fine search")
        expect(result?.fixedTopRows == 80, "expected full browser header detection")
        expect(result?.fixedBottomRows == 40, "expected full fixed footer detection")
    }

    static func testFindsLargeScrollAfterSmallExpectedDistance() {
        let document = (0..<2_000).map { row in
            (0..<32).map { block in
                let value = (row &* 1_103_515_245) ^ (block &* 12_345_679)
                    ^ ((row / 7) &* 2_654_435_761)
                return (value ^ (value >> 13) ^ (value >> 21)) & 255
            }
        }
        let previous = LongScreenshotFrameSignature(rows: Array(document[0..<1_200]))
        let current = LongScreenshotFrameSignature(rows: Array(document[600..<1_800]))

        let result = LongScreenshotMatcher().match(
            previous: previous, current: current, expectedDistance: 80
        )
        expect(result?.direction == .down, "expected a large downward scroll after a small one, got \(String(describing: result))")
        expect(result?.scrollDistance == 600, "expected full search to find a fast scroll")
    }

    static func testKeepsFirstFrameAnchorAcrossLaterMatches() {
        let first = LongScreenshotMatch(
            direction: .down,
            scrollDistance: 3,
            fixedTopRows: 2,
            fixedBottomRows: 1,
            confidence: 1
        )
        let anchor = LongScreenshotStitchingAnchor(
            frameHeight: 10,
            firstMatch: first,
            trailingGuardRows: 2
        )
        let noisyLaterMatch = LongScreenshotMatch(
            direction: .down,
            scrollDistance: 3,
            fixedTopRows: 1,
            fixedBottomRows: 2,
            confidence: 1
        )

        let plan = LongScreenshotSegmentPlanner.plan(
            frameHeight: 10,
            match: noisyLaterMatch,
            anchor: anchor
        )

        expect(plan?.newFrameRows == 4..<7, "expected later frames to reuse the first fixed-region anchor")
        expect(plan?.finalFixedRows == 7..<10, "expected the final crop boundary not to drift")
    }

    static func testMatchesSparseTextAcrossNarrowColumn() {
        let document = (0..<1_400).map { row -> [Int] in
            var blocks = [Int](repeating: 255, count: 32)
            if row % 20 < 8 {
                for block in 0..<6 {
                    blocks[block] = 80 + ((row / 20 * 31 + block * 7) % 80)
                }
            }
            return blocks
        }
        let previous = LongScreenshotFrameSignature(rows: Array(document[0..<1_200]))
        let current = LongScreenshotFrameSignature(rows: Array(document[140..<1_340]))

        let result = LongScreenshotMatcher().match(previous: previous, current: current)

        expect(result?.direction == .down, "expected downward scroll for narrow text column")
        expect(result?.scrollDistance == 140, "expected 140-row scroll for narrow text column")
    }

    static func testMatchesSparseTextBetweenCoarseSampledBlocks() {
        let document = (0..<1_400).map { row -> [Int] in
            var blocks = [Int](repeating: 255, count: 32)
            if row % 20 < 8 {
                for block in 9..<12 {
                    blocks[block] = 80 + ((row / 20 * 31 + block * 7) % 80)
                }
            }
            return blocks
        }
        let previous = LongScreenshotFrameSignature(rows: Array(document[0..<1_200]))
        let current = LongScreenshotFrameSignature(rows: Array(document[140..<1_340]))

        let result = LongScreenshotMatcher().match(previous: previous, current: current)

        expect(result?.direction == .down, "expected downward scroll between coarse sample blocks")
        expect(result?.scrollDistance == 140, "expected 140-row scroll between coarse sample blocks")
    }

    static func testMatchesSparseTextLinesAcrossWideColumn() {
        let document = (0..<1_400).map { row -> [Int] in
            var blocks = [Int](repeating: 255, count: 32)
            if row % 24 < 8 {
                for block in 0..<20 {
                    blocks[block] = 80 + ((row / 24 * 31 + block * 7) % 80)
                }
            }
            return blocks
        }
        let previous = LongScreenshotFrameSignature(rows: Array(document[0..<1_200]))
        let current = LongScreenshotFrameSignature(rows: Array(document[140..<1_340]))

        let result = LongScreenshotMatcher().match(previous: previous, current: current)

        expect(result?.direction == .down, "expected downward scroll for sparse text lines")
        expect(result?.scrollDistance == 140, "expected 140-row scroll for sparse text lines")
    }

    static func testFrameBufferPreservesIntermediateFramesDuringBurst() {
        let buffer = LongScreenshotFrameBuffer<Int>(capacity: 3)
        expect(buffer.offer(1), "first captured frame must enter the buffer")
        expect(buffer.offer(2), "second captured frame must enter the buffer")
        expect(buffer.offer(3), "third captured frame must enter the buffer")
        expect(!buffer.offer(4), "overflow must not discard earlier frames needed for overlap")
        expect(buffer.take(timeout: 0.01) == 1, "consumer must process the earliest frame first")
        expect(buffer.offer(4), "producer must resume buffering when space is available")
        buffer.close()
        expect(buffer.take(timeout: 0.01) == 2, "second frame must survive a burst")
        expect(buffer.take(timeout: 0.01) == 3, "third frame must survive a burst")
        expect(buffer.take(timeout: 0.01) == 4, "new frame must follow earlier frames")
        expect(buffer.take(timeout: 0.01) == nil, "closed and drained buffer must end consumption")
        expect(buffer.droppedFrameCount == 1, "overflow must be reported for user feedback")
        expect(!buffer.canFinalizeSafely, "a capture with dropped frames must not be exported as complete")

        let complete = LongScreenshotFrameBuffer<Int>(capacity: 2)
        expect(complete.offer(7), "complete capture must retain its frame")
        complete.close()
        expect(complete.take(timeout: 0.01) == 7, "complete capture must drain before export")
        expect(complete.canFinalizeSafely, "fully drained capture with no drops may be exported")
    }

    static func testCapturePolicyBoundsMemoryAndSlowsWhenIdle() {
        let largeFrameBytes = 3840 * 2160 * 4
        let largeCapacity = LongScreenshotCapturePolicy.frameCapacity(
            width: 3840, height: 2160
        )
        let smallCapacity = LongScreenshotCapturePolicy.frameCapacity(
            width: 1440, height: 900
        )
        expect(largeCapacity >= 2, "large screenshots still need a short burst buffer")
        expect(largeCapacity * largeFrameBytes <= 160 * 1024 * 1024,
               "4K burst buffer must stay within its pixel memory budget")
        expect(smallCapacity > largeCapacity,
               "smaller screenshots should retain more intermediate frames")
        expect(LongScreenshotCapturePolicy.interval(unchangedFrameCount: 8) >
               LongScreenshotCapturePolicy.interval(unchangedFrameCount: 0),
               "idle capture must sample less often than active scrolling")
        expect(LongScreenshotCapturePolicy.interval(unchangedFrameCount: 8, queuedFrames: 2) >=
               LongScreenshotCapturePolicy.interval(unchangedFrameCount: 8),
               "backlog must not accelerate capture while the page is idle")
        expect(LongScreenshotCapturePolicy.interval(unchangedFrameCount: 0, queuedFrames: 2) >
               LongScreenshotCapturePolicy.interval(unchangedFrameCount: 0),
               "backlog must give the matcher time to catch up during scrolling")
    }

    static func testUnresolvedAlignmentCannotBeExported() {
        var alignment = LongScreenshotAlignmentState()
        alignment.recordMatchFailure()
        expect(alignment.canFinalizeSafely, "one transient mismatch must not invalidate the capture")
        alignment.recordMatchFailure()
        expect(!alignment.canFinalizeSafely, "repeated mismatch must prevent incomplete export")
        alignment.recordAcceptedFrame()
        expect(alignment.canFinalizeSafely, "a later valid overlap must resolve the mismatch")
        alignment.recordRejectedDistance()
        expect(!alignment.canFinalizeSafely, "a distance beyond the stitchable body must prevent export")
        alignment.recordReturnedToCapturedArea()
        expect(alignment.canFinalizeSafely, "returning to the captured area must resolve an unappended gap")
        alignment.recordDroppedFrames()
        expect(!alignment.canFinalizeSafely, "a dropped frame must remain unresolved until overlap is verified")
        alignment.recordAcceptedFrame()
        expect(alignment.canFinalizeSafely, "a later overlapping frame must recover from a dropped frame")
    }

    private static func signatureRow(_ base: Int) -> [Int] {
        signatureRow(base, blockCount: 8)
    }

    private static func signatureRow(_ base: Int, blockCount: Int) -> [Int] {
        (0..<blockCount).map { min(255, base + $0 * 2) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("❌ \(message)")
        }
    }
}
