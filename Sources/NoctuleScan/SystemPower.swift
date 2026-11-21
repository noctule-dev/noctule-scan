// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import IOKit
import IOKit.pwr_mgt

/// What the app does with the system's power messages (Review Focus 1, design §8.1): the Mac
/// doesn't sleep until every session has stopped (`PSI,0`, TEARDOWN), or until a deadline.
///
/// - `canSleep` (the system asks, idle sleep): allowed at once. Nothing stops yet, because the
///   sleep can still be vetoed by another process and then no `willSleep` follows.
/// - `willSleep`: `suspend` starts at once, and `allow` is called when it finishes or when
///   `deadline` passes, whichever is first, once. It never waits for a resume still in flight
///   (a wake's resume can sit in the cooldown wait, up to 120 s, for minutes; a sleep queued behind it
///   would hit the deadline before suspending, and the Mac could sleep with a session that
///   connects during the hold). That resume's task is cancelled, and the session's own
///   `suspend()` interrupts its start, so it doesn't reconnect; the next wake starts it again.
/// - `wake` (a full wake: `NSWorkspace.didWakeNotification`, see `AppDelegate`): `resume` runs
///   after the latest suspend has finished, unless a sleep comes first. This is the only wake
///   signal the app uses; IOKit's has-powered-on also arrives on dark wakes (Power Nap) and is
///   ignored.
///
/// No IOKit here, so tests drive it directly; `SystemPowerObserver` feeds it the real sleep
/// messages.
@MainActor
final class PowerGate {
    enum Event: Equatable {
        case canSleep, willSleep, wake, other
    }

    // `iokit_common_msg(...)` macros don't import into Swift: sys_iokit | sub_iokit_common | code.
    static let canSystemSleepMessage: UInt32 = 0xE000_0270
    static let systemWillSleepMessage: UInt32 = 0xE000_0280

    /// IOKit messages map to sleep events only. Has-powered-on (`0xE0000300`) and the rest are
    /// `.other`: wake comes from `NSWorkspace` (full wakes only).
    static func event(for messageType: UInt32) -> Event {
        switch messageType {
        case canSystemSleepMessage: .canSleep
        case systemWillSleepMessage: .willSleep
        default: .other
        }
    }

    let deadline: Duration
    private let suspend: @MainActor () async -> Void
    private let resume: @MainActor () async -> Void
    /// The latest suspend; a wake's resume runs after it.
    private var lastSuspend: Task<Void, Never>?
    /// A wake's resume that may still be running (cancelled by the next sleep).
    private var pendingResume: Task<Void, Never>?

    init(deadline: Duration = .seconds(20),
         suspend: @escaping @MainActor () async -> Void,
         resume: @escaping @MainActor () async -> Void) {
        self.deadline = deadline
        self.suspend = suspend
        self.resume = resume
    }

    /// Handles one message. `allow` is called exactly once for `canSleep` and `willSleep` (it
    /// answers the system: `IOAllowPowerChange`), and never for the others.
    func handle(_ event: Event, allow: @escaping @MainActor () -> Void) {
        switch event {
        case .canSleep:
            allow()
        case .willSleep:
            let once = Once(allow)
            pendingResume?.cancel()
            pendingResume = nil
            let suspend = suspend
            lastSuspend = Task { @MainActor in
                await suspend()
                once.fire()
            }
            Task { @MainActor [deadline] in
                try? await Task.sleep(for: deadline)
                once.fire()
            }
        case .wake:
            let previous = lastSuspend
            let resume = resume
            pendingResume = Task { @MainActor in
                await previous?.value
                guard !Task.isCancelled else { return }
                await resume()
            }
        case .other:
            break
        }
    }

    @MainActor private final class Once {
        private var action: (@MainActor () -> Void)?
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func fire() {
            let action = action
            self.action = nil
            action?()
        }
    }
}

/// `IORegisterForSystemPower` on the main run loop, feeding a `PowerGate`. The callback runs on
/// the main thread (the notification port's source is on the main run loop). `stop()` deregisters
/// (on quit).
@MainActor
final class SystemPowerObserver {
    private let gate: PowerGate
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    init(gate: PowerGate) { self.gate = gate }

    /// False if registration failed (the app then runs without the sleep hold).
    @discardableResult
    func start() -> Bool {
        guard rootPort == 0 else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            MainActor.assumeIsolated {
                let observer = Unmanaged<SystemPowerObserver>.fromOpaque(refcon).takeUnretainedValue()
                observer.received(messageType, Int(bitPattern: messageArgument))
            }
        }, &notifier)
        guard rootPort != 0, let port else {
            rootPort = 0
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        return true
    }

    func stop() {
        guard rootPort != 0 else { return }
        if let port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                                  .commonModes)
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let port { IONotificationPortDestroy(port) }
        port = nil
        rootPort = 0
        notifier = 0
    }

    private func received(_ messageType: UInt32, _ argument: Int) {
        let rootPort = rootPort
        gate.handle(PowerGate.event(for: messageType)) { [weak self] in
            // Answer only while still registered (after `stop()` the port is closed).
            guard self?.rootPort == rootPort, rootPort != 0 else { return }
            IOAllowPowerChange(rootPort, argument)
        }
    }
}
#endif
