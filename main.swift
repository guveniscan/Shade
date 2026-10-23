import Cocoa
import ServiceManagement
import Carbon.HIToolbox

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

    @objc private func tick() {
        guard enabled, let id = frontWindowID() else { return fade(to: 0) }
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

    @objc fileprivate func toggleEnabled() {
        // Without Accessibility, ask first instead of dimming the screen around System Settings.
        if !enabled && centerOnEnable && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        enabled.toggle()
        toggleItem.state = enabled ? .on : .off
        if enabled { if centerOnEnable { centerFrontWindow() } } else { restoreWindow() }
        updateEscHotKey()
        tick()
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
