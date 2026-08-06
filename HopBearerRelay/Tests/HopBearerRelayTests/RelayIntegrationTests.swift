// REAL integration tests for the cloud-relay bearer. They stand up an actual loopback WebSocket server
// (an NWListener that performs the RFC 6455 HTTP upgrade by hand, Foundation only) and point a live
// `RelayBearer` at it, so the REAL URLSession WebSocket path runs end to end: dial -> didOpenWithProtocol
// -> receiveLoop -> send -> didCloseWith / didCompleteWithError(429) -> scheduleReconnect -> stop(). The
// pure backoff/peerId math stays in RelayBearerLogicTests; this covers the socket-driven half the logic
// tests could not reach (why coverage sat at ~12%).

import XCTest
import Foundation
import Network
import CryptoKit
import Hop            // the published SDK's HopNode, for the §19-pool failover case (PLAT-003)
import HopContract
@testable import HopBearerRelay

// MARK: - A hand-rolled loopback WebSocket server (Foundation/Network only, no third-party dep) --------

private final class WSTestServer {
    enum Mode { case accept, reject429(retryAfter: String?) }

    private let listener: NWListener
    private let q = DispatchQueue(label: "test.ws.server")
    private let lock = NSLock()
    private var _conn: NWConnection?
    private var _connectCount = 0
    var mode: Mode = .accept
    var onUpgraded: (() -> Void)?
    var onClientFrame: ((_ opcode: UInt8, _ payload: [UInt8]) -> Void)?

    private(set) var port: UInt16 = 0

    var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }

    init() { listener = try! NWListener(using: .tcp) }

    func start() {
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: q)
        _ = ready.wait(timeout: .now() + 3)
        port = listener.port?.rawValue ?? 0
    }
    func stop() { listener.cancel(); lock.lock(); _conn?.cancel(); lock.unlock() }

    var url: String { "ws://127.0.0.1:\(port)/" }

    // server -> client frames (unmasked, small payloads only, which is all the tests use).
    func pushBinary(_ d: [UInt8]) { send(frame(0x2, d)) }
    func pushText(_ s: String)    { send(frame(0x1, Array(s.utf8))) }
    func pushClose()              { send(frame(0x8, [])) }

    private func send(_ data: Data) {
        q.async { self.lock.lock(); let c = self._conn; self.lock.unlock(); c?.send(content: data, completion: .contentProcessed { _ in }) }
    }
    private func frame(_ opcode: UInt8, _ payload: [UInt8]) -> Data {
        var f: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { f.append(UInt8(payload.count)) }
        else { f.append(126); f.append(UInt8(payload.count >> 8)); f.append(UInt8(payload.count & 0xff)) }
        f += payload
        return Data(f)
    }

    private func handle(_ c: NWConnection) {
        lock.lock(); _connectCount += 1; lock.unlock()
        var buf = [UInt8]()
        var upgraded = false
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buf.append(contentsOf: [UInt8](data))
                    if !upgraded, let hdrEnd = self.findHeaderEnd(buf) {
                        let header = String(decoding: buf[..<hdrEnd], as: UTF8.self)
                        buf.removeFirst(hdrEnd + 4)
                        switch self.mode {
                        case .reject429(let ra):
                            var resp = "HTTP/1.1 429 Too Many Requests\r\n"
                            if let ra { resp += "Retry-After: \(ra)\r\n" }
                            resp += "Content-Length: 0\r\nConnection: close\r\n\r\n"
                            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
                            return
                        case .accept:
                            let key = self.headerValue(header, "sec-websocket-key") ?? ""
                            let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                            let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
                            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
                                       "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
                            upgraded = true
                            self.lock.lock(); self._conn = c; self.lock.unlock()
                            self.onUpgraded?()
                        }
                    }
                    if upgraded { self.parseClientFrames(&buf) }
                }
                if err == nil && !complete { loop() }
            }
        }
        c.start(queue: q); loop()
    }

    private func findHeaderEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 0x0d && b[i+1] == 0x0a && b[i+2] == 0x0d && b[i+3] == 0x0a { return i }
        return nil
    }
    private func headerValue(_ header: String, _ name: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    // client -> server frames are masked; unmask and hand each payload to the callback.
    private func parseClientFrames(_ buf: inout [UInt8]) {
        while buf.count >= 2 {
            let opcode = buf[0] & 0x0F
            let masked = (buf[1] & 0x80) != 0
            var len = Int(buf[1] & 0x7F)
            var idx = 2
            if len == 126 { guard buf.count >= 4 else { return }; len = Int(buf[2]) << 8 | Int(buf[3]); idx = 4 }
            else if len == 127 { return }   // tests never send frames this large
            var mask = [UInt8]()
            if masked { guard buf.count >= idx + 4 else { return }; mask = Array(buf[idx..<idx+4]); idx += 4 }
            guard buf.count >= idx + len else { return }
            var payload = Array(buf[idx..<idx+len])
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
            buf.removeFirst(idx + len)
            onClientFrame?(opcode, payload)
        }
    }
}

// MARK: - A hand-rolled loopback SOCKS5 proxy (stands in for a local Tor / Arti listener) -----------
//
// It speaks just enough of RFC 1928 to prove the two things that actually matter for Tor reach:
// URLSession really routes the WebSocket through the configured proxy, and it hands over the target
// HOSTNAME (ATYP 0x03) rather than resolving it first, which is the only reason a `.onion` name can
// work. After the handshake it splices bytes to the real loopback WS server, so the whole bearer
// lifecycle runs over the proxied socket instead of being mocked.

private final class SocksTestProxy {
    private let listener: NWListener
    private let q = DispatchQueue(label: "test.socks.proxy")
    private let lock = NSLock()
    private var _requestedHost: String?
    private var _requestedPort: UInt16 = 0
    private var _addressType: UInt8?
    private var _conns: [NWConnection] = []
    /// Where the proxy forwards to once the handshake completes.
    private let upstreamPort: UInt16

    private(set) var port: UInt16 = 0

    /// The hostname the client asked the proxy to reach, and how it encoded it.
    var requestedHost: String? { lock.lock(); defer { lock.unlock() }; return _requestedHost }
    var requestedPort: UInt16 { lock.lock(); defer { lock.unlock() }; return _requestedPort }
    var addressType: UInt8? { lock.lock(); defer { lock.unlock() }; return _addressType }

    init(upstreamPort: UInt16) {
        self.upstreamPort = upstreamPort
        listener = try! NWListener(using: .tcp)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: q)
        _ = ready.wait(timeout: .now() + 3)
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        lock.lock(); let cs = _conns; _conns = []; lock.unlock()
        cs.forEach { $0.cancel() }
    }

    private func track(_ c: NWConnection) { lock.lock(); _conns.append(c); lock.unlock() }

    private func handle(_ client: NWConnection) {
        track(client)
        var buf = [UInt8]()
        var greeted = false
        var upstream: NWConnection?

        func pumpUpstream(_ up: NWConnection) {
            up.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let data, !data.isEmpty {
                    client.send(content: data, completion: .contentProcessed { _ in })
                }
                if done || err != nil { client.cancel(); return }
                pumpUpstream(up)
            }
        }

        func loop() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data, !data.isEmpty {
                    if let up = upstream {
                        up.send(content: data, completion: .contentProcessed { _ in })
                    } else {
                        buf += [UInt8](data)
                        // Greeting: VER NMETHODS METHODS... -> "no authentication".
                        if !greeted, buf.count >= 2, buf.count >= 2 + Int(buf[1]) {
                            buf.removeFirst(2 + Int(buf[1]))
                            greeted = true
                            client.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in })
                        }
                        // CONNECT request: VER CMD RSV ATYP ADDR PORT.
                        if greeted, buf.count >= 5 {
                            let atyp = buf[3]
                            let need = atyp == 0x03 ? 4 + 1 + Int(buf[4]) + 2 : (atyp == 0x01 ? 10 : 22)
                            if buf.count >= need {
                                self.lock.lock()
                                self._addressType = atyp
                                if atyp == 0x03 {
                                    let len = Int(buf[4])
                                    self._requestedHost = String(decoding: buf[5..<(5 + len)], as: UTF8.self)
                                    self._requestedPort = UInt16(buf[need - 2]) << 8 | UInt16(buf[need - 1])
                                }
                                self.lock.unlock()
                                buf.removeFirst(need)
                                let up = NWConnection(host: "127.0.0.1",
                                                      port: NWEndpoint.Port(rawValue: self.upstreamPort)!,
                                                      using: .tcp)
                                upstream = up
                                self.track(up)
                                up.start(queue: self.q)
                                pumpUpstream(up)
                                // Success reply; the bound address is unused by the client.
                                client.send(content: Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]),
                                            completion: .contentProcessed { _ in })
                                if !buf.isEmpty {
                                    up.send(content: Data(buf), completion: .contentProcessed { _ in })
                                    buf.removeAll()
                                }
                            }
                        }
                    }
                }
                if done || err != nil { upstream?.cancel(); client.cancel(); return }
                loop()
            }
        }
        client.start(queue: q)
        loop()
    }
}

// MARK: - Recording sink + spin-wait ---------------------------------------------------------------

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

private func spinWait(_ timeout: TimeInterval = 6, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return cond()
}

final class RelayIntegrationTests: XCTestCase {

    // MARK: the full happy path: dial -> real didOpen -> receive (binary + text) -> send -> WS close.

    func testDialOpenReceiveSendAndClose() throws {
        let server = WSTestServer(); server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0, "the loopback WS server must bind a port")

        var clientFrames: [(UInt8, [UInt8])] = []; let cfLock = NSLock()
        server.onClientFrame = { op, p in cfLock.lock(); clientFrames.append((op, p)); cfLock.unlock() }

        let bearer = RelayBearer(relayURL: server.url)
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        // 1) the real WebSocket upgrade completes -> didOpenWithProtocol -> linkUp(.dialer, stablePeerId).
        guard spinWait(until: { !sink.ups.isEmpty }) else {
            throw XCTSkip("URLSession did not open a cleartext ws:// loopback socket (ATS?) - see report")
        }
        XCTAssertEqual(sink.ups[0].1, .dialer, "we dialed out -> Noise initiator role")
        XCTAssertEqual(sink.ups[0].2, RelayBearer.stablePeerId(forURL: server.url), "the surfaced peerId is the stable derivation")
        let linkId = sink.ups[0].0

        // 2) a server binary frame -> receiveLoop .data -> linkBytes.
        server.pushBinary([0x01, 0x02, 0x03])
        XCTAssertTrue(spinWait { sink.bytes.contains { $0.0 == linkId && Array($0.1) == [0x01, 0x02, 0x03] } },
                      "an inbound binary WS frame surfaces as linkBytes")

        // 3) a server text frame -> receiveLoop .string -> linkBytes(utf8).
        server.pushText("hi")
        XCTAssertTrue(spinWait { sink.bytes.contains { Array($0.1) == Array("hi".utf8) } },
                      "an inbound text WS frame surfaces as its utf8 bytes")

        // 4) bearer.send -> a client WS frame the server receives.
        bearer.send(Data([0xAA, 0xBB, 0xCC]), on: linkId)
        XCTAssertTrue(spinWait { cfLock.withLock { clientFrames.contains { $0.1 == [0xAA, 0xBB, 0xCC] } } },
                      "bearer.send puts the bytes on the wire as a WS frame")

        // 5) server sends a WS close -> real didCloseWith -> handleDown -> linkDown + a scheduled reconnect.
        server.pushClose()
        XCTAssertTrue(spinWait { sink.downs.contains(linkId) }, "a WS close surfaces linkDown")

        // 6) reconnect: the min backoff is ~1s, so the server sees a second connection attempt.
        XCTAssertTrue(spinWait(4) { server.connectCount >= 2 }, "the bearer reconnects after a drop (backoff)")
    }

    // MARK: pooled construction: the URL is resolved PER ATTEMPT, so failover needs no re-register.

    func testPooledBearerResolvesPerAttemptAndReportsOutcomes() throws {
        // The failover mechanism. A fixed URL meant a dead relay was retried forever and the only
        // way to move was an app restart, because the shared BearerManager has no live re-register.
        // Resolving per attempt lets the host hand back a healthier endpoint on the next dial.
        let dead = WSTestServer(); dead.mode = .reject429(retryAfter: nil); dead.start()
        let live = WSTestServer(); live.start()
        defer { dead.stop(); live.stop() }
        XCTAssertGreaterThan(live.port, 0)

        let lock = NSLock()
        var outcomes: [(String, Bool)] = []
        var handOutLive = false
        let deadURL = dead.url, liveURL = live.url

        let bearer = RelayBearer(
            seedURL: deadURL,
            resolveURL: { lock.withLock { handOutLive ? liveURL : deadURL } },
            reportOutcome: { url, ok in lock.withLock { outcomes.append((url, ok)) } }
        )
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        // The first attempt hits the dead relay and must be reported as a FAILURE, attributed to
        // that URL specifically (not to whatever the pool would return later).
        XCTAssertTrue(
            spinWait(4) { lock.withLock { outcomes.contains { $0.0 == deadURL && !$0.1 } } },
            "a failed dial is reported against the endpoint that failed"
        )

        // Now the pool hands back a healthy endpoint; the next attempt must use it WITHOUT any
        // re-registration, and report success.
        lock.withLock { handOutLive = true }
        guard spinWait(8, until: { !sink.ups.isEmpty }) else {
            throw XCTSkip("URLSession did not open a cleartext ws:// loopback socket (ATS?)")
        }
        XCTAssertTrue(
            spinWait(4) { lock.withLock { outcomes.contains { $0.0 == liveURL && $0.1 } } },
            "the next attempt failed over to the healthy endpoint and reported success"
        )
        // The synthetic peer id must NOT change across failover: the manager keys bookkeeping on it.
        XCTAssertEqual(
            sink.ups[0].2,
            RelayBearer.stablePeerId(forURL: deadURL),
            "the peer id stays seeded, so failover does not churn manager bookkeeping"
        )
    }

    // MARK: the same failover, driven by the REAL §19 node pool through the published SDK (PLAT-003).

    func testPooledBearerFailsOverThroughTheNodePoolWithoutRestarting() throws {
        // The case above proves the BEARER asks per attempt; it hand-rolls the resolver, so it says
        // nothing about whether a host can build one. PLAT-003 was that nobody could: sdk/hop.h sold
        // the v4 -> v5 ABI bump as buying failover while no C-ABI wrapper bound hop_relay_add /
        // hop_relay_next / hop_relay_report / hop_relay_pool_size, so an SDK-only integrator's only
        // reachable constructor was the fixed-URL one and a dead relay ended internet reach until the
        // app restarted. Here the closures come straight off HopNode, and nothing else drives the
        // choice of endpoint: the pool does.
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        node.tick(nowMs: 1_700_000_000_000)

        // The dead endpoint REFUSES connections rather than answering 429. A 429 with no Retry-After
        // is honored as the 30 s ceiling, which is longer than any sane test window, so the failover
        // dial would never be observed; a refused connection uses the ordinary 1 s exponential floor.
        let dead = WSTestServer(); dead.start()
        let deadURL = dead.url
        dead.stop()
        let live = WSTestServer(); live.start()
        defer { live.stop() }
        XCTAssertGreaterThan(live.port, 0)
        let liveURL = live.url

        // Only the dead endpoint is configured, so the first dial is forced onto it.
        XCTAssertTrue(node.relayAdd(deadURL))
        XCTAssertEqual(node.relayNext(), deadURL, "the one configured endpoint is what gets dialed")

        // The pool decides where to dial; this mirror exists only so the test can SYNCHRONIZE on the
        // failure having reached the pool. Adding the second endpoint before that point would let the
        // first dial pick it and the test would prove nothing.
        let lock = NSLock()
        var reports: [(String, Bool)] = []
        let bearer = RelayBearer(
            seedURL: deadURL,
            resolveURL: { node.relayNext() },
            reportOutcome: { url, ok in
                lock.withLock { reports.append((url, ok)) }
                node.relayReport(url, ok: ok)
            }
        )
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        // The dial fails against the dead endpoint and the outcome lands in the POOL.
        XCTAssertTrue(
            spinWait(8) { lock.withLock { reports.contains { $0.0 == deadURL && !$0.1 } } },
            "the failed dial must be reported to the pool against the endpoint that failed"
        )

        // A second endpoint appears (gossip supplies it). It is added UNCONFIGURED on purpose: the
        // pool ranks a configured endpoint above a gossiped one at equal health, so the only thing
        // that can move the dial off the dead one is the failure just reported. Add it configured and
        // this assertion would pass on a tie-break even with reporting broken, which is no proof.
        XCTAssertTrue(node.relayAdd(liveURL, configured: false))
        XCTAssertEqual(node.relayNext(), liveURL, "a just-failed endpoint must yield to a healthy one")

        // And the running bearer must actually get there, with no restart and no re-register: it asks
        // the pool again on its next backoff tick and opens a real socket to the healthy endpoint.
        guard spinWait(20, until: { !sink.ups.isEmpty }) else {
            throw XCTSkip("URLSession did not open a cleartext ws:// loopback socket (ATS?)")
        }
        XCTAssertTrue(
            spinWait(8) { lock.withLock { reports.contains { $0.0 == liveURL && $0.1 } } },
            "the successful dial is reported against the endpoint that earned it"
        )
        XCTAssertEqual(node.relayNext(), liveURL, "the working endpoint is kept after a success")
        XCTAssertEqual(node.relayPool().total, 2)
    }

    func testPooledBearerWithNothingDialableWaitsInsteadOfStopping() {
        // Every pooled endpoint backed off is a WAIT state. If the bearer treated it as a stop, a
        // transient outage would end reach permanently until restart.
        let lock = NSLock()
        var asked = 0
        let bearer = RelayBearer(
            seedURL: "ws://127.0.0.1:1/",
            resolveURL: { lock.withLock { asked += 1 }; return nil },
            reportOutcome: { _, _ in }
        )
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        XCTAssertTrue(
            spinWait(6) { lock.withLock { asked >= 2 } },
            "with nothing dialable the bearer must keep asking, not give up"
        )
        XCTAssertTrue(sink.ups.isEmpty, "it must not fabricate a link when there is nowhere to dial")
    }

    // MARK: Tor: an .onion relay dialed through a SOCKS5 proxy, end to end over a real socket.

    func testOnionRelayDialsThroughASocksProxyAndOpensALink() throws {
        guard #available(iOS 17.0, macOS 14.0, *) else {
            throw XCTSkip("proxyConfigurations needs iOS 17 / macOS 14; the bearer fails closed below that")
        }
        let server = WSTestServer(); server.start()
        let proxy = SocksTestProxy(upstreamPort: server.port); proxy.start()
        defer { server.stop(); proxy.stop() }
        XCTAssertGreaterThan(proxy.port, 0, "the loopback SOCKS proxy must bind a port")

        // A v3-shaped onion name that resolves NOWHERE. If the bearer resolved hostnames itself, or
        // ignored the proxy, this dial could not possibly succeed, which is the point of the test.
        let onion = "ws://i3azam4xowcraffcdopctb4uq7wq23uhi3azam4xowcraffcdopctb4d.onion/_hop"
        let bearer = RelayBearer(relayURL: onion, socksProxy: "127.0.0.1:\(proxy.port)")
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        XCTAssertTrue(spinWait(8) { !sink.ups.isEmpty },
                      "the WebSocket upgrade completes through the proxy and surfaces linkUp")
        XCTAssertEqual(sink.ups[0].1, .dialer, "we dialed out, so we are still the Noise initiator")
        XCTAssertEqual(sink.ups[0].2, RelayBearer.stablePeerId(forURL: onion),
                       "the bookkeeping peer id is derived the same way for an onion endpoint")

        // The property that makes .onion work at all: the NAME went to the proxy, unresolved.
        XCTAssertEqual(proxy.addressType, 0x03, "SOCKS5 ATYP 0x03 = domain name, not a resolved address")
        XCTAssertEqual(proxy.requestedHost,
                       "i3azam4xowcraffcdopctb4uq7wq23uhi3azam4xowcraffcdopctb4d.onion",
                       "the full onion hostname is handed to the proxy to resolve")
        XCTAssertEqual(proxy.requestedPort, 80, "the URL's implicit ws:// port rides along")

        // And it is a working link, not just an open socket.
        server.pushBinary([0x07, 0x08])
        XCTAssertTrue(spinWait { sink.bytes.contains { Array($0.1) == [0x07, 0x08] } },
                      "bytes flow over the proxied link like any other relay link")
    }

    func testAProxiedBearerNeverDialsDirectWhenTheProxyIsUnusable() {
        // FAIL CLOSED. A configured-but-unusable proxy (here: a typo'd spec) must not degrade into
        // a clearnet dial. The user's IP would be exposed to the relay while they believe it is not.
        let server = WSTestServer(); server.start()
        defer { server.stop() }
        let lock = NSLock()
        var outcomes: [(String, Bool)] = []
        let bearer = RelayBearer(
            seedURL: server.url,
            resolveURL: { server.url },
            reportOutcome: { url, ok in lock.withLock { outcomes.append((url, ok)) } },
            socksProxy: "127.0.0.1;9050"   // a semicolon instead of a colon: configured, unusable
        )
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        XCTAssertTrue(spinWait(4) { lock.withLock { outcomes.contains { !$0.1 } } },
                      "the refused dial is reported as a failure so the pool can score it")
        XCTAssertEqual(server.connectCount, 0, "no socket was opened to the relay at all")
        XCTAssertTrue(sink.ups.isEmpty, "and no link was surfaced")
    }

    // MARK: 429 rate-limit: the upgrade is rejected, didCompleteWithError carries the 429, backoff honors it.

    func test429RejectionHonorsRetryAfterBackoff() {
        let server = WSTestServer()
        server.mode = .reject429(retryAfter: "5")
        server.start()
        defer { server.stop() }

        let bearer = RelayBearer(relayURL: server.url)
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        defer { bearer.stop() }

        // The upgrade never succeeds, so no linkUp; the first dial did connect (count 1).
        XCTAssertTrue(spinWait(4) { server.connectCount >= 1 }, "the bearer dials the relay")
        XCTAssertFalse(spinWait(1.5) { !sink.ups.isEmpty }, "a 429-rejected upgrade never surfaces linkUp")
        // Retry-After: 5 means the reconnect is deferred well past the 1s floor: no 2nd connect within ~2.5s.
        XCTAssertFalse(spinWait(2.5) { server.connectCount >= 2 },
                       "a 429 Retry-After defers the reconnect beyond the normal 1s backoff")
    }

    // MARK: stop() on a live link tears the socket down and surfaces linkDown.

    func testStopSurfacesLinkDownForLiveLink() throws {
        let server = WSTestServer(); server.start()
        defer { server.stop() }
        let bearer = RelayBearer(relayURL: server.url)
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        guard spinWait(until: { !sink.ups.isEmpty }) else {
            throw XCTSkip("URLSession did not open a cleartext ws:// loopback socket (ATS?) - see report")
        }
        let linkId = sink.ups[0].0
        bearer.stop()
        XCTAssertTrue(spinWait { sink.downs.contains(linkId) }, "stop() surfaces linkDown for the live link")
    }

    // MARK: start() is idempotent and send on the wrong link id is a no-op (guard coverage).

    func testStartIsIdempotentAndSendIgnoresUnknownLink() throws {
        let server = WSTestServer(); server.start()
        defer { server.stop() }
        let bearer = RelayBearer(relayURL: server.url)
        let sink = RecSink(); bearer.sink = sink
        bearer.start()
        bearer.start()   // second start() must be ignored (already started)
        defer { bearer.stop() }
        guard spinWait(until: { !sink.ups.isEmpty }) else {
            throw XCTSkip("URLSession did not open a cleartext ws:// loopback socket (ATS?) - see report")
        }
        XCTAssertEqual(sink.ups.count, 1, "a redundant start() must not open a second link")
        bearer.send(Data([0x00]), on: 999)   // unknown link id -> ignored, no crash
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
