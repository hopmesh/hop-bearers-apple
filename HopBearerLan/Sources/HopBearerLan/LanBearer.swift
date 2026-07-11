// LanBearer — the LAN transport as its OWN library (depends only on HopBearerCore). Two devices on the
// same Wi-Fi/LAN discover each other over Bonjour (`_hoplan._tcp`) and talk over TCP. It is fully
// self-contained: nothing here is shared with HopBearerBle (per "each bearer its own lib") — but it
// speaks the SAME link grammar as the BLE bearer so the consumer sees identical linkUp/linkBytes/
// linkDown semantics regardless of radio:
//
//   • 4-byte big-endian length prefix + a 1-byte frame type: HELLO 0x01, PING 0x02, PONG 0x03, DATA 0x10.
//   • HELLO carries the 16-byte nodeId so both ends learn the peer id (dedup + the consumer's key).
//   • 1 Hz PING keepalive feeds a liveness watchdog; PING/PONG never surface to the consumer.
//   • DATA (0x10) is the consumer seam: Bearer.send wraps bytes in a DATA frame; inbound DATA →
//     sink.linkBytes. One-pipe-per-peer dedup with the "greater nodeId dials" tiebreaker.
//
// Threading: one serial queue (`lanQueue`) owns the listener, browser, every NWConnection's callbacks,
// and all link/dedup state + timers — so it is single-threaded end to end and needs no locks (the same
// discipline the BLE bearer gets from its single run loop).

import Foundation
import Network
import HopContract   // the bearer contract (no libhop)

let LAN_SERVICE_TYPE = "_hoplan._tcp"

private let LAN_PING_S: Double = 1.0
private let LAN_DEAD_S: Double = 15.0     // TCP is reliable; a generous liveness deadline
private let LAN_REAP_S: Double = 5.0      // close a connection that never completes HELLO
private let LAN_CONNECT_S: Double = 8.0   // F-11: give up a dial that never reaches .ready
private let LAN_RESTART_S: Double = 2.0   // F-11: backoff before restarting a failed listener/browser
private let LAN_MAX_FRAME = 4 * 1024 * 1024

let L_HELLO: UInt8 = 0x01
let L_PING:  UInt8 = 0x02
let L_PONG:  UInt8 = 0x03
let L_DATA:  UInt8 = 0x10

// MARK: - Pure dedup decision (apple-12, extracted so it is unit-testable without an NWConnection) -----

/// The one-pipe-per-peer keep rule the LAN bearer's onUp is built on: on a duplicate pair to one peer,
/// keep MY dialed leg iff I am the greater id. Two peers make OPPOSITE decisions (the greater keeps its
/// dialer, the lesser keeps its acceptor), so exactly one physical connection survives. Identical to the
/// BLE bearer's `gt(myId, peer)` keep-rule; extracted here so the survivor selection is testable with no
/// radio (an NWConnection cannot be constructed in a unit test, so the Link/dial paths stay device-
/// tested; the DECISION that governs which leg wins is covered in the tests).
func lanKeepDialed(myId: Data, peer: Data) -> Bool { nodeIdGreater(myId, peer) }

/// Given a duplicate pair (the already-registered `existingIsDialer` and the just-arrived `newIsDialer`)
/// to `peer`, return true iff the NEW leg is the survivor. This IS onUp's survivor pick (onUp calls it):
/// keep the leg whose isDialer matches `lanKeepDialed`, falling back to the new leg if neither matches
/// (defensive; in practice a real duplicate always has one dialer + one acceptor). Pure (no link objects,
/// no I/O), so the unit test pins the exact production keep-rule, not a copy.
func lanNewLegSurvives(myId: Data, peer: Data, existingIsDialer: Bool, newIsDialer: Bool) -> Bool {
    let keepDialed = lanKeepDialed(myId: myId, peer: peer)
    // The survivor is the first of [existing, new] whose isDialer == keepDialed, else the new leg.
    if existingIsDialer == keepDialed { return false }   // existing is the survivor
    if newIsDialer == keepDialed { return true }         // new is the survivor
    return true                                          // neither matched -> new leg (defensive)
}

// MARK: - Pure deframer (extracted from LanLink so the wire format is unit-testable without a socket) --

/// Streaming deframer for the LAN wire format: a 4-byte big-endian length prefix followed by `len` body
/// bytes (body[0] is the 1-byte frame type). Feed it whatever arrived off the socket; it emits every
/// COMPLETE frame body and retains any partial tail for the next feed. `overLimit` flags a length that
/// exceeds LAN_MAX_FRAME or is < 1 (a `bad len` the link closes on), so the socket path can tear down.
///
/// This is the exact byte math LanLink.deframe() runs, lifted into a value type: no NWConnection, no
/// timers, no side effects, so partial frames / back-to-back frames / oversized-length rejection are all
/// unit-testable. LanLink holds one of these and forwards each emitted body to `handle`.
struct LanDeframer {
    private var inBuf = [UInt8]()

    /// Append `bytes`, then pop every complete frame body. Sets `overLimit` and stops if a length is out
    /// of range (the caller closes the link on that). Bodies are returned in arrival order.
    mutating func feed(_ bytes: [UInt8], overLimit: inout Bool) -> [[UInt8]] {
        overLimit = false
        inBuf.append(contentsOf: bytes)
        var out = [[UInt8]]()
        while inBuf.count >= 4 {
            let len = Int(inBuf[0]) << 24 | Int(inBuf[1]) << 16 | Int(inBuf[2]) << 8 | Int(inBuf[3])
            guard len >= 1, len <= LAN_MAX_FRAME else { overLimit = true; return out }
            let total = 4 + len
            guard inBuf.count >= total else { break }   // partial frame — wait for more bytes
            out.append(Array(inBuf[4..<total]))
            inBuf.removeFirst(total)
        }
        return out
    }

    var bufferedCount: Int { inBuf.count }
}

/// The pure dial gate the LAN browser and the rescan-for-dials path SHARE (extracted so it is unit-
/// testable without a live NWBrowser, and so the two call sites can't drift): from a discovered peer,
/// dial iff it is NOT us, we are NOT already linked to it, and we are the greater id (the SPEC §2.1
/// "greater dials" tiebreaker, so exactly one side initiates). The caller still layers its stateful
/// `dialing`-set dedup (one in-flight dial per peer) on top of this decision.
func lanShouldDial(myId: Data, peerId: Data, alreadyLinked: Bool) -> Bool {
    if peerId == myId { return false }        // our own advertised service
    if alreadyLinked { return false }         // already have a link to this peer
    return nodeIdGreater(myId, peerId)        // tiebreaker: the greater id dials
}

/// Build a 4-byte big-endian length-prefixed frame around `body`. The inverse of LanDeframer; shared so a
/// test can round-trip frame -> deframe without reaching into LanLink's socket send.
func lanFrame(_ body: [UInt8]) -> [UInt8] {
    let len = UInt32(body.count)
    return [UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff)] + body
}

// MARK: - LanLink: one TCP NWConnection, same framing/keepalive/HELLO grammar as the BLE link --------

final class LanLink {
    let linkId: LinkId
    let isDialer: Bool
    private let myId: Data
    private(set) var peerId: Data?
    private(set) var up = false
    // apple-12: set true by the bearer iff this exact leg was announced to the sink via linkUp. A
    // deduped loser is closed without ever being surfaced, so its onClose must NOT emit a linkDown.
    // Touched only from bearer code on `lanQueue` (single-threaded), so no extra synchronization here.
    var wasSurfaced = false

    private let conn: NWConnection
    private let queue: DispatchQueue
    private var deframer = LanDeframer()   // the pure length-prefix parser (unit-tested separately). It
                                           // buffers [UInt8], NOT Data: Data's Int subscript is not
                                           // 0-based after removeFirst (matches the BLE Link).
    private var lastRxMs = nowMs()
    private let openedMs = nowMs()
    private var txSeq: UInt64 = 0
    private var rxSeq: UInt64 = 0
    private var ping: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var connectDeadline: DispatchSourceTimer?   // F-11: armed at start(), fires if never .ready
    private var closed = false
    // Own ourselves from start() until close(): nothing else holds a strong ref until onUp inserts us
    // into the bearer's maps, and the NWConnection handlers capture us weakly — so without this the
    // link would dealloc the instant dial()/newConnectionHandler returns, before reaching .ready.
    private var selfRetain: LanLink?

    private let onUp: (LanLink) -> Void
    private let onData: (LanLink, Data) -> Void
    private let onClose: (LanLink) -> Void

    var peerShort: String { shortHex(peerId) }

    init(conn: NWConnection, linkId: LinkId, isDialer: Bool, myId: Data, queue: DispatchQueue,
         onUp: @escaping (LanLink) -> Void, onData: @escaping (LanLink, Data) -> Void,
         onClose: @escaping (LanLink) -> Void) {
        self.conn = conn; self.linkId = linkId; self.isDialer = isDialer; self.myId = myId
        self.queue = queue; self.onUp = onUp; self.onData = onData; self.onClose = onClose
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:       self.onReady()
            case .waiting(let e): log("STATE", "lan waiting \(e)")  // deadline (below) cancels a wedged dial
            case .failed(let e): self.close("nwconn failed \(e)")
            case .cancelled:   self.close("nwconn cancelled")
            default: break
            }
        }
        selfRetain = self          // own our lifecycle until close() (see selfRetain decl)
        // F-11: arm the connect deadline from start(), NOT onReady(). A dial stuck in .waiting
        // (ECONNREFUSED / unreachable / a stale Bonjour record for a restarted peer) never reaches
        // .ready, so the onReady-armed reaper never runs — the link would self-retain forever and
        // pin the peer in the bearer's `dialing` set, permanently blacklisting it for the process.
        let d = DispatchSource.makeTimerSource(queue: queue)
        d.schedule(deadline: .now() + LAN_CONNECT_S)
        d.setEventHandler { [weak self] in
            guard let self, !self.up else { return }
            self.close("connect timeout")
        }
        connectDeadline = d; d.resume()
        conn.start(queue: queue)
    }

    private func onReady() {
        connectDeadline?.cancel(); connectDeadline = nil   // reached .ready; the liveness watchdog takes over
        log("STATE", "lan channel-ready isDialer=\(isDialer)")
        // HELLO first: [0x01][16B nodeId][1B role][1B flags]
        var hello = Data([L_HELLO]); hello.append(myId); hello.append(isDialer ? 1 : 0); hello.append(0)
        sendFrame(hello)
        receiveLoop()
        let p = DispatchSource.makeTimerSource(queue: queue)
        p.schedule(deadline: .now() + LAN_PING_S, repeating: LAN_PING_S)
        p.setEventHandler { [weak self] in self?.sendPing() }
        let w = DispatchSource.makeTimerSource(queue: queue)
        w.schedule(deadline: .now() + 1.0, repeating: 1.0)
        w.setEventHandler { [weak self] in self?.tick() }
        ping = p; watchdog = w; p.resume(); w.resume()
    }

    private func tick() {
        if !up && Double(nowMs() - openedMs) / 1000 > LAN_REAP_S { close("no-HELLO reap"); return }
        if up && Double(nowMs() - lastRxMs) / 1000 > LAN_DEAD_S { close("liveness DEAD") }
    }

    private func sendPing() {
        guard !closed else { return }
        txSeq += 1
        var b = Data([L_PING]); appU64(&b, txSeq); appU64(&b, nowMs())
        sendFrame(b)
    }

    func sendData(_ bytes: Data) {
        guard !closed else { return }
        var body = Data([L_DATA]); body.append(bytes); sendFrame(body)
    }

    private func sendFrame(_ body: Data) {
        guard !closed else { return }
        var len = UInt32(body.count).bigEndian
        var frame = Data(); withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }; frame.append(body)
        conn.send(content: frame, completion: .contentProcessed { [weak self] err in
            if let err { self?.close("send \(err)") }
        })
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastRxMs = nowMs()
                self.deframe([UInt8](data))
            }
            if let error { self.close("recv \(error)"); return }
            if isComplete { self.close("recv EOF"); return }
            if !self.closed { self.receiveLoop() }
        }
    }

    private func deframe(_ bytes: [UInt8]) {
        var overLimit = false
        let frames = deframer.feed(bytes, overLimit: &overLimit)
        for f in frames { handle(f) }
        if overLimit { close("bad len") }
    }

    private func handle(_ b: [UInt8]) {
        guard let type = b.first else { return }
        switch type {
        case L_HELLO:
            if b.count >= 17, !up {
                peerId = Data(b[1..<17]); up = true
                log("STATE", "lan hello-recv peer=\(peerShort)")
                onUp(self)
            }
        case L_PING:
            guard b.count >= 9 else { return }
            rxSeq = u64(b, 1)
            var pong = Data([L_PONG]); pong.append(contentsOf: b[1..<min(17, b.count)]); sendFrame(pong)
        case L_PONG: break
        case L_DATA: onData(self, Data(b.dropFirst()))
        default: break
        }
    }

    func close(_ why: String) {
        guard !closed else { return }
        closed = true
        ping?.cancel(); watchdog?.cancel(); connectDeadline?.cancel()
        conn.cancel()
        log("STATE", "lan link-down (\(why)) peer=\(peerShort) isDialer=\(isDialer)")
        onClose(self)
        selfRetain = nil           // release self — safe to dealloc now
    }

    private func appU64(_ d: inout Data, _ v: UInt64) { var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 { var v: UInt64 = 0; for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }; return v }
}

// MARK: - LanBearer: Bonjour listen + browse, one-pipe-per-peer dedup, monotonic LinkId ---------------

public final class LanBearer: Bearer {
    private let myId: Data
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). LAN (mDNS+TCP) links surface as "LAN".
    public let transportName = "LAN"

    private let lanQueue = DispatchQueue(label: "hop.lan")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var linksByPeerId = [Data: LanLink]()
    private var linksByLinkId = [LinkId: LanLink]()
    private var dialing = Set<String>()         // peerId-hex currently being dialed (pre-HELLO dedup)
    private var nextLinkId: LinkId = 1
    private var stopped = false                 // F-11: gate restart-after-failure once stopped
    private var listenerRestartPending = false
    private var browserRestartPending = false

    public init(myId: Data) { self.myId = myId }

    public func start() {
        log("STATE", "lan node-start myId=\(hex(myId)) service=\(LAN_SERVICE_TYPE)")
        lanQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.startListener()
            self.startBrowser()
        }
    }

    public func stop() {
        lanQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            for l in self.linksByPeerId.values { l.close("stop") }
        }
    }

    // F-11: a failed listener/browser used to only log — after a Wi-Fi transition or sleep/wake the
    // device would silently stop accepting/discovering on LAN until the app relaunched. Rebuild each
    // on failure with a short backoff (unless we've been stopped).
    private func restartListener() {
        guard !stopped, !listenerRestartPending else { return }
        listenerRestartPending = true
        listener?.cancel(); listener = nil
        lanQueue.asyncAfter(deadline: .now() + LAN_RESTART_S) { [weak self] in
            guard let self else { return }
            self.listenerRestartPending = false
            if !self.stopped { self.startListener() }
        }
    }

    private func restartBrowser() {
        guard !stopped, !browserRestartPending else { return }
        browserRestartPending = true
        browser?.cancel(); browser = nil
        lanQueue.asyncAfter(deadline: .now() + LAN_RESTART_S) { [weak self] in
            guard let self else { return }
            self.browserRestartPending = false
            if !self.stopped { self.startBrowser() }
        }
    }

    public func send(_ bytes: Data, on link: LinkId) {
        lanQueue.async { [weak self] in self?.linksByLinkId[link]?.sendData(bytes) }
    }

    private func mint() -> LinkId { let id = nextLinkId; nextLinkId += 1; return id }

    // The Bonjour instance name IS our nodeId (hex), so a browser learns the peer id without connecting.
    private func startListener() {
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: hex(myId), type: LAN_SERVICE_TYPE)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                log("STATE", "lan inbound-connection (acceptor)")
                let link = LanLink(conn: conn, linkId: self.mint(), isDialer: false, myId: self.myId, queue: self.lanQueue,
                                   onUp: { [weak self] in self?.onUp($0) },
                                   onData: { [weak self] in self?.onData($0, $1) },
                                   onClose: { [weak self] in self?.onClose($0) })
                link.start()
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state {
                    log("STATE", "lan listener failed \(e) — restarting")
                    self?.restartListener()
                }
            }
            l.start(queue: lanQueue)
            listener = l
            log("STATE", "lan listening name=\(shortHex(myId))")
        } catch { log("STATE", "lan listener init failed \(error)") }
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjour(type: LAN_SERVICE_TYPE, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                guard let peerId = peerIdFromName(name) else { continue }
                // Skip self / already-linked / not-our-turn (the shared pure gate); then the stateful
                // one-in-flight-dial-per-peer dedup.
                guard lanShouldDial(myId: self.myId, peerId: peerId,
                                    alreadyLinked: self.linksByPeerId[peerId] != nil) else { continue }
                if !self.dialing.insert(hex(peerId)).inserted { continue }   // already dialing this peer
                log("STATE", "lan discovered peer=\(shortHex(peerId)) -> DIAL")
                self.dial(r.endpoint, peerId)
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                log("STATE", "lan browser failed \(e) — restarting")
                self?.restartBrowser()
            }
        }
        b.start(queue: lanQueue)
        browser = b
    }

    private func dial(_ endpoint: NWEndpoint, _ peerId: Data) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let link = LanLink(conn: conn, linkId: mint(), isDialer: true, myId: myId, queue: lanQueue,
                           onUp: { [weak self] in self?.onUp($0) },
                           onData: { [weak self] in self?.onData($0, $1) },
                           onClose: { [weak self] l in self?.onDialClosed(l, peerId) })
        link.start()
    }

    // F-14: a dial that closes before ever coming up (connect timeout / refused) used to just drop
    // the peer from `dialing` and wait for mDNS to re-announce — which may not happen for a long time,
    // silently forfeiting the high-bandwidth LAN path (with Wi-Fi Direct gone, LAN is the only Wi-Fi
    // transport for Android↔Android). Re-scan the current browse results shortly after so a transient
    // failure retries instead of stranding the peer. The greater-id tiebreaker means only we will dial.
    private func onDialClosed(_ link: LanLink, _ peerId: Data) {
        dialing.remove(hex(peerId))
        let neverCameUp = link.peerId == nil || linksByPeerId[peerId] == nil
        onClose(link)
        if !stopped, neverCameUp, linksByPeerId[peerId] == nil {
            lanQueue.asyncAfter(deadline: .now() + LAN_RESTART_S) { [weak self] in
                self?.rescanForDials()
            }
        }
    }

    /// Re-walk the browser's current results and dial any known-but-unlinked peer we should dial.
    /// The BLE central re-dials on every advert sighting; LAN lacks that pressure, so we add it here.
    private func rescanForDials() {
        guard !stopped, let results = browser?.browseResults else { return }
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            guard let peerId = peerIdFromName(name) else { continue }
            guard lanShouldDial(myId: myId, peerId: peerId,
                                alreadyLinked: linksByPeerId[peerId] != nil) else { continue }
            if !dialing.insert(hex(peerId)).inserted { continue }
            log("STATE", "lan rescan re-dial peer=\(shortHex(peerId))")
            dial(r.endpoint, peerId)
        }
    }

    // MARK: link lifecycle (all on lanQueue)

    private func onUp(_ link: LanLink) {
        guard let peer = link.peerId else { return }
        // apple-12: dedup BEFORE surfacing (mirrors the BLE bearer). Surfacing both legs of a duplicate
        // pair and closing the loser afterwards hands the node a doomed handshake start + teardown per
        // simultaneous mutual dial. Now the loser never reaches sink.linkUp: only the survivor is
        // announced, and only the survivor carries wasSurfaced so only it can emit a linkDown later.
        linksByLinkId[link.linkId] = link           // register for send routing + linkDown pairing
        if let existing = linksByPeerId[peer], existing !== link {
            // Survivor pick via the pure, unit-tested keep-rule (this used to be re-inlined here, so the
            // extracted `lanNewLegSurvives` was tested but never actually run in production). `newSurvives`
            // == "the just-arrived leg wins": keep MY dialed leg iff I'm the greater id, so both ends agree.
            let newSurvives = lanNewLegSurvives(myId: myId, peer: peer,
                                                existingIsDialer: existing.isDialer, newIsDialer: link.isDialer)
            let keep = newSurvives ? link : existing
            let drop = newSurvives ? existing : link
            linksByPeerId[peer] = keep                      // set survivor BEFORE closing the dropped leg
            if newSurvives { link.wasSurfaced = true }      // only the survivor is announced (apple-12)
            drop.close("dedup")                             // loser was never surfaced -> no linkDown for it
            log("DEDUP", "lan kept isDialer=\(keep.isDialer) peer=\(shortHex(peer))")
            if newSurvives {                                // this leg is the survivor -> announce it now
                sink?.linkUp(link.linkId, role: link.isDialer ? .dialer : .acceptor, peerId: peer)
            }
            return
        }
        linksByPeerId[peer] = link                  // first (or same) link for this peer -> the survivor
        link.wasSurfaced = true
        sink?.linkUp(link.linkId, role: link.isDialer ? .dialer : .acceptor, peerId: peer)
    }

    private func onData(_ link: LanLink, _ bytes: Data) { sink?.linkBytes(link.linkId, bytes) }

    private func onClose(_ link: LanLink) {
        let wasUp = linksByLinkId.removeValue(forKey: link.linkId) != nil        // true iff registered in onUp
        if let peer = link.peerId, linksByPeerId[peer] === link { linksByPeerId.removeValue(forKey: peer) }
        // apple-12: a deduped loser never reached sink.linkUp, so it must not emit a linkDown either.
        // `link.wasSurfaced` records whether onUp announced this exact leg to the sink, so every linkDown
        // pairs with a prior linkUp (mirrors the BLE bearer).
        if wasUp && link.wasSurfaced { sink?.linkDown(link.linkId) }
    }
}

#if DEBUG
// Test-only seams (DEBUG-only, so nothing ships in release). They live in this file because they touch
// `private` members (the listener, lanQueue, the real dial()/restart paths). They add NO new behavior:
// each just calls the real production path a device/Bonjour would otherwise trigger, so the integration
// tests can drive linkUp/linkBytes/linkDown, the real dialer, and the restart backoff over loopback with
// no radio and no mDNS.
extension LanBearer {
    /// The ephemeral port the listener bound to (nil until the NWListener reaches `.ready`). Lets a test
    /// open a raw loopback NWConnection straight to the real acceptor, bypassing Bonjour discovery.
    var testListenerPort: UInt16? { listener?.port?.rawValue }

    /// Drive the REAL dialer path to a specific host:port, exactly as the browser callback does for a
    /// discovered peer (self-check + one-in-flight dedup + dial()), but without needing an mDNS sighting.
    func testDial(host: String, port: UInt16, peerId: Data) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
        lanQueue.async { [weak self] in
            guard let self else { return }
            guard lanShouldDial(myId: self.myId, peerId: peerId,
                                alreadyLinked: self.linksByPeerId[peerId] != nil) else { return }
            if !self.dialing.insert(hex(peerId)).inserted { return }
            self.dial(ep, peerId)
        }
    }

    /// Force the listener/browser rebuild-on-failure paths (F-11) that a Wi-Fi transition would otherwise
    /// trigger, so the restart backoff is exercised without provoking a real transport failure.
    func testForceRestartListener() { lanQueue.async { [weak self] in self?.restartListener() } }
    func testForceRestartBrowser()  { lanQueue.async { [weak self] in self?.restartBrowser() } }
}
#endif

/// The Bonjour instance name is the peer's 32-hex-char nodeId. Parse it back to 16 bytes. Internal
/// (not private) so the pure-logic tests can exercise the hex round-trip without a live browser.
func peerIdFromName(_ name: String) -> Data? {
    guard name.count == 32 else { return nil }
    var d = Data(capacity: 16); var i = name.startIndex
    while i < name.endIndex {
        let j = name.index(i, offsetBy: 2)
        guard let byte = UInt8(name[i..<j], radix: 16) else { return nil }
        d.append(byte); i = j
    }
    return d.count == 16 ? d : nil
}
