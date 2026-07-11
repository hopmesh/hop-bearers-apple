// apple-12 lifecycle coverage for the BLE bearer, modeled without a CoreBluetooth radio. BleBearer.onUp
// dedups a simultaneous mutual dial BEFORE surfacing (only the survivor reaches sink.linkUp) and onClose
// only emits linkDown for a leg that was actually surfaced (`wasSurfaced`) and registered (`wasUp`). A
// `Link`/`CBL2CAPChannel` can't be built in a unit test, so the object path stays device-tested; here we
// drive the exact onUp/onClose bookkeeping over the REAL `gt` tiebreaker primitive, so a drift in which
// leg wins or an unpaired linkUp/linkDown fails here. This is the BLE analog of the LAN bearer's
// wasSurfaced lifecycle tests (previously BLE only covered the tiebreaker in isolation).

import XCTest
import Foundation
@testable import HopBearerBle

final class LinkLifecycleTests: XCTestCase {

    private func bytes(_ vals: [UInt8]) -> Data { Data(vals) }

    // A minimal leg + sink recorder mirroring BleBearer.onUp / onClose (dedup BEFORE surface; wasSurfaced
    // gates linkDown). newLegSurvives is computed over the real `gt` so it tracks the production keep-rule.
    private struct Leg { let id: UInt64; let isDialer: Bool; var wasSurfaced = false }
    private final class Recorder { var ups: [UInt64] = []; var downs: [UInt64] = [] }

    /// Mirror of BleBearer.onUp's survivor pick: keep MY dialed leg iff I am the greater id (gt), keep the
    /// first of [existing, new] whose direction matches, else default to the new leg.
    private func newLegSurvives(myId: Data, peer: Data, existingIsDialer: Bool, newIsDialer: Bool) -> Bool {
        let keepDialed = gt(myId, peer)
        if existingIsDialer == keepDialed { return false }
        if newIsDialer == keepDialed { return true }
        return true
    }

    /// onUp for a NEW leg given an optional existing leg to the peer. Returns the mutated new leg and
    /// whether the existing leg is dropped (the loser). Only the survivor is surfaced (apple-12).
    private func onUp(myId: Data, peer: Data, existing: Leg?, new newLeg: Leg, rec: Recorder) -> (new: Leg, dropExisting: Bool) {
        var newLeg = newLeg
        guard let existing else { newLeg.wasSurfaced = true; rec.ups.append(newLeg.id); return (newLeg, false) }
        let newWins = newLegSurvives(myId: myId, peer: peer,
                                     existingIsDialer: existing.isDialer, newIsDialer: newLeg.isDialer)
        if newWins { newLeg.wasSurfaced = true; rec.ups.append(newLeg.id) }
        return (newLeg, newWins)
    }

    /// onClose: emit linkDown iff the leg was registered (wasUp) AND surfaced.
    private func onClose(_ leg: Leg, wasUp: Bool, rec: Recorder) {
        if wasUp && leg.wasSurfaced { rec.downs.append(leg.id) }
    }

    func testFirstLinkSurfacesAndPairsExactlyOneLinkDown() {
        let rec = Recorder()
        let (leg, drop) = onUp(myId: bytes([0x01]), peer: bytes([0x02]), existing: nil,
                               new: Leg(id: 1, isDialer: true), rec: rec)
        XCTAssertFalse(drop)
        XCTAssertTrue(leg.wasSurfaced)
        XCTAssertEqual(rec.ups, [1])
        onClose(leg, wasUp: true, rec: rec)
        XCTAssertEqual(rec.downs, [1], "a surfaced link emits exactly one linkDown")
    }

    func testDedupLoserNeverSurfacesAndEmitsNoLinkDown() {
        // I am greater -> I keep my DIALER. Existing dialer is the survivor; the new acceptor loses. The
        // loser must never surface a linkUp and its close must emit NO linkDown (the apple-12 invariant).
        let rec = Recorder()
        let existing = Leg(id: 1, isDialer: true, wasSurfaced: true)
        let (loser, drop) = onUp(myId: bytes([0x02]), peer: bytes([0x01]), existing: existing,
                                 new: Leg(id: 2, isDialer: false), rec: rec)
        XCTAssertFalse(drop, "the new acceptor loses to my existing dialer")
        XCTAssertFalse(loser.wasSurfaced)
        XCTAssertEqual(rec.ups, [], "no linkUp for the deduped loser")
        onClose(loser, wasUp: true, rec: rec)
        XCTAssertEqual(rec.downs, [], "a deduped loser must not emit a linkDown")
    }

    func testDedupWinnerSurfacesAndReplacesExisting() {
        // I am greater; existing is my acceptor (id 1), new is my dialer (id 2). The new dialer wins and
        // surfaces; the dropped existing was surfaced earlier so its own close still pairs one linkDown.
        let rec = Recorder()
        let existing = Leg(id: 1, isDialer: false, wasSurfaced: true)
        let (winner, drop) = onUp(myId: bytes([0x02]), peer: bytes([0x01]), existing: existing,
                                  new: Leg(id: 2, isDialer: true), rec: rec)
        XCTAssertTrue(drop)
        XCTAssertTrue(winner.wasSurfaced)
        XCTAssertEqual(rec.ups, [2])
        onClose(existing, wasUp: true, rec: rec)
        XCTAssertEqual(rec.downs, [1], "the replaced-but-previously-surfaced leg still pairs its linkDown")
    }

    func testUnregisteredLegEmitsNoLinkDown() {
        // wasUp=false (e.g. a channel that closed before HELLO ever registered it): nothing is emitted.
        let rec = Recorder()
        onClose(Leg(id: 9, isDialer: true, wasSurfaced: false), wasUp: false, rec: rec)
        XCTAssertEqual(rec.downs, [])
    }

    func testBothSidesKeepTheSamePhysicalChannel() {
        // The two devices in a mutual dial make opposite keep decisions, so they converge on one channel:
        // the greater keeps its dialer, the lesser keeps that same channel as its acceptor.
        let me = bytes([0x02]); let peer = bytes([0x01])
        // Greater side: existing acceptor, new dialer -> new (my dialer) wins.
        XCTAssertTrue(newLegSurvives(myId: me, peer: peer, existingIsDialer: false, newIsDialer: true))
        // Lesser side (roles swapped): existing dialer, new acceptor -> new (my acceptor) wins.
        XCTAssertTrue(newLegSurvives(myId: peer, peer: me, existingIsDialer: true, newIsDialer: false))
    }
}
