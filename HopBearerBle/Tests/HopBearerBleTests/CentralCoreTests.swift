// Real coverage for CentralCore, the DIALER (central) decision state machine. A CBCentralManager /
// CBPeripheral cannot be constructed in a unit test, so before the seam refactor this logic (dial gating,
// the SPEC 6 backoff schedule, the retained/pendingWaits sets, the WAIT_BASE_S fallback, backoff TTL) was
// 0% covered and only re-modeled in the test file. Now the decisions live in this pure core, and these
// tests DRIVE IT DIRECTLY: an injected clock + zero jitter make the backoff schedule deterministic, and
// injected haveLinkTo / haveLinkToPrefix / appInBackground make every branch reachable with no radio.

import XCTest
import Foundation
import HopContract   // hex(_:), the backoff-key formatter, shared with the bearer
@testable import HopBearerBle

final class CentralCoreTests: XCTestCase {

    // Injected environment.
    private var clock: Double = 1000
    private var linkedPeers = Set<Data>()      // haveLinkTo(peerId)
    private var linkedPrefixes = Set<Data>()   // haveLinkToPrefix(6-byte)
    private var background = false

    private let idA = UUID()
    private let idB = UUID()

    /// 16-byte nodeId whose first byte is `first` (rest zero), controls the greater-id tiebreak.
    private func nodeId(_ first: UInt8) -> Data { Data([first] + [UInt8](repeating: 0, count: 15)) }
    private func pfx(_ bytes: [UInt8]) -> Data { Data(bytes + [UInt8](repeating: 0, count: max(0, 6 - bytes.count))) }

    private func makeCore(myId: Data) -> CentralCore {
        CentralCore(myId: myId,
                    now: { [unowned self] in self.clock },
                    jitter: { 0 },
                    appInBackground: { [unowned self] in self.background },
                    haveLinkTo: { [unowned self] in self.linkedPeers.contains($0) },
                    haveLinkToPrefix: { [unowned self] in self.linkedPrefixes.contains($0) })
    }

    // Foreground-greater (dials) vs foreground-lesser (defers) prefixes relative to myId = 0xFF...
    private var myId: Data { nodeId(0xFF) }
    private var lesserPrefix: Data { pfx([0x00]) }        // myId.prefix(6) > this  -> we DIAL (fg)
    private var greaterPrefix: Data { pfx([0xFF, 0xFF]) } // myId.prefix(6) < this  -> we DEFER (fg)

    override func setUp() { super.setUp(); clock = 1000; linkedPeers = []; linkedPrefixes = []; background = false }

    // MARK: manager state

    func testStateChanged() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.stateChanged(isPoweredOn: true, isPoweredOff: false), [.scan])
        XCTAssertEqual(c.stateChanged(isPoweredOn: false, isPoweredOff: true), [.powerOff])
        XCTAssertEqual(c.stateChanged(isPoweredOn: false, isPoweredOff: false), [])   // resetting/unknown -> nothing
    }

    // MARK: discovery -> dial vs defer

    func testForegroundGreaterIdDialsImmediately() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [.connect(idA), .armDialTimeout(idA)])
        XCTAssertTrue(c.retained.contains(idA))
        XCTAssertEqual(c.advPrefixById[idA], lesserPrefix)
    }

    func testUnknownPrefixAlwaysDialsEvenBackgrounded() {
        background = true
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.discovered(idA, advPrefix: nil), [.connect(idA), .armDialTimeout(idA)])
        XCTAssertTrue(c.retained.contains(idA))
        XCTAssertNil(c.advPrefixById[idA])   // no prefix learned yet
    }

    func testForegroundLesserIdDefersToWaitTimeout() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.discovered(idA, advPrefix: greaterPrefix), [.armWaitTimeout(idA, advPrefix: greaterPrefix)])
        XCTAssertTrue(c.pendingWaits.contains(idA))
        XCTAssertFalse(c.retained.contains(idA), "a deferred peer is NOT retained until the fallback dials")
    }

    func testBackgroundedGreaterIdDefers() {
        background = true
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [.armWaitTimeout(idA, advPrefix: lesserPrefix)])
        XCTAssertTrue(c.pendingWaits.contains(idA))
    }

    func testDiscoverSkippedWhenAlreadyLinkedToPrefix() {
        linkedPrefixes = [lesserPrefix]
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [])
        XCTAssertFalse(c.retained.contains(idA))
    }

    func testDiscoverSkippedWhenAlreadyDialing() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)   // now retained
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [], "already dialing -> no second dial")
    }

    func testSecondDeferForSamePeerIsSuppressed() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.discovered(idA, advPrefix: greaterPrefix), [.armWaitTimeout(idA, advPrefix: greaterPrefix)])
        XCTAssertEqual(c.discovered(idA, advPrefix: greaterPrefix), [], "one wait per peer (SPEC R4)")
    }

    // MARK: wait-timeout fallback

    func testWaitTimeoutDialsWhenNoLinkFormed() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: greaterPrefix)   // deferred
        XCTAssertEqual(c.waitTimeoutFired(idA, advPrefix: greaterPrefix), [.connect(idA), .armDialTimeout(idA)])
        XCTAssertTrue(c.retained.contains(idA))
        XCTAssertFalse(c.pendingWaits.contains(idA))
    }

    func testWaitTimeoutSuppressedWhenPeerAlreadyDialedUs() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: greaterPrefix)
        linkedPrefixes = [greaterPrefix]   // the peer dialed our acceptor meanwhile
        XCTAssertEqual(c.waitTimeoutFired(idA, advPrefix: greaterPrefix), [])
        XCTAssertFalse(c.retained.contains(idA))
    }

    func testWaitTimeoutSuppressedWhenAlreadyDialing() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: greaterPrefix)
        // Simulate we started a dial in the meantime (e.g. a re-discover with a flipped tiebreak).
        _ = c.adopt(idA)   // retains idA
        XCTAssertTrue(c.retained.contains(idA))
        XCTAssertEqual(c.waitTimeoutFired(idA, advPrefix: greaterPrefix), [])
    }

    // MARK: connect lifecycle + backoff schedule

    func testConnectedDiscoversServices() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.connected(idA), [.discoverServices(idA)])
    }

    func testDialTimeoutAbortsAndSchedulesBackoff() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)    // dialed; advPrefixById[idA]=lesserPrefix
        XCTAssertEqual(c.dialTimeoutFired(idA), [.cancelConnection(idA), .cancelDialTimeout(idA)])
        XCTAssertFalse(c.retained.contains(idA))
        // First backoff: base 0.5 -> min(1.0, 30) + 0 jitter -> deadline = now + 1.0
        XCTAssertEqual(c.backoff[hex(lesserPrefix)] ?? .nan, 1001.0, accuracy: 0.0001)
    }

    func testDialTimeoutNoOpWhenNotRetained() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.dialTimeoutFired(idA), [])
    }

    func testBackoffScheduleDoublesOnRepeatedReconnect() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                       // backoff -> 1001 (base 0.5 -> next 1.0)
        XCTAssertEqual(c.backoff[hex(lesserPrefix)] ?? .nan, 1001.0, accuracy: 0.0001)
        // Next reconnect while the deadline is still ahead: base = max(1001-1000, 0.5) = 1.0 -> next 2.0
        XCTAssertEqual(c.disconnected(idA), [.cancelDialTimeout(idA)])
        XCTAssertEqual(c.backoff[hex(lesserPrefix)] ?? .nan, 1002.0, accuracy: 0.0001)
    }

    func testBackoffRateLimitsRediscovery() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                       // backoff deadline = 1001, now = 1000
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [], "still inside the backoff window")
        clock = 1002                                      // past the deadline
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [.connect(idA), .armDialTimeout(idA)])
    }

    func testEvictBackoffDropsExpiredKeys() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                       // backoff[hex(lesserPrefix)] = 1001
        clock = 1000 + LOST_S + 10                        // 1040: past LOST_S for the first key
        _ = c.disconnected(idB)                           // reconnect(idB) runs evictBackoff (cut = 1010)
        XCTAssertNil(c.backoff[hex(lesserPrefix)], "the stale key (1001) is evicted")
        XCTAssertNotNil(c.backoff[idB.uuidString], "the fresh key survives")
    }

    // MARK: PSM read + channel open

    func testReadEndpointOpensL2CAPAndPromotesPrefix() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        let peerId = Data([0xAB] + [UInt8](repeating: 0, count: 15))
        XCTAssertEqual(c.readEndpointValue(idA, psm: 0x1234, peerId: peerId), [.openL2CAP(idA, psm: 0x1234)])
        XCTAssertEqual(c.advPrefixById[idA], peerId.prefix(6), "the stable nodeId prefix is promoted")
    }

    func testReadEndpointCancelsWhenAlreadyLinked() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        let peerId = Data([0xAB] + [UInt8](repeating: 0, count: 15))
        linkedPeers = [peerId]
        XCTAssertEqual(c.readEndpointValue(idA, psm: 0x1234, peerId: peerId),
                       [.cancelDialTimeout(idA), .cancelConnection(idA)])
        XCTAssertFalse(c.retained.contains(idA))
    }

    func testChannelOpenedClearsTimerAndBackoff() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                        // seeds backoff[hex(lesserPrefix)]
        clock = 1002
        _ = c.discovered(idA, advPrefix: lesserPrefix)     // re-dial
        XCTAssertEqual(c.channelOpened(idA), [.cancelDialTimeout(idA)])
        XCTAssertNil(c.backoff[hex(lesserPrefix)], "a successful open resets the peer's backoff")
    }

    func testChannelOpenFailedReReads() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.channelOpenFailed(idA), [.discoverServices(idA)])
    }

    // MARK: dialer link closed

    func testDialerLinkClosedCancelsAndResetsBackoffWhenStable() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                        // seeds backoff
        clock = 1002
        _ = c.discovered(idA, advPrefix: lesserPrefix)     // re-dial -> retained again
        XCTAssertEqual(c.dialerLinkClosed(idA, stableUp: true), [.cancelConnection(idA)])
        XCTAssertNil(c.backoff[hex(lesserPrefix)], "a long-lived link resets backoff on close")
    }

    func testDialerLinkClosedKeepsBackoffWhenNotStable() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        XCTAssertEqual(c.dialerLinkClosed(idA, stableUp: false), [.cancelConnection(idA)])
    }

    func testDialerLinkClosedNoCancelWhenNotRetained() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.dialerLinkClosed(idA, stableUp: false), [])
    }

    // MARK: wake + restore

    func testWakeRearmScan() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.wakeRearmScan(isScanning: true), [])
        XCTAssertEqual(c.wakeRearmScan(isScanning: false), [.scan])
    }

    func testAdoptDialsUnretainedPeerOnly() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.adopt(idA), [.connect(idA), .armDialTimeout(idA)])
        XCTAssertTrue(c.retained.contains(idA))
        XCTAssertEqual(c.adopt(idA), [], "already retained -> no re-adopt")
    }

    func testRestoreConnectedVsDisconnected() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.restore(idA, isConnected: true), [.discoverServices(idA)])
        XCTAssertTrue(c.retained.contains(idA))
        XCTAssertEqual(c.restore(idB, isConnected: false), [.connect(idB)])
        XCTAssertTrue(c.retained.contains(idB))
    }

    // MARK: stop

    // MARK: production defaults (no injected clock/jitter/appInBackground)

    func testDefaultInitializedCoreStillDecides() {
        // Constructing without the test injections exercises the production default closures
        // ({ nowS() } / { Double.random(in: 0...1) } / { bleAppInBackground }). An unknown-prefix
        // discovery must still dial (the branch that needs none of the clock/jitter/bg inputs).
        let c = CentralCore(myId: nodeId(0xFF),
                            haveLinkTo: { _ in false },
                            haveLinkToPrefix: { _ in false })
        XCTAssertEqual(c.discovered(idA, advPrefix: nil), [.connect(idA), .armDialTimeout(idA)])
    }

    func testStopResetClearsInFlightSets() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)   // retained
        _ = c.discovered(idB, advPrefix: greaterPrefix)  // pendingWaits
        XCTAssertFalse(c.retained.isEmpty)
        XCTAssertFalse(c.pendingWaits.isEmpty)
        c.stopReset()
        XCTAssertTrue(c.retained.isEmpty)
        XCTAssertTrue(c.pendingWaits.isEmpty)
    }
}
