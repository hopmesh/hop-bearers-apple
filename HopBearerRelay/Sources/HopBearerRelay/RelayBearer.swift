// RelayBearer — the cloud-relay transport as its OWN library (depends only on HopBearerCore). It is the
// SIMPLEST bearer: ONE outbound WebSocket to the backbone relay, no peer discovery, no HELLO, no length
// framing (a WS message already frames exactly one node packet), no keepalive/dedup. The relay's
// lifecycle maps 1:1 to a single node link:
//
//   • start()  → dial the relay over a URLSessionWebSocketTask (Foundation only — NO third-party dep).
//   • open     → sink.linkUp(linkId, .dialer, peerId) — we dialed, so we're the Noise initiator.
//   • message  → sink.linkBytes(linkId, data) — one WS binary frame = one node packet.
//   • close/err→ sink.linkDown(linkId) + reconnect with exponential backoff (the device "check-in").
//   • send     → task.send(.data(bytes)).
//   • stop()   → cancel the socket; the sink gets linkDown for the live link.
//
// The node identifies the relay via Noise over this link, so the consumer needs no real peer identity
// from the transport — only a STABLE synthetic peerId for the BearerManager's bookkeeping. We derive it
// deterministically from the relay URL (SHA-256 prefix) so it's identical every reconnect; the node
// ignores it. This bearer names nothing about BLE/LAN — it is written purely against start/stop/send/sink.

import Foundation
import CryptoKit
import HopContract   // the bearer contract (no libhop)

private let RELAY_BACKOFF_MIN_S: Double = 1.0
private let RELAY_BACKOFF_MAX_S: Double = 30.0
private let RELAY_STABLE_S: Double = 20.0   // F-13: only reset backoff after the link holds this long

public final class RelayBearer: NSObject, Bearer {
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). The cloud relay link surfaces as "Relay".
    public let transportName = "Relay"

    private let relayURL: String
    /// Stable synthetic peer id (16 bytes) for the manager's bookkeeping — derived from the relay URL so
    /// it's identical every reconnect. The node ignores it (it identifies the relay via Noise).
    private let peerId: Data
    /// ONE link — one WebSocket. The BearerManager translates this local id into its global id space, and
    /// mints a fresh global on every reconnect (linkDown forgets the old mapping), so the node sees each
    /// reconnection as a new link, which is correct.
    private let linkId: LinkId = 1

    /// Serial home for all bearer state + delegate/receive callbacks (which hop here), so it is single-
    /// threaded end to end and needs no locks.
    private let queue = DispatchQueue(label: "hop.relay.bearer")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var started = false
    private var up = false
    private var reconnectScheduled = false
    private var backoff = RELAY_BACKOFF_MIN_S
    private var stableWork: DispatchWorkItem?      // F-13: fires after RELAY_STABLE_S to reset backoff
    private var retryAfter: Double?                // F-13: server-driven backoff from a 429 Retry-After

    public init(relayURL: String) {
        self.relayURL = relayURL
        self.peerId = RelayBearer.stablePeerId(forURL: relayURL)
        super.init()
    }

    // MARK: - Bearer

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            log("STATE", "relay node-start url=\(self.relayURL) peer=\(shortHex(self.peerId))")
            self.dial()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            if self.up { self.up = false; self.sink?.linkDown(self.linkId) }
        }
    }

    public func send(_ bytes: Data, on link: LinkId) {
        queue.async { [weak self] in
            guard let self, link == self.linkId, let task = self.task else { return }
            task.send(.data(bytes)) { _ in }   // one node packet = one WS binary frame
        }
    }

    // MARK: - dial / receive / reconnect (all on `queue`)

    private func dial() {
        guard started, let url = URL(string: relayURL) else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()   // sink.linkUp fires in didOpenWithProtocol (we're the initiator)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let d):   self.sink?.linkBytes(self.linkId, d)
                    case .string(let s): self.sink?.linkBytes(self.linkId, Data(s.utf8))
                    @unknown default:    break
                    }
                    self.receiveLoop()
                case .failure:
                    self.handleDown()
                }
            }
        }
    }

    /// Tear the current socket down (idempotent), surface linkDown once, then schedule a reconnect.
    private func handleDown() {
        stableWork?.cancel(); stableWork = nil       // F-13: the link didn't stay stable
        if up { up = false; sink?.linkDown(linkId) }
        task = nil
        session?.invalidateAndCancel(); session = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard started, !reconnectScheduled else { return }
        reconnectScheduled = true
        // F-13: honor a server-driven Retry-After (429) when present; otherwise exponential backoff.
        // Jitter always, so a fleet whose sockets all drop at once (e.g. a relay redeploy) doesn't
        // reconnect in lockstep. The delay + backoff-step math is the pure `reconnectDelay`/`nextBackoff`
        // below; a Retry-After does NOT advance the exponential backoff (only a plain drop does).
        let jitter = Double.random(in: 0...1)
        let ra = retryAfter
        let delay = RelayBearer.reconnectDelay(retryAfter: ra, backoff: backoff, jitter: jitter)
        if ra != nil {
            retryAfter = nil
        } else {
            backoff = RelayBearer.nextBackoff(backoff)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            if self.started && self.task == nil { self.dial() }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate (delegate callbacks hop onto `queue`)

extension RelayBearer: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.up = true
            log("STATE", "relay link-up peer=\(shortHex(self.peerId))")
            self.sink?.linkUp(self.linkId, role: .dialer, peerId: self.peerId)   // dialer = Noise initiator
            self.receiveLoop()
            // F-13: reset backoff only after the link has been stable for a while, not on open — a
            // relay that accepts then immediately drops (overloaded / scale-capped) would otherwise be
            // re-dialed at the 1s floor forever.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.up else { return }
                self.backoff = RELAY_BACKOFF_MIN_S
            }
            self.stableWork = work
            self.queue.asyncAfter(deadline: .now() + RELAY_STABLE_S, execute: work)
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.handleDown()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // F-13: if the WS upgrade was rejected with 429, honor the server's Retry-After instead of
        // hammering it on the normal backoff schedule. Read the response off the task before hopping
        // queues (it's the HTTP upgrade response for a failed handshake); the parse is the pure
        // `retryAfterSeconds` below (only 429 backs off this way).
        let http = task.response as? HTTPURLResponse
        let retry = RelayBearer.retryAfterSeconds(statusCode: http?.statusCode ?? 0,
                                                  retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"))
        queue.async { [weak self] in
            guard let self, task === self.task else { return }
            if let retry { self.retryAfter = retry; log("STATE", "relay 429 rate-limited; backing off \(retry)s") }
            self.handleDown()
        }
    }
}

// MARK: - Pure reconnect/backoff decisions (extracted so unit tests pin them without a live WebSocket) --
//
// The relay's whole decision surface is otherwise trapped inside URLSession delegate callbacks and the
// serial `queue`, which a unit test can't drive. Lift the DECISIONS into pure static functions the class
// delegates to, so the stable-peerId derivation, the exponential-backoff step, the 429 Retry-After parse,
// and the jittered reconnect delay are all testable with no socket. Behavior is unchanged: these are the
// exact expressions the init / scheduleReconnect / didCompleteWithError paths now call.
extension RelayBearer {
    /// The minimum / maximum exponential-backoff bounds (F-13), exposed for the tests.
    static var backoffMinS: Double { RELAY_BACKOFF_MIN_S }
    static var backoffMaxS: Double { RELAY_BACKOFF_MAX_S }

    /// The stable synthetic 16-byte peer id for a relay URL: SHA-256(url) truncated to 16 bytes. Purely a
    /// function of the URL, so it is identical every reconnect (the node ignores it, identifying the relay
    /// via Noise). This is the exact derivation `init` uses.
    static func stablePeerId(forURL relayURL: String) -> Data {
        Data(SHA256.hash(data: Data(relayURL.utf8))).prefix(16)
    }

    /// The next exponential backoff after a plain drop / too-short link: double, capped at the max (F-13).
    static func nextBackoff(_ current: Double) -> Double { min(current * 2, RELAY_BACKOFF_MAX_S) }

    /// Parse a server-driven Retry-After from a FAILED WS upgrade. Only a 429 backs off this way: a numeric
    /// Retry-After header is honored verbatim; a 429 with a missing / non-numeric header falls back to the
    /// max backoff; any non-429 status returns nil (fall back to the normal exponential schedule).
    static func retryAfterSeconds(statusCode: Int, retryAfterHeader: String?) -> Double? {
        guard statusCode == 429 else { return nil }
        if let h = retryAfterHeader, let secs = Double(h) { return secs }
        return RELAY_BACKOFF_MAX_S
    }

    /// The reconnect delay: a server Retry-After when present, else the current exponential backoff, plus
    /// [0,1) jitter (injected here so tests are deterministic) so a whole fleet doesn't reconnect in
    /// lockstep. A Retry-After does NOT advance the exponential backoff; only a plain drop does (see
    /// scheduleReconnect, which calls `nextBackoff` only on the no-Retry-After branch).
    static func reconnectDelay(retryAfter: Double?, backoff: Double, jitter: Double) -> Double {
        (retryAfter ?? backoff) + jitter
    }
}
