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
import Hop   // the bearer contract (Bearer/LinkSink) + transport utils now live in the Hop SDK

let LAN_SERVICE_TYPE = "_hoplan._tcp"

private let LAN_PING_S: Double = 1.0
private let LAN_DEAD_S: Double = 15.0     // TCP is reliable; a generous liveness deadline
private let LAN_REAP_S: Double = 5.0      // close a connection that never completes HELLO
private let LAN_MAX_FRAME = 4 * 1024 * 1024

private let L_HELLO: UInt8 = 0x01
private let L_PING:  UInt8 = 0x02
private let L_PONG:  UInt8 = 0x03
private let L_DATA:  UInt8 = 0x10

// MARK: - LanLink: one TCP NWConnection, same framing/keepalive/HELLO grammar as the BLE link --------

final class LanLink {
    let linkId: LinkId
    let isDialer: Bool
    private let myId: Data
    private(set) var peerId: Data?
    private(set) var up = false

    private let conn: NWConnection
    private let queue: DispatchQueue
    private var inBuf = [UInt8]()       // [UInt8], NOT Data: Data's Int subscript is not 0-based after
                                        // removeFirst, which crashes deframe() (matches the BLE Link).
    private var lastRxMs = nowMs()
    private let openedMs = nowMs()
    private var txSeq: UInt64 = 0
    private var rxSeq: UInt64 = 0
    private var ping: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
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
            case .failed(let e): self.close("nwconn failed \(e)")
            case .cancelled:   self.close("nwconn cancelled")
            default: break
            }
        }
        selfRetain = self          // own our lifecycle until close() (see selfRetain decl)
        conn.start(queue: queue)
    }

    private func onReady() {
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
                self.inBuf.append(contentsOf: data)
                self.lastRxMs = nowMs()
                self.deframe()
            }
            if let error { self.close("recv \(error)"); return }
            if isComplete { self.close("recv EOF"); return }
            if !self.closed { self.receiveLoop() }
        }
    }

    private func deframe() {
        while inBuf.count >= 4 {
            let len = Int(inBuf[0]) << 24 | Int(inBuf[1]) << 16 | Int(inBuf[2]) << 8 | Int(inBuf[3])
            guard len >= 1, len <= LAN_MAX_FRAME else { close("bad len \(len)"); return }
            let total = 4 + len
            guard inBuf.count >= total else { break }
            handle(Array(inBuf[4..<total]))
            inBuf.removeFirst(total)
        }
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
        ping?.cancel(); watchdog?.cancel()
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

    public init(myId: Data) { self.myId = myId }

    public func start() {
        log("STATE", "lan node-start myId=\(hex(myId)) service=\(LAN_SERVICE_TYPE)")
        lanQueue.async { [weak self] in self?.startListener(); self?.startBrowser() }
    }

    public func stop() {
        lanQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            for l in self.linksByPeerId.values { l.close("stop") }
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
            l.stateUpdateHandler = { state in if case .failed(let e) = state { log("STATE", "lan listener failed \(e)") } }
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
                if peerId == self.myId { continue }                          // our own advertised service
                if self.linksByPeerId[peerId] != nil { continue }            // already linked
                if !nodeIdGreater(self.myId, peerId) { continue }            // tiebreaker: greater dials
                if !self.dialing.insert(hex(peerId)).inserted { continue }   // already dialing this peer
                log("STATE", "lan discovered peer=\(shortHex(peerId)) -> DIAL")
                self.dial(r.endpoint, peerId)
            }
        }
        b.stateUpdateHandler = { state in if case .failed(let e) = state { log("STATE", "lan browser failed \(e)") } }
        b.start(queue: lanQueue)
        browser = b
    }

    private func dial(_ endpoint: NWEndpoint, _ peerId: Data) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let link = LanLink(conn: conn, linkId: mint(), isDialer: true, myId: myId, queue: lanQueue,
                           onUp: { [weak self] in self?.onUp($0) },
                           onData: { [weak self] in self?.onData($0, $1) },
                           onClose: { [weak self] l in self?.dialing.remove(hex(peerId)); self?.onClose(l) })
        link.start()
    }

    // MARK: link lifecycle (all on lanQueue)

    private func onUp(_ link: LanLink) {
        guard let peer = link.peerId else { return }
        linksByLinkId[link.linkId] = link
        sink?.linkUp(link.linkId, role: link.isDialer ? .dialer : .acceptor, peerId: peer)  // surface, then dedup
        if let existing = linksByPeerId[peer], existing !== link {
            let keepDialed = nodeIdGreater(myId, peer)
            let keep = [existing, link].first { $0.isDialer == keepDialed } ?? link
            let drop = (keep === link) ? existing : link
            linksByPeerId[peer] = keep
            drop.close("dedup")
            log("DEDUP", "lan kept isDialer=\(keep.isDialer) peer=\(shortHex(peer))")
        } else {
            linksByPeerId[peer] = link
        }
    }

    private func onData(_ link: LanLink, _ bytes: Data) { sink?.linkBytes(link.linkId, bytes) }

    private func onClose(_ link: LanLink) {
        let wasUp = linksByLinkId.removeValue(forKey: link.linkId) != nil
        if let peer = link.peerId, linksByPeerId[peer] === link { linksByPeerId.removeValue(forKey: peer) }
        if wasUp { sink?.linkDown(link.linkId) }
    }
}

/// The Bonjour instance name is the peer's 32-hex-char nodeId. Parse it back to 16 bytes.
private func peerIdFromName(_ name: String) -> Data? {
    guard name.count == 32 else { return nil }
    var d = Data(capacity: 16); var i = name.startIndex
    while i < name.endIndex {
        let j = name.index(i, offsetBy: 2)
        guard let byte = UInt8(name[i..<j], radix: 16) else { return nil }
        d.append(byte); i = j
    }
    return d.count == 16 ? d : nil
}
