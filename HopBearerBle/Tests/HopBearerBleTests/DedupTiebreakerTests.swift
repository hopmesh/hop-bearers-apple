// Unit tests for `gt`, the SPEC §1.2 unsigned big-endian tiebreaker primitive the dedup keep-rule is
// built on (these drive the REAL `gt`), plus `bleNewLegSurvives`, the pure one-pipe-per-peer keep-rule
// that `BleBearer.onUp` now CALLS (so this pins the exact production decision, not a copy). The keep-rule
// is ALSO covered end-to-end by BleBearerDedupTests, which drives the production onUp dedup over these
// same functions. (An earlier shadow `keepDialed`/`newLegSurvives` re-implementation was removed; this is
// the real extracted function the bearer runs, mirroring the LAN bearer's `lanNewLegSurvives`.)

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

    // MARK: bleNewLegSurvives, the pure keep-rule BleBearer.onUp calls (mirrors lanNewLegSurvives).

    private func nodeId(_ first: UInt8) -> Data { Data([first] + [UInt8](repeating: 0, count: 15)) }

    func testSurvivorPickWhenIAmGreaterKeepsMyDialer() {
        // I am greater (0x02 > 0x01) -> keep MY DIALED leg. A new dialer wins over an existing acceptor;
        // a new acceptor loses to an existing dialer.
        let me = nodeId(0x02); let peer = nodeId(0x01)
        XCTAssertTrue(bleNewLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: true))
        XCTAssertFalse(bleNewLegSurvives(myId: me, peer: peer, existingIsDialer: true, newIsDialer: false))
    }

    func testSurvivorPickWhenIAmLesserKeepsMyAcceptor() {
        // I am lesser (0x01 < 0x02) -> keep MY ACCEPTOR leg. New acceptor wins over existing dialer;
        // new dialer loses.
        let me = nodeId(0x01); let peer = nodeId(0x02)
        XCTAssertTrue(bleNewLegSurvives(myId: me, peer: peer, existingIsDialer: true, newIsDialer: false))
        XCTAssertFalse(bleNewLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: true))
    }

    func testSurvivorPickDegenerateNoMatchFallsBackToNewLeg() {
        // Both legs the same role (never a real dialer/acceptor pair): the `?? link` fallback keeps the
        // new leg, matching onUp's original `[existing, link].first { ... } ?? link`.
        let me = nodeId(0x02); let peer = nodeId(0x01)   // keepDialed == true
        XCTAssertTrue(bleNewLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: false))
    }
}
