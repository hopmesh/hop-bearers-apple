// BleBearer, the PROVEN clean-room BLE transport (ble-lab/SPEC.md §8), behind the `Bearer`/`LinkSink`
// contract so the clean room (Sources/blepeer) and the production app share ONE transport.
//
// This file is the PURE, unit-testable half of the bearer: the wire deframer, the liveness/dial decision
// functions, the `DedupLink` one-pipe-per-peer dedup, and the `BleBearer` link-map owner. Everything that
// names a CoreBluetooth type, the `Link` (CBL2CAPChannel + streams), the `Central`/`Peripheral` delegate
// shells, and `BleBearer.start()/stop()/wake()`, lives in BleBearer+Radio.swift, which cannot run under
// `swift test` (CoreBluetooth has no simulator/headless support and its delegate arg types have no public
// initializers) and is therefore covered by the on-device hopmac/testkit workflow, not CI line coverage.
// The Central/Peripheral DECISION logic those shells used to inline now lives in CentralCore/PeripheralCore
// (pure, testable), the shells only translate CB callbacks into core calls and execute the returned
// effects. So the split is behavior-preserving: WHAT gets decided is unchanged, only WHERE.
//
//   • KEPT IN THE TRANSPORT (unchanged behavior): 4-byte BE framing; the 1 Hz PING keepalive that feeds
//     the watchdog + STATUS counters; the adaptive liveness watchdog (DEAD_FG_S/DEAD_BG_S) + no-HELLO
//     reaper; the HELLO identity handshake; one-pipe-per-peer dedup (`linksByPeerId` + greater-nodeId keep
//     rule); and the Central redial logic INCLUDING the backoff schedule.
//
// Wire format (HELLO/PING/PONG/DATA + 4-byte BE length) is preserved byte-for-byte so a HopBearers node
// still interops with the un-refactored Android / hopmac peers.

import Foundation
import Security       // SecRandomCopyBytes (randomNodeId)
import HopContract   // the bearer contract (no libhop)

// MARK: - Platform config (SPEC §8 / §8.1). Overridable by the iOS app BEFORE BleBearer.start() ---
//
// CLI default: everything on .main (no UI contends, SPEC R8). An iOS app instead points bleQueue at
// a dedicated serial queue and bleRunLoop at a dedicated I/O thread's RunLoop, and sets
// bleAppInBackground from scenePhase. Public mutable globals so the host (app) reassigns them BEFORE
// BleBearer.start() without editing the package.
public var bleQueue: DispatchQueue = .main
public var bleRunLoop: RunLoop = .main
public var bleAppInBackground = false

// SPEC §5 timing.
let PING_S: Double  = 1.0     // 1 Hz PING == the keepalive that feeds the watchdog + STATUS counters
let DEAD_FG_S: Double = 5.0   // foreground liveness deadline
let DEAD_BG_S: Double = 15.0  // background liveness deadline (iOS relaxes conn interval in bg)
let REAP_S: Double  = 3.0     // half-open (no-HELLO) reaper
let WAIT_BASE_S: Double = 4.0 // wait-timeout safety net (SPEC §2.2)
let DIAL_TIMEOUT_S: Double = 12.0
let MAX_FRAME = 4 * 1024 * 1024
let STABLE_UP_MS: UInt64 = 30_000
let LOST_S: Double = 30.0

// apple-02(b): suspend-aware liveness. The watchdog is a 1 Hz RunLoop timer; while iOS suspends the
// process, no timers fire and wall-clock keeps advancing, so on wake `nowMs() - lastRxMs` looks like a
// long RX silence and the link would be reaped as "liveness DEAD" even though the peer is fine, we
// were merely asleep. If the gap between two successive watchdog ticks exceeds SUSPEND_GAP_S the
// process was suspended, so instead of reaping we grant one grace window (reset the RX clock + probe
// with a PING) and only reap on a subsequent tick if the peer really is gone.
let SUSPEND_GAP_S: Double = 3.0     // a tick gap larger than this means we were suspended, not idle

// Wire frame types (SPEC §4). The DATA type is the consumer seam: Bearer.send wraps the consumer's
// application bytes in a DATA frame, and an inbound DATA frame is delivered via sink.linkBytes. The
// PING/PONG types are the transport's own keepalive and never reach the consumer.
let FRAME_HELLO: UInt8 = 0x01
let FRAME_PING:  UInt8 = 0x02
let FRAME_PONG:  UInt8 = 0x03
let FRAME_DATA:  UInt8 = 0x10

// MARK: - Small helpers -------------------------------------------------------------------------
// log / nowMs / nowS / hex / shortHex now live in HopBearerCore (shared by every bearer + consumer).

/// Unsigned big-endian compare: a > b (byte 0 most significant). SPEC §1.2 tiebreaker primitive.
func gt(_ a: Data, _ b: Data) -> Bool {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] > b[i] }
    return a.count > b.count
}

// MARK: - Pure deframer (SPEC §4 framing, extracted so the wire format is unit-testable) ----------

/// Streaming deframer for the BLE wire format: a 4-byte big-endian length prefix followed by `len` body
/// bytes (body[0] is the 1-byte frame type). Feed it whatever the L2CAP input stream produced; it emits
/// every COMPLETE frame body and retains a partial tail. `overLimit` flags a length < 1 or > MAX_FRAME
/// (the `bad len` the link closes on). Byte-for-byte the math in Link.deframe(), lifted into a value type
/// so partial / back-to-back / oversized-length behavior is testable without a CBL2CAPChannel.
struct BleDeframer {
    private var inBuf = [UInt8]()

    mutating func feed(_ bytes: [UInt8], overLimit: inout Bool) -> [[UInt8]] {
        overLimit = false
        inBuf.append(contentsOf: bytes)
        var out = [[UInt8]]()
        while inBuf.count >= 4 {
            let len = Int(UInt32(inBuf[0]) << 24 | UInt32(inBuf[1]) << 16 | UInt32(inBuf[2]) << 8 | UInt32(inBuf[3]))
            guard len >= 1, len <= MAX_FRAME else { overLimit = true; return out }
            let total = 4 + len
            guard inBuf.count >= total else { break }   // partial frame, wait for more bytes
            out.append(Array(inBuf[4..<total]))
            inBuf.removeFirst(total)
        }
        return out
    }

    var bufferedCount: Int { inBuf.count }
}

/// Build a 4-byte big-endian length-prefixed frame around `body` (the inverse of BleDeframer). Shared so
/// a test can round-trip frame -> deframe without reaching into Link's L2CAP output stream.
func bleFrame(_ body: [UInt8]) -> [UInt8] {
    let len = UInt32(body.count)
    return [UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff)] + body
}

// MARK: - Liveness verdict (apple-02(b), pure + testable) ----------------------------------------

/// What the watchdog should do this tick. Extracted as a pure function so the suspend-aware liveness
/// logic is unit-testable without a CoreBluetooth channel (a `Link` can't be built in a unit test).
enum LivenessVerdict: Equatable {
    case keep            // link healthy, do nothing
    case reapNoHello     // half-open past REAP_S with no HELLO, reap
    case reapDead        // real RX silence past the deadline, reap
    case suspendGrace    // the process was suspended across this tick, grant grace, probe, don't reap
}

/// Decide the watchdog action. `tickGapS` is the wall-clock gap since the previous watchdog tick: a gap
/// far larger than the 1 s tick cadence means the process was suspended (iOS froze our timers), so a
/// stale RX clock reflects our sleep, not a dead peer. In that case we grant one grace window instead of
/// reaping. Pure: no globals, no clock reads, the caller passes every input.
func livenessVerdict(up: Bool, openedGapS: Double, rxGapS: Double, tickGapS: Double, deadLimitS: Double) -> LivenessVerdict {
    // A large tick gap means we just resumed from suspension. The RX clock was frozen with us, so it
    // cannot distinguish "peer went quiet" from "we were asleep", grant grace and probe (both when
    // still handshaking and when up), so a suspended receiver never self-reaps a live inbound path.
    if tickGapS > SUSPEND_GAP_S {
        return .suspendGrace
    }
    if !up {
        return openedGapS > REAP_S ? .reapNoHello : .keep
    }
    return rxGapS > deadLimitS ? .reapDead : .keep
}

// MARK: - Dial decision (apple-02(c) / issue /548, pure + testable) ------------------------------
//
// "Android dials iOS" bias. A backgrounded iOS Central cannot scan/dial reliably (iOS throttles bg
// scanning hard and suspends the process), but iOS DOES accept an inbound L2CAP channel in the
// background via CoreBluetooth state restoration. So a backgrounded iOS peer should be the ACCEPTOR:
// it keeps advertising (peripheral) and lets the peer dial it, instead of trying to dial out.
//
// The base tiebreaker (SPEC §2.1) is symmetric: the greater 6-byte id dials, the lesser waits, and the
// waiter's WAIT_BASE_S fallback dials anyway if the greater side never does. That fallback is what makes
// deferring safe: if a backgrounded iOS peer declines to dial even as the greater id, the Android peer's
// existing wait-timeout fires and Android dials the (advertising) iPhone as acceptor. No deadlock, no
// protocol change, iOS just biases toward WAIT while backgrounded.

/// Should THIS central dial the discovered peer IMMEDIATELY (no wait)? `appInBackground` is iOS's
/// suspend-prone state. `haveKnownPrefix` is whether we learned the peer's 6-byte id from its advert
/// (needed for the tiebreak). Pure: the caller passes the tiebreak result so this has no crypto/Data
/// dependency.
///
/// apple-r2-02: a `false` return does NOT mean "never dial". It means "defer": the caller enters the
/// WAIT_BASE_S pending-wait, and if the peer still has not dialed us by the timeout, the caller dials as
/// a fallback so a link ALWAYS forms (no deadlock, no starvation between two backgrounded iPhones with no
/// Android present). Backgrounded iOS is therefore ACCEPTOR-BIASED (it waits WAIT_BASE_S before dialing),
/// not a pure never-dialer. Keeping the fallback is deliberate: dropping it to enforce a hard "never dial
/// backgrounded" would black-hole iOS<->iOS link formation when no peer volunteers to dial.
func shouldDialNow(appInBackground: Bool, haveKnownPrefix: Bool, tiebreakSaysDial: Bool) -> Bool {
    // Unknown peer (no advertised prefix): we cannot run the tiebreak, so we must dial to make any
    // progress. This is the only way to learn the peer at all. Applies even when backgrounded.
    guard haveKnownPrefix else { return true }
    // Backgrounded iOS: do not dial NOW. Advertise + accept and let the peer (Android) dial us; the
    // caller's wait-timeout is the fallback that still dials if no one does.
    if appInBackground { return false }
    // Foreground: the plain SPEC §2.1 tiebreaker. Greater id dials.
    return tiebreakSaysDial
}

/// apple-r2-02: the two outcomes of `didDiscover` for a known peer, made explicit + pure so the
/// deferral semantics are testable without a CoreBluetooth radio. `.dialNow` dials immediately;
/// `.deferThenFallbackDial` enters the WAIT_BASE_S pending-wait and, if the peer has not dialed us by
/// the timeout, dials as a fallback (so a link ALWAYS forms). A backgrounded iOS central maps to
/// `.deferThenFallbackDial`, NOT to a "never dial" state: it is acceptor-biased, not a pure never-dialer.
enum DiscoverAction: Equatable { case dialNow, deferThenFallbackDial }

func discoverAction(appInBackground: Bool, haveKnownPrefix: Bool, tiebreakSaysDial: Bool) -> DiscoverAction {
    shouldDialNow(appInBackground: appInBackground,
                  haveKnownPrefix: haveKnownPrefix,
                  tiebreakSaysDial: tiebreakSaysDial) ? .dialNow : .deferThenFallbackDial
}

/// Does the WAIT_BASE_S wait-timeout fallback dial the peer, given whether the peer dialed us first?
/// This models the closure body at `didDiscover`'s pendingWaits branch: it dials iff no link formed
/// meanwhile (the peer did not dial us and we are not already dialing it). This is the liveness
/// guarantee that makes deferral safe even when BOTH peers are backgrounded and neither would dial now.
func waitTimeoutDials(peerAlreadyDialedUs: Bool, weAreAlreadyDialing: Bool) -> Bool {
    if peerAlreadyDialedUs { return false }   // link already formed via the acceptor path
    if weAreAlreadyDialing { return false }   // we started a dial in the meantime
    return true                               // fallback: dial so the link forms no matter what
}

// MARK: - DedupLink: the one-pipe-per-peer dedup seam ---------------------------------------------

/// The slice of a live link the bearer's dedup/routing needs, with NO CoreBluetooth in it. `Link`
/// (BleBearer+Radio.swift) is the only production conformer; a test conforms a fake so the dedup, the
/// linkUp/linkDown pairing (apple-12 `wasSurfaced`), send routing, and STATUS all run without a
/// CBL2CAPChannel. Class-bound so the dedup's identity checks (`existing !== link`, `keep === link`) hold.
protocol DedupLink: AnyObject {
    var linkId: LinkId { get }
    var peerId: Data? { get }        // learned from HELLO; the dedup/tiebreak key
    var isDialer: Bool { get }
    var wasSurfaced: Bool { get set } // apple-12: true iff this exact leg was announced to the sink
    var peerShort: String { get }
    var rx: UInt64 { get }
    var tx: UInt64 { get }
    var rttMs: UInt64 { get }
    func sendData(_ bytes: Data)
    func close(_ why: String)
}

// MARK: - BleBearer: owns myId, both planes, the dedup map + the linkId map (SPEC §2.3) ----------

/// The PROVEN clean-room BLE transport behind the `Bearer` contract. Owns one-pipe-per-peer dedup
/// internally and assigns a monotonic `LinkId` per established Link; the consumer only ever sees
/// linkUp / linkBytes / linkDown and calls `send`. The CoreBluetooth planes (`Central`/`Peripheral`) and
/// start/stop/wake live in BleBearer+Radio.swift; this class is the radio-free dedup/routing owner.
public final class BleBearer: Bearer {
    let myId: Data                                   // SPEC R11: stable for the whole process lifetime
    /// Where links surface. Set by the consumer (or a BearerManager) before `start()`. Weak: the
    /// sink/manager owns the bearer, so a strong ref back would cycle (see `Bearer.sink`).
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). BLE links surface as "BT".
    public let transportName = "BT"
    var peripheral: Peripheral?
    var central: Central?
    // The link maps + linkId counter are the ONE piece of BleBearer state touched from more than one
    // executor: onUp/onData/onClose/send/closeAllLinks run on bleRunLoop (the stream/timer I/O thread),
    // while the Central's haveLinkTo/haveLinkToPrefix dial gates read them on bleQueue (the CB delegate
    // queue). Swift Dictionary reads concurrent with mutation are undefined behavior, so every access to
    // these three fields goes through `mapLock`. Held only for the map touch itself: never call out to a
    // Link (close/send) or the sink while holding it, to avoid re-entrancy/lock-ordering hazards.
    private let mapLock = NSLock()
    private var linksByPeerId = [Data: DedupLink]()  // dedup: one survivor per peer (SPEC §2.3)
    private var linksByLinkId = [LinkId: DedupLink]() // send routing + linkUp/linkDown pairing
    private var nextLinkId: LinkId = 1               // minted under mapLock
    var status: Timer?
    // apple-02(a): the background-task assertion that keeps an in-flight receive alive across a suspend.
    // Held while backgrounded WITH at least one live link, renewed on each inbound frame, ended on
    // foreground / no-links. No-op on macOS (see BackgroundAssertion).
    let bgAssertion = BackgroundAssertion()
    private var appInBackground = false             // mirrors bleAppInBackground for assertion bookkeeping
    #if os(iOS)
    var beaconWake: BeaconWake?                      // the bearer's own iBeacon background-wake monitor
    #endif

    /// When true, the bearer publishes its GATT/L2CAP endpoint but NEVER advertises, so it can dial
    /// peers (central) yet stay undiscoverable (central-only scan behavior, hopmac). Default false:
    /// the dual-role production bearer advertises so peers can find it.
    let suppressAdvertising: Bool

    public init(myId: Data, suppressAdvertising: Bool = false) {
        self.myId = myId
        self.suppressAdvertising = suppressAdvertising
    }

    /// Convenience: a fresh random 16-byte nodeId (SPEC R11) for callers that don't supply one.
    public static func randomNodeId() -> Data {
        var d = Data(count: 16)
        let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        if rc != errSecSuccess {                       // defensive fallback; SystemRandom is CSPRNG-grade
            d = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        }
        return d
    }

    public func send(_ bytes: Data, on link: LinkId) {
        bleRunLoop.perform { [weak self] in
            guard let self else { return }
            mapLock.lock(); let l = linksByLinkId[link]; mapLock.unlock()        // no-op if link closed/unknown
            l?.sendData(bytes)
        }
    }

    func mint() -> LinkId {
        mapLock.lock(); defer { mapLock.unlock() }
        let id = nextLinkId; nextLinkId += 1; return id
    }

    /// dial gate (Central, on bleQueue): read the peer map under the lock.
    func haveLinkTo(_ peer: Data) -> Bool {
        mapLock.lock(); defer { mapLock.unlock() }
        return linksByPeerId[peer] != nil
    }
    func haveLinkToPrefix(_ pre: Data) -> Bool {
        mapLock.lock(); defer { mapLock.unlock() }
        return linksByPeerId.keys.contains { $0.prefix(6) == pre }
    }

    func printStatus() {
        mapLock.lock(); let links = Array(linksByPeerId.values); mapLock.unlock()
        if links.isEmpty {
            log("STATUS", "links=0")
            return
        }
        let detail = links
            .map { "peer=\($0.peerShort)/rx=\($0.rx)/tx=\($0.tx)/rtt=\($0.rttMs)ms/\($0.isDialer ? "dialer" : "acceptor")" }
            .joined(separator: " ")
        log("STATUS", "links=\(links.count) \(detail)")
    }

    func onUp(_ link: DedupLink) {                  // HELLO completed: dedup, then surface the survivor
        guard let peer = link.peerId else { return }
        // apple-12: dedup BEFORE surfacing. The clean room surfaced both legs of a duplicate pair and
        // let dedup close the loser afterwards, which handed the node a doomed handshake start + teardown
        // per simultaneous mutual dial (handshake churn, plausible securing-stuck / link-id-churn cause).
        // Now the loser never reaches sink.linkUp: only the survivor is announced.
        mapLock.lock()
        linksByLinkId[link.linkId] = link           // register for send routing + linkDown pairing
        let existing = linksByPeerId[peer]
        var drop: DedupLink? = nil
        if let existing, existing !== link {        // SPEC §2.3 dedup
            let keepDialed = gt(myId, peer)         // keep MY dialed channel iff I'm the greater id
            let keep = [existing, link].first { $0.isDialer == keepDialed } ?? link
            drop = (keep === link) ? existing : link
            linksByPeerId[peer] = keep              // SPEC R3: set survivor BEFORE closing the dropped channel
            if keep === link { link.wasSurfaced = true }   // only the survivor is announced (apple-12)
            mapLock.unlock()
            if let drop {
                log("DEDUP", "kept isDialer=\(keep.isDialer) peer=\(shortHex(peer))")
                // Close the loser. It was never surfaced, so onClose emits no linkDown for it.
                drop.close("dedup")
            }
            if keep === link {                      // this leg is the survivor -> announce it now
                sink?.linkUp(link.linkId, role: link.isDialer ? .dialer : .acceptor, peerId: peer)
            }
            return
        }
        linksByPeerId[peer] = link                  // first (or same) link for this peer -> the survivor
        link.wasSurfaced = true
        mapLock.unlock()
        // apple-02(a): a link came up. If we're already backgrounded, take the assertion now so this
        // fresh inbound path survives an imminent suspend (e.g. a peer dialed our backgrounded acceptor).
        if appInBackground { bgAssertion.begin("link-up-bg") }
        sink?.linkUp(link.linkId, role: link.isDialer ? .dialer : .acceptor, peerId: peer)
    }

    func onData(_ link: DedupLink, _ bytes: Data) {
        // apple-02(a): a DATA frame arrived. If we're backgrounded, push the bg-assertion window out so
        // an in-flight multi-frame receive can finish before iOS suspends us.
        if appInBackground { bgAssertion.renew() }
        sink?.linkBytes(link.linkId, bytes)         // one DATA frame -> consumer
    }

    /// apple-02(a): the host (driver) calls this on every foreground/background transition. On entering
    /// the background WITH at least one live link, take the UIApplication background-task assertion so a
    /// suspend does not instantly kill an in-flight inbound receive; on foreground, end it. Also keeps
    /// the shared `bleAppInBackground` liveness flag in lockstep so the two never drift.
    public func setBackground(_ background: Bool) {
        bleAppInBackground = background
        appInBackground = background
        if background {
            mapLock.lock(); let haveLinks = !linksByPeerId.isEmpty; mapLock.unlock()
            if haveLinks { bgAssertion.begin("bg-with-links") }
        } else {
            bgAssertion.end("foreground")
        }
    }

    func onClose(_ link: DedupLink) {               // SPEC R3: identity-checked removal
        mapLock.lock()
        let wasUp = linksByLinkId.removeValue(forKey: link.linkId) != nil        // true iff registered in onUp
        if let peer = link.peerId, linksByPeerId[peer] === link { linksByPeerId.removeValue(forKey: peer) }
        let noLinksLeft = linksByPeerId.isEmpty
        mapLock.unlock()
        // apple-02(a): nothing left to protect once the last link drops, release the assertion so a
        // backgrounded, link-less app is suspended promptly instead of burning its grace window.
        if noLinksLeft { bgAssertion.end("no-links") }
        // A deduped loser never reached sink.linkUp (apple-12), so it must not emit a linkDown either.
        // `link.wasSurfaced` records whether onUp announced this exact leg to the sink.
        if wasUp && link.wasSurfaced { sink?.linkDown(link.linkId) }             // pair every linkDown with a prior linkUp
    }

    func closeAllLinks() {                          // SPEC R11: drop all local links on power-off / stop
        // close() invalidates the link's RunLoop timers + closes its streams, which must happen on the
        // thread that owns bleRunLoop (CFRunLoop thread-affinity). onPowerOff fires on bleQueue, so hop.
        mapLock.lock(); let links = Array(linksByPeerId.values); mapLock.unlock()
        bleRunLoop.perform { for l in links { l.close("power-off") } }
    }
}

#if DEBUG
// Test-only inspectors (DEBUG-only, so nothing ships in release). They read the private link maps so the
// dedup tests can assert which leg survived / that a linkId routes, driving the REAL onUp/onData/onClose
// with a fake DedupLink (no CBL2CAPChannel). They add NO behavior.
extension BleBearer {
    /// The current survivor count (one entry per peer).
    var debugPeerLinkCount: Int { mapLock.lock(); defer { mapLock.unlock() }; return linksByPeerId.count }
    /// The registered survivor Link for a peer (nil if none / deduped-out).
    func debugLink(forPeer peer: Data) -> DedupLink? { mapLock.lock(); defer { mapLock.unlock() }; return linksByPeerId[peer] }
    /// Whether a linkId is currently registered for send-routing / linkDown pairing.
    func debugHasLinkId(_ id: LinkId) -> Bool { mapLock.lock(); defer { mapLock.unlock() }; return linksByLinkId[id] != nil }
    /// The application-background bookkeeping flag (mirrors bleAppInBackground).
    var debugAppInBackground: Bool { appInBackground }
}
#endif
