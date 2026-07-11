// Pure-logic tests for the LAN bearer: the dedup tiebreaker + survivor pick (apple-12). These pin the
// real extracted decision functions (`lanKeepDialed` / `lanNewLegSurvives`) directly.
//
// NOTE: the earlier "shadow" tests here re-implemented the bearer's onUp/onClose bookkeeping (a LegModel
// + Recorder model) INSIDE the test file and never touched the real bearer, which is why coverage sat at
// ~10%. Those were replaced by LanIntegrationTests.swift, which drives the REAL onUp/onClose/dedup over a
// live loopback socket. What remains here are only the genuinely pure function tests.

import XCTest
import Foundation
@testable import HopBearerLan

final class LanBearerLogicTests: XCTestCase {

    private func bytes(_ vals: [UInt8]) -> Data { Data(vals) }

    // MARK: dedup tiebreaker (apple-12) — the "greater id dials, keeps its dialer" keep-rule.

    func testKeepDialedGreaterIdKeepsDialerLesserKeepsAcceptor() {
        let big = bytes([0x02]); let small = bytes([0x01])
        // The greater id keeps its dialed leg; the lesser keeps its acceptor.
        XCTAssertTrue(lanKeepDialed(myId: big, peer: small))
        XCTAssertFalse(lanKeepDialed(myId: small, peer: big))
    }

    func testKeepDialedIsUnsignedBigEndian() {
        // High bit is unsigned (0x80 > 0x7f), most-significant byte decides, longer-on-equal-prefix wins.
        XCTAssertTrue(lanKeepDialed(myId: bytes([0x80]), peer: bytes([0x7f])))
        XCTAssertTrue(lanKeepDialed(myId: bytes([0x02, 0x00]), peer: bytes([0x01, 0xff])))
        XCTAssertTrue(lanKeepDialed(myId: bytes([0x01, 0x02, 0x00]), peer: bytes([0x01, 0x02])))
    }

    func testBothSidesAgreeOnExactlyOneSurvivor() {
        // For a distinct pair the two devices make OPPOSITE keepDialed decisions, so they agree on a
        // single physical connection: one keeps its dialer, the other keeps that channel as its acceptor.
        let a = bytes([0x10, 0x20, 0x30]); let b = bytes([0x10, 0x20, 0x31])
        XCTAssertNotEqual(lanKeepDialed(myId: a, peer: b), lanKeepDialed(myId: b, peer: a))
    }

    // MARK: survivor pick — onUp's dedup selection lifted into lanNewLegSurvives.

    func testSurvivorPickWhenIAmGreaterKeepsMyDialer() {
        // I am greater -> I keep my DIALED leg. So a new dialer leg wins over an existing acceptor;
        // a new acceptor leg loses to an existing dialer.
        let me = bytes([0x02]); let peer = bytes([0x01])
        XCTAssertTrue(lanNewLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: true))
        XCTAssertFalse(lanNewLegSurvives(myId: me, peer: peer, existingIsDialer: true, newIsDialer: false))
    }

    func testSurvivorPickWhenIAmLesserKeepsMyAcceptor() {
        // I am lesser -> I keep my ACCEPTOR leg. New acceptor wins over existing dialer; new dialer loses.
        let me = bytes([0x01]); let peer = bytes([0x02])
        XCTAssertTrue(lanNewLegSurvives(myId: me, peer: peer, existingIsDialer: true, newIsDialer: false))
        XCTAssertFalse(lanNewLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: true))
    }
}
