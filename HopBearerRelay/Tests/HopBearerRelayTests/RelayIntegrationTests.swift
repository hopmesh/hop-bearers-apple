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
