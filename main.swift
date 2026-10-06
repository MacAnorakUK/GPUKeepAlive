// GPUKeepAlive — menu bar utility that wakes the GPU with tiny Metal compute
// workloads while you scroll on a high-refresh external display, so GPU DVFS
// doesn't sit at its lowest clock and cause dropped frames.

import AppKit
import Metal
import ServiceManagement

// MARK: - GPU workload

private let kernelSource = """
#include <metal_stdlib>
using namespace metal;

kernel void spin(device float *buf      [[buffer(0)]],
                 constant uint &iters   [[buffer(1)]],
                 uint id [[thread_position_in_grid]]) {
    float v = buf[id];
    for (uint i = 0; i < iters; i++) {
        v = fma(v, 1.0000001f, 0.0000001f);
    }
    buf[id] = v;   // write back so the loop isn't optimised away
}
"""

/// All mutable state lives on `workQueue`; public methods just hop onto it.
final class GPUPinger {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let threadCount = 65_536
    private let inFlight = DispatchSemaphore(value: 2)   // never queue more than 2 frames of work
    private let workQueue = DispatchQueue(label: "gpu-keepalive", qos: .userInteractive)

    private var timer: DispatchSourceTimer?
    private var iterations: UInt32 = 2_000
    private var hz: Double = 120
    private var activeUntil: DispatchTime = .now()
    private var alwaysOn = false
    let deviceName: String

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: kernelSource, options: nil),
              let fn = library.makeFunction(name: "spin"),
              let pipeline = try? device.makeComputePipelineState(function: fn),
              let buffer = device.makeBuffer(length: 65_536 * MemoryLayout<Float>.stride,
                                             options: .storageModePrivate)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
        self.deviceName = device.name
    }

    func configure(iterations: UInt32, hz: Double) {
        workQueue.async {
            self.iterations = iterations
            if self.hz != hz {
                self.hz = hz
                if self.timer != nil { self.startTimer() }
            }
        }
    }

    /// Keep the GPU busy for `seconds` from now. Called on every scroll event.
    func poke(for seconds: Double) {
        workQueue.async {
            self.activeUntil = .now() + seconds
            if self.timer == nil { self.startTimer() }
        }
    }

    func setAlwaysOn(_ on: Bool) {
        workQueue.async {
            self.alwaysOn = on
            if on && self.timer == nil { self.startTimer() }
        }
    }

    func stop() {
        workQueue.async {
            self.alwaysOn = false
            self.stopTimer()
        }
    }

    // workQueue only
    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now(),
                   repeating: .nanoseconds(Int(1_000_000_000 / hz)),
                   leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if !alwaysOn && DispatchTime.now() > activeUntil {
            stopTimer()   // scrolling stopped: go back to idle
            return
        }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { inFlight.signal(); return }

        enc.setComputePipelineState(pipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        var it = iterations
        enc.setBytes(&it, length: MemoryLayout<UInt32>.size, index: 1)
        let tg = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: threadCount, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        enc.endEncoding()

        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
    }
}

// MARK: - Menu bar app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pinger: GPUPinger!
    private var target: NSScreen?
    private var scrollMonitor: Any?
    private var screensAsleep = false
    private var armed = false
    private let defaults = UserDefaults.standard

    private let idleDelay = 0.9   // seconds after the last scroll event before going idle
    private let strengths: [(name: String, iters: UInt32)] = [
        ("Gentle", 2_000), ("Medium", 8_000), ("Strong", 20_000), ("Max", 50_000),
    ]

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var require5K: Bool {
        get { defaults.object(forKey: "require5K") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "require5K") }
    }
    private var alwaysOn: Bool {
        get { defaults.object(forKey: "alwaysOn") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "alwaysOn") }
    }
    private var strength: Int {
        get { min(defaults.object(forKey: "strength") as? Int ?? 0, strengths.count - 1) }
        set { defaults.set(newValue, forKey: "strength") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let p = GPUPinger() else {
            let alert = NSAlert()
            alert.messageText = "GPUKeepAlive couldn't initialise Metal."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        pinger = p
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        NotificationCenter.default.addObserver(
            self, selector: #selector(update),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        update()
    }

    // MARK: Display detection

    /// Widest pixel resolution the display supports (its native panel width).
    private func nativePixelWidth(_ id: CGDirectDisplayID) -> Int {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return 0 }
        return modes.map { $0.pixelWidth }.max() ?? 0
    }

    /// First external display running at >= 100 Hz (and 5K+ if required).
    private func qualifyingScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return false }
            guard CGDisplayIsBuiltin(id) == 0, screen.maximumFramesPerSecond >= 100 else { return false }
            return !require5K || nativePixelWidth(id) >= 5120
        }
    }

    // MARK: State

    @objc private func screensDidSleep() { screensAsleep = true; update() }
    @objc private func screensDidWake() { screensAsleep = false; update() }

    @objc private func update() {
        target = qualifyingScreen()
        armed = enabled && !screensAsleep && target != nil

        if armed, let target {
            pinger.configure(iterations: strengths[strength].iters,
                             hz: Double(target.maximumFramesPerSecond))
            pinger.setAlwaysOn(alwaysOn)
            if alwaysOn { removeScrollMonitor() } else { installScrollMonitor() }
        } else {
            removeScrollMonitor()
            pinger.stop()
        }
        rebuildMenu()
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScroll() }
        }
    }

    private func removeScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }

    private func handleScroll() {
        guard armed, let target, target.frame.contains(NSEvent.mouseLocation) else { return }
        pinger.poke(for: idleDelay)
    }

    // MARK: Menu

    private func rebuildMenu() {
        let image = NSImage(systemSymbolName: armed ? "bolt.fill" : "bolt.slash",
                            accessibilityDescription: "GPUKeepAlive")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()

        let status: String
        if let target, armed {
            let mode = alwaysOn ? "always on" : "wakes on scroll"
            status = "Armed — \(target.localizedName) @ \(target.maximumFramesPerSecond) Hz (\(mode))"
        } else if !enabled {
            status = "Paused"
        } else if screensAsleep {
            status = "Idle — displays asleep"
        } else {
            status = require5K ? "Idle — no 5K display at 100 Hz+" : "Idle — no external display at 100 Hz+"
        }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "GPU: \(pinger.deviceName)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
        toggle.state = enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        let strengthItem = NSMenuItem(title: "Strength", action: nil, keyEquivalent: "")
        let strengthMenu = NSMenu()
        for (i, level) in strengths.enumerated() {
            let item = NSMenuItem(title: level.name, action: #selector(setStrength(_:)), keyEquivalent: "")
            item.tag = i
            item.state = i == strength ? .on : .off
            item.target = self
            strengthMenu.addItem(item)
        }
        strengthItem.submenu = strengthMenu
        menu.addItem(strengthItem)

        let triggerItem = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for (i, name) in ["When Scrolling", "Always"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(setTrigger(_:)), keyEquivalent: "")
            item.tag = i
            item.state = (i == 1) == alwaysOn ? .on : .off
            item.target = self
            triggerMenu.addItem(item)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        let req = NSMenuItem(title: "Require 5K Display", action: #selector(toggleRequire5K), keyEquivalent: "")
        req.state = require5K ? .on : .off
        req.target = self
        menu.addItem(req)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() { enabled.toggle(); update() }
    @objc private func toggleRequire5K() { require5K.toggle(); update() }
    @objc private func setStrength(_ sender: NSMenuItem) { strength = sender.tag; update() }
    @objc private func setTrigger(_ sender: NSMenuItem) { alwaysOn = sender.tag == 1; update() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at Login failed: \(error)")
        }
        update()
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
