import AppKit
import Carbon.HIToolbox

// ─────────────────────── HotKey helpers ───────────────────────────

private func fourCC(_ s: StaticString) -> FourCharCode {
    let b = s.utf8Start
    return FourCharCode(b[0]) << 24 | FourCharCode(b[1]) << 16
         | FourCharCode(b[2]) << 8  | FourCharCode(b[3])
}

// C-compatible callback required by Carbon's InstallApplicationEventHandler.
private let hotKeyCallback: EventHandlerUPP = { _, _, userData -> OSStatus in
    guard let ud = userData else { return noErr }
    let d = Unmanaged<AppDelegate>.fromOpaque(ud).takeUnretainedValue()
    DispatchQueue.main.async { d.toggleOverlay() }
    return noErr
}

// ─────────────────────────── App entry ────────────────────────────

struct AppEntry {
    let app: NSRunningApplication
    var name: String { app.localizedName ?? app.bundleIdentifier ?? "Unknown" }
    var icon: NSImage? { app.icon }
}

// ──────────────────────── App row cell view ───────────────────────

final class AppRowCell: NSTableCellView {
    let appIcon = NSImageView()
    let appName = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        appIcon.imageScaling = .scaleAxesIndependently
        appName.font = .systemFont(ofSize: 14, weight: .regular)
        appName.lineBreakMode = .byTruncatingTail
        for v in [appIcon, appName] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 26),
            appIcon.heightAnchor.constraint(equalToConstant: 26),
            appName.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 10),
            appName.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            appName.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// ─────────────────────────── App Delegate ─────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate,
                          NSTableViewDataSource, NSTableViewDelegate,
                          NSTextFieldDelegate {

    var statusItem:  NSStatusItem!
    var panel:       NSPanel?
    var searchField: NSTextField?
    var tableView:   NSTableView?
    var hotKeyRef:   EventHotKeyRef?

    var allApps:  [AppEntry] = []
    var filtered: [AppEntry] = []

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKey()
    }

    // MARK: Status item — left-click toggles overlay; right-click shows menu

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let btn = statusItem.button!
        let img = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Axe")
        img?.isTemplate = true
        btn.image = img
        btn.action = #selector(statusItemClicked)
        btn.target = self
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            let show = NSMenuItem(title: "Show Axe  ⌥⌘K",
                                  action: #selector(toggleOverlay), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit Axe",
                                    action: #selector(NSApp.terminate(_:)),
                                    keyEquivalent: ""))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { self.statusItem.menu = nil }
        } else {
            toggleOverlay()
        }
    }

    // MARK: Global hotkey (⌥⌘K) — registered via Carbon; no Accessibility required

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind:  OSType(kEventHotKeyPressed))
        // InstallApplicationEventHandler is a C macro; call the underlying function directly.
        var handlerRef: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback,
                            1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &handlerRef)
        let hkID = EventHotKeyID(signature: fourCC("axe!"), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey),
                            hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: Overlay lifecycle

    @objc func toggleOverlay() {
        if let p = panel, p.isVisible { hideOverlay() } else { showOverlay() }
    }

    func showOverlay() {
        refreshApps()
        if panel == nil { buildPanel() }
        searchField?.stringValue = ""
        applyFilter("")
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        // Give the window a tick to become key before forwarding focus.
        DispatchQueue.main.async { [weak self] in
            guard let sf = self?.searchField else { return }
            sf.window?.makeFirstResponder(sf)
        }
    }

    func hideOverlay() {
        panel?.orderOut(nil)
    }

    // MARK: Build the Spotlight-style panel

    func buildPanel() {
        let W: CGFloat = 520
        let searchH: CGFloat = 52
        let rowH: CGFloat = 44
        let maxRows: CGFloat = 7
        let H = searchH + 1 + rowH * maxRows   // 361

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility              = .hidden
        p.titlebarAppearsTransparent   = true
        p.isMovableByWindowBackground  = true
        p.level                        = .floating
        p.isReleasedWhenClosed         = false
        p.backgroundColor              = .clear

        // Frosted glass background with rounded corners
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        bg.blendingMode = .behindWindow
        bg.material     = .popover
        bg.state        = .active
        bg.wantsLayer   = true
        bg.layer?.cornerRadius  = 12
        bg.layer?.masksToBounds = true
        p.contentView = bg

        // Search field
        let sf = NSTextField(frame: .zero)
        sf.placeholderString = "Type to filter running apps…"
        sf.isBordered    = false
        sf.isBezeled     = false
        sf.drawsBackground = false
        sf.font          = .systemFont(ofSize: 18, weight: .regular)
        sf.focusRingType = .none
        sf.delegate      = self
        sf.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sf)
        searchField = sf

        // Subtle search icon label
        let lupa = NSTextField(labelWithString: " 🔍")
        lupa.font = .systemFont(ofSize: 16)
        lupa.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(lupa)

        NSLayoutConstraint.activate([
            lupa.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            lupa.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),

            sf.leadingAnchor.constraint(equalTo: lupa.trailingAnchor, constant: 6),
            sf.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            sf.centerYAnchor.constraint(equalTo: lupa.centerYAnchor),
            sf.heightAnchor.constraint(equalToConstant: searchH),
        ])

        // Divider
        let div = NSBox(frame: .zero)
        div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(div)
        NSLayoutConstraint.activate([
            div.topAnchor.constraint(equalTo: bg.topAnchor, constant: searchH),
            div.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            div.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            div.heightAnchor.constraint(equalToConstant: 1),
        ])

        // App table
        let tv = NSTableView()
        tv.headerView              = nil
        tv.rowHeight               = rowH
        tv.gridStyleMask           = []
        if #available(macOS 12.0, *) { tv.style = .sourceList }
        else { tv.selectionHighlightStyle = .sourceList }
        tv.backgroundColor         = .clear
        tv.dataSource              = self
        tv.delegate                = self
        tv.action                  = #selector(tableClicked)
        tv.target                  = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.width = W
        tv.addTableColumn(col)
        tableView = tv

        let sv = NSScrollView(frame: .zero)
        sv.documentView          = tv
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground       = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: div.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])

        panel = p
    }

    // MARK: Running app list

    func refreshApps() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        allApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map(AppEntry.init)
    }

    func applyFilter(_ query: String) {
        filtered = query.isEmpty
            ? allApps
            : allApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        tableView?.reloadData()
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: Kill logic

    func killSelected(force: Bool) {
        let row = tableView?.selectedRow ?? -1
        guard row >= 0, row < filtered.count else { return }
        killEntry(filtered[row], force: force)
    }

    func killEntry(_ entry: AppEntry, force: Bool) {
        if force {
            entry.app.forceTerminate()
        } else {
            let pid = entry.app.processIdentifier
            entry.app.terminate()
            // Follow-up force-kill after 2 s if the app is still alive
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSRunningApplication(processIdentifier: pid)?.forceTerminate()
            }
        }
        // Refresh the list after a short tick so the app has time to exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshApps()
            self.applyFilter(self.searchField?.stringValue ?? "")
        }
    }

    // MARK: Table click — single click kills; ⌘-click force-kills

    @objc func tableClicked() {
        let row = tableView?.clickedRow ?? -1
        guard row >= 0, row < filtered.count else { return }
        let force = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        killEntry(filtered[row], force: force)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AppRow")
        let cell = tv.makeView(withIdentifier: id, owner: nil) as? AppRowCell
                   ?? { let c = AppRowCell(frame: .zero); c.identifier = id; return c }()
        let entry = filtered[row]
        cell.appName.stringValue = entry.name
        cell.appIcon.image       = entry.icon
        return cell
    }

    // MARK: NSTextFieldDelegate — search filtering + keyboard nav

    func controlTextDidChange(_ note: Notification) {
        applyFilter(searchField?.stringValue ?? "")
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):        // Esc
            hideOverlay()
            return true

        case #selector(NSResponder.insertNewline(_:)):          // Return / ⌘Return
            let force = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            killSelected(force: force)
            return true

        case #selector(NSResponder.moveUp(_:)):                 // ↑
            moveSelection(by: -1)
            return true

        case #selector(NSResponder.moveDown(_:)):               // ↓
            moveSelection(by: 1)
            return true

        default:
            return false
        }
    }

    func moveSelection(by delta: Int) {
        guard let tv = tableView, tv.numberOfRows > 0 else { return }
        let next = max(0, min(tv.numberOfRows - 1, (tv.selectedRow < 0 ? 0 : tv.selectedRow) + delta))
        tv.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tv.scrollRowToVisible(next)
    }
}

// ─────────────────────────── Entry point ──────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
