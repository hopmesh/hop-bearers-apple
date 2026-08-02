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
        // First CONSECUTIVE failure -> 2.0s + 0 jitter -> deadline = now + 2.0.
        // (Was 1.0s under the old delta-based schedule, which reset to its 0.5s floor every cycle
        // because a 12s dial timeout always outlasts the previous window. See BackoffScheduleTests.)
        XCTAssertEqual(c.backoff[hex(lesserPrefix)] ?? .nan, 1002.0, accuracy: 0.0001)
        XCTAssertEqual(c.failCount[hex(lesserPrefix)], 1)
    }

    func testDialTimeoutNoOpWhenNotRetained() {
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.dialTimeoutFired(idA), [])
    }

    func testBackoffScheduleDoublesOnRepeatedReconnect() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                       // failure 1 -> 2.0s
        XCTAssertEqual(c.backoff[hex(lesserPrefix)] ?? .nan, 1002.0, accuracy: 0.0001)
        // A second failure needs a second DIAL: `disconnected` only charges a peer that is actually
        // in flight, so a stray cancel can no longer be billed as a dial failure.
        clock = 1003
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        XCTAssertEqual(c.disconnected(idA), [.cancelDialTimeout(idA)])  // failure 2 -> 4.0s
        XCTAssertEqual(c.backoff[hex(lesserPrefix)] ?? .nan, 1007.0, accuracy: 0.0001)
        XCTAssertEqual(c.failCount[hex(lesserPrefix)], 2)
    }

    /// The actual regression. Growth must key on the CONSECUTIVE FAILURE COUNT, not on time
    /// remaining. Advancing the clock past each deadline (exactly what a 12s dial timeout does)
    /// used to collapse the schedule back to ~1s forever; now it keeps climbing into quarantine.
    func testBackoffGrowsEvenWhenEachDeadlineHasAlreadyLapsed() {
        let c = makeCore(myId: myId)
        let key = hex(lesserPrefix)
        var previous = 0.0
        for failure in 1...8 {
            // Each failure needs its own DIAL: `disconnected` only charges a peer actually in
            // flight, so a stray cancel is no longer billed as a dial failure.
            _ = c.discovered(idA, advPrefix: lesserPrefix)
            _ = c.disconnected(idA)
            let delay = (c.backoff[key] ?? .nan) - clock
            XCTAssertGreaterThanOrEqual(
                delay, previous,
                "failure \(failure): backoff must not shrink when the prior deadline has lapsed"
            )
            previous = delay
            // Simulate the dial timeout outlasting the window we just set.
            clock = (c.backoff[key] ?? clock) + Double(DIAL_TIMEOUT_S)
        }
        XCTAssertEqual(previous, BACKOFF_QUARANTINE_S, accuracy: 0.0001,
                       "a chronically failing target ends up quarantined, not re-dialed every ~13s")
    }

    /// A peer that completes HELLO is healthy again, so both the deadline and the count clear.
    func testHelloCompleteResetsTheFailureCount() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.disconnected(idA)
        clock = 1003
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.disconnected(idA)
        XCTAssertEqual(c.failCount[hex(lesserPrefix)], 2)
        clock = 1010
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialerLinkUp(idA)
        XCTAssertNil(c.failCount[hex(lesserPrefix)], "a completed HELLO clears the history")
        XCTAssertNil(c.backoff[hex(lesserPrefix)])
    }

    func testAStrayCancelIsNotBilledAsADialFailure() {
        // BEARER-03: the core's own cancels (already-linked, dialerLinkClosed) return as
        // didDisconnect. Billing those as dial failures quarantined a peer for up to ~120s purely
        // for being reachable. Only a dial actually in flight may be charged.
        let c = makeCore(myId: myId)
        XCTAssertEqual(c.disconnected(idA), [], "a peer we never dialed cannot fail a dial")
        XCTAssertNil(c.failCount[idA.uuidString])
        XCTAssertNil(c.backoff[idA.uuidString])
    }

    func testReachingAnAlreadyLinkedPeerClearsItsFailureState() {
        // Android treats reaching the peer as a SUCCESS (`succeededForAddr`); Apple charged it as a
        // failure. Reaching a peer proves it is healthy, whichever side dialed.
        let c = makeCore(myId: myId)
        let peer = nodeId(0x11)
        let key = hex(peer.prefix(6))
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.disconnected(idA)                       // accrue a failure first
        clock = 1005
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        linkedPeers.insert(peer)                      // we are already linked to this nodeId
        let effects = c.readEndpointValue(idA, psm: 0x0080, peerId: peer)
        XCTAssertEqual(effects, [.cancelDialTimeout(idA), .cancelConnection(idA)])
        XCTAssertNil(c.failCount[key], "reaching an already-linked peer clears its failure state")
        XCTAssertNil(c.backoff[key])
    }

    func testBackoffRateLimitsRediscovery() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                       // backoff deadline = 1002, now = 1000
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [], "still inside the backoff window")
        clock = 1003                                      // past the deadline
        XCTAssertEqual(c.discovered(idA, advPrefix: lesserPrefix), [.connect(idA), .armDialTimeout(idA)])
    }

    func testEvictBackoffDropsExpiredKeys() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                       // backoff[hex(lesserPrefix)] = 1002
        clock = 1000 + LOST_S + 10                        // 1040: past LOST_S for the first key
        _ = c.discovered(idB, advPrefix: nil)             // dial idB so its failure is chargeable
        _ = c.disconnected(idB)                           // reconnect(idB) runs evictBackoff (cut = 1010)
        XCTAssertNil(c.backoff[hex(lesserPrefix)], "the stale key (1002) is evicted")
        XCTAssertNotNil(c.backoff[idB.uuidString], "the fresh key survives")
        XCTAssertNil(c.failCount[hex(lesserPrefix)],
                     "the paired counter goes with it, or a long-gone peer returns pre-quarantined")
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

    func testChannelOpenedClearsTheTimerButNotTheBackoff() {
        // android-05/06 parity. Opening the L2CAP channel is NOT proof of a healthy peer: the link
        // is not up until HELLO. Clearing here pinned failCount at 1 forever for a peer that accepts
        // a channel and never says HELLO, making the growth curve and the 120s quarantine
        // unreachable for exactly the peer they exist to park.
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.dialTimeoutFired(idA)                        // seeds backoff[hex(lesserPrefix)]
        clock = 1003
        _ = c.discovered(idA, advPrefix: lesserPrefix)     // re-dial
        XCTAssertEqual(c.channelOpened(idA), [.cancelDialTimeout(idA)])
        XCTAssertNotNil(c.backoff[hex(lesserPrefix)], "L2CAP-open alone must NOT clear the backoff")
        XCTAssertNotNil(c.failCount[hex(lesserPrefix)], "nor the failure count")

        // HELLO completed: NOW the peer is proven healthy.
        XCTAssertEqual(c.dialerLinkUp(idA), [])
        XCTAssertNil(c.backoff[hex(lesserPrefix)], "HELLO-complete resets the peer's backoff")
        XCTAssertNil(c.failCount[hex(lesserPrefix)])
    }

    func testAPeerThatNeverCompletesHelloAccruesBackoffToQuarantine() {
        // The regression this whole seam exists for: connect -> L2CAP opens -> no HELLO -> reaped.
        // Under the old reset point this looped forever at a flat ~2s. It must now climb.
        let c = makeCore(myId: myId)
        let key = hex(lesserPrefix)
        var previous = 0.0
        for _ in 1...8 {
            _ = c.discovered(idA, advPrefix: lesserPrefix)   // dial (gate passes: clock is past backoff)
            _ = c.channelOpened(idA)                         // L2CAP opens, but HELLO never arrives
            _ = c.dialerLinkClosed(idA, stableUp: false)     // the no-HELLO reaper closes it
            _ = c.disconnected(idA)                          // ...and the cancel lands as didDisconnect
            let delay = (c.backoff[key] ?? .nan) - clock
            XCTAssertGreaterThanOrEqual(delay, previous, "backoff must grow across no-HELLO cycles")
            previous = delay
            clock = (c.backoff[key] ?? clock) + 1            // wait out the window, then advert again
        }
        XCTAssertEqual(previous, BACKOFF_QUARANTINE_S, accuracy: 0.0001,
                       "a peer that never completes HELLO must end up quarantined")
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
    // MARK: channelOpenFailed, the observed device spin

    /// The bug, measured on an iPhone: a cross-dial makes CoreBluetooth refuse with "L2CAP PSM already
    /// connected", the core treated it as a stale PSM per SPEC 7.4, re-read, got the identical error,
    /// and looped forever against a peer it was talking to. Once the link registers, the error IS that
    /// link, so the answer is to cancel rather than re-read.
    func testAnOpenFailureAgainstAnAlreadyLinkedPeerCancelsRatherThanReReading() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.readEndpointValue(idA, psm: 192, peerId: nodeId(0x11))   // promotes advPrefixById
        linkedPrefixes = [nodeId(0x11).prefix(6)]                       // HELLO completed meanwhile
        XCTAssertEqual(c.channelOpenFailed(idA), [.cancelDialTimeout(idA), .cancelConnection(idA)],
                       "the open error IS our own link, so re-reading can only reproduce it")
    }

    /// The window before HELLO registers the link is exactly where the spin lived, so an unbounded
    /// re-read is wrong even when no link is visible yet.
    func testConsecutiveOpenFailuresAreBoundedAndThenTearDown() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        XCTAssertEqual(c.channelOpenFailed(idA), [.discoverServices(idA)], "1st re-read is the SPEC 7.4 stale-PSM case")
        XCTAssertEqual(c.channelOpenFailed(idA), [.discoverServices(idA)])
        XCTAssertEqual(c.channelOpenFailed(idA), [.discoverServices(idA)])
        XCTAssertEqual(c.channelOpenFailed(idA), [.cancelDialTimeout(idA), .cancelConnection(idA)],
                       "past the bound the connection is torn down so reconnect+backoff takes over")
    }

    /// A stale PSM that resolves must not leave the device one failure closer to a teardown.
    func testASuccessfulOpenClearsTheFailureRun() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.channelOpenFailed(idA)
        _ = c.channelOpenFailed(idA)
        _ = c.channelOpened(idA)
        XCTAssertEqual(c.channelOpenFailed(idA), [.discoverServices(idA)],
                       "the run reset, so this is a fresh first re-read")
    }

    /// The counter is per device, so one bad peer cannot spend another peer's budget.
    func testTheFailureRunIsPerDevice() {
        let c = makeCore(myId: myId)
        _ = c.discovered(idA, advPrefix: lesserPrefix)
        _ = c.discovered(idB, advPrefix: lesserPrefix)
        for _ in 0..<4 { _ = c.channelOpenFailed(idA) }
        XCTAssertEqual(c.channelOpenFailed(idB), [.discoverServices(idB)],
                       "idB is untouched by idA's failures")
    }

}
