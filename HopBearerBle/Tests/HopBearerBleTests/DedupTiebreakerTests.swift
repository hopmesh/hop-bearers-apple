// Unit tests for `gt`, the SPEC §1.2 unsigned big-endian tiebreaker primitive the dedup keep-rule is
// built on. These drive the REAL `gt` function. The keep-rule ITSELF (which leg of a duplicate pair
// survives) is no longer re-modeled here; it is covered end-to-end by BleBearerDedupTests, which drives
// the production BleBearer.onUp dedup over this same `gt`. (Previously this file also carried a shadow
// `keepDialed`/`newLegSurvives` re-implementation, removed, since it tested the test, not the bearer.)

import XCTest
import Foundation
@testable import HopBearerBle

final class DedupTiebreakerTests: XCTestCase {

    private func bytes(_ vals: [UInt8]) -> Data { Data(vals) }

    func testGtMostSignificantByteWins() {
        XCTAssertTrue(gt(bytes([0x02, 0x00]), bytes([0x01, 0xFF])))
        XCTAssertFalse(gt(bytes([0x01, 0xFF]), bytes([0x02, 0x00])))
    }

    func testGtEqualPrefixFallsThroughToNextByte() {
        XCTAssertTrue(gt(bytes([0x01, 0x02]), bytes([0x01, 0x01])))
        XCTAssertFalse(gt(bytes([0x01, 0x01]), bytes([0x01, 0x02])))
    }

    func testGtEqualBytesLongerWins() {
        // A prefix that matches, but a is longer -> a is greater (count tiebreak).
        XCTAssertTrue(gt(bytes([0x01, 0x02, 0x03]), bytes([0x01, 0x02])))
        XCTAssertFalse(gt(bytes([0x01, 0x02]), bytes([0x01, 0x02, 0x03])))
    }

    func testGtIdenticalIsNotGreater() {
        XCTAssertFalse(gt(bytes([0xAA, 0xBB]), bytes([0xAA, 0xBB])))
    }

    func testGtHandlesHighBitAsUnsigned() {
        // 0x80 (128) must compare greater than 0x7F (127): unsigned, not signed.
        XCTAssertTrue(gt(bytes([0x80]), bytes([0x7F])))
        XCTAssertFalse(gt(bytes([0x7F]), bytes([0x80])))
    }

    func testGtEmptyVsNonEmpty() {
        XCTAssertTrue(gt(bytes([0x00]), bytes([])))   // longer (non-empty) wins the count tiebreak
        XCTAssertFalse(gt(bytes([]), bytes([0x00])))
    }
}
