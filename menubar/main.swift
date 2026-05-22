import AppKit
import Carbon.HIToolbox
import Darwin
import ServiceManagement

let appVersion = "1.5.3"

// MARK: - Settings

enum KillMode: Int { case graceful = 0, force = 1 }

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
            memLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),

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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 0),
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
            toggleRow("Launch at Login",
                      on: AppSettings.launchAtLogin) { AppSettings.setLaunchAtLogin($0) },
            toggleRow("Close overlay when last app quits",
                      on: AppSettings.autoClose)     { AppSettings.autoClose = $0 },
        ])

        addSection("Kill Behaviour", to: root, rows: [
            popupRow("Default mode",
                     options: ["Graceful  (SIGTERM → SIGKILL after grace period)",
                               "Force  (SIGKILL immediately)"],
                     selected: AppSettings.killMode.rawValue) { AppSettings.killMode = KillMode(rawValue: $0) ?? .graceful },
            popupRow("Grace period",
                     options: ["Instant", "2 seconds", "5 seconds"],
                     selected: [0.0, 2.0, 5.0].firstIndex(of: AppSettings.gracePeriod) ?? 1)
                { AppSettings.gracePeriod = [0.0, 2.0, 5.0][safe: $0] ?? 2 },
            toggleRow("Confirm before killing",
                      on: AppSettings.confirmKill) { AppSettings.confirmKill = $0 },
        ])

        addSection("App List", to: root, rows: [
            toggleRow("Show background agents and helpers",
                      on: AppSettings.showBackground) { AppSettings.showBackground = $0 },
        ])

        addSection("Keyboard Shortcut", to: root, rows: [
            labelRow("Open overlay", value: "⌘ A"),
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
        header.textColor = .tertiaryLabelColor
        let hPad = padded(header, top: 18, left: 20, bottom: 6)
        stack.addArrangedSubview(hPad)
        hPad.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let box = NSBox(); box.boxType = .custom
        box.fillColor = NSColor.separatorColor.withAlphaComponent(0.5)
        box.borderColor = .clear; box.cornerRadius = 8; box.borderWidth = 0
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
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let lbl = NSTextField(labelWithString: label); lbl.font = .systemFont(ofSize: 13)
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sw = NSSwitch(); sw.state = on ? .on : .off
        let box = ToggleBox(sw, handler: handler)
        row.addArrangedSubview(lbl); row.addArrangedSubview(box)
        return row
    }

    private func popupRow(_ label: String, options: [String], selected: Int,
                          handler: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        let lbl = NSTextField(labelWithString: label); lbl.font = .systemFont(ofSize: 13)
        lbl.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let pop = NSPopUpButton()
        for opt in options { pop.addItem(withTitle: opt) }
        pop.selectItem(at: min(selected, options.count - 1))
        let box = PopupBox(pop, handler: handler)
        row.addArrangedSubview(lbl); row.addArrangedSubview(box)
        return row
    }

    private func labelRow(_ label: String, value: String) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let lbl = NSTextField(labelWithString: label); lbl.font = .systemFont(ofSize: 13)
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let val = NSTextField(labelWithString: value)
        val.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        val.textColor = .secondaryLabelColor
        row.addArrangedSubview(lbl); row.addArrangedSubview(val)
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
            ("⌘A",                       "Open Axe from anywhere — no Accessibility needed",       ""),
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

    // Overlay
    var panel:       NSPanel?
    var searchField: NSTextField?
    var tableView:   NSTableView?
    var emptyView:   EmptyStateView?
    var hintLabel:   NSTextField?

    // Data
    var allApps:      [AppEntry]  = []
    var filtered:     [AppEntry]  = []
    var checkedPIDs:      Set<pid_t>  = []
    var sortByMemory:     Bool        = false
    var sortButton:       NSButton?
    var axeCheckedButton: NSButton?

    // Rotating kill-button phrases — picked once on first checkbox tick, held until cleared
    var currentKillPhrase: String = ""
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
        "I am inevitable",                     // Avengers: Endgame — Thanos
    ]

    // Carbon hot key
    var hotKeyRef: EventHotKeyRef?

    // Settings / Onboarding
    let settingsWindow  = SettingsWindow()
    let onboardingWindow = OnboardingWindow()

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKey()
        watchWorkspace()
        // Show onboarding on very first launch
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.onboardingWindow.show()
            }
        }
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
        addItem(menu, "Show Axe", key: "", tip: "⌘A", action: #selector(toggleOverlay))
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

    // MARK: Update checker

    @objc func checkForUpdatesMI() { checkForUpdates(userInitiated: true) }

    func checkForUpdates(userInitiated: Bool) {
        guard let url = URL(string:
            "https://api.github.com/repos/emerytech/homebrew-axe/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag  = json["tag_name"] as? String else {
                    if userInitiated {
                        let a = NSAlert()
                        a.messageText     = "Couldn't check for updates"
                        a.informativeText = "Make sure you're connected to the internet and try again."
                        a.runModal()
                    }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                self?.handleUpdateResult(latest: latest, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleUpdateResult(latest: String, userInitiated: Bool) {
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
        let a = NSAlert()
        a.messageText     = "Axe \(latest) is available"
        a.informativeText = "You're running v\(appVersion). Run the command below in Terminal to update."
        a.addButton(withTitle: "Copy Upgrade Command")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew upgrade emerytech/axe/axe", forType: .string)
        }
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
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // Called by the Carbon hot key. Skips the toggle when the overlay is
    // already key so ⌘A can be handled as "select all" inside the panel.
    func hotkeyPressed() {
        if let p = panel, p.isVisible, p.isKeyWindow { return }
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
            if let p = self.panel, p.isVisible { self.hideOverlay() } else { self.showOverlay() }
        }
    }

    func showOverlay() {
        checkedPIDs.removeAll()
        currentKillPhrase = ""
        refreshApps()
        if panel == nil { buildPanel() }
        searchField?.stringValue = ""
        applyFilter("")

        // Position: center of the screen with the frontmost window
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let pw = panel!.frame
            panel?.setFrameOrigin(NSPoint(
                x: sf.midX - pw.width  / 2,
                y: sf.midY - pw.height / 2 + sf.height * 0.08))
        }

        // Animate in: fade + subtle scale
        let cv = panel!.contentView!
        cv.wantsLayer = true
        cv.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
        panel?.alphaValue = 0
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cv.animator().layer?.setAffineTransform(.identity)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: panel)

        DispatchQueue.main.async { [weak self] in
            guard let sf = self?.searchField else { return }
            sf.window?.makeFirstResponder(sf)
        }
    }

    func hideOverlay() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification,
                                                  object: panel)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
        })
    }

    @objc func panelResignedKey() {
        // Don't dismiss if a child window (e.g. settings) just opened
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let p = self.panel, p.isVisible,
                  !p.isKeyWindow else { return }
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

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            sortBtn.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            sortBtn.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sortBtn.widthAnchor.constraint(equalToConstant: 26),
            sortBtn.heightAnchor.constraint(equalToConstant: 26),
            sf.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            sf.trailingAnchor.constraint(equalTo: sortBtn.leadingAnchor, constant: -8),
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
        let tv = NSTableView()
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
        col.width = W; tv.addTableColumn(col)
        tableView = tv

        let sv = NSScrollView()
        sv.documentView = tv; sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false; sv.drawsBackground = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sv)

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
            // Pick a new phrase on the first tick; hold it while more boxes are added
            if currentKillPhrase.isEmpty {
                currentKillPhrase = killPhrases.randomElement() ?? "Yeet"
            }
            let btnTitle = "\(currentKillPhrase) (\(checked))"
            axeCheckedButton?.attributedTitle = NSAttributedString(
                string: btnTitle,
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            axeCheckedButton?.isHidden = false
            hintLabel?.isHidden = true
        } else {
            currentKillPhrase = ""   // reset so next session gets a fresh phrase
            axeCheckedButton?.isHidden = true
            hintLabel?.isHidden = false
            let sel = tableView?.selectedRowIndexes.count ?? 0
            if sel > 1 {
                hintLabel?.stringValue = "\(sel) selected  ·  ↵ quit  ·  ⌘↵ force kill  ·  esc close"
            } else {
                hintLabel?.stringValue = "↑↓ navigate  ·  ↵ quit  ·  ⌘↵ force kill  ·  ⌘A select all  ·  esc close"
            }
        }
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
        alert.addButton(withTitle: "Off with its head!")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Spare them for now")   // .alertSecondButtonReturn
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
            hideOverlay(); return true

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
