// BackgroundAssertion — apple-02(a): a UIApplication.beginBackgroundTask assertion that keeps the
// process alive for the OS grace window (~30 s) when it enters the background WHILE a BLE link is
// live/servicing. Without it, iOS can suspend the process the instant the user backgrounds the app,
// killing an in-flight L2CAP receive mid-frame (the socket read stops, the peer sees EOF, and the
// link is torn down before the inbound bundle finishes). The assertion buys the read enough runway to
// finish and gives the acceptor/state-restoration path a chance to keep the pipe.
//
// This is transport machinery (it exists to protect an in-flight BLE receive), so it lives in the BLE
// bearer next to the Link/watchdog it guards — NOT in the app. It is platform-abstracted so the macOS
// CLI/hopmac build (which cannot and need not take a UIKit assertion) compiles to a no-op.
//
// Concurrency: the public surface (begin/renew/end) is called only from the BLE bearer's executors
// (bleQueue / bleRunLoop) and serialized by an internal lock, so the UIKit token is never raced.

import Foundation
import HopContract   // log(_:_:)

#if canImport(UIKit)
import UIKit

/// Holds at most one live UIApplication background-task assertion. `begin()` takes one if none is held
/// and (re)arms an internal safety timer that ends it after `maxHoldS` even if the caller forgets, so a
/// bug can never strand the assertion (which would let iOS watchdog-kill us for over-holding). Ending is
/// idempotent. All UIApplication calls are marshalled to the main thread as UIKit requires.
final class BackgroundAssertion {
    private let lock = NSLock()
    private var taskId: UIBackgroundTaskIdentifier = .invalid
    private var expiry: DispatchWorkItem?
    /// Cap our self-held window well under the OS grace (~30 s) so we voluntarily end before iOS would
    /// force-expire us (a forced expiration risks a watchdog strike). 20 s is ample to finish a receive.
    private let maxHoldS: Double

    init(maxHoldS: Double = 20.0) { self.maxHoldS = maxHoldS }

    /// Take (or renew) the assertion. Safe to call repeatedly (e.g. on every backgrounding or on each
    /// inbound frame while backgrounded): it holds ONE token and just pushes the safety expiry out.
    func begin(_ reason: String) {
        lock.lock()
        let alreadyHeld = taskId != .invalid
        lock.unlock()
        onMain {
            self.lock.lock()
            if self.taskId == .invalid {
                self.taskId = UIApplication.shared.beginBackgroundTask(withName: "hop.ble.\(reason)") {
                    // OS is about to reclaim the window: end cleanly so we don't get force-killed.
                    self.end("os-expiration")
                }
                if self.taskId != .invalid {
                    log("STATE", "bg-assertion begin (\(reason))")
                }
            }
            self.lock.unlock()
            self.armExpiry()
        }
        _ = alreadyHeld
    }

    /// Push the internal safety timer out by `maxHoldS`. Called on each serviced inbound frame so an
    /// actively-receiving link keeps its runway, bounded by the OS grace.
    func renew() { armExpiry() }

    /// Release the assertion now. Idempotent; safe from any thread.
    func end(_ reason: String) {
        onMain {
            self.lock.lock()
            self.expiry?.cancel(); self.expiry = nil
            let id = self.taskId
            self.taskId = .invalid
            self.lock.unlock()
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                log("STATE", "bg-assertion end (\(reason))")
            }
        }
    }

    private func armExpiry() {
        onMain {
            self.lock.lock()
            self.expiry?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.end("self-timeout") }
            self.expiry = w
            let held = self.taskId != .invalid
            self.lock.unlock()
            guard held else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.maxHoldS, execute: w)
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

#else

/// macOS (CLI/hopmac): no UIKit, no app-suspension model, so the assertion is a no-op. Keeps the BLE
/// bearer source identical across platforms with zero `#if` at the call sites.
final class BackgroundAssertion {
    init(maxHoldS: Double = 20.0) {}
    func begin(_ reason: String) {}
    func renew() {}
    func end(_ reason: String) {}
}

#endif
