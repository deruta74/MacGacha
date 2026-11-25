// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Network

/// Observes system policy only while the scheduler has work. No global input monitor or event tap.
@MainActor final class UpdateQueueEnvironment {
    private(set) var permitsNetwork = false
    private(set) var onAC: Bool?
    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var clockObservers: [NSObjectProtocol] = []
    private var onChange: (@MainActor () -> Void)?

    var idleSeconds: TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return 0 }
        defer { IOObjectRelease(service) }
        guard let idle = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return 0 }
        return idle.doubleValue / 1_000_000_000
    }

    nonisolated static func permitsTransfer(available: Bool, constrained: Bool) -> Bool {
        available && !constrained
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard pathMonitor == nil else { return }
        observePath()
        updatePower()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let environment = Unmanaged<UpdateQueueEnvironment>.fromOpaque(context).takeUnretainedValue()
                environment.updatePower()
                environment.onChange?()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        clockObservers = [NSNotification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pathMonitor != nil else { return }
                self.pathMonitor?.cancel()
                self.permitsNetwork = false
                self.observePath()
                self.updatePower()
                self.onChange?()
            }
        }
    }

    private func observePath() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let allowed = Self.permitsTransfer(available: path.status == .satisfied, constrained: path.isConstrained)
            DispatchQueue.main.async {
                guard let self, let monitor, self.pathMonitor === monitor else { return }
                self.permitsNetwork = allowed
                self.onChange?()
            }
        }
        monitor.start(queue: .main)
    }

    private func updatePower() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            onAC = nil
            return
        }
        onAC = (source as String) == kIOPMACPowerKey
    }

    func stop() {
        onChange = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers.removeAll()
        permitsNetwork = false
        onAC = nil
    }

    isolated deinit { stop() }
}


@MainActor protocol UpdateQueuePowerAsserting {
    func acquire(reason: String) -> Bool
    func release()
}

@MainActor final class SystemUpdateQueuePowerAssertion: UpdateQueuePowerAsserting {
    private var assertion: IOPMAssertionID?

    func acquire(reason: String) -> Bool {
        if assertion != nil { return true }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess else { return false }
        assertion = id
        return true
    }

    func release() {
        guard let assertion else { return }
        self.assertion = nil
        _ = IOPMAssertionRelease(assertion)
    }

    isolated deinit { release() }
}
