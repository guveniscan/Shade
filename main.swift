import Cocoa
import ServiceManagement
import Carbon.HIToolbox
import CoreAudio
import AudioToolbox

/// Main volume of the default output device, via Core Audio (same approach as mic-duck).
enum Volume {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func outputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func get(_ device: AudioDeviceID) -> Float32? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr ? vol : nil
    }

    static func set(_ device: AudioDeviceID, _ vol: Float32) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var v = vol
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

/// Which app, and which browser tab, is making sound.
enum Playback {
    /// Maps a helper process to the app it works for, e.g. Safari's WebKit.GPU to Safari.
    private static let responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }

    /// Apps currently playing audio; nil where Core Audio can't tell (before macOS 14.4).
    static func apps() -> Set<pid_t>? {
        guard #available(macOS 14.4, *) else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        var pids = Set<pid_t>()
        for id in ids {
            var running: UInt32 = 0, pid: pid_t = 0, s = UInt32(4)
            addr.mSelector = kAudioProcessPropertyIsRunningOutput
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            addr.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &s, &pid) == noErr else { continue }
            pids.insert(responsible?(pid) ?? pid)
        }
        return pids
    }

    /// Whether a window has a tab showing a speaker icon; nil if it has no tabs we can read.
    /// Goes by structure, not labels, which are localized: Safari gives a tab a button only while it plays,
    /// and Chromium browsers add one next to the close button.
    static func hasAudibleTab(_ window: AXUIElement) -> Bool? {
        var tabs: [AXUIElement] = []
        collectTabs(window, depth: 0, into: &tabs)
        guard !tabs.isEmpty else { return nil }
        return tabs.contains { tab in
            children(tab).contains {
                attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                    && !(attribute($0, "AXDOMClassList") as? [String] ?? []).contains("TabCloseButton")
            }
        }
    }

    private static func collectTabs(_ e: AXUIElement, depth: Int, into tabs: inout [AXUIElement]) {
        guard depth < 20, attribute(e, kAXRoleAttribute) as? String != "AXWebArea" else { return }
        if attribute(e, kAXSubroleAttribute) as? String == "AXTabButton" { return tabs.append(e) }
        children(e).forEach { collectTabs($0, depth: depth + 1, into: &tabs) }
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &ref) == .success ? ref : nil
    }
}

// A borderless, click-through black window covering one screen.
final class Overlay: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .black
        alphaValue = 0
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var visible = false
    private let defaults = UserDefaults.standard
    private let animationDuration = 0.3

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var intensity: Double {
        get { defaults.object(forKey: "intensity") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "intensity") }
    }
    private var centerOnEnable: Bool {
        get { defaults.object(forKey: "centerOnEnable") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "centerOnEnable") }
    }

    /// Volume while shaded, in percent; nil leaves the volume alone (the default).
    private var duckLevel: Double? {
        get { defaults.object(forKey: "duckLevel") as? Double }
        set { defaults.set(newValue, forKey: "duckLevel") }
    }
    private let duckLevels: [(title: String, percent: Double?)] = [
        ("Off", nil), ("Mute", 0), ("0.5%", 0.5), ("1%", 1), ("2%", 2), ("5%", 5), ("10%", 10), ("20%", 20),
    ]

    func applicationWillTerminate(_ notification: Notification) {
        restoreVolume()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildOverlays()
        buildMenu()
        registerHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(tick),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Polling catches window switches inside the same app and new windows.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: Overlays

    private func buildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        visible = false
    }

    @objc private func screensChanged() {
        buildOverlays()
        tick()
    }

    /// Topmost normal-level window of the frontmost app.
    private func frontWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) > 50, (b["Height"] ?? 0) > 50,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return id
        }
        return nil
    }

    /// Whether a window still exists (on any Space, minimized or not).
    private func windowExists(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return !list.isEmpty
    }

    /// The app's main window via Accessibility; sheets and panels don't change it. Nil without permission.
    private func mainWindow(of pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMainWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Remembers the front window as the one shade is focused on.
    private func focusFrontWindow() {
        focusedWindow = frontWindowID()
        focusedApp = focusedWindow == nil ? nil : NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusedAXWindow = focusedApp.flatMap(mainWindow(of:))
        focusedFrame = focusedAXWindow.flatMap(frame(of:))
    }

    /// The focused window was closed, its app quit, or the user picked another window or app.
    private func focusLost() -> Bool {
        guard let w = focusedWindow, let pid = focusedApp else { return false }
        // Our own menu being open doesn't count.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           front != getpid(), front != pid { return true }
        let main = mainWindow(of: pid)
        if windowExists(w), let ax = focusedAXWindow, let main, CFEqual(ax, main) {
            focusedFrame = frame(of: ax) ?? focusedFrame
            return false
        }
        if switchedTab(to: main) { focusFrontWindow(); return false }
        return !windowExists(w) || (focusedAXWindow != nil && main != nil)
    }

    /// Native tabs (Terminal, Finder, …) are separate windows stacked in one spot, so picking or closing a tab
    /// swaps the main window. Counts as a tab switch when the old window went away or off screen and the new
    /// one sits exactly where it was.
    private func switchedTab(to main: AXUIElement?) -> Bool {
        guard let w = focusedWindow, !windowIsOnScreen(w), let main, let old = focusedFrame,
              let new = frame(of: main) else { return false }
        return abs(new.minX - old.minX) < 2 && abs(new.minY - old.minY) < 2
            && abs(new.width - old.width) < 2 && abs(new.height - old.height) < 2
    }

    private func windowIsOnScreen(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return list.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    @objc private func tick() {
        // Leave shade mode, like Esc, once the focus moves off the focused window.
        if enabled, focusLost() { return toggleEnabled() }
        guard enabled, let id = frontWindowID() else { return fade(to: 0) }
        if focusedWindow == nil { focusFrontWindow() }
        for o in overlays { o.order(.below, relativeTo: Int(id)) }
        fade(to: intensity)
    }

    private func fade(to target: Double) {
        let show = target > 0
        if show == visible && (!show || overlays.first?.alphaValue == CGFloat(target)) { return }
        visible = show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            overlays.forEach { $0.animator().alphaValue = CGFloat(target) }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Shade")
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "r")
        toggleItem.keyEquivalentModifierMask = [.command, .control]
        toggleItem.state = enabled ? .on : .off
        menu.addItem(toggleItem)

        let sub = NSMenu()
        sub.addItem(sliderItem())
        let intensityItem = NSMenuItem(title: "Intensity", action: nil, keyEquivalent: "")
        intensityItem.submenu = sub
        menu.addItem(intensityItem)

        let center = NSMenuItem(title: "Center Window on Enable", action: #selector(toggleCenter(_:)), keyEquivalent: "")
        center.state = centerOnEnable ? .on : .off
        menu.addItem(center)

        let volumeMenu = NSMenu()
        for (i, l) in duckLevels.enumerated() {
            let mi = NSMenuItem(title: l.title, action: #selector(chooseDuckLevel(_:)), keyEquivalent: "")
            mi.tag = i
            mi.state = l.percent == duckLevel ? .on : .off
            volumeMenu.addItem(mi)
            if i == 0 { volumeMenu.addItem(.separator()) }
        }
        volumeMenu.items.forEach { $0.target = self }
        let volumeItem = NSMenuItem(title: "Lower Volume While Shaded", action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Shade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        sub.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private var toggleItem: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?
    private var escHotKeyRef: EventHotKeyRef?
    /// The window we centered, where it was before, and where we put it.
    private var moved: (window: AXUIElement, from: CGPoint, to: CGPoint)?
    private var moveTimer: Timer?
    /// The window shade is focused on, its app, and its Accessibility element.
    private var focusedWindow: CGWindowID?
    private var focusedApp: pid_t?
    private var focusedAXWindow: AXUIElement?
    /// Where the focused window last was, to recognize a tab of it taking its place.
    private var focusedFrame: CGRect?
    /// Set while the volume is lowered: the output device, its original volume, and the level we set.
    private var ducked: (device: AudioDeviceID, original: Float32, applied: Float32)?

    @objc fileprivate func toggleEnabled() {
        // Without Accessibility, ask first instead of dimming the screen around System Settings.
        if !enabled && centerOnEnable && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        enabled.toggle()
        toggleItem.state = enabled ? .on : .off
        if enabled { focusFrontWindow() } else { focusedWindow = nil; focusedApp = nil; focusedAXWindow = nil; focusedFrame = nil }
        if enabled { if centerOnEnable { centerFrontWindow() } } else { restoreWindow() }
        if enabled { duckVolume() } else { restoreVolume() }
        updateEscHotKey()
        tick()
    }

    /// Whether the sound comes from the focused window, so ducking it would turn down what the user is watching.
    /// Before macOS 14.4 it can't see who is playing and says no, so the volume is lowered as before.
    private func focusedWindowIsPlaying() -> Bool {
        guard let pid = focusedApp, Playback.apps()?.contains(pid) == true else { return false }
        var ref: CFTypeRef?
        let windows = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &ref) == .success
            ? (ref as? [AXUIElement] ?? []) : []
        // With one window, or without tabs to look at, the app playing is the window playing.
        guard windows.count > 1, let window = focusedAXWindow else { return true }
        return Playback.hasAudibleTab(window) ?? true
    }

    /// Lowers the output volume to the chosen level, never raising it.
    /// Skipped when the focused window is the one making sound.
    private func duckVolume() {
        guard let percent = duckLevel, !focusedWindowIsPlaying(),
              let out = Volume.outputDevice(), let current = Volume.get(out) else { return }
        let target = min(ducked?.original ?? current, Float32(percent / 100))
        ducked = (out, ducked?.original ?? current, target)
        Volume.set(out, target)
    }

    /// Puts the volume back, unless the user changed it while shaded.
    private func restoreVolume() {
        guard let d = ducked else { return }
        ducked = nil
        if let now = Volume.get(d.device), abs(now - d.applied) > 0.01 { return }
        Volume.set(d.device, d.original)
    }

    @objc private func chooseDuckLevel(_ sender: NSMenuItem) {
        duckLevel = duckLevels[sender.tag].percent
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
        guard enabled else { return }
        // Apply right away while shaded, unless the user has set the volume by hand since.
        if let d = ducked, let now = Volume.get(d.device), abs(now - d.applied) > 0.01 { return }
        if duckLevel == nil { restoreVolume() } else { duckVolume() }
    }

    /// Esc leaves shade mode, like exiting full screen.
    fileprivate func escPressed() {
        if enabled { toggleEnabled() }
    }

    @objc private func toggleCenter(_ sender: NSMenuItem) {
        centerOnEnable.toggle()
        sender.state = centerOnEnable ? .on : .off
        if centerOnEnable { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    }

    /// Moves the frontmost app's focused window to the center of its screen.
    /// Needs Accessibility permission, which toggleEnabled asks for before turning on.
    private func centerFrontWindow() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return }
        let window = ref as! AXUIElement

        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return }

        // AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let cocoaRect = NSRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.max {
            $0.frame.intersection(cocoaRect).width * $0.frame.intersection(cocoaRect).height <
            $1.frame.intersection(cocoaRect).width * $1.frame.intersection(cocoaRect).height
        } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }

        var target = CGPoint(x: vf.midX - size.width / 2,
                             y: primaryHeight - vf.maxY + max(0, (vf.height - size.height) / 2))
        target.x = max(vf.minX, target.x)
        moved = (window, pos, target)
        animate(window, from: pos, to: target) { [weak self] in
            // Read back where the app actually put it; some windows get nudged.
            var ref: CFTypeRef?
            var placed = target
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success {
                AXValueGetValue(ref as! AXValue, .cgPoint, &placed)
            }
            self?.moved?.to = placed
        }
    }

    /// Slides a window between two points with an ease-in-out curve, cancelling any slide in progress.
    private func animate(_ window: AXUIElement, from: CGPoint, to: CGPoint, completion: (() -> Void)? = nil) {
        moveTimer?.invalidate()
        let start = Date()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(start) / self.animationDuration)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            var p = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
            if let value = AXValueCreate(.cgPoint, &p) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
            if t >= 1 {
                timer.invalidate()
                self.moveTimer = nil
                completion?()
            }
        }
        RunLoop.main.add(moveTimer!, forMode: .common)
    }

    /// Puts the centered window back where it was, unless the user has moved it since.
    private func restoreWindow() {
        guard let m = moved else { return }
        moved = nil
        var ref: CFTypeRef?
        var current = CGPoint.zero
        let midSlide = moveTimer != nil
        guard AXUIElementCopyAttributeValue(m.window, kAXPositionAttribute as CFString, &ref) == .success,
              AXValueGetValue(ref as! AXValue, .cgPoint, &current),
              midSlide || (abs(current.x - m.to.x) < 2 && abs(current.y - m.to.y) < 2) else { return }
        animate(m.window, from: current, to: m.from)
    }

    /// Global Cmd+Ctrl+R hotkey via Carbon (works without Accessibility permission).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { hk.id == 2 ? me.escPressed() : me.toggleEnabled() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x5348_4445), id: 1) // 'SHDE'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        updateEscHotKey()
    }

    /// Esc is grabbed only while shade is on, so it works normally the rest of the time.
    private func updateEscHotKey() {
        if enabled, escHotKeyRef == nil {
            let id = EventHotKeyID(signature: OSType(0x5348_4445), id: 2)
            RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escHotKeyRef)
        } else if !enabled, let ref = escHotKeyRef {
            UnregisterEventHotKey(ref)
            escHotKeyRef = nil
        }
    }

    private var slider: NSSlider!
    private var sliderLabel: NSTextField!

    /// Menu row with a continuous slider for fine-grained intensity.
    private func sliderItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        slider = NSSlider(value: intensity * 100, minValue: 5, maxValue: 95,
                          target: self, action: #selector(sliderMoved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 5, width: 150, height: 20)
        sliderLabel = NSTextField(labelWithString: "")
        sliderLabel.frame = NSRect(x: 170, y: 7, width: 44, height: 16)
        sliderLabel.alignment = .right
        sliderLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.addSubview(slider)
        view.addSubview(sliderLabel)
        updateSliderLabel()
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func updateSliderLabel() {
        sliderLabel.stringValue = "\(Int((intensity * 100).rounded()))%"
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        intensity = (sender.doubleValue).rounded() / 100
        updateSliderLabel()
        // The poll timer pauses while the menu is open, so apply the new level directly.
        if visible { overlays.forEach { $0.alphaValue = CGFloat(intensity) } }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
