// Real coverage for PeripheralCore, the ACCEPTOR (peripheral) decision state machine. A
// CBPeripheralManager / CBATTRequest cannot be constructed in a unit test, so before the seam refactor
// the publish/advertise/self-heal decisions and the PSM-read response builder were 0% covered. These
// tests drive the pure core directly, with the HOPLAB_NO_ADV diagnostic injected so both the "advertise"
// and "suppress" branches are reachable with no radio.

import XCTest
import Foundation
@testable import HopBearerBle

final class PeripheralCoreTests: XCTestCase {

    private let myId = Data([0x11, 0x22, 0x33, 0x44] + [UInt8](repeating: 0xAA, count: 12))

    private func makeCore(suppress: Bool = false, noAdvEnv: Bool = false) -> PeripheralCore {
        PeripheralCore(myId: myId, suppressAdvertising: suppress, noAdvEnv: { noAdvEnv })
    }

    // MARK: manager state

    func testStateChanged() {
        let c = makeCore()
        XCTAssertEqual(c.stateChanged(isPoweredOn: true, isPoweredOff: false), [.addServiceAndPublish])
        let c2 = makeCore()
        XCTAssertEqual(c2.stateChanged(isPoweredOn: false, isPoweredOff: true), [.powerOff])
        XCTAssertFalse(c2.published, "power-off marks us unpublished")
        XCTAssertEqual(makeCore().stateChanged(isPoweredOn: false, isPoweredOff: false), [])
    }

    // MARK: publish result

    func testPublishSuccessAdvertises() {
        let c = makeCore()
        XCTAssertEqual(c.publishResult(psm: 0x0080, failed: false), [.startAdvertisingAfterPublish])
        XCTAssertTrue(c.published)
        XCTAssertEqual(c.psm, 0x0080)
    }

    func testPublishFailureStaysUnpublished() {
        let c = makeCore()
        XCTAssertEqual(c.publishResult(psm: 0, failed: true), [])
        XCTAssertFalse(c.published)
    }

    func testPublishSuppressedByCentralOnlyHost() {
        let c = makeCore(suppress: true)
        XCTAssertEqual(c.publishResult(psm: 0x0080, failed: false), [.advertisingSuppressed])
        XCTAssertTrue(c.published, "still published (can accept) but never advertises")
    }

    func testPublishSuppressedByNoAdvEnv() {
        let c = makeCore(noAdvEnv: true)
        XCTAssertEqual(c.publishResult(psm: 0x0080, failed: false), [.advertisingSuppressed])
    }

    // MARK: F-12 self-heal

    func testSelfHealNoOpWhenStopped() {
        let c = makeCore()
        _ = c.markStopped()
        XCTAssertEqual(c.selfHeal(isPoweredOn: true, isAdvertising: false), [])
    }

    func testSelfHealNoOpWhenNotPoweredOn() {
        XCTAssertEqual(makeCore().selfHeal(isPoweredOn: false, isAdvertising: false), [])
    }

    func testSelfHealNoOpUnderNoAdvEnv() {
        XCTAssertEqual(makeCore(noAdvEnv: true).selfHeal(isPoweredOn: true, isAdvertising: false), [])
    }

    func testSelfHealRepublishesWhenUnpublished() {
        XCTAssertEqual(makeCore().selfHeal(isPoweredOn: true, isAdvertising: false), [.publishL2CAP])
    }

    func testSelfHealRestartsAdvertisingWhenPublishedButNotAdvertising() {
        let c = makeCore()
        _ = c.publishResult(psm: 0x0080, failed: false)   // published = true
        XCTAssertEqual(c.selfHeal(isPoweredOn: true, isAdvertising: false), [.startAdvertising])
    }

    func testSelfHealNoOpWhenPublishedAndAdvertising() {
        let c = makeCore()
        _ = c.publishResult(psm: 0x0080, failed: false)
        XCTAssertEqual(c.selfHeal(isPoweredOn: true, isAdvertising: true), [])
    }

    // MARK: PSM read response

    func testReadResponseIsPsmBigEndianThenNodeId() {
        let c = makeCore()
        _ = c.publishResult(psm: 0x0102, failed: false)
        XCTAssertEqual(c.readResponse(), Data([0x01, 0x02]) + myId)
    }

    // MARK: iOS advert cycle cadence

    func testAdvCycleTogglesBeaconAtTheRightTicks() {
        let c = makeCore()
        // ~5s service-UUID then ~2s beacon out of every 7s: apply only when the form flips.
        // counter after each step: 1,2,3,4,5,6,0 ; wantBeacon = counter >= 5.
        let expected: [(apply: Bool, beacon: Bool)] = [
            (false, false), // 1
            (false, false), // 2
            (false, false), // 3
            (false, false), // 4
            (true,  true),  // 5 -> flip to beacon
            (false, true),  // 6 -> stay beacon
            (true,  false), // 0 -> flip back to service-UUID
        ]
        for (i, e) in expected.enumerated() {
            let step = c.advCycleStep()
            XCTAssertEqual(step.apply, e.apply, "apply mismatch at tick \(i + 1)")
            XCTAssertEqual(step.beacon, e.beacon, "beacon mismatch at tick \(i + 1)")
        }
    }

    // MARK: state restoration + stop

    func testWillRestoreMarksUnpublished() {
        let c = makeCore()
        _ = c.publishResult(psm: 0x0080, failed: false)
        XCTAssertTrue(c.published)
        c.willRestore()
        XCTAssertFalse(c.published, "restore forces a republish via the self-heal loop")
    }

    func testMarkStoppedReportsPriorPublishAndClears() {
        let c = makeCore()
        _ = c.publishResult(psm: 0x0080, failed: false)
        XCTAssertTrue(c.markStopped(), "was published -> shell should unpublish the PSM")
        XCTAssertTrue(c.stopped)
        XCTAssertFalse(c.published)
        // A second stop reports not-published (idempotent).
        XCTAssertFalse(c.markStopped())
    }
}
