// More real-decision coverage for the LAN bearer, beyond the pass-4 dedup/deframer set:
//
//   • lanShouldDial: the pure dial gate the NWBrowser callback AND the rescan-for-dials path share
//     (skip self, skip already-linked, dial only if we are the greater id). Extracted so the two call
//     sites can't drift and so the gate is testable with no live NWBrowser. This is what decides, for a
//     freshly discovered Bonjour peer, whether THIS device initiates the TCP dial.
//   • the defensive branch of lanNewLegSurvives (both legs same direction), an impossible-in-practice
//     duplicate that the survivor pick must still resolve deterministically rather than trap.
//
// Pure logic, no NWConnection/NWBrowser, so it runs headlessly.

import XCTest
import Foundation
@testable import HopBearerLan

final class LanDialGateTests: XCTestCase {

    private func bytes(_ vals: [UInt8]) -> Data { Data(vals) }

    // MARK: lanShouldDial. The shared browser/rescan dial gate.

    func testGreaterIdDialsUnlinkedPeer() {
        // I am greater and not yet linked -> I dial (I am the initiator for this pair).
        XCTAssertTrue(lanShouldDial(myId: bytes([0x02]), peerId: bytes([0x01]), alreadyLinked: false))
    }

    func testLesserIdDoesNotDial() {
        // I am lesser -> I wait to be dialed (the greater peer initiates); the gate says no.
        XCTAssertFalse(lanShouldDial(myId: bytes([0x01]), peerId: bytes([0x02]), alreadyLinked: false))
    }

    func testNeverDialSelf() {
        // Our own advertised service shows up in our own browse results; we must never dial ourselves,
        // even though gt(self, self) is false anyway this pins the explicit self-check.
        let me = bytes([0x05, 0x06])
        XCTAssertFalse(lanShouldDial(myId: me, peerId: me, alreadyLinked: false))
    }

    func testAlreadyLinkedPeerIsNotRedialed() {
        // Even as the greater id, if a link already exists we must not open a second one.
        XCTAssertFalse(lanShouldDial(myId: bytes([0x02]), peerId: bytes([0x01]), alreadyLinked: true))
    }

    func testGateAgreesWithTiebreakerAcrossThePair() {
        // For a distinct unlinked pair exactly one side's gate opens (the greater id), so a single dial is
        // initiated per pair, the property the one-pipe-per-peer design depends on.
        let a = bytes([0x10, 0x20, 0x30]); let b = bytes([0x10, 0x20, 0x31])
        let aDials = lanShouldDial(myId: a, peerId: b, alreadyLinked: false)
        let bDials = lanShouldDial(myId: b, peerId: a, alreadyLinked: false)
        XCTAssertNotEqual(aDials, bDials, "exactly one of the pair dials")
        XCTAssertTrue(bDials, "the greater id (b) is the dialer")
    }

    // MARK: lanNewLegSurvives defensive branch. Both legs the same direction.

    func testSurvivorDefaultsToNewLegWhenNeitherMatchesKeepRule() {
        // I am greater (keepDialed = true), but BOTH the existing and the new leg are acceptors (neither
        // is my dialer). This can't happen with a real simultaneous dial (one leg is always the dialer),
        // but the survivor pick must still be deterministic: it falls through to the NEW leg.
        let me = bytes([0x02]); let peer = bytes([0x01])
        XCTAssertTrue(lanNewLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: false),
                      "neither leg matches the keep-rule -> defensively keep the new leg")
        // Symmetric: I am lesser (keepDialed = false) but both legs are dialers -> also new leg.
        XCTAssertTrue(lanNewLegSurvives(myId: peer, peer: me, existingIsDialer: true, newIsDialer: true))
    }
}
