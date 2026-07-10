// Pure-logic tests for the BLE bearer's dedup tiebreaker (apple-12) and the big-endian nodeId compare
// it is built on. These need no CoreBluetooth radio: `gt` and the greater-id keep-rule are pure and
// eminently unit-testable, which is exactly the class of coverage apple-07 asked for. A CoreBluetooth
// `CBL2CAPChannel` can't be constructed in a unit test, so the Link/Central paths stay device-tested;
// the decision LOGIC that governs which of a duplicate pair survives is covered here.

import XCTest
import Foundation
@testable import HopBearerBle

final class DedupTiebreakerTests: XCTestCase {

    private func bytes(_ vals: [UInt8]) -> Data { Data(vals) }

    // MARK: gt — the SPEC §1.2 unsigned big-endian tiebreaker primitive.

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

    // MARK: the dedup keep-rule that gt drives (BleBearer.onUp).
    //
    // The rule: on a duplicate pair to one peer, keep MY dialed leg iff I am the greater id
    // (keepDialed = gt(myId, peer)). This is what makes the two sides agree on ONE survivor: the
    // greater id keeps its dialer, the lesser id keeps its acceptor, so exactly one L2CAP channel wins.
    // Modeling it here guards apple-12's "dedup before surface" from silently flipping which leg wins.

    /// Mirror of the keep decision in BleBearer.onUp: returns true iff we keep our DIALED leg.
    private func keepDialed(myId: Data, peer: Data) -> Bool { gt(myId, peer) }

    func testGreaterIdKeepsDialerLesserKeepsAcceptor() {
        let big = bytes([0x02])
        let small = bytes([0x01])
        // The greater id keeps its dialer.
        XCTAssertTrue(keepDialed(myId: big, peer: small))
        // The lesser id keeps its acceptor (does NOT keep its dialer).
        XCTAssertFalse(keepDialed(myId: small, peer: big))
    }

    func testBothSidesAgreeOnExactlyOneSurvivor() {
        // For any distinct pair, the two devices make OPPOSITE keepDialed decisions, which means they
        // agree on a single physical channel: one keeps its dialer, the other keeps that same channel as
        // its acceptor. If they ever matched, both would keep their own dialer -> two channels survive.
        let a = bytes([0x10, 0x20, 0x30])
        let b = bytes([0x10, 0x20, 0x31])
        XCTAssertTrue(keepDialed(myId: a, peer: b) != keepDialed(myId: b, peer: a))
    }
}
