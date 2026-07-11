// PeripheralCore, the ACCEPTOR (peripheral) decision state machine, lifted out of the CoreBluetooth
// `Peripheral` delegate for the same reason CentralCore was: a `CBPeripheralManager` / `CBATTRequest`
// cannot be constructed in a unit test, so the publish/advertise/self-heal state and the PSM-read
// response builder were 0% covered. This core holds the identical decision logic keyed on plain values
// (Bool / UInt16 / Data), driven directly by tests; the `Peripheral` shell (BleBearer+Radio.swift) does
// the CoreBluetooth I/O and executes the effects verbatim, so the split is behavior-preserving.
//
// The F-12 self-heal timer, the iOS advert-cycle DispatchSourceTimer, and the CBL2CAPChannel handoff stay
// in the shell (they are radio/timer machinery). The DECISIONS they drive, when to publish vs advertise,
// whether to suppress advertising, the ~5s-service / ~2s-beacon advert cadence, the read response bytes ,
// live here and are unit-tested.

import Foundation
import HopContract   // log

/// One CoreBluetooth action the `Peripheral` shell performs. Equatable so tests assert the list directly.
enum PeripheralEffect: Equatable {
    case powerOff                    // SPEC R11: onPowerOff -> the bearer closes all links
    case addServiceAndPublish        // add the GATT service, then publishL2CAPChannel(withEncryption: false)
    case publishL2CAP                // F-12 self-heal: (re)publish the L2CAP channel
    case startAdvertising            // start/restart the service-UUID advert
    case advertisingSuppressed       // central-only host: publish-only, never advertise (log only)
    case startAdvertisingAfterPublish// after a successful publish: iOS runs the advert cycle, others the plain advert
}

/// The pure Peripheral decision engine. Owns exactly the acceptor state that carries a decision
/// (`published`/`psm`/`stopped`) plus the iOS advert-cycle counter (platform-neutral arithmetic, so it is
/// testable on macOS even though the timer that drives it is iOS-only). The `CBPeripheralManager` handle,
/// the self-heal timer, and the advert DispatchSourceTimer stay in the shell.
final class PeripheralCore {
    private let myId: Data
    private let suppressAdvertising: Bool
    private let noAdvEnv: () -> Bool   // HOPLAB_NO_ADV diagnostic (central-only, publish-but-don't-advertise)

    private(set) var published = false
    private(set) var psm: UInt16 = 0
    private(set) var stopped = false

    // iOS advert cycle bookkeeping (see advCycleStep). Plain Int/Bool so the decision is testable on macOS.
    private var advCounter = 0
    private var advBeaconNow = false

    init(myId: Data, suppressAdvertising: Bool, noAdvEnv: @escaping () -> Bool = { ProcessInfo.processInfo.environment["HOPLAB_NO_ADV"] != nil }) {
        self.myId = myId
        self.suppressAdvertising = suppressAdvertising
        self.noAdvEnv = noAdvEnv
    }

    // MARK: manager state (peripheralManagerDidUpdateState)

    /// poweredOff -> power-off + mark unpublished (SPEC R11); poweredOn -> add the GATT service and publish
    /// the L2CAP channel; other states -> nothing.
    func stateChanged(isPoweredOn: Bool, isPoweredOff: Bool) -> [PeripheralEffect] {
        if isPoweredOff { published = false; return [.powerOff] }
        guard isPoweredOn else { return [] }
        return [.addServiceAndPublish]
    }

    // MARK: publish result (didPublishL2CAPChannel)

    /// The publish completed. On error, stay unpublished so the F-12 self-heal loop retries. On success,
    /// record the PSM and either suppress advertising (central-only host) or advertise.
    func publishResult(psm: UInt16, failed: Bool) -> [PeripheralEffect] {
        if failed { return [] }                                            // `published` stays false; self-heal retries
        self.psm = psm
        published = true
        if suppressAdvertising || noAdvEnv() { return [.advertisingSuppressed] }
        return [.startAdvertisingAfterPublish]
    }

    // MARK: F-12 self-heal (ble-lab SPEC §7.1)

    /// Periodic self-heal decision: if powered on and not stopped (and not the no-advert diagnostic),
    /// republish the L2CAP channel when unpublished, else restart advertising when not advertising.
    func selfHeal(isPoweredOn: Bool, isAdvertising: Bool) -> [PeripheralEffect] {
        guard !stopped, isPoweredOn else { return [] }
        if noAdvEnv() { return [] }
        if !published { return [.publishL2CAP] }
        if !isAdvertising { return [.startAdvertising] }
        return []
    }

    // MARK: PSM read response (didReceiveRead)

    /// SPEC §3.1: the endpoint characteristic value, [2B PSM big-endian][16B nodeId]. Pure; the shell sets
    /// it on the CBATTRequest and responds .success.
    func readResponse() -> Data {
        var v = Data([UInt8(psm >> 8), UInt8(psm & 0xff)])
        v.append(myId)
        return v
    }

    // MARK: iOS advert cycle (startAdvertisingCycle timer body)

    /// Advance the ~7s advert cycle one 1 Hz tick: ~5s service-UUID advert, ~2s iBeacon advert. Returns
    /// whether the advert form must change this tick and, if so, which form (beacon vs service-UUID). The
    /// two forms are mutually exclusive on iOS, so the shell only re-applies advertising when `apply` is true.
    func advCycleStep() -> (apply: Bool, beacon: Bool) {
        advCounter = (advCounter + 1) % 7
        let wantBeacon = advCounter >= 5   // ~2s beacon out of every 7s
        if wantBeacon != advBeaconNow {
            advBeaconNow = wantBeacon
            return (true, wantBeacon)
        }
        return (false, advBeaconNow)
    }

    // MARK: state restoration + stop

    /// SPEC R10 willRestoreState: reset `published` so the self-heal loop republishes if the restored
    /// channel is not actually live.
    func willRestore() { published = false }

    /// stop(): mark stopped so self-heal no-ops. Returns whether we were published (the shell unpublishes
    /// the PSM iff so), then clears `published`.
    func markStopped() -> Bool {
        stopped = true
        let wasPublished = published
        published = false
        return wasPublished
    }
}
