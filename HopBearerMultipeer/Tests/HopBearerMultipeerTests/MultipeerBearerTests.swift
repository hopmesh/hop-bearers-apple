// Radio-free tests for the Multipeer bearer's decision logic. No MCSession, no Wi-Fi, no device: the
// framework glue lives in +Radio.swift and is covered by the on-device workflow. What is pinned here
// is the small set of facts whose silent change would break interop or the link table.

import XCTest
import HopContract
@testable import HopBearerMultipeer

private final class CapturingSink: LinkSink {
    private(set) var ups: [(LinkId, HopRole, Data)] = []
    private(set) var downs: [LinkId] = []
    private(set) var bytes: [(LinkId, Data)] = []
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { ups.append((link, role, peerId)) }
    func linkBytes(_ link: LinkId, _ b: Data) { bytes.append((link, b)) }
    func linkDown(_ link: LinkId) { downs.append(link) }
}

final class MultipeerBearerTests: XCTestCase {

    /// iOS silently refuses to browse or advertise a service the app has not declared under
    /// NSBonjourServices, and the symptom is "no peers ever appear" rather than an error. The app's
    /// Info.plist declares `_hop-mesh._tcp` / `_hop-mesh._udp`, so this string is a contract with a
    /// file in another package and cannot be renamed casually.
    func testServiceTypeMatchesTheInfoPlistDeclaration() {
        XCTAssertEqual(MultipeerBearer.serviceType, "hop-mesh")
    }

    /// The toggle handle. `BearerManager.setEnabled` matches on `transportName`, and the driver and
    /// both demo apps already map "P2P" to the Peer-to-Peer row, so this string is what makes the
    /// transport switchable with no UI change. It is why the extraction was worth doing.
    func testTransportNameIsTheToggleHandleTheUiAlreadyKnows() {
        XCTAssertEqual(MultipeerBearer(transportId: "aa").transportName, "P2P")
    }

    /// Exactly one side of a pair invites, or both invite and race to build duplicate sessions.
    ///
    /// This asserts the SMALLER id invites, which is deliberately the opposite of the BLE/LAN
    /// tiebreak where the greater id dials. It is preserved verbatim from the in-driver code: the
    /// rule only works if both devices agree, so flipping it for parity is a symmetric change that
    /// must ship to both sides at once, not something an extraction may quietly alter.
    func testOnlyTheSmallerIdInvitesAndTheRuleIsTotal() {
        XCTAssertTrue(MultipeerBearer.shouldInvite(me: "aaaa", peer: "bbbb"))
        XCTAssertFalse(MultipeerBearer.shouldInvite(me: "bbbb", peer: "aaaa"))
        // Total and antisymmetric: for any distinct pair exactly one side invites.
        for (a, b) in [("00", "ff"), ("0a", "0b"), ("7f", "80")] {
            XCTAssertNotEqual(MultipeerBearer.shouldInvite(me: a, peer: b),
                              MultipeerBearer.shouldInvite(me: b, peer: a),
                              "exactly one of \(a)/\(b) must invite")
        }
        // A peer with our own name must not be invited (it is us, seen reflected).
        XCTAssertFalse(MultipeerBearer.shouldInvite(me: "abcd", peer: "abcd"))
    }

    func testDisplayNameParsesToAPeerIdAndRejectsForeignAdvertisers() {
        let name = String(repeating: "ab", count: 16)   // 32 hex chars = 16 bytes
        XCTAssertEqual(MultipeerBearer.peerId(fromDisplayName: name), Data(repeating: 0xAB, count: 16))
        // Anything else is some other app on the same service type, not a hop peer.
        XCTAssertNil(MultipeerBearer.peerId(fromDisplayName: "too-short"))
        XCTAssertNil(MultipeerBearer.peerId(fromDisplayName: String(repeating: "zz", count: 16)))
        XCTAssertNil(MultipeerBearer.peerId(fromDisplayName: ""))
    }

    /// Local ids start at 1 because BearerManager translates each into its own global space. The old
    /// in-driver code minted from 10_000 purely to keep the driver's hand-rolled id ranges apart,
    /// which is exactly the bookkeeping this extraction deletes.
    func testMintsLocalIdsFromOneSoTheManagerOwnsTheGlobalSpace() {
        let b = MultipeerBearer(transportId: "aa")
        XCTAssertEqual(b.mint(), 1)
        XCTAssertEqual(b.mint(), 2)
    }

    /// Multipeer can report the same peer connected more than once. A duplicate must not mint a
    /// second link, or the consumer would see two paths to one peer and could route into the stale one.
    func testDuplicateConnectDoesNotMintASecondLink() {
        let b = MultipeerBearer(transportId: "aa")
        let first = b.noteConnected(peerName: "peer1")
        XCTAssertEqual(first, 1)
        XCTAssertNil(b.noteConnected(peerName: "peer1"), "a repeat connect must be ignored")
        XCTAssertEqual(b.linkId(forPeer: "peer1"), 1)
    }

    func testDisconnectTearsDownAndIsIdempotent() {
        let b = MultipeerBearer(transportId: "aa")
        _ = b.noteConnected(peerName: "peer1")
        XCTAssertEqual(b.noteDisconnected(peerName: "peer1"), 1)
        XCTAssertNil(b.linkId(forPeer: "peer1"))
        XCTAssertNil(b.noteDisconnected(peerName: "peer1"), "a second disconnect must not re-report")
    }

    /// Two peers get distinct links, and dropping one leaves the other routable. This is the property
    /// the old `mcPeerByLink` dictionary provided inside the driver.
    func testTwoPeersGetDistinctLinksAndOneDroppingLeavesTheOther() {
        let b = MultipeerBearer(transportId: "aa")
        let l1 = b.noteConnected(peerName: "p1")
        let l2 = b.noteConnected(peerName: "p2")
        XCTAssertNotEqual(l1, l2)
        _ = b.noteDisconnected(peerName: "p1")
        XCTAssertNil(b.linkId(forPeer: "p1"))
        XCTAssertEqual(b.linkId(forPeer: "p2"), l2)
    }

    /// The public initializer must mint a RANDOM 32-hex transport id and must not derive it from the
    /// node id it is handed. The display name is broadcast in cleartext over Bonjour/AWDL, so putting
    /// the address there would let a passive listener correlate the device across locations (apple-03).
    func testPublicInitMintsARandomIdAndIgnoresTheNodeAddress() {
        let addr = Data(repeating: 0xAB, count: 32)
        let a = MultipeerBearer(myId: addr)
        let b = MultipeerBearer(myId: addr)
        XCTAssertEqual(a.transportId.count, 32)
        XCTAssertNotNil(MultipeerBearer.peerId(fromDisplayName: a.transportId),
                        "the id must be parseable hex, since peers parse it back")
        XCTAssertNotEqual(a.transportId, b.transportId,
                          "two bearers with the SAME node id must not share a transport id")
        XCTAssertFalse(a.transportId.contains("abab"), "the address must not leak into the display name")
    }

    /// Sending on a link we do not own must be a no-op, not a crash. The manager can hand down a send
    /// for a link that just went away, and a bearer that trapped there would take the node with it.
    func testSendOnAnUnknownLinkIsANoOp() {
        let b = MultipeerBearer(transportId: "aa")
        b.send(Data([1, 2, 3]), on: 999)     // no session, no such link
        let drained = expectation(description: "queue drained")
        b.queue.async { drained.fulfill() }  // proves the async body ran without trapping
        wait(for: [drained], timeout: 2)
    }

    /// Private mode persists rather than applying once, so re-enabling the transport later does not
    /// silently start advertising a node that asked to stay unannounced.
    func testAdvertisingPreferencePersists() {
        let b = MultipeerBearer(transportId: "aa")
        XCTAssertTrue(b.advertisingEnabled, "advertising is on by default")
        b.setAdvertising(false)
        let settled = expectation(description: "settled")
        b.queue.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(b.advertisingEnabled, "the preference must outlive the call that set it")
    }

    /// `blocked` is what a UI uses to say "Local Network permission is pending" instead of showing a
    /// dead transport, so it must start false and be settable from the bearer's own queue.
    func testBlockedStartsFalseAndIsObservable() {
        let b = MultipeerBearer(transportId: "aa")
        XCTAssertFalse(b.blocked)
        b.blockedForTest(true)
        XCTAssertTrue(b.blocked)
    }

    /// The link table survives churn: connect, drop, reconnect must yield a FRESH id, because the
    /// consumer keys state on link id and reusing one would alias a dead path to a live one.
    func testReconnectAfterDropMintsAFreshLinkId() {
        let b = MultipeerBearer(transportId: "aa")
        let first = b.noteConnected(peerName: "p")
        _ = b.noteDisconnected(peerName: "p")
        let second = b.noteConnected(peerName: "p")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "a reconnect must not reuse the dead link id")
    }
}
