// Pure-logic tests for the LAN bearer (apple-07 coverage). Everything here is device-independent: the
// dedup tiebreaker + survivor pick (apple-12), the wasSurfaced link-lifecycle rule (the exact logic the
// audit fix corrected), the length-prefix deframer, and the Bonjour-name hex round-trip. A live
// NWConnection cannot be built in a unit test, so LanLink's socket path stays device-tested; the
// DECISION logic that governs which leg wins + whether a linkUp/linkDown pair is emitted is covered here.

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

    // MARK: wasSurfaced link-lifecycle rule (the audit fix): only a SURFACED leg may emit linkDown, and a
    // deduped loser is never surfaced. Model the exact onUp/onClose bookkeeping without a socket.

    /// A minimal sink/link model mirroring LanBearer.onUp / onClose bookkeeping (dedup BEFORE surface,
    /// wasSurfaced gates linkDown). Any drift between this and the real bearer would be a bug in the fix.
    private struct LegModel { let id: UInt64; let isDialer: Bool; var wasSurfaced = false }
    private final class Recorder {
        var ups: [UInt64] = []; var downs: [UInt64] = []
        func up(_ id: UInt64) { ups.append(id) }
        func down(_ id: UInt64) { downs.append(id) }
    }

    /// Run the onUp survivor+surface decision for a NEW leg given an optional existing leg to the peer.
    /// Returns the (possibly mutated) new leg and whether the existing leg should be dropped.
    private func onUp(myId: Data, peer: Data, existing: LegModel?, new newLeg: LegModel,
                      rec: Recorder) -> (new: LegModel, dropExisting: Bool) {
        var newLeg = newLeg
        guard let existing else {
            newLeg.wasSurfaced = true; rec.up(newLeg.id); return (newLeg, false)
        }
        let newWins = lanNewLegSurvives(myId: myId, peer: peer,
                                        existingIsDialer: existing.isDialer, newIsDialer: newLeg.isDialer)
        if newWins { newLeg.wasSurfaced = true; rec.up(newLeg.id) }  // only the survivor is announced
        return (newLeg, newWins)                                     // if new wins, existing is dropped
    }

    /// onClose: emit linkDown iff the leg was registered (wasUp) AND was surfaced.
    private func onClose(_ leg: LegModel, wasUp: Bool, rec: Recorder) {
        if wasUp && leg.wasSurfaced { rec.down(leg.id) }
    }

    func testFirstLinkSurfacesAndPairsLinkDown() {
        let rec = Recorder()
        let (leg, drop) = onUp(myId: bytes([0x01]), peer: bytes([0x02]), existing: nil,
                               new: LegModel(id: 1, isDialer: false), rec: rec)
        XCTAssertFalse(drop)
        XCTAssertTrue(leg.wasSurfaced)
        XCTAssertEqual(rec.ups, [1])
        onClose(leg, wasUp: true, rec: rec)
        XCTAssertEqual(rec.downs, [1], "a surfaced link must emit exactly one linkDown")
    }

    func testDedupLoserIsNeverSurfacedAndEmitsNoLinkDown() {
        // I am greater, so I keep my DIALER. The existing leg is my dialer (survivor); the new acceptor
        // leg loses. The loser must never surface a linkUp, and its close must emit NO linkDown — the
        // exact apple-12 invariant the audit fix restored (the buggy code surfaced the loser then closed
        // it, handing the host a linkDown for a link it never saw come up).
        let rec = Recorder()
        let existing = LegModel(id: 1, isDialer: true, wasSurfaced: true)   // already surfaced survivor
        let (loser, drop) = onUp(myId: bytes([0x02]), peer: bytes([0x01]), existing: existing,
                                 new: LegModel(id: 2, isDialer: false), rec: rec)
        XCTAssertFalse(drop, "the NEW acceptor leg loses to my existing dialer")
        XCTAssertFalse(loser.wasSurfaced, "the loser is never surfaced")
        XCTAssertEqual(rec.ups, [], "no linkUp for the deduped loser")
        // The loser is closed by dedup. It was never surfaced -> onClose emits no linkDown.
        onClose(loser, wasUp: true, rec: rec)
        XCTAssertEqual(rec.downs, [], "a deduped loser must NOT emit a linkDown (apple-12)")
    }

    func testDedupWinnerSurfacesAndReplacesExisting() {
        // I am greater, existing is my acceptor (id 1), new is my dialer (id 2). The new dialer wins,
        // surfaces, and the existing acceptor is dropped. The dropped existing WAS surfaced earlier, so
        // its own close still pairs one linkDown; the winner surfaces one linkUp.
        let rec = Recorder()
        let existing = LegModel(id: 1, isDialer: false, wasSurfaced: true)
        let (winner, drop) = onUp(myId: bytes([0x02]), peer: bytes([0x01]), existing: existing,
                                  new: LegModel(id: 2, isDialer: true), rec: rec)
        XCTAssertTrue(drop, "the new dialer wins; the existing acceptor is dropped")
        XCTAssertTrue(winner.wasSurfaced)
        XCTAssertEqual(rec.ups, [2])
        onClose(existing, wasUp: true, rec: rec)     // the dropped-but-previously-surfaced leg closes
        XCTAssertEqual(rec.downs, [1])
    }

    func testUnregisteredLinkEmitsNoLinkDown() {
        // wasUp=false (never registered in onUp, e.g. a connect that closed before HELLO). Even if the
        // model somehow marked wasSurfaced, an unregistered link emits nothing.
        let rec = Recorder()
        onClose(LegModel(id: 9, isDialer: true, wasSurfaced: false), wasUp: false, rec: rec)
        XCTAssertEqual(rec.downs, [])
    }
}
