// The Apple half of the shared BLE dial-backoff schedule. Deliberately mirrors
// bearers/android/bearer-ble/src/test/java/sh/hopme/bearers/ble/BackoffTest.kt case for case, so the
// two platforms assert the SAME numbers rather than each asserting its own drift.
//
// Regression this locks in: Apple previously computed the next backoff from the time REMAINING on the
// current deadline (`max(deadline - now, 0.5) * 2`). A dial takes DIAL_TIMEOUT_S (12 s) to fail, which
// always outlasts a sub-2 s window, so by the time reconnect ran the deadline had already lapsed, the
// base fell to the 0.5 s floor, and the "next" backoff was ~1 s every single cycle. A peer that
// GATT-connects but never yields an L2CAP channel (a rotated MAC, a non-Hop advertiser) therefore
// re-dialed roughly every 13 s forever, monopolizing a dial slot and starving healthy peers. Android
// found and fixed this; Apple carried the broken version until now.
//
// tools/ble-backoff-parity.sh keeps the constants themselves in step across the two packages.

import XCTest
import Foundation
@testable import HopBearerBle

final class BackoffScheduleTests: XCTestCase {

    // Zero jitter so the schedule is exact; jitter is exercised separately.
    private func b(_ n: Int) -> Double { bleNextBackoffS(failCount: n, jitter: 0) }

    func testGrowsExponentiallyThenCaps() {
        XCTAssertEqual(b(1), 2.0, accuracy: 1e-9)    // 2s
        XCTAssertEqual(b(2), 4.0, accuracy: 1e-9)    // 4s
        XCTAssertEqual(b(3), 8.0, accuracy: 1e-9)    // 8s
        XCTAssertEqual(b(4), 16.0, accuracy: 1e-9)   // 16s
        XCTAssertEqual(b(5), BACKOFF_MAX_S, accuracy: 1e-9) // 32s clamped to the 30s normal cap
    }

    func testQuarantinesAChronicFailure() {
        // Past the threshold the cap lifts to ~2 min so a clearly-unreachable target stops
        // monopolizing a dial slot every cycle.
        XCTAssertGreaterThan(b(BACKOFF_QUARANTINE_AFTER), BACKOFF_MAX_S)
        XCTAssertEqual(b(20), BACKOFF_QUARANTINE_S, accuracy: 1e-9)
    }

    func testIsMonotonicNonDecreasing() {
        var prev = 0.0
        for n in 1...30 {
            let cur = b(n)
            XCTAssertGreaterThanOrEqual(cur, prev, "backoff must never shrink as failures accumulate (n=\(n))")
            prev = cur
        }
    }

    func testJitterIsAddedWithinBound() {
        XCTAssertEqual(bleNextBackoffS(failCount: 1, jitter: 0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(bleNextBackoffS(failCount: 1, jitter: 0.5), 2.5, accuracy: 1e-9)
        let j = bleNextBackoffS(failCount: 1, jitter: 1.0)
        XCTAssertTrue((2.0...3.0).contains(j))
    }

    func testClampsFloorFailureCount() {
        // Defensive: N < 1 is treated as the first failure, never a negative delay.
        XCTAssertEqual(bleNextBackoffS(failCount: 0, jitter: 0), b(1), accuracy: 1e-9)
        XCTAssertEqual(bleNextBackoffS(failCount: -5, jitter: 0), b(1), accuracy: 1e-9)
    }

    /// The schedule must match the canonical vectors both bearers are pinned to.
    func testMatchesCanonicalVectors() {
        // (fail_count, milliseconds) straight out of bearers/ble-backoff-vectors.json.
        let vectors: [(Int, Double)] = [
            (1, 2_000), (2, 4_000), (3, 8_000), (4, 16_000), (5, 30_000), (6, 64_000),
            (7, 120_000), (8, 120_000), (9, 120_000), (10, 120_000), (11, 120_000), (12, 120_000),
        ]
        for (n, ms) in vectors {
            XCTAssertEqual(b(n) * 1000.0, ms, accuracy: 1e-6, "vector fail_count=\(n)")
        }
    }
}
