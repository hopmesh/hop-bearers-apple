// apple-02: unit coverage for the backgrounded-BLE-only-iOS receive hardening. The three code-side
// fixes each expose a PURE decision function that runs without a CoreBluetooth radio:
//
//   (b) suspend-aware liveness  -> livenessVerdict(...)   : don't reap a link across a process suspend
//   (c) "Android dials iOS"      -> shouldDialNow(...)     : a backgrounded iOS central becomes acceptor
//   (a) bg-task assertion        -> BackgroundAssertion    : lifecycle-safe, no-op on macOS
//
// A `Link` / `CBL2CAPChannel` can't be constructed in a unit test, so the Link/Central object paths
// stay device-tested; the DECISION logic that governs suspend-grace and dial-vs-wait is covered here,
// which is exactly what the soak needs de-risked before the (external) device soak validates it live.

import XCTest
import Foundation
@testable import HopBearerBle

final class BackgroundLivenessTests: XCTestCase {

    // MARK: (b) suspend-aware liveness, livenessVerdict

    /// A healthy, up link with recent RX and a normal ~1 s tick cadence is kept.
    func testHealthyUpLinkIsKept() {
        let v = livenessVerdict(up: true, openedGapS: 40, rxGapS: 1.0, tickGapS: 1.0, deadLimitS: DEAD_BG_S)
        XCTAssertEqual(v, .keep)
    }

    /// Real RX silence past the deadline (with a normal tick cadence, i.e. we were NOT asleep) reaps.
    func testRealSilencePastDeadlineReaps() {
        let v = livenessVerdict(up: true, openedGapS: 40, rxGapS: DEAD_BG_S + 1, tickGapS: 1.0, deadLimitS: DEAD_BG_S)
        XCTAssertEqual(v, .reapDead)
    }

    /// THE apple-02(b) regression guard: an up link with a long RX gap BUT a large tick gap (the process
    /// was suspended) must NOT be reaped; it gets suspend-grace instead. This is the exact frame where
    /// the old code killed a live inbound path on wake.
    func testSuspendGapGrantsGraceNotReap() {
        // rxGap looks fatal on its own, but the tick gap proves we were asleep, not that the peer died.
        let v = livenessVerdict(up: true, openedGapS: 120, rxGapS: 60, tickGapS: 55, deadLimitS: DEAD_BG_S)
        XCTAssertEqual(v, .suspendGrace)
    }

    /// A tick gap just under the suspend threshold is treated as a normal (awake) tick, so a normal RX
    /// gap is still evaluated on its merits, here still alive.
    func testTickGapJustUnderThresholdIsNormal() {
        let v = livenessVerdict(up: true, openedGapS: 40, rxGapS: 1.0, tickGapS: SUSPEND_GAP_S - 0.5, deadLimitS: DEAD_BG_S)
        XCTAssertEqual(v, .keep)
    }

    /// Suspend-grace also protects a half-open (not-yet-up) link across a suspend, rather than reaping it
    /// as no-HELLO: the handshake may simply have been frozen with us.
    func testSuspendGraceProtectsHalfOpenLink() {
        let v = livenessVerdict(up: false, openedGapS: 30, rxGapS: 30, tickGapS: 20, deadLimitS: DEAD_FG_S)
        XCTAssertEqual(v, .suspendGrace)
    }

    /// A half-open link that never HELLOs, with a NORMAL tick cadence (we were awake the whole time), is
    /// reaped once past REAP_S, suspend-grace must not mask a genuinely dead half-open link.
    func testHalfOpenNoHelloReapsWhenAwake() {
        let v = livenessVerdict(up: false, openedGapS: REAP_S + 1, rxGapS: REAP_S + 1, tickGapS: 1.0, deadLimitS: DEAD_FG_S)
        XCTAssertEqual(v, .reapNoHello)
    }

    /// After a suspend-grace tick reset the RX clock, the NEXT (awake) tick with continued silence
    /// reaps: grace is one window, not an indefinite reprieve. Model the two-tick sequence:
    ///   tick 1: big tick gap -> suspendGrace (caller resets rxGap to ~0)
    ///   tick 2: normal tick gap, but the peer is truly gone so rxGap climbs back past the deadline -> reap
    func testGraceIsSingleWindowThenReapsIfStillDead() {
        let t1 = livenessVerdict(up: true, openedGapS: 120, rxGapS: 60, tickGapS: 55, deadLimitS: DEAD_BG_S)
        XCTAssertEqual(t1, .suspendGrace)
        // Caller reset lastRxMs on grace; peer still dead, so after the deadLimit elapses again, awake:
        let t2 = livenessVerdict(up: true, openedGapS: 120 + DEAD_BG_S + 1, rxGapS: DEAD_BG_S + 1, tickGapS: 1.0, deadLimitS: DEAD_BG_S)
        XCTAssertEqual(t2, .reapDead)
    }

    // MARK: (c) "Android dials iOS" acceptor-bias, shouldDialNow

    /// Foreground, greater id: the plain SPEC §2.1 tiebreaker applies, so we dial.
    func testForegroundGreaterIdDials() {
        XCTAssertTrue(shouldDialNow(appInBackground: false, haveKnownPrefix: true, tiebreakSaysDial: true))
    }

    /// Foreground, lesser id: we wait (acceptor) as the tiebreaker says.
    func testForegroundLesserIdWaits() {
        XCTAssertFalse(shouldDialNow(appInBackground: false, haveKnownPrefix: true, tiebreakSaysDial: false))
    }

    /// THE apple-02(c) core: backgrounded, even as the GREATER id we do NOT dial; we defer so the
    /// Android peer dials our advertising acceptor. This is the "Android dials iOS" bias.
    func testBackgroundGreaterIdDefersToAcceptor() {
        XCTAssertFalse(shouldDialNow(appInBackground: true, haveKnownPrefix: true, tiebreakSaysDial: true))
    }

    /// Backgrounded and lesser id: also wait (already the acceptor). Consistent with the bias.
    func testBackgroundLesserIdWaits() {
        XCTAssertFalse(shouldDialNow(appInBackground: true, haveKnownPrefix: true, tiebreakSaysDial: false))
    }

    /// An UNKNOWN peer (no advertised prefix -> no tiebreak possible) is always dialed, even backgrounded:
    /// it is the only way to learn the peer and make any progress. The bias only applies once we know who
    /// the peer is.
    func testUnknownPeerAlwaysDialsEvenBackgrounded() {
        XCTAssertTrue(shouldDialNow(appInBackground: true, haveKnownPrefix: false, tiebreakSaysDial: false))
        XCTAssertTrue(shouldDialNow(appInBackground: false, haveKnownPrefix: false, tiebreakSaysDial: false))
    }

    /// Symmetry / no-deadlock property: for a known distinct pair, at least one side dials. In the
    /// worst case (backgrounded iOS as greater id declines), the peer is the lesser id and would
    /// normally wait, but the peer's wait-timeout fallback (WAIT_BASE_S) still dials, so the link forms.
    /// We assert the decision itself is well-defined (never both-nil): a foreground peer of either
    /// polarity produces a definite dialer.
    func testForegroundPairAlwaysHasADialer() {
        // Greater foreground dials; lesser foreground waits. Exactly one dialer.
        let greaterDials = shouldDialNow(appInBackground: false, haveKnownPrefix: true, tiebreakSaysDial: true)
        let lesserDials  = shouldDialNow(appInBackground: false, haveKnownPrefix: true, tiebreakSaysDial: false)
        XCTAssertNotEqual(greaterDials, lesserDials)
    }

    // MARK: apple-r2-02: deferral is NOT "never dial"; the wait-timeout fallback still forms the link.

    /// A backgrounded iOS central maps to `.deferThenFallbackDial`, never a silent no-dial. This pins the
    /// corrected invariant (the old comment claimed "never dial", but didDiscover defers then falls back).
    func testBackgroundedKnownPeerDefersButDoesNotNeverDial() {
        XCTAssertEqual(discoverAction(appInBackground: true, haveKnownPrefix: true, tiebreakSaysDial: true),
                       .deferThenFallbackDial)
        XCTAssertEqual(discoverAction(appInBackground: true, haveKnownPrefix: true, tiebreakSaysDial: false),
                       .deferThenFallbackDial)
    }

    /// A foregrounded greater id dials immediately; unknown peers dial immediately regardless of bg.
    func testForegroundGreaterAndUnknownDialImmediately() {
        XCTAssertEqual(discoverAction(appInBackground: false, haveKnownPrefix: true, tiebreakSaysDial: true),
                       .dialNow)
        XCTAssertEqual(discoverAction(appInBackground: true, haveKnownPrefix: false, tiebreakSaysDial: false),
                       .dialNow)
    }

    /// THE apple-r2-02 regression guard: two backgrounded peers BOTH defer, so neither dials immediately.
    /// The link therefore depends entirely on the wait-timeout fallback dialing, proving the fallback is
    /// load-bearing and must NOT be removed (removing it to enforce a hard "never dial backgrounded" would
    /// black-hole iOS<->iOS link formation with no Android present).
    func testTwoBackgroundedPeersBothDeferSoFallbackIsRequired() {
        let a = discoverAction(appInBackground: true, haveKnownPrefix: true, tiebreakSaysDial: true)
        let b = discoverAction(appInBackground: true, haveKnownPrefix: true, tiebreakSaysDial: false)
        XCTAssertEqual(a, .deferThenFallbackDial)
        XCTAssertEqual(b, .deferThenFallbackDial)
        // With neither dialing now, the fallback for at least one side must dial (peer has not dialed us,
        // we are not already dialing) so a link forms.
        XCTAssertTrue(waitTimeoutDials(peerAlreadyDialedUs: false, weAreAlreadyDialing: false))
    }

    /// The fallback is suppressed once a link has formed (peer dialed us) or we already started a dial,
    /// so it never opens a duplicate second leg.
    func testWaitTimeoutSuppressedWhenLinkAlreadyForming() {
        XCTAssertFalse(waitTimeoutDials(peerAlreadyDialedUs: true, weAreAlreadyDialing: false))
        XCTAssertFalse(waitTimeoutDials(peerAlreadyDialedUs: false, weAreAlreadyDialing: true))
        XCTAssertFalse(waitTimeoutDials(peerAlreadyDialedUs: true, weAreAlreadyDialing: true))
    }

    // MARK: (a) background-task assertion, BackgroundAssertion lifecycle

    /// On macOS the assertion is a compiled no-op; the calls must be safe and non-crashing regardless of
    /// order (begin/renew/end/end). This guards the lifecycle surface the bearer drives.
    func testBackgroundAssertionLifecycleIsSafe() {
        let a = BackgroundAssertion(maxHoldS: 0.1)
        a.begin("test")
        a.renew()
        a.end("test")
        a.end("double-end-idempotent")   // idempotent: must not crash
        a.renew()                        // renew after end: no-op, must not crash
        a.begin("re-begin")
        a.end("cleanup")
    }
}
