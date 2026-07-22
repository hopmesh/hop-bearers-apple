// BeaconWake, the BLE bearer's OWN background-wake monitor (iOS).
//
// An iBeacon region monitor: when a peer's iBeacon (emitted by a nearby Android, byte-matched UUID)
// crosses our region boundary, iOS relaunches/wakes this app EVEN AFTER FORCE-QUIT and fires the
// region callback, which pokes the BLE Central back into scanning so the L2CAP link re-forms
// (BACKGROUND.md Layer C). This is the only background path that re-links a terminated app.
//
// This is BLE-transport machinery, so it lives in HopBearerBle, NOT in the app/facade and NOT in
// hop-core (bearers are byte senders; the wake is just how the BLE radio gets a chance to re-link).
// Owned and started by BleBearer; on a region enter / inside-determination it calls `onWake`, which
// BleBearer routes straight to Central.wake().
//
// iOS-only: CLBeaconRegion monitoring is unavailable on macOS, so the CLI/hopmac builds skip this
// file entirely (the bearer's #if os(iOS) guards leave `wake()` reachable via the AppDelegate path).

import Foundation

/// The iBeacon UUID THIS app monitors for background wake, and the SINGLE SOURCE OF TRUTH for the
/// value across the shared bearer, the app drivers, and the Android emitter (F-40). It MUST byte-match
/// what Android emits (bearer-ble BEACON_UUID), a mismatch means iOS never sees the beacon and a
/// force-quit app never wakes (the historic F0900BEA-vs-7ED7BEAC silent bug). Kept OUTSIDE the
/// `#if os(iOS)` guard (it's a plain UUID, platform-neutral) so macOS builds, e.g. the hopmac test
/// tool, can reference it too instead of redefining the literal.
public let BEACON_UUID = UUID(uuidString: "7ED7BEAC-3C2A-4F19-9B8E-1A2B3C4D5E6F")!

#if os(iOS)
import CoreLocation

/// Region monitor that wakes the BLE bearer. On a region enter / inside-state it invokes `onWake`.
final class BeaconWake: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private let region = CLBeaconRegion(uuid: BEACON_UUID, identifier: "hop")
    private let onWake: (String) -> Void

    init(onWake: @escaping (String) -> Void) {
        self.onWake = onWake
        super.init()
        location.delegate = self
        region.notifyOnEntry = true
        region.notifyEntryStateOnDisplay = true   // re-fire on display-on so a quiet boundary still wakes us
    }

    /// Request Always-authorization (needed for background region monitoring) and begin monitoring.
    /// Idempotent, safe to call on every BleBearer.start() / cold-launch wake.
    func start() {
        location.requestAlwaysAuthorization()
        if location.authorizationStatus == .authorizedAlways {
            location.startMonitoring(for: region)
        }
        // Otherwise we wait for the authorization-change callback below to start monitoring.
    }

    func stop() {
        location.stopMonitoring(for: region)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onWake("region-enter")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        if state == .inside { onWake("region-inside") }
    }
}
#endif
