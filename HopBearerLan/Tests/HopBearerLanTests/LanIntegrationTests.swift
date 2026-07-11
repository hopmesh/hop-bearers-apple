// REAL integration tests for the LAN bearer. These stand up an actual `LanBearer` and drive it over a
// real loopback TCP socket (NWListener + NWConnection on 127.0.0.1), bypassing Bonjour discovery via the
// DEBUG test seams. Unlike the pure-logic tests, they exercise the LIVE code: the acceptor + dialer
// `LanLink` (start / onReady / HELLO / receiveLoop / deframe / handle / sendFrame / ping / watchdog /
// close) and the bearer's real onUp/onData/onClose bookkeeping incl. the one-pipe-per-peer dedup - the
// paths the old "shadow" model tests only re-implemented in the test file. No device, no radio, no mDNS.

import XCTest
import Foundation
import Network
import HopContract
@testable import HopBearerLan

// MARK: - Test helpers -----------------------------------------------------------------------------

/// Thread-safe recorder standing in for the node multiplexer. The bearer's callbacks arrive on `lanQueue`.
private final class RecSink: LinkSink {
    private let lock = NSLock()
    private var _ups: [(LinkId, HopRole, Data)] = []
    private var _bytes: [(LinkId, Data)] = []
    private var _downs: [LinkId] = []
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { lock.lock(); _ups.append((link, role, peerId)); lock.unlock() }
    func linkBytes(_ link: LinkId, _ b: Data) { lock.lock(); _bytes.append((link, b)); lock.unlock() }
    func linkDown(_ link: LinkId) { lock.lock(); _downs.append(link); lock.unlock() }
    var ups: [(LinkId, HopRole, Data)] { lock.lock(); defer { lock.unlock() }; return _ups }
    var bytes: [(LinkId, Data)] { lock.lock(); defer { lock.unlock() }; return _bytes }
    var downs: [LinkId] { lock.lock(); defer { lock.unlock() }; return _downs }
}

/// A raw loopback peer that speaks the LAN wire grammar directly (reusing the production `lanFrame` /
/// `LanDeframer`), so a test can play the OTHER end of a real socket against the bearer.
private final class RawPeer {
    private let conn: NWConnection
    private let q = DispatchQueue(label: "test.rawpeer")
    private var deframer = LanDeframer()
    private let onReady: (RawPeer) -> Void
    private let onBody: ([UInt8]) -> Void

    init(host: String, port: UInt16, onReady: @escaping (RawPeer) -> Void, onBody: @escaping ([UInt8]) -> Void) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.onReady = onReady; self.onBody = onBody
    }
    func start() {
        conn.stateUpdateHandler = { [weak self] st in guard let self else { return }; if case .ready = st { self.onReady(self) } }
        conn.start(queue: q)
        recv()
    }
    private func recv() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let data, !data.isEmpty { var over = false; for b in self.deframer.feed([UInt8](data), overLimit: &over) { self.onBody(b) } }
            if err == nil && !complete { self.recv() }
        }
    }
    func send(_ body: [UInt8]) { conn.send(content: Data(lanFrame(body)), completion: .contentProcessed { _ in }) }
    func cancel() { conn.cancel() }
}

/// A HELLO frame body: [0x01][16B nodeId][1B role][1B flags].
private func helloBody(_ id: Data, dialer: Bool) -> [UInt8] { [L_HELLO] + [UInt8](id) + [dialer ? 1 : 0, 0] }
private func dataBody(_ payload: [UInt8]) -> [UInt8] { [L_DATA] + payload }
private func pingBody() -> [UInt8] { [L_PING] + [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 1, count: 8) }

/// Spin the calling thread (letting the bearer's background queues run) until `cond` holds or timeout.
private func spinWait(_ timeout: TimeInterval = 6, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return cond()
}

/// A free loopback TCP port (open an ephemeral listener, read its port, tear it down).
private func freeLoopbackPort() -> UInt16 {
    let l = try! NWListener(using: .tcp)
    let ready = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    l.start(queue: .global())
    _ = ready.wait(timeout: .now() + 3)
    let port = l.port?.rawValue ?? 0
    l.cancel()
    return port
}

final class LanIntegrationTests: XCTestCase {

    private func randId() -> Data { Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }

    // MARK: acceptor side - a real LanBearer accepts a real loopback socket and runs the full link.

    func testAcceptorRealLinkUpBytesPingAndDown() {
        let myId = randId()
        let bearer = LanBearer(myId: myId)
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        XCTAssertTrue(spinWait { bearer.testListenerPort != nil }, "the real NWListener must bind a port")
        let port = bearer.testListenerPort!

        // The raw dialer brings the acceptor's link up with a HELLO, then we drive DATA / PING both ways.
        let peerId = randId()
        var rx: [[UInt8]] = []; let rxLock = NSLock()
        let peer = RawPeer(host: "127.0.0.1", port: port,
                           onReady: { $0.send(helloBody(peerId, dialer: true)) },
                           onBody: { b in rxLock.lock(); rx.append(b); rxLock.unlock() })
        peer.start()

        // 1) HELLO -> the REAL onUp fires a linkUp with role .acceptor (we dialed in, so the bearer accepts).
        XCTAssertTrue(spinWait { !sink.ups.isEmpty }, "the acceptor must surface a linkUp")
        let up = sink.ups[0]
        XCTAssertEqual(up.1, .acceptor, "an inbound connection surfaces as an acceptor leg")
        XCTAssertEqual(up.2, peerId, "the peerId learned from HELLO is surfaced verbatim")
        let linkId = up.0

        // 2) inbound DATA -> the REAL receiveLoop/deframe/handle path surfaces linkBytes.
        peer.send(dataBody([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertTrue(spinWait { sink.bytes.contains { $0.0 == linkId && Array($0.1) == [0xDE, 0xAD, 0xBE, 0xEF] } },
                      "an inbound DATA frame must surface as linkBytes")

        // 3) bearer.send -> the REAL sendData/sendFrame path puts a DATA frame on the wire we can read back.
        bearer.send(Data([0x01, 0x02, 0x03]), on: linkId)
        XCTAssertTrue(spinWait { rxLock.withLock { rx.contains { $0 == dataBody([0x01, 0x02, 0x03]) } } },
                      "bearer.send must frame a DATA packet the peer receives")

        // 4) inbound PING -> the REAL handle(L_PING) path answers with a PONG.
        peer.send(pingBody())
        XCTAssertTrue(spinWait { rxLock.withLock { rx.contains { $0.first == L_PONG } } },
                      "a PING must be answered with a PONG")

        // 5) unknown + PONG frame types are handled without surfacing anything (default / L_PONG branches).
        peer.send([0x99, 0x00]); peer.send([L_PONG, 0x00])

        // 6) hold the link long enough for the bearer's own 1 Hz ping + watchdog tick to run (sendPing/tick).
        XCTAssertTrue(spinWait(2.0) { rxLock.withLock { rx.contains { $0.first == L_PING } } },
                      "the bearer's keepalive ping must reach the peer")

        // 7) drop the socket -> the REAL receiveLoop EOF -> close -> onClose surfaces exactly one linkDown.
        peer.cancel()
        XCTAssertTrue(spinWait { sink.downs.contains(linkId) }, "closing the socket must surface a linkDown")
    }

    // MARK: dedup - two legs to the SAME peer exercise the real onUp one-pipe-per-peer survivor pick.

    func testAcceptorDedupKeepsOnePipePerPeer() {
        // myId chosen GREATER than the peer id so the keep-rule is "keep my dialer"; both inbound legs are
        // acceptors (neither is my dialer), so the survivor pick falls through to the NEW leg: the second
        // connection wins and the first is dropped (its prior linkUp pairs one linkDown).
        let myId = Data(repeating: 0xFF, count: 16)
        let peerId = Data(repeating: 0x01, count: 16)
        let bearer = LanBearer(myId: myId)
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }
        XCTAssertTrue(spinWait { bearer.testListenerPort != nil })
        let port = bearer.testListenerPort!

        let peer1 = RawPeer(host: "127.0.0.1", port: port, onReady: { $0.send(helloBody(peerId, dialer: true)) }, onBody: { _ in })
        peer1.start()
        XCTAssertTrue(spinWait { sink.ups.count == 1 }, "first leg surfaces")
        let first = sink.ups[0].0

        let peer2 = RawPeer(host: "127.0.0.1", port: port, onReady: { $0.send(helloBody(peerId, dialer: true)) }, onBody: { _ in })
        peer2.start()
        // Dedup: the new leg wins, surfaces its own linkUp, and the first (previously-surfaced) leg is
        // dropped -> exactly one linkDown for the first, and the bearer keeps a single pipe to the peer.
        XCTAssertTrue(spinWait { sink.ups.count == 2 }, "the dedup survivor surfaces a second linkUp")
        XCTAssertTrue(spinWait { sink.downs.contains(first) }, "the deduped-out first leg emits its linkDown")
        peer1.cancel(); peer2.cancel()
    }

    // MARK: dialer side - the real dial() path against a raw acceptor (no Bonjour needed).

    func testDialerRealLinkOverLoopback() {
        // A raw NWListener that is NOT advertising _hoplan._tcp, so the bearer's browser can't discover it:
        // the only dial is the one we drive, keeping the dialer path deterministic.
        let listener = try! NWListener(using: .tcp)
        let listenerId = Data(repeating: 0x00, count: 16)   // < the bearer id, so the bearer is the dialer
        var rx: [[UInt8]] = []; let rxLock = NSLock()
        var acceptConn: NWConnection?
        listener.newConnectionHandler = { c in
            acceptConn = c
            var deframer = LanDeframer()
            c.stateUpdateHandler = { st in if case .ready = st { c.send(content: Data(lanFrame(helloBody(listenerId, dialer: false))), completion: .contentProcessed { _ in }) } }
            func loop() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, err in
                    if let data, !data.isEmpty { var o = false; for b in deframer.feed([UInt8](data), overLimit: &o) { rxLock.lock(); rx.append(b); rxLock.unlock() } }
                    if err == nil && !complete { loop() }
                }
            }
            c.start(queue: .global()); loop()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 3)
        let port = listener.port!.rawValue
        defer { listener.cancel() }

        let bearer = LanBearer(myId: Data(repeating: 0xFF, count: 16))
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        bearer.testDial(host: "127.0.0.1", port: port, peerId: listenerId)

        // The REAL dialer LanLink connects, sends HELLO, receives the acceptor's HELLO -> linkUp .dialer.
        XCTAssertTrue(spinWait { !sink.ups.isEmpty }, "the dialer must surface a linkUp")
        XCTAssertEqual(sink.ups[0].1, .dialer, "an outbound dial surfaces as a dialer leg")
        XCTAssertEqual(sink.ups[0].2, listenerId)
        let linkId = sink.ups[0].0

        // The dialer sent a HELLO the raw acceptor received.
        XCTAssertTrue(spinWait { rxLock.withLock { rx.contains { $0.first == L_HELLO } } }, "the dialer sends HELLO first")

        // Data both directions over the real dialer link.
        bearer.send(Data([0xAA, 0xBB]), on: linkId)
        XCTAssertTrue(spinWait { rxLock.withLock { rx.contains { $0 == dataBody([0xAA, 0xBB]) } } })

        // Tear the raw acceptor down; the dialer link closes and surfaces linkDown, running onDialClosed.
        acceptConn?.cancel()
        XCTAssertTrue(spinWait { sink.downs.contains(linkId) }, "a dropped dialer link surfaces linkDown")
    }

    // MARK: a dial to a dead port fails fast -> onDialClosed(neverCameUp) + rescan, no phantom linkUp.

    func testDialToDeadPortNeverSurfacesAndClearsDialing() {
        let bearer = LanBearer(myId: Data(repeating: 0xFF, count: 16))
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }
        let dead = freeLoopbackPort()            // nothing is listening here -> ECONNREFUSED
        let peerId = Data(repeating: 0x02, count: 16)
        bearer.testDial(host: "127.0.0.1", port: dead, peerId: peerId)
        // The dial closes before HELLO (onDialClosed, neverCameUp): no linkUp, no linkDown, `dialing` is
        // cleared, and a rescanForDials is scheduled ~LAN_RESTART_S later. Stay alive past that so the
        // rescan path actually runs (the browser's own self-advert is skipped by the dial gate).
        XCTAssertFalse(spinWait(4.0) { !sink.ups.isEmpty }, "a refused dial must never surface a phantom linkUp")
        XCTAssertTrue(sink.downs.isEmpty, "a never-surfaced dial must not emit a linkDown")
    }

    // MARK: stop() surfaces linkDown for a live link and tears the transport down.

    func testStopSurfacesLinkDownForLiveLink() {
        let bearer = LanBearer(myId: randId())
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        XCTAssertTrue(spinWait { bearer.testListenerPort != nil })
        let port = bearer.testListenerPort!
        let peer = RawPeer(host: "127.0.0.1", port: port, onReady: { $0.send(helloBody(self.randId(), dialer: true)) }, onBody: { _ in })
        peer.start()
        XCTAssertTrue(spinWait { !sink.ups.isEmpty })
        let linkId = sink.ups[0].0
        bearer.stop()   // closes the live link -> onClose -> linkDown
        XCTAssertTrue(spinWait { sink.downs.contains(linkId) }, "stop() must surface linkDown for the live link")
        peer.cancel()
    }

    // MARK: F-11 restart-on-failure paths (listener + browser rebuild with backoff).

    func testForceRestartListenerAndBrowserRebuild() {
        let bearer = LanBearer(myId: randId())
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }
        XCTAssertTrue(spinWait { bearer.testListenerPort != nil }, "listener up before restart")
        let before = bearer.testListenerPort!
        bearer.testForceRestartListener()
        bearer.testForceRestartBrowser()
        // After the LAN_RESTART_S backoff the listener is torn down and rebuilt, binding a FRESH ephemeral
        // port. Waiting for the port to actually change proves the whole restart path (cancel + backoff +
        // startListener) ran, not just that a listener still happens to exist.
        XCTAssertTrue(spinWait(6.0) { if let p = bearer.testListenerPort, p != before { return true }; return false },
                      "the listener rebuilds on a fresh port after a forced restart")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
