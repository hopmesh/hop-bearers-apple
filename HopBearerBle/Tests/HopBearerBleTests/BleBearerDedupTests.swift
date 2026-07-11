// Real dedup / link-lifecycle coverage for BleBearer. This REPLACES the old LinkLifecycleTests, which
// re-modeled onUp/onClose with local structs and never touched the bearer (a "shadow" test). Here we
// drive the REAL BleBearer.onUp / onData / onClose / send / setBackground through a fake `DedupLink`
// and a fake `LinkSink`, so the production dedup, the apple-12 wasSurfaced linkUp/linkDown pairing, and
// send routing all run under test with no CBL2CAPChannel. The dedup keep-rule runs over the real `gt`.

import XCTest
import Foundation
import HopContract
@testable import HopBearerBle

/// A CoreBluetooth-free stand-in for `Link`, so the bearer's dedup/routing/STATUS run without a radio.
private final class FakeLink: DedupLink {
    let linkId: LinkId
    let peerId: Data?
    let isDialer: Bool
    var wasSurfaced = false
    var peerShort: String { shortHex(peerId) }
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var rttMs: UInt64 = 0
    private(set) var sent: [Data] = []
    private(set) var closedWhy: String?

    init(_ linkId: LinkId, peer: Data?, isDialer: Bool) {
        self.linkId = linkId; self.peerId = peer; self.isDialer = isDialer
    }
    func sendData(_ bytes: Data) { sent.append(bytes) }
    func close(_ why: String) { closedWhy = why }
}

/// Records what the bearer surfaces to its consumer.
private final class FakeSink: LinkSink {
    private(set) var ups: [(LinkId, HopRole, Data)] = []
    private(set) var bytes: [(LinkId, Data)] = []
    private(set) var downs: [LinkId] = []
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { ups.append((link, role, peerId)) }
    func linkBytes(_ link: LinkId, _ b: Data) { bytes.append((link, b)) }
    func linkDown(_ link: LinkId) { downs.append(link) }
}

final class BleBearerDedupTests: XCTestCase {

    private func d(_ v: [UInt8]) -> Data { Data(v) }
    /// A 16-byte nodeId whose first byte is `first` (so the greater-id tiebreak is easy to control).
    private func nodeId(_ first: UInt8) -> Data { Data([first] + [UInt8](repeating: 0, count: 15)) }

    override func tearDown() {
        bleAppInBackground = false   // this global is process-shared; never leak background state across tests
        super.tearDown()
    }

    private func makeBearer(myId: Data) -> (BleBearer, FakeSink) {
        let b = BleBearer(myId: myId)
        let s = FakeSink()
        b.sink = s
        return (b, s)
    }

    // MARK: first link surfaces + pairs exactly one linkDown

    func testFirstLinkSurfacesAndPairsOneLinkDown() {
        let (b, sink) = makeBearer(myId: nodeId(0x02))
        let peer = nodeId(0x01)
        let link = FakeLink(1, peer: peer, isDialer: true)
        b.onUp(link)
        XCTAssertTrue(link.wasSurfaced)
        XCTAssertEqual(sink.ups.count, 1)
        XCTAssertEqual(sink.ups.first?.0, 1)
        XCTAssertEqual(sink.ups.first?.1, .dialer)
        XCTAssertEqual(sink.ups.first?.2, peer)
        XCTAssertEqual(b.debugPeerLinkCount, 1)
        XCTAssertTrue(b.debugHasLinkId(1))
        b.onClose(link)
        XCTAssertEqual(sink.downs, [1], "a surfaced link emits exactly one linkDown")
        XCTAssertEqual(b.debugPeerLinkCount, 0)
    }

    // MARK: dedup, the loser is closed, never surfaced, and emits no linkDown (apple-12)

    func testDedupLoserClosedNeverSurfacedNoLinkDown() {
        // I am greater (0x02 > 0x01) -> I keep MY DIALER. Existing dialer wins; the new acceptor loses.
        let (b, sink) = makeBearer(myId: nodeId(0x02))
        let peer = nodeId(0x01)
        let existing = FakeLink(1, peer: peer, isDialer: true)
        let loser = FakeLink(2, peer: peer, isDialer: false)
        b.onUp(existing)
        b.onUp(loser)
        XCTAssertEqual(sink.ups.map { $0.0 }, [1], "only the survivor (existing dialer) is announced")
        XCTAssertFalse(loser.wasSurfaced)
        XCTAssertEqual(loser.closedWhy, "dedup", "the loser is closed with the dedup reason")
        XCTAssertTrue(b.debugLink(forPeer: peer) === existing, "the existing dialer stays the survivor")
        // The loser was registered (wasUp) but never surfaced -> its close emits NO linkDown.
        b.onClose(loser)
        XCTAssertEqual(sink.downs, [], "a deduped loser must not emit a linkDown")
        // The survivor still pairs its own linkDown.
        b.onClose(existing)
        XCTAssertEqual(sink.downs, [1])
    }

    func testDedupWinnerReplacesExistingAndBothSurfacedLegsPairDown() {
        // I am greater -> keep my DIALER. Existing acceptor (1) is replaced by the new dialer (2).
        let (b, sink) = makeBearer(myId: nodeId(0x02))
        let peer = nodeId(0x01)
        let existing = FakeLink(1, peer: peer, isDialer: false)
        let winner = FakeLink(2, peer: peer, isDialer: true)
        b.onUp(existing)
        b.onUp(winner)
        XCTAssertEqual(sink.ups.map { $0.0 }, [1, 2], "both legs surfaced (existing earlier, winner now)")
        XCTAssertTrue(winner.wasSurfaced)
        XCTAssertEqual(existing.closedWhy, "dedup")
        XCTAssertTrue(b.debugLink(forPeer: peer) === winner)
        // The replaced-but-previously-surfaced existing leg still pairs one linkDown when it closes.
        b.onClose(existing)
        XCTAssertEqual(sink.downs, [1])
        b.onClose(winner)
        XCTAssertEqual(sink.downs, [1, 2])
    }

    func testLesserIdKeepsAcceptor() {
        // I am lesser (0x01 < 0x02) -> keepDialed=false -> I keep MY ACCEPTOR. Existing dialer loses.
        let (b, sink) = makeBearer(myId: nodeId(0x01))
        let peer = nodeId(0x02)
        let existingDialer = FakeLink(1, peer: peer, isDialer: true)
        let acceptor = FakeLink(2, peer: peer, isDialer: false)
        b.onUp(existingDialer)
        b.onUp(acceptor)
        XCTAssertTrue(b.debugLink(forPeer: peer) === acceptor, "the lesser id keeps its acceptor")
        XCTAssertEqual(existingDialer.closedWhy, "dedup")
        XCTAssertEqual(sink.ups.map { $0.0 }, [1, 2])
    }

    // MARK: unregistered / never-HELLOed leg emits nothing

    func testCloseOfUnregisteredLinkEmitsNoLinkDown() {
        let (b, sink) = makeBearer(myId: nodeId(0x02))
        let ghost = FakeLink(9, peer: nodeId(0x01), isDialer: true)
        // Never onUp'd -> not registered, not surfaced. onClose must be a no-op to the sink.
        b.onClose(ghost)
        XCTAssertEqual(sink.downs, [])
    }

    func testOnUpWithNilPeerIsIgnored() {
        let (b, sink) = makeBearer(myId: nodeId(0x02))
        let noHello = FakeLink(1, peer: nil, isDialer: true)   // HELLO never arrived -> peerId nil
        b.onUp(noHello)
        XCTAssertEqual(sink.ups.count, 0)
        XCTAssertEqual(b.debugPeerLinkCount, 0)
    }

    // MARK: DATA delivery

    func testOnDataSurfacesBytesForTheLink() {
        let (b, sink) = makeBearer(myId: nodeId(0x02))
        let link = FakeLink(7, peer: nodeId(0x01), isDialer: false)
        b.onUp(link)
        b.onData(link, d([0xDE, 0xAD]))
        XCTAssertEqual(sink.bytes.count, 1)
        XCTAssertEqual(sink.bytes.first?.0, 7)
        XCTAssertEqual(sink.bytes.first?.1, d([0xDE, 0xAD]))
    }

    // MARK: send routing (drains through the real bleRunLoop.perform)

    func testSendRoutesToTheRegisteredLink() {
        let (b, _) = makeBearer(myId: nodeId(0x02))
        let link = FakeLink(3, peer: nodeId(0x01), isDialer: true)
        b.onUp(link)
        b.send(d([0x01, 0x02, 0x03]), on: 3)
        // send() hops onto bleRunLoop (== .main here); spin it so the perform block runs.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(link.sent, [d([0x01, 0x02, 0x03])])
        // An unknown linkId is a no-op (no crash, nothing sent).
        b.send(d([0xFF]), on: 999)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(link.sent.count, 1)
    }

    func testCloseAllLinksClosesEverySurvivor() {
        let (b, _) = makeBearer(myId: nodeId(0x02))
        let l1 = FakeLink(1, peer: nodeId(0x01), isDialer: true)
        let l2 = FakeLink(2, peer: nodeId(0x03), isDialer: false)
        b.onUp(l1); b.onUp(l2)
        b.closeAllLinks()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(l1.closedWhy, "power-off")
        XCTAssertEqual(l2.closedWhy, "power-off")
    }

    // MARK: apple-02(a) background bookkeeping

    func testSetBackgroundTracksTheFlagAndBgAssertionPaths() {
        let (b, _) = makeBearer(myId: nodeId(0x02))
        // Background with a live link -> begins the assertion (no-op on macOS) and flips the flags.
        let link = FakeLink(1, peer: nodeId(0x01), isDialer: true)
        b.onUp(link)
        b.setBackground(true)
        XCTAssertTrue(bleAppInBackground)
        XCTAssertTrue(b.debugAppInBackground)
        // While backgrounded, onUp of a fresh link and onData both drive the bg-assertion begin/renew paths.
        let link2 = FakeLink(2, peer: nodeId(0x03), isDialer: false)
        b.onUp(link2)                 // exercises `if appInBackground { bgAssertion.begin("link-up-bg") }`
        b.onData(link2, d([0x01]))    // exercises `if appInBackground { bgAssertion.renew() }`
        b.setBackground(false)
        XCTAssertFalse(bleAppInBackground)
        XCTAssertFalse(b.debugAppInBackground)
    }

    // MARK: STATUS (does not crash with / without links)

    func testPrintStatusWithAndWithoutLinks() {
        let (b, _) = makeBearer(myId: nodeId(0x02))
        b.printStatus()                                        // links=0 branch
        b.onUp(FakeLink(1, peer: nodeId(0x01), isDialer: true))
        b.printStatus()                                        // detail branch
    }

    // MARK: dial gate + linkId minting (the seam the Central reads on its own queue)

    func testHaveLinkToAndPrefixReflectRegisteredSurvivors() {
        let (b, _) = makeBearer(myId: nodeId(0x02))
        let peer = Data([0xAB, 0xCD] + [UInt8](repeating: 0, count: 14))
        XCTAssertFalse(b.haveLinkTo(peer))
        XCTAssertFalse(b.haveLinkToPrefix(peer.prefix(6)))
        b.onUp(FakeLink(1, peer: peer, isDialer: true))
        XCTAssertTrue(b.haveLinkTo(peer), "an exact peer match is linked")
        XCTAssertTrue(b.haveLinkToPrefix(peer.prefix(6)), "the 6-byte prefix matches the survivor")
        XCTAssertFalse(b.haveLinkToPrefix(Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00])))
    }

    func testMintIsMonotonic() {
        let (b, _) = makeBearer(myId: nodeId(0x02))
        let a = b.mint(); let c = b.mint(); let d = b.mint()
        XCTAssertEqual([a, c, d], [1, 2, 3])
    }

    // MARK: randomNodeId

    func testRandomNodeIdIs16Bytes() {
        XCTAssertEqual(BleBearer.randomNodeId().count, 16)
        XCTAssertNotEqual(BleBearer.randomNodeId(), BleBearer.randomNodeId())
    }
}
