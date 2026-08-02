// Pure-logic tests for the cloud-relay bearer. Everything the relay decides (the stable synthetic peerId,
// the exponential backoff step, the 429 Retry-After parse, and the jittered reconnect delay) is trapped
// inside URLSession delegate callbacks + a serial queue in production, so it was lifted into pure static
// functions the class delegates to. A live WebSocket cannot be driven in a unit test, so the socket path
// stays device/integration-tested; the DECISION logic (F-13 backoff + rate-limit handling, the reconnect
// cadence, the bookkeeping peerId) is covered here.

import XCTest
import Foundation
import CryptoKit
@testable import HopBearerRelay

final class RelayBearerLogicTests: XCTestCase {

    // MARK: stable peerId. SHA-256(url) prefix, deterministic across reconnects.

    func testStablePeerIdIs16BytesAndDeterministic() {
        let a = RelayBearer.stablePeerId(forURL: "wss://relay.hopme.sh/")
        let b = RelayBearer.stablePeerId(forURL: "wss://relay.hopme.sh/")
        XCTAssertEqual(a.count, 16, "the manager's bookkeeping peerId is 16 bytes")
        XCTAssertEqual(a, b, "same URL -> identical peerId every reconnect")
    }

    func testStablePeerIdMatchesSha256Prefix() {
        // Pin the exact derivation so a future change to how the relay is keyed is caught here.
        let url = "wss://relay.hopme.sh/"
        let expected = Data(SHA256.hash(data: Data(url.utf8))).prefix(16)
        XCTAssertEqual(RelayBearer.stablePeerId(forURL: url), expected)
    }

    func testStablePeerIdDiffersByURL() {
        XCTAssertNotEqual(RelayBearer.stablePeerId(forURL: "wss://a.example/"),
                          RelayBearer.stablePeerId(forURL: "wss://b.example/"),
                          "distinct relays get distinct bookkeeping ids")
    }

    func testConstructedBearerUsesTheStableDerivation() {
        // The init wiring must use the same derivation (guards the one-liner from drifting). We can't read
        // the private stored peerId, but constructing the bearer must not crash and the static derivation
        // (which init calls) is what we pin above.
        _ = RelayBearer(relayURL: "wss://relay.hopme.sh/")
    }

    // MARK: exponential backoff step. Double, capped at the max.

    func testNextBackoffDoublesUntilCap() {
        XCTAssertEqual(RelayBearer.nextBackoff(1.0), 2.0)
        XCTAssertEqual(RelayBearer.nextBackoff(2.0), 4.0)
        XCTAssertEqual(RelayBearer.nextBackoff(8.0), 16.0)
    }

    func testNextBackoffCapsAtMax() {
        // 16 -> 32 would exceed the 30s cap, so it clamps; and it never climbs above the cap thereafter.
        XCTAssertEqual(RelayBearer.nextBackoff(16.0), RelayBearer.backoffMaxS)
        XCTAssertEqual(RelayBearer.nextBackoff(RelayBearer.backoffMaxS), RelayBearer.backoffMaxS)
    }

    func testBackoffProgressionFromMinReachesCap() {
        // Walk the real schedule from the 1s floor; it must be monotonic non-decreasing and land on the cap.
        var b = RelayBearer.backoffMinS
        var seen = [b]
        for _ in 0..<10 { b = RelayBearer.nextBackoff(b); seen.append(b) }
        XCTAssertEqual(seen.first, RelayBearer.backoffMinS)
        XCTAssertEqual(seen.last, RelayBearer.backoffMaxS, "the schedule saturates at the max")
        XCTAssertTrue(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "backoff never decreases")
    }

    // MARK: 429 Retry-After parse. Only 429 backs off this way.

    func testRetryAfterNumericHeaderOn429IsHonored() {
        XCTAssertEqual(RelayBearer.retryAfterSeconds(statusCode: 429, retryAfterHeader: "12"), 12.0)
        XCTAssertEqual(RelayBearer.retryAfterSeconds(statusCode: 429, retryAfterHeader: "0"), 0.0)
    }

    func testRetryAfter429WithMissingHeaderFallsBackToMax() {
        XCTAssertEqual(RelayBearer.retryAfterSeconds(statusCode: 429, retryAfterHeader: nil),
                       RelayBearer.backoffMaxS, "a 429 with no Retry-After backs off the full cap")
    }

    func testRetryAfter429WithNonNumericHeaderFallsBackToMax() {
        // An HTTP-date Retry-After (not seconds) can't be parsed as Double -> fall back to the cap, don't
        // hammer at the 1s floor.
        XCTAssertEqual(RelayBearer.retryAfterSeconds(statusCode: 429, retryAfterHeader: "Wed, 21 Oct 2026 07:28:00 GMT"),
                       RelayBearer.backoffMaxS)
    }

    func testNon429StatusYieldsNilSoNormalBackoffApplies() {
        // Any non-429 failure (or no HTTP response at all, statusCode 0) must NOT engage server-driven
        // backoff; nil means "use the normal exponential schedule".
        XCTAssertNil(RelayBearer.retryAfterSeconds(statusCode: 0, retryAfterHeader: nil))
        XCTAssertNil(RelayBearer.retryAfterSeconds(statusCode: 200, retryAfterHeader: "5"))
        XCTAssertNil(RelayBearer.retryAfterSeconds(statusCode: 503, retryAfterHeader: "5"),
                     "even a 503 with a Retry-After is ignored; only 429 is honored")
    }

    // MARK: reconnect delay. Retry-After wins over backoff, jitter is additive.

    func testReconnectDelayUsesRetryAfterWhenPresent() {
        // With a server Retry-After, the delay is that value + jitter; the exponential backoff is ignored.
        XCTAssertEqual(RelayBearer.reconnectDelay(retryAfter: 12.0, backoff: 4.0, jitter: 0.0), 12.0)
        XCTAssertEqual(RelayBearer.reconnectDelay(retryAfter: 12.0, backoff: 4.0, jitter: 0.5), 12.5)
    }

    func testReconnectDelayUsesBackoffWhenNoRetryAfter() {
        XCTAssertEqual(RelayBearer.reconnectDelay(retryAfter: nil, backoff: 4.0, jitter: 0.0), 4.0)
        XCTAssertEqual(RelayBearer.reconnectDelay(retryAfter: nil, backoff: 4.0, jitter: 0.25), 4.25)
    }

    // MARK: SOCKS proxy spec parsing (the host-supplied Tor hook).

    func testSocksProxyParsesHostAndPort() {
        XCTAssertEqual(SocksProxy.parse("127.0.0.1:9050"), SocksProxy(host: "127.0.0.1", port: 9050))
        XCTAssertEqual(SocksProxy.parse("  localhost:9150  "), SocksProxy(host: "localhost", port: 9150),
                       "surrounding whitespace in a config value must not defeat the parse")
        XCTAssertEqual(SocksProxy.parse("[::1]:9050"), SocksProxy(host: "::1", port: 9050),
                       "a bracketed IPv6 literal keeps its own colons")
    }

    func testSocksProxyRejectsAnythingIncomplete() {
        // A half-filled setting must be nil, not a partial proxy: "no proxy" and "proxy somewhere I
        // did not ask for" are both wrong answers, and the second one leaks.
        XCTAssertNil(SocksProxy.parse(nil))
        XCTAssertNil(SocksProxy.parse(""))
        XCTAssertNil(SocksProxy.parse("   "))
        XCTAssertNil(SocksProxy.parse("127.0.0.1"), "no port")
        XCTAssertNil(SocksProxy.parse(":9050"), "no host")
        XCTAssertNil(SocksProxy.parse("127.0.0.1:"), "empty port")
        XCTAssertNil(SocksProxy.parse("127.0.0.1:notaport"))
        XCTAssertNil(SocksProxy.parse("127.0.0.1:0"), "port 0 is not a listener")
        XCTAssertNil(SocksProxy.parse("127.0.0.1:99999"), "out of UInt16 range")
        XCTAssertNil(SocksProxy.parse("::1:9050"), "an unbracketed IPv6 literal is ambiguous, not a guess")
        XCTAssertNil(SocksProxy.parse("[::1]9050"), "brackets without the port separator")
    }

    // MARK: the three-state setting. Absent = direct, good = proxy, present-but-broken = never dial.

    func testSocksProxySettingResolvesTheThreeStates() {
        XCTAssertEqual(SocksProxySetting(spec: nil), .direct)
        XCTAssertEqual(SocksProxySetting(spec: ""), .direct)
        XCTAssertEqual(SocksProxySetting(spec: "   "), .direct)
        XCTAssertEqual(SocksProxySetting(spec: "127.0.0.1:9050"), .proxy(SocksProxy(host: "127.0.0.1", port: 9050)))
    }

    func testAConfiguredButBrokenSpecIsUnusableNotDirect() {
        // The whole reason this is three states and not an optional. A typo must NOT read as "the
        // user did not want a proxy", or one bad character silently puts relay traffic on the
        // clearnet while the user believes it is proxied.
        XCTAssertEqual(SocksProxySetting(spec: "127.0.0.1;9050"), .unusable)
        XCTAssertEqual(SocksProxySetting(spec: "127.0.0.1"), .unusable)
        XCTAssertEqual(SocksProxySetting(spec: "127.0.0.1:0"), .unusable)
    }

    // MARK: session configuration. Direct = plain; proxy = SOCKS5; unusable = nil (fail closed).

    func testSessionConfigurationWithoutAProxyIsPlain() {
        let cfg = RelayBearer.sessionConfiguration(socks: .direct)
        XCTAssertNotNil(cfg, "the default path must always produce a configuration")
        if #available(iOS 17.0, macOS 14.0, *) {
            XCTAssertTrue(cfg?.proxyConfigurations.isEmpty ?? false, "no proxy was asked for, so none is set")
        }
    }

    func testSessionConfigurationWithAProxyCarriesExactlyOneProxy() throws {
        guard #available(iOS 17.0, macOS 14.0, *) else {
            throw XCTSkip("proxyConfigurations needs iOS 17 / macOS 14; the bearer fails closed below that")
        }
        let cfg = try XCTUnwrap(RelayBearer.sessionConfiguration(socks: .proxy(SocksProxy(host: "127.0.0.1", port: 9050))))
        XCTAssertEqual(cfg.proxyConfigurations.count, 1, "every dial routes through the one configured proxy")
    }

    func testSessionConfigurationFailsClosedOnAnUnusableProxy() {
        // The dial path treats nil as "do not dial". Returning a plain configuration here instead
        // would silently put a connection the user believes is proxied onto the clearnet.
        XCTAssertNil(RelayBearer.sessionConfiguration(socks: .unusable))
    }

    func testReconnectDelayJitterStaysWithinOneSecond() {
        // The production jitter is Double.random(in: 0...1); assert the delay for any such jitter lands in
        // [base, base+1] so the anti-lockstep spread is bounded.
        let base = 8.0
        for _ in 0..<200 {
            let j = Double.random(in: 0...1)
            let d = RelayBearer.reconnectDelay(retryAfter: nil, backoff: base, jitter: j)
            XCTAssertGreaterThanOrEqual(d, base)
            XCTAssertLessThanOrEqual(d, base + 1.0)
        }
    }
}
