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

    public init(relayURL: String) {
        self.relayURL = relayURL
        self.peerId = Data(SHA256.hash(data: Data(relayURL.utf8))).prefix(16)
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
        if up { up = false; sink?.linkDown(linkId) }
        task = nil
        session?.invalidateAndCancel(); session = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard started, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = backoff + Double.random(in: 0...1)   // backoff + jitter
        backoff = min(backoff * 2, RELAY_BACKOFF_MAX_S)
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
            self.backoff = RELAY_BACKOFF_MIN_S
            log("STATE", "relay link-up peer=\(shortHex(self.peerId))")
            self.sink?.linkUp(self.linkId, role: .dialer, peerId: self.peerId)   // dialer = Noise initiator
            self.receiveLoop()
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
        queue.async { [weak self] in
            guard let self, task === self.task else { return }
            self.handleDown()
        }
    }
}
