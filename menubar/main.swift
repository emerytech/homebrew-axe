// Copyright © 2025 Taylor Emery. All rights reserved.
// Licensed under the Elastic License 2.0 — see LICENSE in the repository root.
// You may view and build this software, but you may not resell it or offer it
// as a competing product or service.

import AppKit
import Carbon.HIToolbox
import Darwin
import ServiceManagement

let appVersion = "2.4.1"

// MARK: - Private CoreGraphics Services (Space management)
// Resolved at runtime via dlsym — no link-time dependency on private symbols.
// These have been stable since macOS 10.8; used by Moom, Swish, etc.
// No Accessibility permission required.
private enum CGSSpace {
    typealias ConnFn = @convention(c) () -> UInt32
    typealias AddFn  = @convention(c) (UInt32, Int32) -> UInt64
    typealias ShowFn = @convention(c) (UInt32, CFArray) -> Int32

    /// Creates a new desktop Space and switches to it. Returns false if the
    /// private APIs are unavailable (caller should fall back to the manual HUD).
    static func createAndSwitch() -> Bool {
        // CoreGraphics is always loaded alongside AppKit
        guard let lib = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                Int32(RTLD_NOLOAD | RTLD_LAZY))
        else { return false }
        defer { dlclose(lib) }

        guard let pConn = dlsym(lib, "CGSMainConnection"),
              let pAdd  = dlsym(lib, "CGSAddSpace"),
              let pShow = dlsym(lib, "CGSShowSpaces")
        else { return false }

        let conn = unsafeBitCast(pConn, to: ConnFn.self)
        let add  = unsafeBitCast(pAdd,  to: AddFn.self)
        let show = unsafeBitCast(pShow, to: ShowFn.self)

        let cid = conn()
        guard cid != 0 else { return false }
        let sid = add(cid, 0)   // 0 = normal desktop Space
        guard sid != 0 else { return false }
        _ = show(cid, [NSNumber(value: sid)] as CFArray)
        return true
    }
}

// MARK: - Settings

enum KillMode: Int  { case graceful = 0, force = 1 }
enum UIStyle:  Int  { case spotlight = 0, popover = 1 }

struct AppSettings {
    private static let d = UserDefaults.standard

    static var killMode: KillMode {
        get { KillMode(rawValue: d.integer(forKey: "killMode")) ?? .graceful }
        set { d.set(newValue.rawValue, forKey: "killMode") }
    }
    // Seconds to wait before following up with SIGKILL (graceful mode only)
    static var gracePeriod: Double {
        get { d.object(forKey: "gracePeriod") == nil ? 2 : d.double(forKey: "gracePeriod") }
        set { d.set(newValue, forKey: "gracePeriod") }
    }
    // Show apps with non-regular activation policy (agents, helpers, etc.)
    static var showBackground: Bool {
        get { d.bool(forKey: "showBackground") }
        set { d.set(newValue, forKey: "showBackground") }
    }
    // Dismiss the overlay automatically after the last selected app is killed
    static var autoClose: Bool {
        get { d.object(forKey: "autoClose") == nil ? true : d.bool(forKey: "autoClose") }
        set { d.set(newValue, forKey: "autoClose") }
    }
    static var uiStyle: UIStyle {
        get { UIStyle(rawValue: d.integer(forKey: "uiStyle")) ?? .popover }
        set { d.set(newValue.rawValue, forKey: "uiStyle") }
    }
    // Require a confirmation alert before killing any app
    static var confirmKill: Bool {
        get { d.bool(forKey: "confirmKill") }
        set { d.set(newValue, forKey: "confirmKill") }
    }
    static var launchAtLogin: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    static func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
    // Global hotkey stored as Carbon key code + Carbon modifier flags + display character
    static var hotKeyCode: UInt32 {
        get { d.object(forKey: "hotKeyCode") == nil ? UInt32(kVK_ANSI_Z) : UInt32(d.integer(forKey: "hotKeyCode")) }
        set { d.set(Int(newValue), forKey: "hotKeyCode") }
    }
    static var hotKeyMods: UInt32 {
        get { d.object(forKey: "hotKeyMods") == nil ? UInt32(cmdKey) : UInt32(d.integer(forKey: "hotKeyMods")) }
        set { d.set(Int(newValue), forKey: "hotKeyMods") }
    }
    static var hotKeyChar: String {
        get { d.string(forKey: "hotKeyChar") ?? "Z" }
        set { d.set(newValue, forKey: "hotKeyChar") }
    }
    /// Human-readable shortcut string, e.g. "⌘A" or "⌥⇧B"
    static func shortcutLabel() -> String {
        var s = ""
        let m = hotKeyMods
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey)  != 0 { s += "⌥" }
        if m & UInt32(shiftKey)   != 0 { s += "⇧" }
        if m & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += hotKeyChar
        return s
    }
    /// Whether the user has entered a valid license key — stops nudge reminders.
    static var isLicensed: Bool {
        get { d.bool(forKey: "isLicensed") }
        set { d.set(newValue, forKey: "isLicensed") }
    }
    /// Lemon Squeezy instance UUID for this activation — used to deactivate if user moves to a new Mac.
    static var licenseInstanceID: String? {
        get { d.string(forKey: "licenseInstanceID") }
        set { if let v = newValue { d.set(v, forKey: "licenseInstanceID") }
              else { d.removeObject(forKey: "licenseInstanceID") } }
    }
    /// When the support nudge was last shown.
    static var lastNudgeDate: Date? {
        get { d.object(forKey: "lastNudgeDate") as? Date }
        set { d.set(newValue, forKey: "lastNudgeDate") }
    }
    /// First-ever launch date — used to delay the first nudge by 24 h.
    static var firstLaunchDate: Date {
        if let stored = d.object(forKey: "firstLaunchDate") as? Date { return stored }
        let now = Date(); d.set(now, forKey: "firstLaunchDate"); return now
    }
    /// Maximum number of sessions to keep. Default 10.
    static var maxSessions: Int {
        get { d.object(forKey: "maxSessions") == nil ? 10 : d.integer(forKey: "maxSessions") }
        set { d.set(newValue, forKey: "maxSessions") }
    }
    /// If true, restore the most-recent session automatically on launch.
    static var autoRestoreLastSession: Bool {
        get { d.bool(forKey: "autoRestoreLastSession") }
        set { d.set(newValue, forKey: "autoRestoreLastSession") }
    }
    /// Phrases the user has explicitly turned off. Stored as a JSON array of strings.
    /// Unrecognised / new phrases are implicitly enabled (not in this set).
    static var disabledKillPhrases: Set<String> {
        get {
            guard let data = d.data(forKey: "disabledKillPhrases"),
                  let arr  = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                d.set(data, forKey: "disabledKillPhrases")
            }
        }
    }
    static var disabledSparePhrases: Set<String> {
        get {
            guard let data = d.data(forKey: "disabledSparePhrases"),
                  let arr  = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                d.set(data, forKey: "disabledSparePhrases")
            }
        }
    }
    /// Version the user clicked "Later" on — skip re-prompting for the same version.
    static var dismissedUpdateVersion: String? {
        get { d.string(forKey: "dismissedUpdateVersion") }
        set { if let v = newValue { d.set(v, forKey: "dismissedUpdateVersion") }
              else { d.removeObject(forKey: "dismissedUpdateVersion") } }
    }
    /// Timestamp of the last automatic (background) update check.
    static var lastAutoUpdateCheck: Date? {
        get { d.object(forKey: "lastAutoUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastAutoUpdateCheck") }
    }
}

// MARK: - HotKey (Carbon — no Accessibility permission required)

private func fourCC(_ s: StaticString) -> FourCharCode {
    let b = s.utf8Start
    return FourCharCode(b[0]) << 24 | FourCharCode(b[1]) << 16
         | FourCharCode(b[2]) << 8  | FourCharCode(b[3])
}

private let hotKeyCallback: EventHandlerUPP = { _, _, ud -> OSStatus in
    guard let ud else { return noErr }
    let d = Unmanaged<AppDelegate>.fromOpaque(ud).takeUnretainedValue()
    DispatchQueue.main.async { d.hotkeyPressed() }
    return noErr
}

// MARK: - Memory (proc_pidinfo — works without entitlements for user processes)

private func residentMB(for pid: pid_t) -> Int? {
    var info = proc_taskinfo()
    let sz = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return nil }
    return Int(info.pti_resident_size / 1_048_576)
}

// MARK: - AppEntry

struct AppEntry {
    let app:   NSRunningApplication
    let memMB: Int?
    var name:  String    { app.localizedName ?? app.bundleIdentifier ?? "Unknown" }
    var icon:  NSImage?  { app.icon }
    init(_ a: NSRunningApplication) { app = a; memMB = residentMB(for: a.processIdentifier) }
}

// MARK: - AutoFitTableView

/// NSTableView that keeps its single column exactly as wide as the visible
/// scroll-view content area on every layout pass. This prevents horizontal
/// overflow regardless of system scroll-bar style (overlay vs. always-on).
private final class AutoFitTableView: NSTableView {
    override func layout() {
        super.layout()
        guard let col = tableColumns.first,
              let sv  = enclosingScrollView else { return }
        let available = sv.contentView.bounds.width
        if available > 1 && abs(col.width - available) > 0.5 {
            col.width = available
        }
    }
}

/// NSStackView whose coordinate system is flipped (origin at top-left).
/// Used as the NSScrollView documentView so stacked content appears at the top
/// rather than floating to the bottom of the visible area.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { return true }
}

// MARK: - RoundedIconView

final class RoundedIconView: NSImageView {
    override func draw(_ dirty: NSRect) {
        NSBezierPath(roundedRect: bounds,
                     xRadius: bounds.width * 0.22,
                     yRadius: bounds.height * 0.22).addClip()
        super.draw(dirty)
    }
}

// MARK: - AppRowCell

final class AppRowCell: NSTableCellView {
    let appIcon  = RoundedIconView()
    let checkBox = NSButton()
    let appName  = NSTextField(labelWithString: "")
    let memLabel = NSTextField(labelWithString: "")

    /// Called with the new checked state whenever the checkbox is toggled.
    var onCheckToggle: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appIcon.imageScaling = .scaleAxesIndependently

        checkBox.setButtonType(.switch)
        checkBox.title        = ""
        checkBox.controlSize  = .small
        checkBox.target       = self
        checkBox.action       = #selector(checkChanged)

        appName.font = .systemFont(ofSize: 14)
        appName.lineBreakMode = .byTruncatingTail

        memLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        memLabel.textColor = .tertiaryLabelColor
        memLabel.alignment = .right
        memLabel.setContentHuggingPriority(.required, for: .horizontal)
        memLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [appIcon, checkBox, appName, memLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 28),
            appIcon.heightAnchor.constraint(equalToConstant: 28),

            checkBox.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 10),
            checkBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkBox.widthAnchor.constraint(equalToConstant: 14),
            checkBox.heightAnchor.constraint(equalToConstant: 14),

            memLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            memLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memLabel.widthAnchor.constraint(equalToConstant: 74),

            appName.leadingAnchor.constraint(equalTo: checkBox.trailingAnchor, constant: 8),
            appName.trailingAnchor.constraint(lessThanOrEqualTo: memLabel.leadingAnchor, constant: -8),
            appName.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func checkChanged() {
        onCheckToggle?(checkBox.state == .on)
    }
}

// MARK: - EmptyStateView

final class EmptyStateView: NSView {
    private let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .quaternaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ msg: String) { label.stringValue = msg; isHidden = false }
    func hide()              { isHidden = true }
}

// MARK: - Menu bar icon (drawn programmatically to match the app icon)

private func drawAxeIcon(px: CGFloat) {
    let inset = px * 0.08
    let body  = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let bg    = NSBezierPath(roundedRect: body, xRadius: px * 0.2, yRadius: px * 0.2)
    NSGradient(colors: [
        NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    let arm: CGFloat = px * 0.27, thick: CGFloat = px * 0.14
    let cx = px / 2, cy = px / 2
    NSGraphicsContext.saveGraphicsState()
    bg.setClip()
    NSColor(srgbRed: 0.96, green: 0.28, blue: 0.28, alpha: 1).setFill()
    for angle: CGFloat in [45, -45] {
        let t = NSAffineTransform()
        t.translateX(by: cx, yBy: cy); t.rotate(byDegrees: angle); t.concat()
        NSBezierPath(roundedRect: NSRect(x: -arm, y: -thick / 2, width: arm * 2, height: thick),
                     xRadius: thick / 2, yRadius: thick / 2).fill()
        let u = NSAffineTransform()
        u.translateX(by: -cx, yBy: -cy); u.rotate(byDegrees: -angle); u.concat()
    }
    NSGraphicsContext.restoreGraphicsState()
}

private func makeMenuBarIcon() -> NSImage {
    let size: CGFloat = 18
    let img = NSImage(size: NSSize(width: size, height: size))
    for scale: CGFloat in [1, 2] {
        let px = size * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawAxeIcon(px: px)
        NSGraphicsContext.current = nil
        img.addRepresentation(rep)
    }
    return img
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 0),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Axe Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        buildUI(in: w)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }

    // ── UI construction ──────────────────────────────────────────

    private func buildUI(in w: NSWindow) {
        let root = NSStackView()
        root.orientation     = .vertical
        root.spacing         = 0
        root.alignment       = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])

        addSection("General", to: root, rows: [
            popupRow("Interface style",
                     options: ["Menu bar popover", "Spotlight overlay"],
                     selected: AppSettings.uiStyle == .popover ? 0 : 1) {
                         AppSettings.uiStyle = $0 == 0 ? .popover : .spotlight },
            toggleRow("Launch at Login",
                      on: AppSettings.launchAtLogin) { AppSettings.setLaunchAtLogin($0) },
            toggleRow("Close overlay when last app quits",
                      on: AppSettings.autoClose)     { AppSettings.autoClose = $0 },
        ])

        addSection("Kill Behaviour", to: root, rows: [
            popupRow("Default mode",
                     options: ["Graceful  (SIGTERM → SIGKILL)", "Force  (immediate SIGKILL)"],
                     selected: AppSettings.killMode.rawValue) { AppSettings.killMode = KillMode(rawValue: $0) ?? .graceful },
            popupRow("Grace period",
                     options: ["Instant", "2 seconds", "5 seconds"],
                     selected: [0.0, 2.0, 5.0].firstIndex(of: AppSettings.gracePeriod) ?? 1)
                { AppSettings.gracePeriod = [0.0, 2.0, 5.0][safe: $0] ?? 2 },
            toggleRow("Confirm before killing",
                      on: AppSettings.confirmKill) { AppSettings.confirmKill = $0 },
        ])

        addSection("Phrases", to: root, rows: [
            phraseRow(),
        ])

        addSection("Sessions", to: root, rows: [
            popupRow("Max saved sessions",
                     options: ["5", "10", "20", "50"],
                     selected: [5, 10, 20, 50].firstIndex(of: AppSettings.maxSessions) ?? 1)
                { AppSettings.maxSessions = [5, 10, 20, 50][safe: $0] ?? 10 },
            toggleRow("Auto-restore last session on launch",
                      on: AppSettings.autoRestoreLastSession) { AppSettings.autoRestoreLastSession = $0 },
        ])

        addSection("App List", to: root, rows: [
            toggleRow("Show background agents and helpers",
                      on: AppSettings.showBackground) { AppSettings.showBackground = $0 },
        ])

        addSection("Keyboard Shortcut", to: root, rows: [
            shortcutRow(),
        ])

        // Bottom divider + version
        let div = NSBox(); div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(div)
        div.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let ver = NSTextField(labelWithString: "Axe v\(appVersion)  ·  emerytech/homebrew-axe")
        ver.font = .systemFont(ofSize: 11); ver.textColor = .quaternaryLabelColor
        ver.alignment = .center
        let verPad = padded(ver, top: 10, bottom: 12)
        root.addArrangedSubview(verPad)
        verPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        w.contentView?.layoutSubtreeIfNeeded()
        let h = root.fittingSize.height
        var f = w.frame; f.size.height = h + 28; f.origin.y -= (h - w.frame.height) / 2
        w.setFrame(f, display: false)
        w.center()
    }

    // ── Section builders ─────────────────────────────────────────

    private func addSection(_ title: String, to stack: NSStackView, rows: [NSView]) {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let hPad = padded(header, top: 22, left: 20, bottom: 7)
        stack.addArrangedSubview(hPad)
        hPad.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let box = NSBox(); box.boxType = .custom
        box.fillColor   = NSColor.controlBackgroundColor
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.8)
        box.cornerRadius = 10; box.borderWidth = 0.5
        box.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(); inner.orientation = .vertical; inner.spacing = 0; inner.alignment = .leading
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        for (i, row) in rows.enumerated() {
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
            if i < rows.count - 1 {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                inner.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -32).isActive = true
            }
        }
        let wrapper = padded(box, top: 0, left: 16, bottom: 0, right: 16)
        stack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func toggleRow(_ label: String, on: Bool, handler: @escaping (Bool) -> Void) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sw = NSSwitch(); sw.state = on ? .on : .off
        let box = ToggleBox(sw, handler: handler)
        row.addArrangedSubview(lbl); row.addArrangedSubview(box)
        return row
    }

    private func popupRow(_ label: String, options: [String], selected: Int,
                          handler: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pop = NSPopUpButton()
        for opt in options { pop.addItem(withTitle: opt) }
        pop.selectItem(at: min(selected, options.count - 1))
        let box = PopupBox(pop, handler: handler)
        row.addArrangedSubview(lbl); row.addArrangedSubview(box)
        return row
    }

    private func labelRow(_ label: String, value: String) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let val = NSTextField(labelWithString: value)
        val.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        val.textColor = .secondaryLabelColor
        row.addArrangedSubview(lbl); row.addArrangedSubview(val)
        return row
    }

    private var phrasesWindow: PhrasesWindow?

    private func phraseRow() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let lbl = NSTextField(labelWithString: "Kill & spare phrases")
        lbl.font = .systemFont(ofSize: 13, weight: .regular); lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let killEnabled  = (NSApp.delegate as? AppDelegate)?.killPhrases.count ?? 0
        let spareEnabled = (NSApp.delegate as? AppDelegate)?.sparePhrases.count ?? 0
        let disabledKill  = AppSettings.disabledKillPhrases.count
        let disabledSpare = AppSettings.disabledSparePhrases.count
        let detail = NSTextField(labelWithString:
            "\(killEnabled - disabledKill)/\(killEnabled) kill · \(spareEnabled - disabledSpare)/\(spareEnabled) spare")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .tertiaryLabelColor
        let btn = NSButton(title: "Customise…", target: self, action: #selector(openPhrasesWindow))
        btn.bezelStyle = .rounded
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(detail)
        row.addArrangedSubview(btn)
        return row
    }

    @objc private func openPhrasesWindow() {
        if phrasesWindow == nil { phrasesWindow = PhrasesWindow() }
        phrasesWindow?.show()
    }

    private func shortcutRow() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let lbl = NSTextField(labelWithString: "Open overlay")
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(labelWithString: "Click to record a new shortcut")
        sub.font = .systemFont(ofSize: 11); sub.textColor = .tertiaryLabelColor
        sub.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let labelStack = NSStackView(views: [lbl, sub])
        labelStack.orientation = .vertical; labelStack.spacing = 2; labelStack.alignment = .leading
        let recorder = HotKeyRecorder()
        recorder.onChange = { code, mods, char in
            AppSettings.hotKeyCode = code
            AppSettings.hotKeyMods = mods
            AppSettings.hotKeyChar = char
            (NSApp.delegate as? AppDelegate)?.reregisterHotKey()
        }
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(labelStack)
        row.addArrangedSubview(recorder)
        return row
    }

    // Helper to wrap a view with padding
    private func padded(_ v: NSView, top: CGFloat = 0, left: CGFloat = 0,
                        bottom: CGFloat = 0, right: CGFloat = 0) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            v.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: left),
            v.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -right),
            v.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -bottom),
        ])
        return wrap
    }
}

// ── SessionRowView: NSStackView row with right-click context menu ─────────────
private final class SessionRowView: NSStackView {
    var sessionID:  UUID?
    var onRename:   (() -> Void)?
    var onDelete:   (() -> Void)?
    var onNewSpace: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let newSpace = NSMenuItem(title: "Restore on New Space…",
                                  action: #selector(handleNewSpace), keyEquivalent: "")
        newSpace.target = self
        let rename = NSMenuItem(title: "Rename…",
                                action: #selector(handleRename), keyEquivalent: "")
        rename.target = self
        let delete = NSMenuItem(title: "Delete",
                                action: #selector(handleDelete), keyEquivalent: "")
        delete.target = self
        menu.addItem(newSpace)
        menu.addItem(.separator())
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleNewSpace() { onNewSpace?() }
    @objc private func handleRename()   { onRename?()   }
    @objc private func handleDelete()   { onDelete?()   }
}

// Tiny helper objects to connect controls to closures without using objc bridging tricks
private final class ToggleBox: NSView {
    let sw: NSSwitch; let handler: (Bool) -> Void
    init(_ sw: NSSwitch, handler: @escaping (Bool) -> Void) {
        self.sw = sw; self.handler = handler
        super.init(frame: .zero)
        sw.target = self; sw.action = #selector(changed)
        sw.translatesAutoresizingMaskIntoConstraints = false; addSubview(sw)
        NSLayoutConstraint.activate([
            sw.topAnchor.constraint(equalTo: topAnchor),
            sw.leadingAnchor.constraint(equalTo: leadingAnchor),
            sw.trailingAnchor.constraint(equalTo: trailingAnchor),
            sw.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed() { handler(sw.state == .on) }
}

private final class PopupBox: NSView {
    let pop: NSPopUpButton; let handler: (Int) -> Void
    init(_ pop: NSPopUpButton, handler: @escaping (Int) -> Void) {
        self.pop = pop; self.handler = handler
        super.init(frame: .zero)
        pop.target = self; pop.action = #selector(changed)
        pop.translatesAutoresizingMaskIntoConstraints = false; addSubview(pop)
        NSLayoutConstraint.activate([
            pop.topAnchor.constraint(equalTo: topAnchor),
            pop.leadingAnchor.constraint(equalTo: leadingAnchor),
            pop.trailingAnchor.constraint(equalTo: trailingAnchor),
            pop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed() { handler(pop.indexOfSelectedItem) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - HotKeyRecorder

/// Converts AppKit modifier flags to the Carbon bitmask RegisterEventHotKey expects.
private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var r: UInt32 = 0
    if flags.contains(.control) { r |= UInt32(controlKey) }
    if flags.contains(.option)  { r |= UInt32(optionKey)  }
    if flags.contains(.shift)   { r |= UInt32(shiftKey)   }
    if flags.contains(.command) { r |= UInt32(cmdKey)     }
    return r
}

/// A pill-shaped control that shows the current global shortcut and enters
/// recording mode when clicked, capturing the next key+modifier combination.
final class HotKeyRecorder: NSControl {
    private var isRecording = false
    /// Called with (carbonKeyCode, carbonModifiers, displayChar) when the user sets a new shortcut.
    var onChange: ((UInt32, UInt32, String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isRecording = true; needsDisplay = true; return true
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false; needsDisplay = true
        return super.resignFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
        if isRecording { window?.makeFirstResponder(nil) }
        else           { window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        // Escape cancels recording
        if event.keyCode == UInt16(kVK_Escape) { window?.makeFirstResponder(nil); return }
        // Must include at least one modifier key
        let usable: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(usable)
        guard !flags.isEmpty else { NSSound.beep(); return }
        let char = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        onChange?(UInt32(event.keyCode), carbonModifiers(flags), char)
        window?.makeFirstResponder(nil)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.withAlphaComponent(0.9).setStroke()
        }
        path.fill(); path.lineWidth = 1; path.stroke()

        let text = isRecording ? "Type shortcut…" : AppSettings.shortcutLabel()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: isRecording ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz  = str.size()
        str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                             y: (bounds.height - sz.height) / 2 + 1))
    }
}

// MARK: - Session persistence

struct SavedApp: Codable {
    let bundleID: String
    let name:     String
}

struct AppSession: Codable {
    let id:         UUID
    var name:       String
    let date:       Date
    let apps:       [SavedApp]
    var isFavorite: Bool = false   // true = "Workflow", sorts to top
}

final class SessionManager {
    static let shared = SessionManager()
    private let key = "savedSessions"
    private var max: Int { AppSettings.maxSessions }

    var all: [AppSession] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode([AppSession].self, from: d) else { return [] }
            return s
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: key)
            }
        }
    }

    func save(_ session: AppSession) {
        var s = all; s.insert(session, at: 0)
        all = Array(s.prefix(max))
    }

    func delete(id: UUID) { all = all.filter { $0.id != id } }

    func toggleFavorite(id: UUID) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].isFavorite.toggle()
        // Keep favorites grouped at front; stable sort within each group preserves insertion order
        all = s.filter { $0.isFavorite } + s.filter { !$0.isFavorite }
    }

    func rename(id: UUID, to newName: String) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].name = newName
        all = s
    }

    func restore(_ session: AppSession) {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in session.apps {
            // If already running, bring it to front
            if let running = runningApps.first(where: { $0.bundleIdentifier == app.bundleID }) {
                if #available(macOS 14.0, *) {
                    running.activate()
                } else {
                    running.activate(options: [.activateIgnoringOtherApps])
                }
                continue
            }
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: app.bundleID) else { continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }
}

// MARK: - RedButton (reliable coloured background via layer)

/// NSButton subclass that draws a solid coloured rounded background via Core Animation.
/// NSButtonCell.backgroundColor is unreliable for bezel styles — this is the safe way.
final class RedButton: NSButton {
    var fillColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = (isHighlighted
            ? fillColor.withAlphaComponent(0.7)
            : fillColor).cgColor
        layer?.cornerRadius = 7
    }
    // Keep intrinsic height tidy
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize; s.height = 26; return s
    }
}

// MARK: - PhrasesWindow

final class PhrasesWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var seg: NSSegmentedControl?
    private var killScroll:  NSScrollView?
    private var spareScroll: NSScrollView?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Phrases"
        w.minSize = NSSize(width: 360, height: 400)
        w.isReleasedWhenClosed = false
        w.delegate = self
        buildUI(in: w)
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { window = nil }

    private func buildUI(in w: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 0; root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])

        // ── Segmented switcher ────────────────────────────────────
        let segCtrl = NSSegmentedControl(labels: [killSegLabel(), spareSegLabel()],
                                          trackingMode: .selectOne,
                                          target: self, action: #selector(segChanged(_:)))
        segCtrl.selectedSegment = 0
        seg = segCtrl
        segCtrl.translatesAutoresizingMaskIntoConstraints = false
        let segPad = NSView(); segPad.translatesAutoresizingMaskIntoConstraints = false
        segPad.addSubview(segCtrl)
        NSLayoutConstraint.activate([
            segCtrl.topAnchor.constraint(equalTo: segPad.topAnchor, constant: 14),
            segCtrl.bottomAnchor.constraint(equalTo: segPad.bottomAnchor, constant: -14),
            segCtrl.centerXAnchor.constraint(equalTo: segPad.centerXAnchor),
        ])
        root.addArrangedSubview(segPad)
        segPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let topDiv = NSBox(); topDiv.boxType = .separator
        topDiv.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(topDiv)
        topDiv.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Scroll views (one per tab) ─────────────────────────────
        let killSV  = makeScrollView(phrases: killPhraseList(),  disabled: AppSettings.disabledKillPhrases,  isKill: true)
        let spareSV = makeScrollView(phrases: sparePhraseList(), disabled: AppSettings.disabledSparePhrases, isKill: false)
        spareSV.isHidden = true
        killScroll  = killSV
        spareScroll = spareSV
        for sv in [killSV, spareSV] {
            sv.translatesAutoresizingMaskIntoConstraints = false
            root.addArrangedSubview(sv)
            sv.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        // ── Bottom toolbar ─────────────────────────────────────────
        let botDiv = NSBox(); botDiv.boxType = .separator
        botDiv.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(botDiv)
        botDiv.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let selAll   = NSButton(title: "Select All",   target: self, action: #selector(selectAll))
        let deselAll = NSButton(title: "Deselect All", target: self, action: #selector(deselectAll))
        selAll.bezelStyle   = .inline
        deselAll.bezelStyle = .inline
        let botRow = NSStackView(views: [selAll, deselAll])
        botRow.orientation = .horizontal; botRow.spacing = 10
        botRow.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        root.addArrangedSubview(botRow)
        botRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    // ── Phrase list data (mirrors AppDelegate arrays) ─────────────
    private func killPhraseList() -> [String] {
        return (NSApp.delegate as? AppDelegate)?.killPhrases ?? []
    }
    private func sparePhraseList() -> [String] {
        return (NSApp.delegate as? AppDelegate)?.sparePhrases ?? []
    }

    private func makeScrollView(phrases: [String], disabled: Set<String>, isKill: Bool) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (i, phrase) in phrases.enumerated() {
            let btn = NSButton()
            btn.setButtonType(.switch)
            btn.tag   = 42   // sentinel: identifies these as phrase-toggle checkboxes
            btn.title = phrase
            btn.state = disabled.contains(phrase) ? .off : .on
            btn.font  = .systemFont(ofSize: 13)
            btn.target = self
            btn.action = isKill ? #selector(killCheckChanged(_:)) : #selector(spareCheckChanged(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false

            let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                btn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                btn.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
                btn.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),
            ])
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            if i < phrases.count - 1 {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            }
        }

        let sv = NSScrollView()
        sv.documentView = stack
        sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.hasHorizontalScroller = false; sv.horizontalScrollElasticity = .none
        sv.drawsBackground = false
        // Make the stack fill the scroll view width
        stack.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor).isActive = true
        return sv
    }

    // ── Actions ───────────────────────────────────────────────────
    @objc private func segChanged(_ sender: NSSegmentedControl) {
        killScroll?.isHidden  = sender.selectedSegment != 0
        spareScroll?.isHidden = sender.selectedSegment != 1
    }

    @objc private func killCheckChanged(_ sender: NSButton) {
        var dis = AppSettings.disabledKillPhrases
        if sender.state == .on { dis.remove(sender.title) } else { dis.insert(sender.title) }
        AppSettings.disabledKillPhrases = dis
        seg?.setLabel(killSegLabel(), forSegment: 0)
    }

    @objc private func spareCheckChanged(_ sender: NSButton) {
        var dis = AppSettings.disabledSparePhrases
        if sender.state == .on { dis.remove(sender.title) } else { dis.insert(sender.title) }
        AppSettings.disabledSparePhrases = dis
        seg?.setLabel(spareSegLabel(), forSegment: 1)
    }

    @objc private func selectAll() {
        setAll(enabled: true)
    }
    @objc private func deselectAll() {
        setAll(enabled: false)
    }

    private func setAll(enabled: Bool) {
        let isKill = seg?.selectedSegment == 0
        let sv = isKill ? killScroll : spareScroll
        guard let stack = (sv?.documentView as? NSStackView) else { return }
        for view in stack.arrangedSubviews {
            for sub in view.subviews {
                if let btn = sub as? NSButton, btn.tag == 42 {
                    btn.state = enabled ? .on : .off
                }
            }
        }
        if isKill {
            AppSettings.disabledKillPhrases = enabled ? [] : Set(killPhraseList())
            seg?.setLabel(killSegLabel(), forSegment: 0)
        } else {
            AppSettings.disabledSparePhrases = enabled ? [] : Set(sparePhraseList())
            seg?.setLabel(spareSegLabel(), forSegment: 1)
        }
    }

    // ── Segment label helpers (show enabled count) ─────────────────
    private func killSegLabel() -> String {
        let total   = killPhraseList().count
        let enabled = total - AppSettings.disabledKillPhrases.count
        return "Kill Phrases (\(enabled)/\(total))"
    }
    private func spareSegLabel() -> String {
        let total   = sparePhraseList().count
        let enabled = total - AppSettings.disabledSparePhrases.count
        return "Spare Phrases (\(enabled)/\(total))"
    }
}

// MARK: - NudgeWindow  (support reminder — shown every 6 h, stops once licensed)

// MARK: - SpaceRestoreHUD

/// Floating top-center banner shown while waiting for the user to switch to a new Space.
/// When NSWorkspace fires activeSpaceDidChangeNotification the apps are launched there.
final class SpaceRestoreHUD: NSObject, NSWindowDelegate {
    private var window:    NSWindow?
    private var onCancel:  (() -> Void)?
    let sessionName: String

    init(sessionName: String, onCancel: @escaping () -> Void) {
        self.sessionName = sessionName
        self.onCancel    = onCancel
        super.init()
    }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let W: CGFloat = 380
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 0),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = ""; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false; w.level = .floating; w.delegate = self
        buildUI(in: w, width: W)
        window = w
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: sf.midX - W/2, y: sf.maxY - w.frame.height - 60))
        } else { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    func dismiss() { window?.close() }

    func windowWillClose(_ n: Notification) {
        onCancel?(); onCancel = nil; window = nil
    }

    private func buildUI(in w: NSWindow, width W: CGFloat) {
        let cv = w.contentView!
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 10; root.alignment = .centerX
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        // Icon
        let iconView = NSImageView()
        if let sym = NSImage(systemSymbolName: "macwindow.on.rectangle",
                             accessibilityDescription: nil) {
            iconView.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 30, weight: .light))
        }
        iconView.contentTintColor = .controlAccentColor
        root.addArrangedSubview(iconView)

        // Headline
        let headline = NSTextField(labelWithString: "Restore \"\(sessionName)\" on a new Space")
        headline.font = .systemFont(ofSize: 14, weight: .semibold)
        headline.alignment = .center; headline.lineBreakMode = .byWordWrapping
        headline.preferredMaxLayoutWidth = W - 48
        root.addArrangedSubview(headline)

        // Instructions
        let body = NSTextField(labelWithString:
            "Switch to any Space and the workflow will open there.\n\nPress ⌃↑ to open Mission Control, then click + to create a new Space.")
        body.font = .systemFont(ofSize: 12); body.textColor = .secondaryLabelColor
        body.alignment = .center; body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = W - 48
        root.addArrangedSubview(body)

        // Pulse label
        let waiting = NSTextField(labelWithString: "Waiting for you to switch Spaces…")
        waiting.font = .systemFont(ofSize: 11); waiting.textColor = .tertiaryLabelColor
        waiting.alignment = .center
        root.addArrangedSubview(waiting)

        root.setCustomSpacing(16, after: body)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded; cancelBtn.keyEquivalent = "\u{1B}"
        root.addArrangedSubview(cancelBtn)
    }

    @objc private func cancelTapped() { onCancel?(); onCancel = nil; dismiss() }
}

// MARK: - UpdateWindow

final class UpdateWindow: NSObject, NSWindowDelegate {
    private var window:   NSWindow?
    private weak var brewBtn: NSButton?
    private let latestVersion: String
    private let releaseNotes:  String

    init(latestVersion: String, releaseNotes: String) {
        self.latestVersion = latestVersion
        self.releaseNotes  = releaseNotes
    }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); bringToFront(); return }
        let W: CGFloat = 460
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Axe \(latestVersion) Available"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 400, height: 300)
        w.delegate = self
        buildUI(in: w, width: W)
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        bringToFront()
    }

    private func bringToFront() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ n: Notification) { window = nil }

    private func buildUI(in w: NSWindow, width W: CGFloat) {
        guard let cv = w.contentView else { return }

        // ── App icon + title row ────────────────────────────────────
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
        ])

        let titleLbl = NSTextField(labelWithString: "Axe \(latestVersion) is available")
        titleLbl.font = .systemFont(ofSize: 14, weight: .semibold)

        let subLbl = NSTextField(labelWithString: "You have version \(appVersion).")
        subLbl.font = .systemFont(ofSize: 12)
        subLbl.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLbl, subLbl])
        textStack.orientation = .vertical
        textStack.alignment   = .leading
        textStack.spacing     = 3

        let headerRow = NSStackView(views: [iconView, textStack])
        headerRow.orientation = .horizontal
        headerRow.alignment   = .centerY
        headerRow.spacing     = 14

        // ── "What's New" label ──────────────────────────────────────
        let notesHdr = NSTextField(labelWithString: "WHAT'S NEW")
        notesHdr.font = .systemFont(ofSize: 10, weight: .semibold)
        notesHdr.textColor = .tertiaryLabelColor

        // ── Notes text view inside a scroll view ────────────────────
        let tv = NSTextView()
        tv.isEditable   = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(width: 0, height: 2)

        // Render GitHub Markdown on macOS 12+, else strip symbols
        if #available(macOS 12.0, *),
           let attrStr = try? AttributedString(
               markdown: releaseNotes,
               options: AttributedString.MarkdownParsingOptions(
                   interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let nsBase = NSAttributedString(attrStr)
            let nsAttr = NSMutableAttributedString(attributedString: nsBase)
            let fullRange = NSRange(location: 0, length: nsAttr.length)
            // Apply base font only where the markdown parser didn't set one
            nsAttr.enumerateAttribute(NSAttributedString.Key.font, in: fullRange) { val, range, _ in
                if val == nil {
                    nsAttr.addAttribute(NSAttributedString.Key.font,
                                        value: NSFont.systemFont(ofSize: 12.5), range: range)
                }
            }
            tv.textStorage?.setAttributedString(nsAttr)
        } else {
            let plain = releaseNotes
                .replacingOccurrences(of: #"#{1,6} ?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
            tv.string = plain
            tv.font   = .systemFont(ofSize: 12.5)
        }

        let sv = NSScrollView()
        sv.documentView          = tv
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers    = true
        sv.borderType            = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false

        // ── Button row ──────────────────────────────────────────────
        let laterBtn = NSButton(title: "Later", target: self, action: #selector(laterTapped))
        laterBtn.bezelStyle = .rounded

        let dmgBtn = NSButton(title: "Download DMG", target: self, action: #selector(dmgTapped))
        dmgBtn.bezelStyle = .rounded

        let brewBtn = NSButton(title: "Update with Homebrew", target: self, action: #selector(brewTapped))
        brewBtn.bezelStyle    = .rounded
        brewBtn.keyEquivalent = "\r"
        self.brewBtn = brewBtn

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let btnRow = NSStackView(views: [laterBtn, spacer, dmgBtn, brewBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing     = 8

        // ── Root stack ──────────────────────────────────────────────
        let root = NSStackView(views: [headerRow, notesHdr, sv, btnRow])
        root.orientation = .vertical
        root.alignment   = .leading
        root.spacing     = 10
        root.edgeInsets  = NSEdgeInsets(top: 28, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sv.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            btnRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            // Give the scroll view most of the vertical space
            sv.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    @objc private func laterTapped() {
        AppSettings.dismissedUpdateVersion = latestVersion
        window?.close()
    }

    @objc private func dmgTapped() {
        NSWorkspace.shared.open(
            URL(string: "https://github.com/emerytech/homebrew-axe/releases/latest/download/Axe.dmg")!)
        window?.close()
    }

    @objc private func brewTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew upgrade emerytech/axe/axe", forType: .string)
        brewBtn?.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.brewBtn?.title = "Update with Homebrew"
        }
    }
}

// MARK: - NudgeWindow

final class NudgeWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    static let purchaseURL  = "https://ets3d.lemonsqueezy.com/checkout/buy/7cf62599-8c8e-4dd1-bd5c-3e7643bbb7c2"  // $9.99 — 3 seats
    static let extraSeatURL = "https://ets3d.lemonsqueezy.com/checkout/buy/d7d5c5b5-e7ac-40ef-acc7-b178742a5c45?discount=0"  // $4.99 — 1 extra seat

    func show() {
        AppSettings.lastNudgeDate = Date()
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let W: CGFloat = 360
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 0),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = ""; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        buildUI(in: w, width: W)
        window = w
        // Position bottom-right of screen like a notification
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: sf.maxX - W - 20, y: sf.minY + 20))
        } else { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { window = nil }

    private var keyField:      NSTextField?
    private var statusLabel:   NSTextField?
    private var activateBtn:   NSButton?
    private var keyStack:      NSView?
    private var extraSeatBtn:  NSButton?   // shown only when activation limit is reached

    private func buildUI(in w: NSWindow, width W: CGFloat) {
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 0; root.alignment = .centerX
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])

        // ── Heart + headline ─────────────────────────────────────
        let heart = NSTextField(labelWithString: "♥")
        heart.font = .systemFont(ofSize: 28); heart.textColor = .systemRed
        heart.alignment = .center

        let headline = NSTextField(labelWithString: "Enjoying Axe?")
        headline.font = .systemFont(ofSize: 16, weight: .semibold); headline.alignment = .center

        let body = NSTextField(labelWithString:
            "Axe is free to keep. If it's been saving you time,\na small tip keeps the blade sharp. ⚔️")
        body.font = .systemFont(ofSize: 12, weight: .regular)
        body.textColor = .secondaryLabelColor; body.alignment = .center
        body.lineBreakMode = .byWordWrapping

        let topStack = NSStackView(views: [heart, headline, body])
        topStack.orientation = .vertical; topStack.spacing = 6; topStack.alignment = .centerX
        let topPad = padded(topStack, top: 24, left: 20, bottom: 16, right: 20)
        root.addArrangedSubview(topPad)
        topPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Buy + dismiss buttons ─────────────────────────────────
        let buyBtn = NSButton(title: "Buy Axe →", target: self, action: #selector(buyTapped))
        buyBtn.bezelStyle = .rounded; buyBtn.keyEquivalent = "\r"
        let laterBtn = NSButton(title: "Maybe Later", target: self, action: #selector(laterTapped))
        laterBtn.bezelStyle = .inline

        let btnRow = NSStackView(views: [buyBtn, laterBtn])
        btnRow.orientation = .horizontal; btnRow.spacing = 10; btnRow.alignment = .centerY
        let btnPad = padded(btnRow, top: 0, left: 20, bottom: 14, right: 20)
        root.addArrangedSubview(btnPad)
        btnPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Divider + license key section ─────────────────────────
        let div = NSBox(); div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(div)
        div.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let alreadyBtn = NSButton(title: "Already bought? Enter your key →",
                                  target: self, action: #selector(toggleKeyEntry))
        alreadyBtn.bezelStyle = .inline; alreadyBtn.isBordered = false
        alreadyBtn.font = .systemFont(ofSize: 11); alreadyBtn.contentTintColor = .tertiaryLabelColor

        let field = NSTextField()
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .center; field.bezelStyle = .roundedBezel; field.focusRingType = .none
        keyField = field

        let actBtn = NSButton(title: "Activate", target: self, action: #selector(activateTapped))
        actBtn.bezelStyle = .rounded
        activateBtn = actBtn

        let statusLbl = NSTextField(labelWithString: "")
        statusLbl.font = .systemFont(ofSize: 11); statusLbl.alignment = .center
        statusLbl.textColor = .systemRed; statusLbl.lineBreakMode = .byWordWrapping
        statusLabel = statusLbl

        let extraBtn = NSButton(title: "Buy an extra seat — $4.99 →",
                               target: self, action: #selector(extraSeatTapped))
        extraBtn.bezelStyle = .rounded
        extraBtn.isHidden = true
        extraSeatBtn = extraBtn

        let kStack = NSStackView(views: [field, actBtn, statusLbl, extraBtn])
        kStack.orientation = .vertical; kStack.spacing = 8; kStack.alignment = .centerX
        kStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        field.widthAnchor.constraint(equalTo: kStack.widthAnchor, constant: -40).isActive = true
        kStack.isHidden = true
        keyStack = kStack

        let bottomStack = NSStackView(views: [alreadyBtn, kStack])
        bottomStack.orientation = .vertical; bottomStack.spacing = 8; bottomStack.alignment = .centerX
        bottomStack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 16, right: 0)
        root.addArrangedSubview(bottomStack)
        bottomStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        w.contentView?.layoutSubtreeIfNeeded()
        let h = root.fittingSize.height
        var f = w.frame; f.size.height = h + 28
        w.setFrame(f, display: false)
    }

    @objc private func buyTapped() {
        NSWorkspace.shared.open(URL(string: NudgeWindow.purchaseURL)!)
        window?.close()
    }

    @objc private func laterTapped() { window?.close() }

    @objc private func toggleKeyEntry() {
        guard let ks = keyStack, let w = window else { return }
        let wasHidden = ks.isHidden
        ks.isHidden = !wasHidden
        // Resize window to fit new content
        w.contentView?.layoutSubtreeIfNeeded()
        if let root = w.contentView?.subviews.first as? NSStackView {
            let h = root.fittingSize.height
            var f = w.frame
            let delta = (h + 28) - f.height
            f.size.height += delta
            f.origin.y    -= delta   // grow upward
            w.setFrame(f, display: true, animate: true)
        }
        if wasHidden { w.makeFirstResponder(keyField) }
    }

    @objc private func activateTapped() {
        let raw = keyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            statusLabel?.textColor = .systemOrange
            statusLabel?.stringValue = "Enter a license key above."; return
        }
        activateBtn?.isEnabled = false
        extraSeatBtn?.isHidden = true
        statusLabel?.textColor = .secondaryLabelColor; statusLabel?.stringValue = "Validating…"

        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "license_key":   raw,
            "instance_name": Host.current().localizedName ?? "Mac",
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.statusLabel?.textColor = .systemRed
                    self.statusLabel?.stringValue = "Network error: \(error.localizedDescription)"
                    self.activateBtn?.isEnabled = true; return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.statusLabel?.textColor = .systemRed
                    self.statusLabel?.stringValue = "Couldn't read response."
                    self.activateBtn?.isEnabled = true; return
                }

                if let errorMsg = json["error"] as? String, !errorMsg.isEmpty {
                    // ── Activation limit reached — show extra seat upsell ──
                    let isLimit = errorMsg.lowercased().contains("activation limit") ||
                                  errorMsg.lowercased().contains("activation_limit")
                    self.statusLabel?.textColor = .systemRed
                    if isLimit {
                        let limit = (json["license_key"] as? [String: Any])?["activation_limit"] as? Int ?? 3
                        self.statusLabel?.stringValue = "All \(limit) seats on this key are in use."
                        self.extraSeatBtn?.isHidden = false
                        self.resizeWindow()
                    } else {
                        self.statusLabel?.stringValue = errorMsg
                    }
                    self.activateBtn?.isEnabled = true; return
                }

                if json["activated"] as? Bool == true {
                    // Store the instance ID so we can deactivate later if needed
                    if let instance = json["instance"] as? [String: Any],
                       let instanceID = instance["id"] as? String {
                        AppSettings.licenseInstanceID = instanceID
                    }
                    // Show seat info (e.g. "2 of 3 seats used")
                    var seatInfo = ""
                    if let lk = json["license_key"] as? [String: Any],
                       let used  = lk["activation_usage"] as? Int,
                       let limit = lk["activation_limit"] as? Int {
                        seatInfo = "  (\(used) of \(limit) seats used)"
                    }
                    AppSettings.isLicensed = true
                    self.statusLabel?.textColor = .systemGreen
                    self.statusLabel?.stringValue = "✓ Activated — thank you! 🪓\(seatInfo)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.window?.close() }
                } else {
                    self.statusLabel?.textColor = .systemRed
                    self.statusLabel?.stringValue = "License key not recognised."
                    self.activateBtn?.isEnabled = true
                }
            }
        }.resume()
    }

    @objc private func extraSeatTapped() {
        NSWorkspace.shared.open(URL(string: NudgeWindow.extraSeatURL)!)
    }

    private func resizeWindow() {
        guard let w = window,
              let root = w.contentView?.subviews.first as? NSStackView else { return }
        w.contentView?.layoutSubtreeIfNeeded()
        let h = root.fittingSize.height
        var f = w.frame
        let delta = (h + 28) - f.height
        f.size.height += delta; f.origin.y -= delta
        w.setFrame(f, display: true, animate: true)
    }

    private func padded(_ v: NSView, top: CGFloat = 0, left: CGFloat = 0,
                        bottom: CGFloat = 0, right: CGFloat = 0) -> NSView {
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false; wrap.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            v.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: left),
            v.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -right),
            v.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -bottom),
        ])
        return wrap
    }
}

// MARK: - OnboardingWindow

final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var onDismiss: (() -> Void)?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let W: CGFloat = 460
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 0),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = ""; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        buildUI(in: w, width: W)
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { onDismiss?(); window = nil }

    private func buildUI(in w: NSWindow, width W: CGFloat) {
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 0; root.alignment = .centerX
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])

        // ── Icon + heading ──────────────────────────────────────────
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleAxesIndependently
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = label("Welcome to Axe", size: 22, weight: .bold)
        let sub   = label("The fastest way to quit running apps", size: 13,
                          weight: .regular, color: .secondaryLabelColor)

        let heading = NSStackView(views: [iconView, title, sub])
        heading.orientation = .vertical; heading.spacing = 6; heading.alignment = .centerX
        let hPad = padded(heading, top: 32, left: 0, bottom: 24)
        root.addArrangedSubview(hPad); hPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Feature rows ────────────────────────────────────────────
        let features: [(String, String, String)] = [
            ("⌘Z",                       "Open Axe from anywhere — no Accessibility needed",       ""),
            ("magnifyingglass",           "Type to instantly filter your running apps",              "sf"),
            ("cursorarrow.click.2",       "Double-click a row to quit  ·  ⌘-double-click to force kill", "sf"),
            ("checkmark.square",          "Tick checkboxes to build a batch list, then confirm",    "sf"),
            ("keyboard",                  "↑↓ navigate  ·  ↵ quit  ·  ⌘↵ force kill",              "sf"),
            ("escape",                    "Esc to close the overlay",                               "sf"),
        ]

        let sep1 = NSBox(); sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(sep1)
        sep1.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let featureStack = NSStackView()
        featureStack.orientation = .vertical; featureStack.spacing = 0; featureStack.alignment = .leading
        featureStack.translatesAutoresizingMaskIntoConstraints = false

        for (i, (sym, desc, kind)) in features.enumerated() {
            let row = NSStackView(); row.orientation = .horizontal
            row.spacing = 14; row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.15).cgColor
            badge.layer?.cornerRadius = 5
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(equalToConstant: 32).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 26).isActive = true

            if kind == "sf", let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
                let iv = NSImageView()
                iv.image = img.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
                iv.contentTintColor = .secondaryLabelColor
                iv.translatesAutoresizingMaskIntoConstraints = false
                badge.addSubview(iv)
                NSLayoutConstraint.activate([
                    iv.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                    iv.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
                ])
            } else {
                let kl = NSTextField(labelWithString: sym)
                kl.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
                kl.textColor = .secondaryLabelColor
                kl.alignment = .center
                kl.translatesAutoresizingMaskIntoConstraints = false
                badge.addSubview(kl)
                NSLayoutConstraint.activate([
                    kl.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                    kl.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
                    kl.widthAnchor.constraint(equalTo: badge.widthAnchor),
                ])
            }

            let dl = NSTextField(labelWithString: desc)
            dl.font = .systemFont(ofSize: 13); dl.lineBreakMode = .byWordWrapping
            dl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            row.addArrangedSubview(badge); row.addArrangedSubview(dl)
            featureStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: featureStack.widthAnchor).isActive = true

            if i < features.count - 1 {
                let s = NSBox(); s.boxType = .separator
                s.translatesAutoresizingMaskIntoConstraints = false
                featureStack.addArrangedSubview(s)
                s.widthAnchor.constraint(equalTo: featureStack.widthAnchor, constant: -40).isActive = true
            }
        }
        root.addArrangedSubview(featureStack)
        featureStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(sep2)
        sep2.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Interface style picker ──────────────────────────────────
        let pickerTitle = label("Choose how Axe opens", size: 13, weight: .semibold)

        let seg = NSSegmentedControl(
            labels: ["Menu Bar Popover", "Spotlight Overlay"],
            trackingMode: .selectOne, target: self,
            action: #selector(stylePickerChanged(_:)))
        seg.selectedSegment = AppSettings.uiStyle == .popover ? 0 : 1
        seg.translatesAutoresizingMaskIntoConstraints = false

        let pickerHint = label("Popover drops from the menu bar icon  ·  Spotlight floats center-screen",
                               size: 11, weight: .regular, color: .tertiaryLabelColor)

        let pickerStack = NSStackView(views: [pickerTitle, seg, pickerHint])
        pickerStack.orientation = .vertical; pickerStack.spacing = 8; pickerStack.alignment = .centerX
        pickerStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.addArrangedSubview(pickerStack)
        pickerStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let sep3 = NSBox(); sep3.boxType = .separator
        sep3.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(sep3)
        sep3.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Get Started button ──────────────────────────────────────
        let btn = NSButton(title: "Get Started", target: self, action: #selector(dismiss))
        btn.bezelStyle = .rounded; btn.keyEquivalent = "\r"
        btn.translatesAutoresizingMaskIntoConstraints = false
        let btnPad = padded(btn, top: 14, left: 0, bottom: 18)
        root.addArrangedSubview(btnPad); btnPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        w.contentView?.layoutSubtreeIfNeeded()
        let h = root.fittingSize.height
        var f = w.frame; f.size.height = h + 28
        w.setFrame(f, display: false); w.center()
    }

    @objc private func dismiss() { window?.close() }

    @objc private func stylePickerChanged(_ sender: NSSegmentedControl) {
        // segment 0 = Menu bar popover, segment 1 = Spotlight overlay
        AppSettings.uiStyle = sender.selectedSegment == 0 ? .popover : .spotlight
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color; f.alignment = .center
        return f
    }

    private func padded(_ v: NSView, top: CGFloat = 0, left: CGFloat = 0,
                        bottom: CGFloat = 0, right: CGFloat = 0) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            v.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -bottom),
        ])
        return wrap
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate,
                          NSTableViewDataSource, NSTableViewDelegate,
                          NSTextFieldDelegate {

    // Status bar
    var statusItem: NSStatusItem!

    // Overlay — spotlight mode
    var panel:          NSPanel?
    // Overlay — popover mode
    var popover:        NSPopover?
    var popoverVC:      NSViewController?
    // Tracks which style was used to build the current overlay (detects setting changes)
    var lastBuiltStyle: UIStyle?

    var searchField: NSTextField?
    var tableView:   NSTableView?
    var emptyView:   EmptyStateView?
    var hintLabel:   NSTextField?

    // ── Sessions panel (shown inside the overlay on demand) ────────
    var isShowingSessions  = false
    var sessionBtn:        NSButton?       // the clock icon in the search bar
    var appListContainer:  NSView?         // the NSScrollView holding the app table
    var sessionsPanelView: NSView?         // replaces the table area in sessions mode
    var sessionsListStack: NSStackView?    // inner stack rebuilt on each show

    // Data
    var allApps:      [AppEntry]  = []
    var filtered:     [AppEntry]  = []
    var checkedPIDs:      Set<pid_t>  = []
    var sortByMemory:     Bool        = false
    var sortButton:       NSButton?
    var axeCheckedButton: NSButton?

    // Rotating kill-button phrases — picked randomly on first checkbox tick,
    // then cycled automatically every 10 s while apps remain selected.
    var currentKillPhrase: String = ""
    var phraseIndex:       Int    = 0
    var phraseTimer:       Timer?

    // New-Space restore — set when user taps "Restore on New Space"; cleared on space change
    var pendingSpaceRestoreSession: AppSession?
    var spaceRestoreHUD: SpaceRestoreHUD?
    var updateWindow: UpdateWindow?
    var enabledKillPhrases: [String] {
        let dis = AppSettings.disabledKillPhrases
        let enabled = killPhrases.filter { !dis.contains($0) }
        return enabled.isEmpty ? killPhrases : enabled   // always keep at least one
    }
    var enabledSparePhrases: [String] {
        let dis = AppSettings.disabledSparePhrases
        let enabled = sparePhrases.filter { !dis.contains($0) }
        return enabled.isEmpty ? sparePhrases : enabled
    }

    let killPhrases: [String] = [
        "Dracarys",                            // GoT — Daenerys burns everything
        "Et tu, Brute?",                       // Shakespeare — Julius Caesar, stabbed
        "Avada Kedavra",                       // Harry Potter — killing curse
        "Valar Morghulis",                     // GoT — "all men must die"
        "Finish him!",                         // Mortal Kombat
        "FATALITY",                            // Mortal Kombat
        "Execute Order 66",                    // Star Wars — Jedi purge
        "Hasta la vista, baby",                // Terminator 2
        "The Lannisters send their regards",   // GoT — Red Wedding
        "Yippee-ki-yay",                       // Die Hard
        "Here's Johnny!",                      // The Shining
        "This is Sparta!",                     // 300 — kicked into the pit
        "Another one bites the dust",          // Queen
        "Set phasers to kill",                 // Star Trek
        "Luca Brasi sleeps with the fishes",   // The Godfather
        "Redrum",                              // The Shining
        "Off with their heads!",               // Alice in Wonderland
        "I am become Death",                   // Oppenheimer / Bhagavad Gita
        "He's dead, Jim",                      // Star Trek
        "I am inevitable",                          // Avengers: Endgame — Thanos
        "Sick of these MFN apps on my MFN Mac",     // Snakes on a Plane
        "Just die already",                         // universal exasperation
        "Go on, get",                               // classic Southern sendoff
        "To the train station",                     // Yellowstone
        "Rock, paper, you're dead",                 // original
        "You're going to the farm upstate",         // the classic parent lie
        "You are the weakest link. Goodbye.",       // The Weakest Link
        "The tribe has spoken",                     // Survivor
        "Derezz",                                   // TRON — programs being killed
        "Exit stage left",                          // Snagglepuss
        "Get off my lawn!",                         // Gran Torino
        "Bye bye bye",                              // NSYNC
        "One does not simply exist anymore",        // LOTR meme
        "Hit the road, Jack",                       // Ray Charles
        "Here, hold this hand grenade",             // classic cartoon gag
        "Frankly, my dear, I don't give a damn",    // Gone with the Wind
        "Cancel Culture",                           // very 2020s
        "That's a wrap",                            // film set dismissal
        "Pull the plug",                            // classic shutdown
        "Done and dusted",                          // British finality
        "You're fired!",                            // The Apprentice
        "I think we should see other people",       // the soft kill
        "Death before dishonor",                    // old soldier's creed
    ]

    let sparePhrases: [String] = [
        "Nah, you're good",
        "My bad, live",
        "Walk it off",
        "Fine. Stay.",
        "Changed my mind",
        "Not today",
        "I'll allow it",
        "Abort! Abort!",
        "Retreat!",
        "Run. Run far away.",
        "Lucky. Very lucky.",
        "Consider this a warning",
        "Don't make me regret this",
        "You didn't see anything",
        "Everyone gets one",
        "Godspeed, little app",
        "You live to crash another day",
        "Let's not and say we did",
        "As you were",
        "Touch grass instead",
        "Carry on, nothing to see here",
        "Move along, move along",
        "This is your last warning",
        "On second thought…",
    ]

    // Carbon hot key
    var hotKeyRef: EventHotKeyRef?

    // Settings / Onboarding / Nudge
    let settingsWindow   = SettingsWindow()
    let onboardingWindow = OnboardingWindow()
    let nudgeWindow      = NudgeWindow()
    private var nudgeTimer: Timer?

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKey()
        watchWorkspace()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Show onboarding on very first launch
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.onboardingWindow.show()
            }
        }
        // Auto-restore last session if enabled
        if AppSettings.autoRestoreLastSession,
           let lastSession = SessionManager.shared.all.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SessionManager.shared.restore(lastSession)
            }
        }

        // Support nudge — show every 6 hours, skip first 24 h and if already licensed
        _ = AppSettings.firstLaunchDate   // ensures first-launch date is recorded
        startNudgeTimer()

        // Silent background update check
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2) {
            self.checkForUpdates(userInitiated: false)
        }
    }

    // MARK: Status item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let btn = statusItem.button!
        btn.image  = makeMenuBarIcon()
        btn.action = #selector(statusItemClicked)
        btn.target = self
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showStatusMenu() } else { toggleOverlay() }
    }

    func showStatusMenu() {
        let menu = NSMenu()

        // ── Favorite workflows — direct one-click access at the very top ──
        let saved = SessionManager.shared.all
        let workflows = saved.filter { $0.isFavorite }
        if !workflows.isEmpty {
            let hdr = NSMenuItem(title: "Workflows", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)
            for session in workflows {
                let icon = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
                let item = NSMenuItem(title: session.name,
                                      action: #selector(restoreSessionMI(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.image  = icon
                item.representedObject = session.id.uuidString
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        addItem(menu, "Show Axe", key: "", tip: "⌘Z", action: #selector(toggleOverlay))
        menu.addItem(.separator())

        // Sessions submenu (all sessions)
        let sessionsItem = NSMenuItem(title: "All Sessions", action: nil, keyEquivalent: "")
        let sessionsSub  = NSMenu()
        if saved.isEmpty {
            let empty = NSMenuItem(title: "No saved sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sessionsSub.addItem(empty)
        } else {
            let df = DateFormatter(); df.dateFormat = "MMM d · h:mma"
            for session in saved {
                let sub    = NSMenu()
                let star   = session.isFavorite ? "⭐ " : ""
                let title  = "\(star)\(session.name)  ·  \(df.string(from: session.date))"
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")

                let restore = NSMenuItem(title: "▶  Restore \(session.apps.count) apps",
                                         action: #selector(restoreSessionMI(_:)),
                                         keyEquivalent: "")
                restore.target = self
                restore.representedObject = session.id.uuidString

                let newSpace = NSMenuItem(title: "⊞  Restore on New Space…",
                                          action: #selector(restoreOnNewSpaceMI(_:)),
                                          keyEquivalent: "")
                newSpace.target = self
                newSpace.representedObject = session.id.uuidString

                let favTitle = session.isFavorite ? "☆  Remove from Workflows" : "⭐  Add to Workflows"
                let favItem = NSMenuItem(title: favTitle,
                                         action: #selector(toggleFavoriteMI(_:)),
                                         keyEquivalent: "")
                favItem.target = self
                favItem.representedObject = session.id.uuidString

                let rename = NSMenuItem(title: "✏️  Rename…",
                                        action: #selector(renameSessionMI(_:)),
                                        keyEquivalent: "")
                rename.target = self
                rename.representedObject = session.id.uuidString

                let delete = NSMenuItem(title: "🗑  Delete",
                                        action: #selector(deleteSessionMI(_:)),
                                        keyEquivalent: "")
                delete.target = self
                delete.representedObject = session.id.uuidString

                sub.addItem(restore)
                sub.addItem(newSpace)
                sub.addItem(.separator())
                sub.addItem(favItem)
                sub.addItem(rename)
                sub.addItem(.separator())
                sub.addItem(delete)
                parent.submenu = sub
                sessionsSub.addItem(parent)
            }
        }
        sessionsSub.addItem(.separator())
        let saveItem = NSMenuItem(title: "Save Current Workflow…",
                                  action: #selector(saveSessionMI), keyEquivalent: "")
        saveItem.target = self
        sessionsSub.addItem(saveItem)
        sessionsItem.submenu = sessionsSub
        menu.addItem(sessionsItem)

        menu.addItem(.separator())
        if AppSettings.isLicensed {
            let li = NSMenuItem(title: "Licensed — Thanks! ✦", action: nil, keyEquivalent: "")
            li.isEnabled = false; menu.addItem(li)
        } else {
            addItem(menu, "Support Axe ♥", key: "", action: #selector(showNudgeWindow))
        }
        menu.addItem(.separator())
        addItem(menu, "Settings…",           key: ",", action: #selector(openSettings))
        addItem(menu, "Quick Start Guide…",  key: "",  action: #selector(showOnboarding))
        addItem(menu, "Check for Updates…",  key: "",  action: #selector(checkForUpdatesMI))
        menu.addItem(.separator())
        addItem(menu, "Quit Axe", key: "q", action: #selector(quitAxe))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, key: String,
                         tip: String? = nil, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let tip { item.toolTip = tip }
        menu.addItem(item)
        return item
    }

    // MARK: Settings / Onboarding

    @objc func openSettings()   { settingsWindow.show() }
    @objc func showOnboarding() { onboardingWindow.show() }
    @objc func quitAxe()        { NSApp.terminate(nil) }
    @objc func showNudgeWindow() { nudgeWindow.show() }

    // MARK: Support nudge timer

    private let nudgeIntervalHours: Double = 6

    func startNudgeTimer() {
        nudgeTimer?.invalidate()
        let interval = nudgeIntervalHours * 3600
        // Check once at launch (after a short delay so the app is fully set up)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.showNudgeIfNeeded() }
        // Then fire every 6 hours while the app stays running
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.showNudgeIfNeeded()
        }
    }

    func showNudgeIfNeeded() {
        guard !AppSettings.isLicensed else { return }
        // Don't nudge within the first 24 hours
        let hoursSinceLaunch = Date().timeIntervalSince(AppSettings.firstLaunchDate) / 3600
        guard hoursSinceLaunch >= 24 else { return }
        // Don't nudge if we showed one less than nudgeIntervalHours ago
        if let last = AppSettings.lastNudgeDate {
            let hoursSinceLast = Date().timeIntervalSince(last) / 3600
            guard hoursSinceLast >= nudgeIntervalHours else { return }
        }
        nudgeWindow.show()
    }

    // MARK: Update checker

    @objc func checkForUpdatesMI() { checkForUpdates(userInitiated: true) }

    func checkForUpdates(userInitiated: Bool) {
        // Auto-checks run at most once every 24 hours
        if !userInitiated {
            if let last = AppSettings.lastAutoUpdateCheck,
               Date().timeIntervalSince(last) < 86_400 { return }
            AppSettings.lastAutoUpdateCheck = Date()
        }

        guard let url = URL(string:
            "https://api.github.com/repos/emerytech/homebrew-axe/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data,
                      let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag   = json["tag_name"] as? String else {
                    if userInitiated {
                        let a = NSAlert()
                        a.messageText     = "Couldn't check for updates"
                        a.informativeText = "Make sure you're connected to the internet and try again."
                        a.runModal()
                    }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                let notes  = (json["body"] as? String) ?? ""
                self?.handleUpdateResult(latest: latest, notes: notes, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleUpdateResult(latest: String, notes: String, userInitiated: Bool) {
        guard isNewerVersion(latest, than: appVersion) else {
            if userInitiated {
                let a = NSAlert()
                a.messageText     = "Axe is up to date"
                a.informativeText = "You're running the latest version (v\(appVersion))."
                a.addButton(withTitle: "OK")
                a.runModal()
            }
            return
        }
        // For background checks, skip if the user already dismissed this version
        if !userInitiated, AppSettings.dismissedUpdateVersion == latest { return }

        let win = UpdateWindow(latestVersion: latest, releaseNotes: notes)
        updateWindow = win
        win.show()
    }

    private func isNewerVersion(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    // MARK: Sessions

    @objc func saveSessionMI() { saveSession() }

    @objc func restoreSessionMI(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let session = SessionManager.shared.all.first(where: { $0.id == id })
        else { return }
        SessionManager.shared.restore(session)
    }

    @objc func deleteSessionMI(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        SessionManager.shared.delete(id: id)
        refreshSessionsPanel()
    }

    @objc func toggleFavoriteMI(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        SessionManager.shared.toggleFavorite(id: id)
        refreshSessionsPanel()
    }

    @objc func renameSessionMI(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let session = SessionManager.shared.all.first(where: { $0.id == id })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workflow"
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        tf.stringValue       = session.name
        tf.placeholderString = "Workflow name"
        alert.accessoryView  = tf
        alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        SessionManager.shared.rename(id: id, to: newName)
        refreshSessionsPanel()
    }

    func saveSession() {
        let selfPID  = ProcessInfo.processInfo.processIdentifier
        let running  = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .compactMap { app -> SavedApp? in
                guard let bid = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return SavedApp(bundleID: bid, name: name)
            }

        guard !running.isEmpty else {
            let a = NSAlert()
            a.messageText     = "Nothing to save"
            a.informativeText = "No regular apps are running right now."
            a.runModal(); return
        }

        // Name prompt
        let df = DateFormatter(); df.dateFormat = "MMM d, h:mma"
        let fallbackName = df.string(from: Date())
        let alert = NSAlert()
        alert.messageText     = "Save Workflow"
        alert.informativeText = "\(running.count) apps will be saved. Name it after what you're working on so you can switch back to it anytime."
        alert.addButton(withTitle: "Save & Quit All")
        alert.addButton(withTitle: "Save Only")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        tf.placeholderString = "e.g. Design, Dev, Client meetings…"
        tf.stringValue       = ""
        alert.accessoryView  = tf
        alert.window.initialFirstResponder = tf

        let resp = alert.runModal()
        guard resp != .alertThirdButtonReturn else { return }   // Cancel

        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        let session = AppSession(id: UUID(),
                                 name: name.isEmpty ? fallbackName : name,
                                 date: Date(),
                                 apps: running)
        SessionManager.shared.save(session)

        if resp == .alertFirstButtonReturn {
            // Quit every saved app
            running.forEach { saved in
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == saved.bundleID }?
                    .terminate()
            }
        }
    }

    // MARK: Hot key (⌥⌘K)

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind:  OSType(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &ref)
        let id = EventHotKeyID(signature: fourCC("axe!"), id: 1)
        // ⌘A — when the overlay is already frontmost, hotkeyPressed() lets
        // the in-overlay selectAll: fire instead of toggling.
        RegisterEventHotKey(AppSettings.hotKeyCode, AppSettings.hotKeyMods,
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Unregisters the current hot key and registers a fresh one from AppSettings.
    /// Call after the user changes the shortcut in Settings.
    // MARK: Sessions panel

    /// Builds the sessions overlay panel view (initially hidden).
    private func buildSessionsPanel() -> NSView {
        let container = NSView()
        container.wantsLayer = true

        // ── Header bar ─────────────────────────────────────────────
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let backBtn = NSButton()
        backBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") {
            backBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        }
        backBtn.contentTintColor = .secondaryLabelColor
        backBtn.target = self; backBtn.action = #selector(toggleSessionsPanel)
        backBtn.toolTip = "Back to app list"
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(backBtn)

        let titleLbl = NSTextField(labelWithString: "Sessions")
        titleLbl.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLbl.textColor = .labelColor; titleLbl.alignment = .center
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLbl)

        let saveBtn = NSButton()
        saveBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Save Session") {
            saveBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        saveBtn.contentTintColor = .controlAccentColor
        saveBtn.target = self; saveBtn.action = #selector(saveSessionFromPanel)
        saveBtn.toolTip = "Save current session"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(saveBtn)

        let headerH: CGFloat = 36
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerH),
            backBtn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            backBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 28),
            backBtn.heightAnchor.constraint(equalToConstant: 28),
            titleLbl.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLbl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            saveBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            saveBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            saveBtn.widthAnchor.constraint(equalToConstant: 28),
            saveBtn.heightAnchor.constraint(equalToConstant: 28),
        ])

        // ── Thin divider under header ───────────────────────────────
        let hdrDiv = divider()
        hdrDiv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hdrDiv)
        NSLayoutConstraint.activate([
            hdrDiv.topAnchor.constraint(equalTo: header.bottomAnchor),
            hdrDiv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hdrDiv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hdrDiv.heightAnchor.constraint(equalToConstant: 1),
        ])

        // ── Scrollable sessions list ────────────────────────────────
        let listStack = FlippedStackView()
        listStack.orientation = .vertical; listStack.spacing = 0; listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false
        sessionsListStack = listStack

        let listSV = NSScrollView()
        listSV.documentView = listStack
        listSV.hasVerticalScroller = true; listSV.autohidesScrollers = true
        listSV.hasHorizontalScroller = false; listSV.horizontalScrollElasticity = .none
        listSV.drawsBackground = false
        listSV.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listSV)
        listStack.widthAnchor.constraint(equalTo: listSV.contentView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            listSV.topAnchor.constraint(equalTo: hdrDiv.bottomAnchor),
            listSV.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listSV.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listSV.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    /// Rebuild the sessions list stack with current saved sessions.
    func refreshSessionsPanel() {
        guard let stack = sessionsListStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let all      = SessionManager.shared.all
        let workflows = all.filter { $0.isFavorite }
        let recents   = all.filter { !$0.isFavorite }

        if all.isEmpty {
            let empty = NSTextField(labelWithString: "No workflows saved yet.\nPress + to save the current apps.")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
            empty.alignment = .center; empty.lineBreakMode = .byWordWrapping
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
                empty.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
                empty.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 24),
                empty.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -24),
            ])
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }

        let fmt = DateFormatter(); fmt.dateFormat = "MMM d · h:mma"

        func addSectionHeader(_ title: String) {
            let lbl = NSTextField(labelWithString: title.uppercased())
            lbl.font = .systemFont(ofSize: 9, weight: .semibold)
            lbl.textColor = .tertiaryLabelColor
            lbl.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 15),
                lbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -15),
                lbl.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
                lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
            ])
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        func addRow(_ session: AppSession, index: Int, isFav: Bool, lastInGroup: Bool) {
            let row = SessionRowView()
            row.orientation = .horizontal; row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
            row.alignment = .centerY
            row.wantsLayer = true
            row.layer?.backgroundColor = isFav
                ? NSColor.systemYellow.withAlphaComponent(0.05).cgColor
                : NSColor.clear.cgColor

            // ── Star / workflow toggle
            let starBtn = NSButton()
            starBtn.isBordered = false
            let starSym = isFav ? "star.fill" : "star"
            if let sym = NSImage(systemSymbolName: starSym, accessibilityDescription: isFav ? "Remove from Workflows" : "Add to Workflows") {
                starBtn.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            }
            starBtn.contentTintColor = isFav ? .systemYellow : .tertiaryLabelColor
            starBtn.target = self; starBtn.action = #selector(toggleFavoriteFromPanel(_:))
            starBtn.tag = index; starBtn.toolTip = isFav ? "Remove from Workflows" : "Add to Workflows"
            starBtn.translatesAutoresizingMaskIntoConstraints = false
            starBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            // ── Icon
            let iconView = NSImageView()
            let iconSym = isFav ? "tray.full" : "tray"
            if let sym = NSImage(systemSymbolName: iconSym, accessibilityDescription: nil) {
                iconView.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            }
            iconView.contentTintColor = isFav
                ? .controlAccentColor
                : .secondaryLabelColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true

            // ── Text
            let nameLabel = NSTextField(labelWithString: session.name)
            nameLabel.font = .systemFont(ofSize: 13, weight: isFav ? .semibold : .medium)
            nameLabel.textColor = isFav ? .labelColor : .labelColor
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let appCount = session.apps.count
            let metaStr = "\(appCount) app\(appCount == 1 ? "" : "s")  ·  \(fmt.string(from: session.date))"
            let metaLabel = NSTextField(labelWithString: metaStr)
            metaLabel.font = .systemFont(ofSize: 11)
            metaLabel.textColor = .tertiaryLabelColor
            metaLabel.lineBreakMode = .byTruncatingTail
            metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let textStack = NSStackView(views: [nameLabel, metaLabel])
            textStack.orientation = .vertical; textStack.spacing = 2; textStack.alignment = .leading
            textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            // ── Restore (current space)
            let restoreBtn = NSButton()
            restoreBtn.isBordered = false
            if let sym = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Restore here") {
                restoreBtn.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            }
            restoreBtn.contentTintColor = .controlAccentColor
            restoreBtn.target = self; restoreBtn.action = #selector(restoreSessionFromPanel(_:))
            restoreBtn.tag = index; restoreBtn.toolTip = "Restore here"
            restoreBtn.translatesAutoresizingMaskIntoConstraints = false
            restoreBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true

            // ── Restore on New Space
            let newSpaceBtn = NSButton()
            newSpaceBtn.isBordered = false
            if let sym = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                 accessibilityDescription: "Restore on New Space") {
                newSpaceBtn.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            }
            newSpaceBtn.contentTintColor = .secondaryLabelColor
            newSpaceBtn.target = self; newSpaceBtn.action = #selector(restoreOnNewSpaceFromPanel(_:))
            newSpaceBtn.tag = index; newSpaceBtn.toolTip = "Restore on New Space"
            newSpaceBtn.translatesAutoresizingMaskIntoConstraints = false
            newSpaceBtn.widthAnchor.constraint(equalToConstant: 22).isActive = true

            // ── Delete
            let delBtn = NSButton()
            delBtn.isBordered = false
            if let sym = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Delete") {
                delBtn.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            }
            delBtn.contentTintColor = .tertiaryLabelColor
            delBtn.target = self; delBtn.action = #selector(deleteSessionFromPanel(_:))
            delBtn.tag = index; delBtn.toolTip = "Delete"
            delBtn.translatesAutoresizingMaskIntoConstraints = false
            delBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            row.addArrangedSubview(starBtn)
            row.addArrangedSubview(iconView)
            row.addArrangedSubview(textStack)
            row.addArrangedSubview(restoreBtn)
            row.addArrangedSubview(newSpaceBtn)
            row.addArrangedSubview(delBtn)

            // right-click → Restore on New Space / Rename / Delete
            row.sessionID  = session.id
            row.onNewSpace = { [weak self] in self?.restoreOnNewSpace(session) }
            row.onRename   = { [weak self] in self?.renameSessionInPanel(id: session.id) }
            row.onDelete   = { [weak self] in
                SessionManager.shared.delete(id: session.id)
                self?.refreshSessionsPanel()
            }

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            if !lastInGroup {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            }
        }

        // Workflows section
        if !workflows.isEmpty {
            addSectionHeader("Workflows")
            for (i, session) in workflows.enumerated() {
                // tag = index in the full `all` array so selectors work correctly
                let fullIndex = all.firstIndex(where: { $0.id == session.id }) ?? i
                addRow(session, index: fullIndex, isFav: true, lastInGroup: i == workflows.count - 1)
            }
        }

        // Recent section
        if !recents.isEmpty {
            if !workflows.isEmpty {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            addSectionHeader("Recent")
            for (i, session) in recents.enumerated() {
                let fullIndex = all.firstIndex(where: { $0.id == session.id }) ?? i
                addRow(session, index: fullIndex, isFav: false, lastInGroup: i == recents.count - 1)
            }
        }
    }

    private func renameSessionInPanel(id: UUID) {
        guard let session = SessionManager.shared.all.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        tf.stringValue = session.name; tf.placeholderString = "Workflow name"
        alert.accessoryView = tf; alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        SessionManager.shared.rename(id: id, to: newName)
        refreshSessionsPanel()
    }

    @objc func toggleSessionsPanel() {
        isShowingSessions.toggle()
        appListContainer?.isHidden  = isShowingSessions
        sessionsPanelView?.isHidden = !isShowingSessions
        sessionBtn?.contentTintColor = isShowingSessions ? .controlAccentColor : .tertiaryLabelColor
        if isShowingSessions {
            refreshSessionsPanel()
            searchField?.window?.makeFirstResponder(nil)
        } else {
            searchField?.window?.makeFirstResponder(searchField)
        }
        updateHint()
    }

    @objc func saveSessionFromPanel() {
        // Reuse the existing save-session flow
        saveSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshSessionsPanel()
        }
    }

    @objc func restoreSessionFromPanel(_ sender: NSButton) {
        let sessions = SessionManager.shared.all
        guard sender.tag < sessions.count else { return }
        SessionManager.shared.restore(sessions[sender.tag])
        hideOverlay()
    }

    @objc func deleteSessionFromPanel(_ sender: NSButton) {
        let sessions = SessionManager.shared.all
        guard sender.tag < sessions.count else { return }
        SessionManager.shared.delete(id: sessions[sender.tag].id)
        refreshSessionsPanel()
    }

    @objc func toggleFavoriteFromPanel(_ sender: NSButton) {
        let sessions = SessionManager.shared.all
        guard sender.tag < sessions.count else { return }
        SessionManager.shared.toggleFavorite(id: sessions[sender.tag].id)
        refreshSessionsPanel()
    }

    @objc func restoreOnNewSpaceFromPanel(_ sender: NSButton) {
        let sessions = SessionManager.shared.all
        guard sender.tag < sessions.count else { return }
        restoreOnNewSpace(sessions[sender.tag])
    }

    @objc func restoreOnNewSpaceMI(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let session = SessionManager.shared.all.first(where: { $0.id == id })
        else { return }
        restoreOnNewSpace(session)
    }

    func restoreOnNewSpace(_ session: AppSession) {
        // Confirm before creating a new Space and restarting apps
        let n = session.apps.count
        let alert = NSAlert()
        alert.messageText     = "Open \"\(session.name)\" on a New Space?"
        alert.informativeText = "\(n) app\(n == 1 ? "" : "s") will open on a new desktop Space. " +
                                "Any already running will be restarted there."
        alert.addButton(withTitle: "Create Space & Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        hideOverlay()
        pendingSpaceRestoreSession = session

        // Try to create and switch to a new Space automatically.
        // activeSpaceDidChangeNotification will fire → activeSpaceChanged handles the rest.
        if createAndSwitchToNewSpace() { return }

        // Fallback: CGS APIs unavailable — show the manual HUD instead.
        let hud = SpaceRestoreHUD(sessionName: session.name) { [weak self] in
            self?.pendingSpaceRestoreSession = nil
            self?.spaceRestoreHUD = nil
        }
        hud.show()
        spaceRestoreHUD = hud
    }

    /// Creates a fresh desktop Space and switches to it. Returns true on success.
    @discardableResult
    private func createAndSwitchToNewSpace() -> Bool {
        CGSSpace.createAndSwitch()
    }

    @objc func activeSpaceChanged(_ note: Notification) {
        guard let session = pendingSpaceRestoreSession else { return }
        pendingSpaceRestoreSession = nil
        spaceRestoreHUD?.dismiss()
        spaceRestoreHUD = nil

        // Terminate any running copies so they relaunch fresh on this new Space
        let runningApps = NSWorkspace.shared.runningApplications
        let hadRunning = session.apps.compactMap { app in
            runningApps.first(where: { $0.bundleIdentifier == app.bundleID })
        }
        hadRunning.forEach { $0.terminate() }

        // Wait long enough for apps to quit, then launch everything on the new Space
        let delay: Double = hadRunning.isEmpty ? 0.4 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            SessionManager.shared.restore(session)
        }
    }

    func reregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let id = EventHotKeyID(signature: fourCC("axe!"), id: 1)
        RegisterEventHotKey(AppSettings.hotKeyCode, AppSettings.hotKeyMods,
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // Called by the Carbon hot key. In spotlight mode, skip the toggle when
    // the panel is already key so ⌘A fires "select all" inside the search field.
    func hotkeyPressed() {
        // Only suppress the toggle when the hotkey is ⌘A and spotlight is focused —
        // that lets NSTextField fire "select all" instead of closing the overlay.
        // For any other shortcut, always toggle so pressing the hotkey closes the overlay.
        if AppSettings.uiStyle == .spotlight,
           AppSettings.hotKeyCode == UInt32(kVK_ANSI_A),
           AppSettings.hotKeyMods == UInt32(cmdKey),
           let p = panel, p.isVisible, p.isKeyWindow { return }
        toggleOverlay()
    }

    // MARK: Live app list — updates while overlay is open

    func watchWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification,
                  NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(self, selector: #selector(workspaceChanged), name: n, object: nil)
        }
    }

    @objc func workspaceChanged() {
        guard let p = panel, p.isVisible else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(liveRefresh), object: nil)
        perform(#selector(liveRefresh), with: nil, afterDelay: 0.25)
    }

    @objc func liveRefresh() {
        let query = searchField?.stringValue ?? ""
        refreshApps()
        applyFilter(query)
    }

    // MARK: Overlay lifecycle

    @objc func toggleOverlay() {
        DispatchQueue.main.async {
            if self.isOverlayVisible { self.hideOverlay() } else { self.showOverlay() }
        }
    }

    var isOverlayVisible: Bool {
        switch AppSettings.uiStyle {
        case .spotlight: return panel?.isVisible ?? false
        case .popover:   return popover?.isShown  ?? false
        }
    }

    // Tear down the built overlay so it's rebuilt fresh (called when style changes).
    func teardownOverlay() {
        panel?.orderOut(nil); panel = nil
        popover?.close();     popover = nil; popoverVC = nil
        searchField = nil; tableView = nil; emptyView = nil
        hintLabel = nil; sortButton = nil; axeCheckedButton = nil
        sessionBtn = nil; appListContainer = nil
        sessionsPanelView = nil; sessionsListStack = nil
        isShowingSessions = false
        lastBuiltStyle = nil
    }

    func showOverlay() {
        // Rebuild if the user switched styles since last open
        if let built = lastBuiltStyle, built != AppSettings.uiStyle { teardownOverlay() }

        checkedPIDs.removeAll()
        stopPhraseCycling()
        currentKillPhrase = ""
        isShowingSessions = false
        refreshApps()

        switch AppSettings.uiStyle {
        case .spotlight: showSpotlight()
        case .popover:   showPopover()
        }

        searchField?.stringValue = ""
        applyFilter("")
        DispatchQueue.main.async { [weak self] in
            guard let sf = self?.searchField else { return }
            sf.window?.makeFirstResponder(sf)
        }
    }

    // MARK: Spotlight mode

    private func showSpotlight() {
        if panel == nil { buildPanel(); lastBuiltStyle = .spotlight }

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let pw = panel!.frame
            panel?.setFrameOrigin(NSPoint(
                x: sf.midX - pw.width  / 2,
                y: sf.midY - pw.height / 2 + sf.height * 0.08))
        }

        let cv = panel!.contentView!
        cv.wantsLayer = true
        cv.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
        panel?.alphaValue = 0
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cv.animator().layer?.setAffineTransform(.identity)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    // MARK: Popover mode

    private func showPopover() {
        if popover == nil { buildPopover(); lastBuiltStyle = .popover }
        guard let btn = statusItem.button else { return }
        popover?.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideOverlay() {
        switch lastBuiltStyle ?? AppSettings.uiStyle {
        case .spotlight:
            NotificationCenter.default.removeObserver(self,
                name: NSWindow.didResignKeyNotification, object: panel)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            })
        case .popover:
            popover?.close()
        }
    }

    @objc func panelResignedKey() {
        // Don't dismiss if a child window (settings) or a sheet (confirm dialog) is open.
        // beginSheetModal makes the sheet key, not the panel, so isKeyWindow goes false —
        // checking attachedSheet prevents the overlay from vanishing mid-confirmation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let p = self.panel, p.isVisible,
                  !p.isKeyWindow, p.attachedSheet == nil else { return }
            self.hideOverlay()
        }
    }

    // MARK: Build overlay panel

    func buildPanel() {
        let W: CGFloat  = 560
        let searchH: CGFloat = 54
        let rowH: CGFloat    = 46
        let maxRows: CGFloat = 7
        let hintH: CGFloat   = 34
        let H = searchH + 1 + rowH * maxRows + 1 + hintH  // 412

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility             = .hidden
        p.titlebarAppearsTransparent  = true
        p.isMovableByWindowBackground = true
        p.level              = .floating
        p.isReleasedWhenClosed = false
        p.backgroundColor    = .clear

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        bg.blendingMode = .behindWindow
        bg.material     = .popover
        bg.state        = .active
        bg.wantsLayer   = true
        bg.layer?.cornerRadius  = 12
        bg.layer?.masksToBounds = true
        p.contentView = bg

        // ── Search bar ─────────────────────────────────────────────
        let searchIcon = NSImageView()
        if let sym = NSImage(systemSymbolName: "magnifyingglass",
                             accessibilityDescription: nil) {
            searchIcon.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        }
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(searchIcon)

        let sortBtn = NSButton()
        sortBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "arrow.up.arrow.down",
                             accessibilityDescription: "Sort") {
            sortBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sortBtn.contentTintColor = .tertiaryLabelColor
        sortBtn.target           = self
        sortBtn.action           = #selector(toggleSort)
        sortBtn.toolTip          = "Sort by name / memory"
        sortBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sortBtn)
        sortButton = sortBtn

        let sf = NSTextField(frame: .zero)
        let initialCount = allApps.count
        sf.placeholderString = initialCount == 1 ? "1 app running…" : "\(initialCount) apps running…"
        sf.isBordered = false; sf.isBezeled = false; sf.drawsBackground = false
        sf.font = .systemFont(ofSize: 18); sf.focusRingType = .none
        sf.delegate = self
        sf.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sf)
        searchField = sf

        // Sessions toggle button
        let sesBtn = NSButton()
        sesBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "clock.arrow.circlepath",
                             accessibilityDescription: "Sessions") {
            sesBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sesBtn.contentTintColor = .tertiaryLabelColor
        sesBtn.target = self; sesBtn.action = #selector(toggleSessionsPanel)
        sesBtn.toolTip = "Sessions"
        sesBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sesBtn)
        sessionBtn = sesBtn

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            sesBtn.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            sesBtn.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sesBtn.widthAnchor.constraint(equalToConstant: 26),
            sesBtn.heightAnchor.constraint(equalToConstant: 26),
            sortBtn.trailingAnchor.constraint(equalTo: sesBtn.leadingAnchor, constant: -2),
            sortBtn.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sortBtn.widthAnchor.constraint(equalToConstant: 26),
            sortBtn.heightAnchor.constraint(equalToConstant: 26),
            sf.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            sf.trailingAnchor.constraint(equalTo: sortBtn.leadingAnchor, constant: -6),
            sf.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            sf.heightAnchor.constraint(equalToConstant: searchH),
        ])

        // ── Top divider ────────────────────────────────────────────
        let topDiv = divider()
        bg.addSubview(topDiv)
        NSLayoutConstraint.activate([
            topDiv.topAnchor.constraint(equalTo: bg.topAnchor, constant: searchH),
            topDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            topDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            topDiv.heightAnchor.constraint(equalToConstant: 1),
        ])

        // ── Table (app list) ───────────────────────────────────────
        let tv = AutoFitTableView()
        tv.headerView  = nil
        tv.rowHeight   = rowH
        tv.gridStyleMask = []
        tv.backgroundColor = .clear
        tv.dataSource  = self
        tv.delegate    = self
        tv.allowsMultipleSelection = true
        tv.action       = #selector(tableClicked)
        tv.doubleAction = #selector(tableDoubleClicked)
        tv.target       = self
        if #available(macOS 12.0, *) { tv.style = .sourceList }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.minWidth = 100; col.maxWidth = 10_000; col.width = W
        tv.addTableColumn(col)
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView = tv

        let sv = NSScrollView()
        sv.documentView = tv; sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.horizontalScrollElasticity = .none
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sv)
        appListContainer = sv

        // ── Sessions panel (hidden until sessions button is tapped) ─
        let sp = buildSessionsPanel()
        sp.isHidden = true
        sp.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sp)
        sessionsPanelView = sp

        // ── Empty state ────────────────────────────────────────────
        let ev = EmptyStateView()
        ev.translatesAutoresizingMaskIntoConstraints = false
        ev.isHidden = true
        bg.addSubview(ev)
        emptyView = ev

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topDiv.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sv.heightAnchor.constraint(equalToConstant: rowH * maxRows),
            ev.topAnchor.constraint(equalTo: sv.topAnchor),
            ev.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: sv.trailingAnchor),
            ev.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
            sp.topAnchor.constraint(equalTo: topDiv.bottomAnchor),
            sp.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sp.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sp.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
        ])

        // ── Bottom divider + hint bar ──────────────────────────────
        let botDiv = divider()
        bg.addSubview(botDiv)

        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .quaternaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hint)
        hintLabel = hint

        // "Axe X Apps" button — shown in place of the hint text when boxes are checked
        let axeBtn = RedButton()
        axeBtn.isBordered = false
        axeBtn.wantsLayer = true
        axeBtn.target  = self
        axeBtn.action  = #selector(axeCheckedApps)
        axeBtn.isHidden = true
        axeBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(axeBtn)
        axeCheckedButton = axeBtn

        NSLayoutConstraint.activate([
            botDiv.topAnchor.constraint(equalTo: sv.bottomAnchor),
            botDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            botDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            botDiv.heightAnchor.constraint(equalToConstant: 1),
            hint.topAnchor.constraint(equalTo: botDiv.bottomAnchor),
            hint.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            hint.heightAnchor.constraint(equalToConstant: hintH),
            axeBtn.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            axeBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            axeBtn.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 16),
            axeBtn.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -16),
        ])

        panel = p
        updateHint()
    }

    // MARK: Build popover

    private func buildPopover() {
        let W: CGFloat       = 420
        let searchH: CGFloat = 50
        let rowH: CGFloat    = 46
        let maxRows: CGFloat = 8
        let hintH: CGFloat   = 34
        let H = searchH + 1 + rowH * maxRows + 1 + hintH

        let vc = NSViewController()
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        vc.view = bg
        vc.preferredContentSize = NSSize(width: W, height: H)
        popoverVC = vc

        // ── Search bar ─────────────────────────────────────────────
        let searchIcon = NSImageView()
        if let sym = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            searchIcon.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        }
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(searchIcon)

        let sortBtn = NSButton()
        sortBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: sortByMemory ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down",
                             accessibilityDescription: "Sort") {
            sortBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sortBtn.contentTintColor = sortByMemory ? .controlAccentColor : .tertiaryLabelColor
        sortBtn.target = self; sortBtn.action = #selector(toggleSort)
        sortBtn.toolTip = "Sort by name / memory"
        sortBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sortBtn)
        sortButton = sortBtn

        let count = allApps.count
        let sf = NSTextField(frame: .zero)
        sf.placeholderString = count == 1 ? "1 app running…" : "\(count) apps running…"
        sf.isBordered = false; sf.isBezeled = false; sf.drawsBackground = false
        sf.font = .systemFont(ofSize: 16); sf.focusRingType = .none
        sf.delegate = self
        sf.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sf)
        searchField = sf

        let sesBtn2 = NSButton()
        sesBtn2.isBordered = false
        if let sym = NSImage(systemSymbolName: "clock.arrow.circlepath",
                             accessibilityDescription: "Sessions") {
            sesBtn2.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sesBtn2.contentTintColor = .tertiaryLabelColor
        sesBtn2.target = self; sesBtn2.action = #selector(toggleSessionsPanel)
        sesBtn2.toolTip = "Sessions"
        sesBtn2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sesBtn2)
        sessionBtn = sesBtn2

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            searchIcon.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            sesBtn2.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            sesBtn2.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sesBtn2.widthAnchor.constraint(equalToConstant: 26),
            sesBtn2.heightAnchor.constraint(equalToConstant: 26),
            sortBtn.trailingAnchor.constraint(equalTo: sesBtn2.leadingAnchor, constant: -2),
            sortBtn.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sortBtn.widthAnchor.constraint(equalToConstant: 26),
            sortBtn.heightAnchor.constraint(equalToConstant: 26),
            sf.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            sf.trailingAnchor.constraint(equalTo: sortBtn.leadingAnchor, constant: -4),
            sf.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            sf.heightAnchor.constraint(equalToConstant: searchH),
        ])

        // ── Divider ────────────────────────────────────────────────
        let topDiv = divider()
        bg.addSubview(topDiv)
        NSLayoutConstraint.activate([
            topDiv.topAnchor.constraint(equalTo: bg.topAnchor, constant: searchH),
            topDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            topDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            topDiv.heightAnchor.constraint(equalToConstant: 1),
        ])

        // ── Table ──────────────────────────────────────────────────
        let tv = AutoFitTableView()
        tv.headerView = nil; tv.rowHeight = rowH
        tv.gridStyleMask = []; tv.backgroundColor = .clear
        tv.dataSource = self; tv.delegate = self
        tv.allowsMultipleSelection = true
        tv.action = #selector(tableClicked); tv.doubleAction = #selector(tableDoubleClicked)
        tv.target = self
        if #available(macOS 12.0, *) { tv.style = .sourceList }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.minWidth = 100; col.maxWidth = 10_000; col.width = W
        tv.addTableColumn(col)
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView = tv

        let sv2 = NSScrollView()
        sv2.documentView = tv; sv2.hasVerticalScroller = true
        sv2.hasHorizontalScroller = false
        sv2.horizontalScrollElasticity = .none
        sv2.autohidesScrollers = true
        sv2.drawsBackground = false
        sv2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sv2)
        appListContainer = sv2

        let sp2 = buildSessionsPanel()
        sp2.isHidden = true
        sp2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sp2)
        sessionsPanelView = sp2

        let ev = EmptyStateView()
        ev.translatesAutoresizingMaskIntoConstraints = false; ev.isHidden = true
        bg.addSubview(ev); emptyView = ev

        NSLayoutConstraint.activate([
            sv2.topAnchor.constraint(equalTo: topDiv.bottomAnchor),
            sv2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sv2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sv2.heightAnchor.constraint(equalToConstant: rowH * maxRows),
            ev.topAnchor.constraint(equalTo: sv2.topAnchor),
            ev.leadingAnchor.constraint(equalTo: sv2.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: sv2.trailingAnchor),
            ev.bottomAnchor.constraint(equalTo: sv2.bottomAnchor),
            sp2.topAnchor.constraint(equalTo: topDiv.bottomAnchor),
            sp2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sp2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sp2.bottomAnchor.constraint(equalTo: sv2.bottomAnchor),
        ])

        // ── Hint bar ───────────────────────────────────────────────
        let botDiv = divider(); bg.addSubview(botDiv)
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .quaternaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hint); hintLabel = hint

        let axeBtn = RedButton()
        axeBtn.isBordered = false; axeBtn.wantsLayer = true
        axeBtn.target = self; axeBtn.action = #selector(axeCheckedApps)
        axeBtn.isHidden = true
        axeBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(axeBtn); axeCheckedButton = axeBtn

        NSLayoutConstraint.activate([
            botDiv.topAnchor.constraint(equalTo: sv2.bottomAnchor),
            botDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            botDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            botDiv.heightAnchor.constraint(equalToConstant: 1),
            hint.topAnchor.constraint(equalTo: botDiv.bottomAnchor),
            hint.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            hint.heightAnchor.constraint(equalToConstant: hintH),
            axeBtn.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            axeBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            axeBtn.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 16),
            axeBtn.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -16),
        ])

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior  = .transient
        pop.animates  = true
        popover = pop
        updateHint()
    }

    private func divider() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    // MARK: App data

    func refreshApps() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let entries = NSWorkspace.shared.runningApplications
            .filter {
                $0.processIdentifier != selfPID
                && (AppSettings.showBackground
                    ? $0.activationPolicy != .prohibited
                    : $0.activationPolicy == .regular)
            }
            .map(AppEntry.init)
        allApps = sortByMemory
            ? entries.sorted { ($0.memMB ?? -1) > ($1.memMB ?? -1) }
            : entries.sorted { $0.name < $1.name }
        updatePlaceholder()
    }

    func applyFilter(_ query: String) {
        filtered = query.isEmpty
            ? allApps
            : allApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // Drop checked PIDs for apps that are no longer running
        let alivePIDs = Set(allApps.map { $0.app.processIdentifier })
        checkedPIDs   = checkedPIDs.intersection(alivePIDs)
        tableView?.reloadData()
        if !filtered.isEmpty && checkedPIDs.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateEmptyState(query: query)
        updateHint()
    }

    func refreshAndFilter() {
        refreshApps()
        applyFilter(searchField?.stringValue ?? "")
    }

    private func updatePlaceholder() {
        let n = allApps.count
        searchField?.placeholderString = n == 1 ? "1 app running…" : "\(n) apps running…"
    }

    @objc func axeCheckedApps() { killSelected(force: false) }

    @objc func toggleSort() {
        sortByMemory.toggle()
        let imgName = sortByMemory ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down"
        if let sym = NSImage(systemSymbolName: imgName, accessibilityDescription: nil) {
            sortButton?.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sortButton?.contentTintColor = sortByMemory ? .controlAccentColor : .tertiaryLabelColor
        refreshAndFilter()
    }

    private func updateEmptyState(query: String) {
        if filtered.isEmpty {
            emptyView?.show(query.isEmpty ? "No apps running" : "No matches for \"\(query)\"")
        } else {
            emptyView?.hide()
        }
    }

    private func updateHint() {
        let checked = checkedPIDs.count
        if checked > 0 {
            // Pick a random phrase on the first tick, then let the timer cycle it
            if currentKillPhrase.isEmpty {
                let phrases = enabledKillPhrases
                phraseIndex = Int.random(in: 0..<max(1, phrases.count))
                currentKillPhrase = phrases[safe: phraseIndex] ?? "Yeet"
                startPhraseCycling()
            }
            let btnTitle = "\(currentKillPhrase) (\(checked))"
            axeCheckedButton?.attributedTitle = NSAttributedString(
                string: btnTitle,
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            axeCheckedButton?.isHidden = false
            hintLabel?.isHidden = true
        } else {
            stopPhraseCycling()
            currentKillPhrase = ""   // reset so next session gets a fresh phrase
            axeCheckedButton?.isHidden = true
            hintLabel?.isHidden = false
            let sel = tableView?.selectedRowIndexes.count ?? 0
            if sel > 1 {
                hintLabel?.stringValue = "\(sel) selected  ·  ↵ quit  ·  ⌘↵ force kill  ·  esc close"
            } else {
                if isShowingSessions {
                    hintLabel?.stringValue = "▶ restore  ·  ✕ delete  ·  esc back to apps"
                } else {
                    let isDefaultHotkey = AppSettings.hotKeyCode == UInt32(kVK_ANSI_A)
                                       && AppSettings.hotKeyMods == UInt32(cmdKey)
                    let selectHint = isDefaultHotkey ? "  ·  ⌘A select all" : ""
                    hintLabel?.stringValue = "↑↓ navigate  ·  ↵ quit  ·  ⌘↵ force kill\(selectHint)  ·  esc close"
                }
            }
        }
    }

    // MARK: Phrase cycling

    private func startPhraseCycling() {
        phraseTimer?.invalidate()
        guard enabledKillPhrases.count > 1 else { return }   // nothing to cycle to
        phraseTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.cycleKillPhrase()
        }
    }

    private func stopPhraseCycling() {
        phraseTimer?.invalidate()
        phraseTimer = nil
        phraseIndex = 0
    }

    @objc private func cycleKillPhrase() {
        let phrases = enabledKillPhrases
        guard phrases.count > 1 else { return }
        phraseIndex = (phraseIndex + 1) % phrases.count
        currentKillPhrase = phrases[phraseIndex]
        updateHint()
    }

    // MARK: Kill logic

    func killSelected(force: Bool) {
        if !checkedPIDs.isEmpty {
            // Checked boxes take priority over the table highlight
            let targets = filtered.filter { checkedPIDs.contains($0.app.processIdentifier) }
            confirmAndExecuteKill(targets: targets, force: force)
        } else {
            let rows = tableView?.selectedRowIndexes ?? IndexSet()
            guard !rows.isEmpty else { return }
            let targets = rows.compactMap { filtered[safe: $0] }
            confirmAndExecuteKill(targets: targets, force: force)
        }
    }

    // Shows a confirmation sheet when "Confirm before killing" is on, then kills.
    private func confirmAndExecuteKill(targets: [AppEntry], force: Bool) {
        guard !targets.isEmpty else { return }

        guard AppSettings.confirmKill else {
            executeKill(targets: targets, force: force)
            return
        }

        let alert = NSAlert()
        if targets.count == 1 {
            alert.messageText     = "Axe \(targets[0].name)?"
            alert.informativeText = "\(targets[0].name) will be terminated."
        } else {
            alert.messageText     = "Axe \(targets.count) apps?"
            alert.informativeText = "All \(targets.count) selected apps will be terminated."
        }
        let yesPhrase = (enabledKillPhrases.randomElement()  ?? "Do it!")        + " (yes)"
        let noPhrase  = (enabledSparePhrases.randomElement() ?? "Spare them for now") + " (no)"
        alert.addButton(withTitle: yesPhrase)   // .alertFirstButtonReturn  (right/default)
        alert.addButton(withTitle: noPhrase)    // .alertSecondButtonReturn (left/cancel)
        alert.alertStyle = .warning

        if let p = panel, p.isVisible {
            alert.beginSheetModal(for: p) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.executeKill(targets: targets, force: force)
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                executeKill(targets: targets, force: force)
            }
        }
    }

    private func executeKill(targets: [AppEntry], force: Bool) {
        targets.forEach { killEntry($0, force: force) }
        if AppSettings.autoClose && targets.count >= filtered.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.filtered.isEmpty == true { self?.hideOverlay() }
            }
        }
    }

    func killEntry(_ entry: AppEntry, force: Bool) {
        let resolved = force ? KillMode.force : AppSettings.killMode
        if resolved == .force {
            entry.app.forceTerminate()
        } else {
            let pid = entry.app.processIdentifier
            entry.app.terminate()
            let delay = AppSettings.gracePeriod
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSRunningApplication(processIdentifier: pid)?.forceTerminate()
                }
            }
        }
        // Animate the row out, then refresh the list
        let pid = entry.app.processIdentifier
        if let row = filtered.firstIndex(where: { $0.app.processIdentifier == pid }),
           let rv = tableView?.rowView(atRow: row, makeIfNecessary: false) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                rv.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.refreshAndFilter()
            })
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.refreshAndFilter()
            }
        }
    }

    // MARK: Table interactions

    @objc func tableClicked() {
        updateHint()
    }

    @objc func tableDoubleClicked() {
        let row = tableView?.clickedRow ?? -1
        guard row >= 0, row < filtered.count else { return }
        let force = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        confirmAndExecuteKill(targets: [filtered[row]], force: force)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AppRow")
        let cell = tv.makeView(withIdentifier: id, owner: nil) as? AppRowCell
                   ?? { let c = AppRowCell(frame: .zero); c.identifier = id; return c }()
        let e = filtered[row]
        let pid = e.app.processIdentifier
        cell.appName.stringValue  = e.name
        cell.appIcon.image        = e.icon
        cell.memLabel.stringValue = e.memMB.map { "\($0) MB" } ?? "—"
        cell.checkBox.state       = checkedPIDs.contains(pid) ? .on : .off
        cell.onCheckToggle = { [weak self] checked in
            guard let self else { return }
            if checked { self.checkedPIDs.insert(pid) }
            else       { self.checkedPIDs.remove(pid) }
            self.updateHint()
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateHint()
    }

    // MARK: NSTextFieldDelegate — search + keyboard navigation

    func controlTextDidChange(_ note: Notification) {
        applyFilter(searchField?.stringValue ?? "")
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):
            if isShowingSessions { toggleSessionsPanel() } else { hideOverlay() }
            return true

        case #selector(NSResponder.insertNewline(_:)):
            let force = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            killSelected(force: force); return true

        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)):
            // Delete with empty search field = kill selected
            if searchField?.stringValue.isEmpty == true {
                killSelected(force: false); return true
            }
            return false

        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true

        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true

        case #selector(NSResponder.selectAll(_:)):
            tableView?.selectAll(nil)
            updateHint(); return true

        default:
            return false
        }
    }

    func moveSelection(by delta: Int) {
        guard let tv = tableView, tv.numberOfRows > 0 else { return }
        let cur  = tv.selectedRow < 0 ? (delta > 0 ? -1 : 0) : tv.selectedRow
        let next = max(0, min(tv.numberOfRows - 1, cur + delta))
        tv.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tv.scrollRowToVisible(next)
        updateHint()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
