// RelayBearer, the cloud-relay transport as its OWN library (depends only on HopBearerCore). It is the
// SIMPLEST bearer: ONE outbound WebSocket to the backbone relay, no peer discovery, no HELLO, no length
// framing (a WS message already frames exactly one node packet), no keepalive/dedup. The relay's
// lifecycle maps 1:1 to a single node link:
//
//   • start()  → dial the relay over a URLSessionWebSocketTask (Foundation only, NO third-party dep).
//   • open     → sink.linkUp(linkId, .dialer, peerId): we dialed, so we're the Noise initiator.
//   • message  → sink.linkBytes(linkId, data): one WS binary frame = one node packet.
//   • close/err→ sink.linkDown(linkId) + reconnect with exponential backoff (the device "check-in").
//   • send     → task.send(.data(bytes)).
//   • stop()   → cancel the socket; the sink gets linkDown for the live link.
//
// The node identifies the relay via Noise over this link, so the consumer needs no real peer identity
// from the transport, just a STABLE synthetic peerId for the BearerManager's bookkeeping. We derive it
// deterministically from the relay URL (SHA-256 prefix) so it's identical every reconnect; the node
// ignores it. This bearer names nothing about BLE/LAN; it is written purely against start/stop/send/sink.
//
// TOR: there is no Tor code here and there should not be. A host that wants relay traffic to ride Tor
// runs a proxy (the Tor daemon, or Arti embedded in the app) and passes its `SocksProxy` in; the dial
// string then just happens to be a `.onion` URL, which the pool and this bearer treat like any other.
// See docs/tor.md for what that does and, importantly, does not hide.

import Foundation
import Network
import CryptoKit
import HopContract   // the bearer contract (no libhop)

private let RELAY_BACKOFF_MIN_S: Double = 1.0
private let RELAY_BACKOFF_MAX_S: Double = 30.0
private let RELAY_STABLE_S: Double = 20.0   // F-13: only reset backoff after the link holds this long

/// A SOCKS5 proxy every relay dial is routed through, e.g. a local Tor or Arti listener on
/// `127.0.0.1:9050`.
///
/// Hop embeds no Tor implementation and does not want one: Tor is a whole networking stack with its
/// own release cadence and threat surface, and the host app (or the OS) is already the thing that
/// knows whether a proxy is running. Pointing the socket at a proxy the host supplies is the entire
/// integration, and it is transport-generic: this is a SOCKS5 setting, not a Tor setting.
///
/// The proxy also does the name resolution (the target hostname is handed to it unresolved), which
/// is what makes a `.onion` dial string work at all: there is no DNS record to look up. See
/// `docs/tor.md`.
public struct SocksProxy: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Parse a `host:port` spec, e.g. `127.0.0.1:9050` or `[::1]:9050`. Returns nil for anything
    /// that is not a complete, usable endpoint, so a half-filled config can never be read as "no
    /// proxy wanted" by one caller and "proxy at some default" by another.
    public static func parse(_ spec: String?) -> SocksProxy? {
        guard let raw = spec?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let host: String
        let portText: Substring
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            // Bracketed IPv6: the colons inside the address are not the separator.
            host = String(raw[raw.index(after: raw.startIndex)..<close])
            let after = raw[raw.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            portText = after.dropFirst()
        } else {
            guard let colon = raw.lastIndex(of: ":"), raw.firstIndex(of: ":") == colon else { return nil }
            host = String(raw[raw.startIndex..<colon])
            portText = raw[raw.index(after: colon)...]
        }
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
        return SocksProxy(host: host, port: port)
    }
}

/// What the host's proxy setting resolved to, decided ONCE at construction.
///
/// The third case is the point. A setting that was supplied but does not parse must never quietly
/// become "dial direct": that is a typo turning into a clearnet connection the user believes is
/// proxied. Resolving the spec into three explicit states makes that impossible to get wrong later,
/// because the dial path has no "no proxy configured" branch it can fall into by accident.
public enum SocksProxySetting: Equatable, Sendable {
    /// No proxy configured. Dial normally (the default for every existing caller).
    case direct
    /// Dial every relay connection through this proxy.
    case proxy(SocksProxy)
    /// A proxy WAS configured but the spec is unusable. Never dial.
    case unusable

    /// Resolve a host-supplied `host:port` spec. Nil, empty, or whitespace means no proxy was asked
    /// for; anything else must parse or the bearer refuses to dial at all.
    public init(spec: String?) {
        guard let raw = spec?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            self = .direct
            return
        }
        self = SocksProxy.parse(raw).map { SocksProxySetting.proxy($0) } ?? .unusable
    }
}

public final class RelayBearer: NSObject, Bearer {
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). The cloud relay link surfaces as "Relay".
    public let transportName = "Relay"

    /// Where to dial, resolved PER ATTEMPT rather than fixed at construction.
    ///
    /// This is what makes relay failover possible without a live re-register on the shared
    /// `BearerManager` (which has none). A fixed URL meant a dead relay was retried forever and the
    /// only way to move was an app restart; asking each attempt lets the host hand back a different,
    /// healthier endpoint from the node's §19 relay pool. Returning nil or an empty string means
    /// "nothing dialable right now", which is a WAIT (retry on the next backoff tick), not a stop.
    private let resolveURL: () -> String?
    /// Reports the outcome of each attempt back to the host so the pool can score endpoints.
    /// `(url, ok)`. No-op by default so a fixed-URL caller behaves exactly as before.
    private let reportOutcome: (String, Bool) -> Void
    /// The URL the CURRENT attempt used, so an outcome is attributed to the endpoint that earned it
    /// rather than to whatever the pool would hand out now.
    private var currentURL: String?
    /// Stable synthetic peer id (16 bytes) for the manager's bookkeeping. Derived from the FIRST
    /// resolved URL and then held fixed: the manager keys its bookkeeping on this, and the node
    /// identifies the relay via Noise regardless, so it must not change when we fail over.
    private var peerId: Data
    /// How the host's proxy setting resolved. `.direct` for every caller that configured none.
    private let socks: SocksProxySetting
    /// ONE link, one WebSocket. The BearerManager translates this local id into its global id space, and
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

    /// Fixed-URL construction. Unchanged behavior, retained for callers that genuinely have one
    /// relay (tests, the ble-lab client, a pinned deployment).
    /// `socksProxy` is a `host:port` spec (e.g. a local Tor listener at `127.0.0.1:9050`); nil or
    /// empty dials direct, and an unparseable value refuses to dial rather than falling back to it.
    public init(relayURL: String, socksProxy: String? = nil) {
        self.resolveURL = { relayURL }
        self.reportOutcome = { _, _ in }
        self.peerId = RelayBearer.stablePeerId(forURL: relayURL)
        self.socks = SocksProxySetting(spec: socksProxy)
        super.init()
    }

    /// Pooled construction: resolve the endpoint per dial attempt and report each outcome, so a
    /// failing relay is scored down and the next attempt lands somewhere healthier (DESIGN.md §19).
    /// `seedURL` fixes the synthetic peer id up front so the manager's bookkeeping is stable across
    /// failover.
    public init(
        seedURL: String,
        resolveURL: @escaping () -> String?,
        reportOutcome: @escaping (String, Bool) -> Void,
        socksProxy: String? = nil
    ) {
        self.resolveURL = resolveURL
        self.reportOutcome = reportOutcome
        self.peerId = RelayBearer.stablePeerId(forURL: seedURL)
        self.socks = SocksProxySetting(spec: socksProxy)
        super.init()
    }

    // MARK: - Bearer

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            log("STATE", "relay node-start peer=\(shortHex(self.peerId))")
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
        guard started else { return }
        // Resolve per attempt so failover works without a live re-register (see `resolveURL`).
        guard let candidate = resolveURL(), !candidate.isEmpty, let url = URL(string: candidate) else {
            // Nothing dialable: every pooled endpoint is backed off. Wait for the next tick rather
            // than treating this as a permanent stop, or a transient outage would end reach.
            currentURL = nil
            scheduleReconnect()
            return
        }
        currentURL = candidate
        guard let configuration = RelayBearer.sessionConfiguration(socks: socks) else {
            // The host asked for every relay byte to go through a proxy and it cannot be applied
            // (an unusable spec, or an OS without proxyConfigurations). FAIL CLOSED: dialing direct
            // would put the connection on the clearnet, which is the exact thing the caller
            // configured a proxy to avoid, and it would do so silently. handleDown() reports the
            // attempt as a failure against this endpoint, which is honest, from this node the
            // endpoint really is unreachable, and it gives the UI its "no reach" signal instead of
            // a pool that looks healthy while nothing ever connects. It also puts the retry on the
            // normal backoff rather than a hot loop.
            log("STATE", "relay dial refused: SOCKS proxy configured but unusable (endpoint or OS)")
            handleDown()
            return
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
        // Report BEFORE scheduling the next attempt, so the pool has already scored this endpoint
        // down by the time `dial()` asks it where to go. Reporting after would re-pick the corpse.
        if let url = currentURL { reportOutcome(url, false) }
        currentURL = nil
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
            // Score the endpoint that actually answered, not whatever the pool would return now.
            if let url = self.currentURL { self.reportOutcome(url, true) }
            log("STATE", "relay link-up peer=\(shortHex(self.peerId))")
            self.sink?.linkUp(self.linkId, role: .dialer, peerId: self.peerId)   // dialer = Noise initiator
            self.receiveLoop()
            // F-13: reset backoff only after the link has been stable for a while, not on open, a
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

    /// The URLSession configuration for one dial: plain when no proxy is configured, SOCKS5-routed
    /// when one is.
    ///
    /// Returns nil when a proxy was requested but cannot be applied, and the caller must then NOT
    /// dial (see `dial()`). Two ways that happens: an unusable setting (`.unusable`, e.g. a typo in
    /// the host's config), and an OS older than iOS 17 / macOS 14, where `proxyConfigurations` does
    /// not exist. The package still supports iOS 16 / macOS 13, and on those a proxied relay simply
    /// does not connect. That is deliberate: a silent clearnet fallback is worse than no reach,
    /// because the user believes their IP is hidden from the relay when it is not.
    static func sessionConfiguration(socks: SocksProxySetting) -> URLSessionConfiguration? {
        let cfg = URLSessionConfiguration.default
        let proxy: SocksProxy
        switch socks {
        case .direct: return cfg
        case .unusable: return nil
        case .proxy(let p): proxy = p
        }
        guard #available(iOS 17.0, macOS 14.0, *) else { return nil }
        guard let port = NWEndpoint.Port(rawValue: proxy.port) else { return nil }
        // Hand the proxy the HOSTNAME, never a resolved address: a .onion name has no DNS record,
        // so the proxy is the only thing that can resolve it, and resolving locally would leak the
        // lookup even when it could succeed. URLSession does this for us (verified in the
        // integration tests: the proxy sees SOCKS5 ATYP 0x03 with the literal hostname).
        cfg.proxyConfigurations = [
            ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port))
        ]
        return cfg
    }

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
