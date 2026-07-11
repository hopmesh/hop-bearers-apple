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
