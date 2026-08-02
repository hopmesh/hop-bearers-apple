// CentralCore, the DIALER (central) decision state machine, lifted verbatim out of the CoreBluetooth
// `Central` delegate so the highest-value transport logic (dial gating, the SPEC §6 backoff schedule,
// the in-flight/retained set, the pending-wait fallback, the SPEC R2 backoff TTL) is PURE and unit-
// testable WITHOUT a radio. A `CBCentralManager` / `CBPeripheral` cannot be constructed in a unit test,
// so the old `Central` was 0% covered and only re-modeled in the test file; this core is the identical
// logic keyed on plain values (UUID / Data / UInt16), driven directly by tests.
//
// SHAPE: functional core, imperative shell. Each CB delegate method in `Central` (BleBearer+Radio.swift)
// translates its CoreBluetooth arguments into plain values, calls the matching CentralCore method, and
// EXECUTES the returned `[CentralEffect]` verbatim against CoreBluetooth. The core never names a CB type
// and performs no I/O; the shell performs I/O and owns nothing but the `CBPeripheral` handles + timers.
// Because the shell runs the effects in the exact order the original statements ran, the split is
// behavior-preserving: the only thing that moved is WHERE the decision is made, not WHAT it decides.
//
// Threading: the owning `Central` calls every method on `bleQueue` (the CB delegate queue), single-homed,
// so the core needs no locking (the same discipline the original `Central` relied on).

import Foundation
import HopContract   // log / hex

/// One CoreBluetooth action the shell must perform. The core returns these in execution order; the shell
/// resolves each `UUID` to its retained `CBPeripheral` and performs the call. Nothing here names a CB type
/// so the whole list is Equatable and asserted directly in tests.
enum CentralEffect: Equatable {
    case scan                        // scanForPeripherals(withServices: [SERVICE_UUID], allowDuplicates)
    case powerOff                    // SPEC R11: onPowerOff -> the bearer closes all links
    case connect(UUID)               // cm.connect(peer), no dial-timeout of its own (see armDialTimeout)
    case cancelConnection(UUID)      // cm.cancelPeripheralConnection(peer)
    case discoverServices(UUID)      // peer.discoverServices(nil)
    case openL2CAP(UUID, psm: UInt16)// peer.openL2CAPChannel(psm)
    case armDialTimeout(UUID)        // schedule DIAL_TIMEOUT_S -> dialTimeoutFired(id)
    case cancelDialTimeout(UUID)     // clearDialTimer: cancel + drop the peer's dial-timeout work item
    case armWaitTimeout(UUID, advPrefix: Data?)   // schedule WAIT_BASE_S(+jitter) -> waitTimeoutFired(id, advPrefix)
}

/// The pure Central decision engine. Owns exactly the state the old `Central` owned that carries a
/// DECISION (retained/pendingWaits/advPrefixById/backoff); the `CBPeripheral` handles and the timer work
/// items stay in the shell. Every method returns the effects to run, in order.
final class CentralCore {
    private let myId: Data
    private let now: () -> Double
    private let jitter: () -> Double
    private let appInBackground: () -> Bool
    /// How many consecutive didOpen errors a device may cause before the connection is torn down
    /// instead of re-read again. A genuinely stale PSM clears on the first or second re-read, so this
    /// only ever bites a cause that re-reading cannot fix, which is what produced the observed spin.
    private let MAX_CONSECUTIVE_OPEN_FAILURES = 3

    private let haveLinkTo: (Data) -> Bool
    private let haveLinkToPrefix: (Data) -> Bool

    // The retained/in-flight peers (SPEC §3.2.3). Kept as bare UUIDs; the shell keeps the matching
    // `CBPeripheral` handles and reconciles its map to this set after every call, so the two never drift.
    private(set) var retained = Set<UUID>()
    private(set) var pendingWaits = Set<UUID>()          // SPEC R4: one outstanding wait per peer
    private(set) var advPrefixById = [UUID: Data]()      // backoff-key source (prefix once known)
    private(set) var backoff = [String: Double]()        // SPEC R2: key = 6B-prefix hex (stable), else identifier
    // CONSECUTIVE failed dials per backoff key. The schedule is a function of this count, NOT of the
    // time remaining on the previous deadline: a dial takes DIAL_TIMEOUT_S (12 s) to fail, which always
    // outlasts a sub-2 s window, so a delta-based schedule found its deadline already lapsed and reset
    // to the floor on every cycle. A peer that GATT-connects but never yields an L2CAP channel (a
    // rotated MAC, a non-Hop advertiser) then re-dialed every ~13 s forever, monopolizing a dial slot
    // and starving healthy peers. Android hit this and fixed it in DialBackoff.kt; Apple carried the
    // original delta-based schedule until now. Both sides are pinned by ble-backoff-vectors.json.
    private(set) var failCount = [String: Int]()

    init(myId: Data,
         now: @escaping () -> Double = { nowS() },
         jitter: @escaping () -> Double = { Double.random(in: 0...1) },
         appInBackground: @escaping () -> Bool = { bleAppInBackground },
         haveLinkTo: @escaping (Data) -> Bool,
         haveLinkToPrefix: @escaping (Data) -> Bool) {
        self.myId = myId
        self.now = now
        self.jitter = jitter
        self.appInBackground = appInBackground
        self.haveLinkTo = haveLinkTo
        self.haveLinkToPrefix = haveLinkToPrefix
    }

    // MARK: manager state (centralManagerDidUpdateState)

    /// poweredOff -> power-off (SPEC R11); poweredOn -> (re)start the service-filtered scan; else nothing.
    func stateChanged(isPoweredOn: Bool, isPoweredOff: Bool) -> [CentralEffect] {
        if isPoweredOff { return [.powerOff] }
        guard isPoweredOn else { return [] }
        return [.scan]
    }

    // MARK: discovery (centralManager didDiscover)

    /// The dial gate. Mirrors `didDiscover` exactly: backoff rate-limit, then already-linked, then already-
    /// dialing, then the apple-02(c)/apple-r2-02 dial-vs-defer decision. Dialing immediately returns the
    /// dial effects; deferring records the pending wait and asks the shell to arm the WAIT_BASE_S fallback.
    func discovered(_ id: UUID, advPrefix: Data?) -> [CentralEffect] {
        // Read the R2 window under the PROMOTED key when this advert carries no prefix. Apple
        // peripherals structurally cannot advertise manufacturer data, so `advPrefix` is permanently
        // nil for an Apple peer: the gate read `id.uuidString` while every failure was FILED under
        // the nodeId prefix promoted at PSM-read time, so the two keys never met and the rate limit
        // was inert for exactly the peers it most needed to throttle.
        let bkey = (advPrefix ?? advPrefixById[id]).map(hex) ?? id.uuidString
        if let until = backoff[bkey], now() < until { return [] }           // SPEC R2: rate-limited
        if let pre = advPrefix, haveLinkToPrefix(pre) { return [] }          // SPEC R4: already linked
        guard !retained.contains(id) else { return [] }                     // already dialing
        let tiebreak = advPrefix.map { gt(myId.prefix(6), $0) } ?? true
        let dialNow = shouldDialNow(appInBackground: appInBackground(),
                                    haveKnownPrefix: advPrefix != nil,
                                    tiebreakSaysDial: tiebreak)
        if dialNow {
            return dial(id, advPrefix)
        }
        if pendingWaits.insert(id).inserted {                               // SPEC R4: one wait per peer
            return [.armWaitTimeout(id, advPrefix: advPrefix)]
        }
        return []
    }

    /// SPEC R4/R6: the WAIT_BASE_S fallback fired. Dial only if no link formed meanwhile (the peer never
    /// dialed us AND we are not already dialing it), the liveness guarantee that makes deferral safe.
    func waitTimeoutFired(_ id: UUID, advPrefix: Data?) -> [CentralEffect] {
        pendingWaits.remove(id)
        let peerDialedUs = advPrefix.map { haveLinkToPrefix($0) } ?? false
        guard waitTimeoutDials(peerAlreadyDialedUs: peerDialedUs,
                               weAreAlreadyDialing: retained.contains(id)) else { return [] }
        return dial(id, advPrefix)
    }

    /// SPEC §3.2.2/3.2.3: begin a dial. Retain the peer, promote the backoff key, arm the dial timeout.
    private func dial(_ id: UUID, _ advPrefix: Data?) -> [CentralEffect] {
        retained.insert(id)
        // Only record a prefix we actually have. Assigning nil here used to CLOBBER the stable
        // nodeId prefix promoted by `readEndpointValue`, so the promotion survived only inside a
        // single post-read dial cycle and the backoff key reverted to the (rotatable) identifier.
        if let advPrefix { advPrefixById[id] = advPrefix }
        return [.connect(id), .armDialTimeout(id)]
    }

    // MARK: connect lifecycle

    /// didConnect -> discover services (SPEC: nil filter, not [SERVICE_UUID]).
    func connected(_ id: UUID) -> [CentralEffect] { [.discoverServices(id)] }

    /// SPEC R6: the 12 s dial-timeout fired. Abort the indefinite connect and reconnect (backoff), but
    /// only if the peer is still retained (a race can fire this after the link already came up).
    func dialTimeoutFired(_ id: UUID) -> [CentralEffect] {
        guard retained.contains(id) else { return [] }
        return [.cancelConnection(id)] + reconnect(id)
    }

    /// didFailToConnect / didDisconnect both reconnect (SPEC §6 backoff schedule).
    func disconnected(_ id: UUID) -> [CentralEffect] {
        openFailures[id] = nil          // the connection is gone; the next dial starts a fresh run
        // Only charge a failure for a dial that was actually in flight. Without this guard the
        // core's OWN cancels (the already-linked branch below, and dialerLinkClosed) came back as
        // didDisconnect and were billed as dial failures against a peer we had demonstrably just
        // reached, quarantining a one-metre-away peer for up to ~120s. Android treats reaching the
        // peer as a SUCCESS (`succeededForAddr`); this is the mirror-image asymmetry.
        guard retained.contains(id) else { return [] }
        return reconnect(id)
    }

    /// SPEC §6: release the peer, then set the next backoff deadline from the CONSECUTIVE failure count
    /// (2 s, 4 s, 8 s, 16 s, 30 s cap, then a ~2 min quarantine past BACKOFF_QUARANTINE_AFTER), plus
    /// jitter, and evict expired backoff keys (SPEC R2 TTL). Shares the schedule with Android's
    /// `nextBackoffMs`; both are pinned by `bearers/ble-backoff-vectors.json`.
    private func reconnect(_ id: UUID) -> [CentralEffect] {
        retained.remove(id)
        let key = advPrefixById[id].map(hex) ?? id.uuidString
        let n = (failCount[key] ?? 0) + 1
        failCount[key] = n
        backoff[key] = now() + bleNextBackoffS(failCount: n, jitter: jitter())
        evictBackoff()
        return [.cancelDialTimeout(id)]   // clearDialTimer(p)
    }

    /// SPEC R2: keep the backoff table bounded, drop keys whose deadline is older than LOST_S ago.
    private func evictBackoff() {
        let cut = now() - LOST_S
        backoff = backoff.filter { $0.value > cut }
        // Drop the paired counter too. Leaving it would keep a long-gone peer permanently
        // quarantined the instant it reappears, and would leak an unbounded map.
        failCount = failCount.filter { backoff[$0.key] != nil }
    }

    // MARK: PSM read + channel open (didUpdateValueFor / didOpen)

    /// SPEC §3.2.2: the endpoint characteristic read back [2B PSM][16B nodeId]. If already linked to that
    /// nodeId, cancel this redundant dial (SPEC R4); otherwise promote the stable nodeId prefix and open
    /// the L2CAP channel. `psm`/`peerId` are parsed by the shell from the CBCharacteristic value.
    func readEndpointValue(_ id: UUID, psm: UInt16, peerId: Data) -> [CentralEffect] {
        if haveLinkTo(peerId) {                                             // SPEC R4: already linked
            // Reaching a peer we are already linked to PROVES it is healthy, so promote its stable
            // key and clear its failure state before cancelling, exactly as Android does
            // (`succeededForAddr` on the already-linked branch). Previously this redundant dial was
            // billed as a failure by the follow-on didDisconnect, so a peer one metre away could be
            // quarantined for ~120s purely for being reachable.
            advPrefixById[id] = peerId.prefix(6)
            let key = hex(peerId.prefix(6))
            backoff[key] = nil
            failCount[key] = nil
            retained.remove(id)
            return [.cancelDialTimeout(id), .cancelConnection(id)]
        }
        advPrefixById[id] = peerId.prefix(6)                               // SPEC R2: stable nodeId prefix
        return [.openL2CAP(id, psm: psm)]
    }

    /// didOpen success: the L2CAP channel is open. Clears the dial timeout ONLY; success is declared
    /// later, at HELLO-complete, by `dialerLinkUp`. The Link itself is constructed by the shell (it
    /// owns the CBL2CAPChannel); nothing here touches `retained` because the peer stays retained for
    /// the life of the link.
    func channelOpened(_ id: UUID) -> [CentralEffect] {
        openFailures[id] = nil          // a channel opened, so any consecutive-failure run is over
        // android-05/06 parity: the socket is connected but the link is NOT yet up (no HELLO).
        // Cancel the dial timeout (this dial did reach L2CAP), but do NOT declare success here.
        // Clearing the failure state on L2CAP-open pinned `failCount` at 1 forever for any peer
        // that accepts a channel and never completes HELLO (the documented iOS ~30s L2CAP teardown,
        // a wedged stack, a half-dead peer): each cycle cleared the count, the 3s no-HELLO reaper
        // closed the link, and reconnect() recomputed from zero. The 4/8/16/30s growth and the
        // 120s quarantine added in #323 were therefore UNREACHABLE for exactly the peer they exist
        // to park. Android moved this reset to HELLO-complete for this reason; Apple never did.
        return [.cancelDialTimeout(id)]
    }

    /// HELLO completed on a link we dialed: NOW the peer is proven healthy, so clear its failure
    /// state. Mirrors Android's `dialerLinkUp` -> `DialState.succeededForAddr`.
    func dialerLinkUp(_ id: UUID) -> [CentralEffect] {
        let key = advPrefixById[id].map(hex) ?? id.uuidString
        backoff[key] = nil
        failCount[key] = nil
        return []
    }

    /// didOpen error. SPEC §7.4 reads this as a stale PSM and re-reads by re-discovering services,
    /// which is right for a stale PSM and wrong for every other cause, because the re-read is issued
    /// immediately and without bound.
    ///
    /// Observed on a device: a cross-dial (both sides dialling at once) makes CoreBluetooth refuse the
    /// open with "L2CAP PSM already connected". That is not a stale PSM, it is OUR OWN channel, so the
    /// re-read produces the identical error and the peer spin-loops read psm, openL2CAP, error,
    /// re-read against a peer it is successfully talking to, burning radio and GATT operations with no
    /// exit. haveLinkTo cannot see it, because linksByPeerId is only populated once HELLO completes,
    /// and that window is exactly where the spin lives.
    ///
    /// Two bounds, because the two causes want different answers:
    ///   1. A link to this device's known nodeId prefix already exists, so the error IS that link.
    ///      Cancel rather than re-read; this dial was redundant.
    ///   2. Otherwise allow a bounded number of consecutive re-reads. A genuinely stale PSM clears on
    ///      the first or second, so past that the connection is torn down and the ordinary reconnect
    ///      and backoff path takes over instead of a hot loop.
    func channelOpenFailed(_ id: UUID) -> [CentralEffect] {
        if let pre = advPrefixById[id], haveLinkToPrefix(pre) {
            openFailures[id] = nil
            retained.remove(id)
            return [.cancelDialTimeout(id), .cancelConnection(id)]
        }
        let n = (openFailures[id] ?? 0) + 1
        openFailures[id] = n
        if n > MAX_CONSECUTIVE_OPEN_FAILURES {
            openFailures[id] = nil
            retained.remove(id)
            return [.cancelDialTimeout(id), .cancelConnection(id)]
        }
        return [.discoverServices(id)]
    }

    /// Consecutive didOpen errors per device, cleared by a successful open, a disconnect or a stop.
    private var openFailures = [UUID: Int]()

    /// The dialer's own link closed (chained ahead of the bearer's onClose). Reset backoff if the link
    /// was long-lived (SPEC §6), and cancel the connection so didDisconnect -> reconnect re-arms the dial.
    /// Does NOT release `retained` (the following didDisconnect's reconnect does).
    func dialerLinkClosed(_ id: UUID, stableUp: Bool) -> [CentralEffect] {
        if stableUp {
            let key = advPrefixById[id].map(hex) ?? id.uuidString
            backoff[key] = nil
            failCount[key] = nil      // a link that stayed up >= STABLE_UP_MS proves the peer is real
        }
        return retained.contains(id) ? [.cancelConnection(id)] : []
    }

    // MARK: background wake / state restoration

    /// Background-wake scan re-arm (idempotent): rescan only if not already scanning.
    func wakeRearmScan(isScanning: Bool) -> [CentralEffect] { isScanning ? [] : [.scan] }

    /// Wake re-adoption: pin a no-timeout dial to a still-connected peer we are not already handling, so a
    /// link can complete via state restoration even after the scan window closes. Keeps the known prefix.
    func adopt(_ id: UUID) -> [CentralEffect] {
        guard !retained.contains(id) else { return [] }
        return dial(id, advPrefixById[id])
    }

    /// SPEC §3.2.3 willRestoreState: re-retain the peer, then resume the handshake (discover services) if
    /// it is still connected, else re-arm a no-timeout pending connect. No dial timeout is armed here.
    func restore(_ id: UUID, isConnected: Bool) -> [CentralEffect] {
        retained.insert(id)
        return isConnected ? [.discoverServices(id)] : [.connect(id)]
    }

    // MARK: stop

    /// stop(): drop the in-flight sets. The shell cancels the actual connections + dial-timeout work items.
    /// Backoff/advPrefix are intentionally NOT cleared (mirrors the original stop()).
    func stopReset() {
        retained.removeAll()
        pendingWaits.removeAll()
        openFailures.removeAll()
    }
}
