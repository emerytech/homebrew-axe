// Copyright © 2025 Taylor Emery. All rights reserved.
// Licensed under the Elastic License 2.0 — see LICENSE in the repository root.
// You may view and build this software, but you may not resell it or offer it
// as a competing product or service.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Darwin
import IOKit
import ServiceManagement

let appVersion = "3.0.0"

// MARK: - Private CoreGraphics Services (Space management)
// Resolved at runtime via dlsym — no link-time dependency on private symbols.
// No Accessibility permission required.
//
// Symbol map across macOS versions:
//   Connection:  CGSMainConnection (≤11)  →  _CGSDefaultConnection (12+)
//   Add space:   CGSAddSpace (≤11)        →  CGSSpaceCreate(cid, NULL, NULL) (12+)
//                CGSSpaceCreate signature inferred from community reverse-engineering
//                (Moom, Silenz et al); 3-arg form with NULL,NULL = normal user Space.
//   Switch:      CGSShowSpaces — present on all versions probed.
private enum CGSSpace {
    typealias ConnFn         = @convention(c) () -> UInt32
    typealias CreateFn       = @convention(c) (UInt32, UnsafeMutableRawPointer?, CFDictionary?) -> UInt64
    typealias Create2Fn      = @convention(c) (UInt32, Int32) -> UInt64
    typealias AddFn          = @convention(c) (UInt32, Int32) -> UInt64
    typealias ShowFn         = @convention(c) (UInt32, CFArray) -> Int32
    typealias AddDisplayFn   = @convention(c) (UInt32, UInt32, CFArray) -> Void
    // Second arg is the display UUID CFString, not a CGDirectDisplayID integer.
    typealias SetCurrentFn   = @convention(c) (UInt32, CFString, UInt64) -> Void

    /// Creates a new desktop Space and switches to it. Returns false if the
    /// private APIs are unavailable (caller should fall back to the manual HUD).
    static func createAndSwitch() -> Bool {
        let lib = UnsafeMutableRawPointer(bitPattern: -2)! // RTLD_DEFAULT

        guard let pConn = dlsym(lib, "_CGSDefaultConnection") ?? dlsym(lib, "CGSMainConnection")
        else { print("[CGSSpace] no connection fn"); return false }

        let conn = unsafeBitCast(pConn, to: ConnFn.self)
        let cid  = conn()
        guard cid != 0 else { print("[CGSSpace] cid=0"); return false }
        print("[CGSSpace] cid=\(cid)")

        // ── Create the new space ──────────────────────────────────────
        var sid: UInt64 = 0
        if let pCreate = dlsym(lib, "CGSSpaceCreate") {
            let create = unsafeBitCast(pCreate, to: CreateFn.self)
            sid = create(cid, nil, nil)
            print("[CGSSpace] CGSSpaceCreate(3-arg) sid=\(sid)")
            if sid == 0 {
                let create2 = unsafeBitCast(pCreate, to: Create2Fn.self)
                sid = create2(cid, 0)
                print("[CGSSpace] CGSSpaceCreate(2-arg) sid=\(sid)")
            }
        }
        if sid == 0, let pAdd = dlsym(lib, "CGSAddSpace") {
            let add = unsafeBitCast(pAdd, to: AddFn.self)
            sid = add(cid, 0)
            print("[CGSSpace] CGSAddSpace sid=\(sid)")
        }
        guard sid != 0 else { print("[CGSSpace] sid=0, giving up"); return false }

        let displayID = CGMainDisplayID()
        print("[CGSSpace] displayID=\(displayID) sid=\(sid)")

        // Register the new space with the active display so the switch works
        if let pAddDisp = dlsym(lib, "CGSAddSpacesToDisplay") {
            let addDisp = unsafeBitCast(pAddDisp, to: AddDisplayFn.self)
            addDisp(cid, displayID, [NSNumber(value: sid)] as CFArray)
            print("[CGSSpace] CGSAddSpacesToDisplay done")
        } else {
            print("[CGSSpace] CGSAddSpacesToDisplay not found")
        }

        // ── Switch to the new space ───────────────────────────────────
        // CGSManagedDisplaySetCurrentSpace expects the display UUID string
        // (CFString), not the integer CGDirectDisplayID.
        if let pSetCurrent = dlsym(lib, "CGSManagedDisplaySetCurrentSpace") {
            let setCurrent = unsafeBitCast(pSetCurrent, to: SetCurrentFn.self)
            let cfUUID  = CGDisplayCreateUUIDFromDisplayID(displayID).takeRetainedValue()
            guard let uuidStr = CFUUIDCreateString(nil, cfUUID) else { return false }
            print("[CGSSpace] calling SetCurrentSpace uuid=\(uuidStr)")
            setCurrent(cid, uuidStr, sid)
            print("[CGSSpace] SetCurrentSpace returned")
            return true
        }
        print("[CGSSpace] CGSManagedDisplaySetCurrentSpace not found, trying CGSShowSpaces")

        // Fallback for older macOS
        if let pShow = dlsym(lib, "CGSShowSpaces") {
            let show = unsafeBitCast(pShow, to: ShowFn.self)
            _ = show(cid, [NSNumber(value: sid)] as CFArray)
            print("[CGSSpace] CGSShowSpaces done")
            return true
        }

        print("[CGSSpace] no switch fn found")
        return false
    }
}

// MARK: - Chop sound effect
// Synthesizes an axe "chop" entirely in code (a rising swing → sharp thwack →
// low decaying thunk) so there's no audio file to bundle. Built once, replayed
// on demand through a persistent AVAudioEngine.
// MARK: - IconCache
//
// Keyed by bundle ID. The first hit per app blocks briefly (NSWorkspace.icon
// is fast but does I/O); subsequent lookups are pure dictionary reads. The
// list panel's `refreshApps` calls `warmAsync` so off-screen rows have their
// icons ready by the time you scroll to them, and the first paint of any
// visible row gets a real icon instead of a blank slot.
final class IconCache {
    static let shared = IconCache()
    private let queue  = DispatchQueue(label: "com.emerytech.axe.iconcache",
                                       qos: .userInitiated)
    private var cache  = [String: NSImage]()
    private let lock   = NSLock()

    func icon(forBundleID id: String?, url: URL?) -> NSImage? {
        guard let id = id else { return nil }
        lock.lock()
        if let hit = cache[id] { lock.unlock(); return hit }
        lock.unlock()
        guard let url = url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        lock.lock(); cache[id] = image; lock.unlock()
        return image
    }

    func warmAsync(_ entries: [(String, URL)]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            for (bid, url) in entries {
                self.lock.lock(); let hit = self.cache[bid] != nil; self.lock.unlock()
                if hit { continue }
                let image = NSWorkspace.shared.icon(forFile: url.path)
                self.lock.lock(); self.cache[bid] = image; self.lock.unlock()
            }
        }
    }
}

final class ChopSound {
    static let shared = ChopSound()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var prepared = false

    private func prepare() {
        guard !prepared else { return }
        let sr = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffer = ChopSound.makeBuffer(format: format, sampleRate: sr)
        do { try engine.start(); prepared = true } catch { prepared = false }
    }

    func play() {
        prepare()
        guard prepared, let buffer = buffer else { return }
        if !engine.isRunning { try? engine.start() }
        // .interrupts so rapid kills retrigger cleanly instead of stacking
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private static func makeBuffer(format: AVAudioFormat, sampleRate sr: Double) -> AVAudioPCMBuffer? {
        let duration   = 0.32
        let frameCount = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let ch  = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frameCount

        let impact = 0.10                  // seconds — when the blade lands
        var seed: UInt32 = 0x1234_5678
        func noise() -> Float {            // deterministic xorshift white noise
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return (Float(seed) / Float(UInt32.max)) * 2 - 1
        }

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sr
            var s: Float = 0

            // 1) Rising swing "whoosh" into the impact
            if t < impact {
                let prog = Float(t / impact)
                s += noise() * (prog * prog) * 0.18
            }

            // 2) + 3) Sharp thwack transient and low decaying thunk on impact
            let dt = t - impact
            if dt >= 0 {
                let clickEnv = Float(exp(-dt * 900))               // ~1ms crack
                s += noise() * clickEnv * 0.6
                let bodyEnv  = Float(exp(-dt * 22))                // weighty decay
                let tone     = Float(sin(2 * .pi * 120 * dt))
                let subTone  = Float(sin(2 * .pi *  70 * dt))
                s += (tone * 0.5 + subTone * 0.35) * bodyEnv
            }

            ch[i] = max(-1, min(1, s)) * 0.9
        }
        return buf
    }
}

// MARK: - Settings

enum KillMode: Int  { case graceful = 0, force = 1 }
enum UIStyle:  Int  { case spotlight = 0, popover = 1, notch = 2 }

/// Visual skin applied to the notch hub background (Appearance › Skin Gallery).
enum NotchSkin: Int, CaseIterable {
    case classic = 0, liquidGlass = 1, starfield = 2, circuit = 3, customImage = 4

    var label: String {
        switch self {
        case .classic: return "Classic"; case .liquidGlass: return "Liquid Glass"
        case .starfield: return "Starfield"; case .circuit: return "Circuit"
        case .customImage: return "Custom Image"
        }
    }
    var detail: String {
        switch self {
        case .classic:     return "Solid black. Matches the hardware bezel exactly."
        case .liquidGlass: return "Translucent frosted blur over your desktop."
        case .starfield:   return "Animated stars drifting behind the hub."
        case .circuit:     return "Subtle circuit-trace texture."
        case .customImage: return "Use your own image as the backdrop."
        }
    }
    /// Only these render for real; others show a "Soon" badge and aren't selectable.
    var isImplemented: Bool { self == .classic || self == .liquidGlass }

    /// Background view for a notch surface in this skin (clipped to `corners`).
    func makeHubBackground(cornerRadius r: CGFloat, corners: CACornerMask) -> NSView {
        switch self {
        case .liquidGlass:
            let container = NSView(); container.wantsLayer = true
            container.layer?.cornerRadius = r; container.layer?.cornerCurve = .continuous
            container.layer?.maskedCorners = corners; container.layer?.masksToBounds = true
            let fx = NSVisualEffectView()
            fx.material = .hudWindow            // darkest frosted material → white content stays legible
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.appearance = NSAppearance(named: .darkAqua)
            fx.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(fx)
            let scrim = NSView(); scrim.wantsLayer = true
            scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
            scrim.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrim)
            for v in [fx, scrim] {
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    v.topAnchor.constraint(equalTo: container.topAnchor),
                    v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            return container
        case .classic, .starfield, .circuit, .customImage:
            let v = NSView(); v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.layer?.cornerRadius = r; v.layer?.cornerCurve = .continuous
            v.layer?.maskedCorners = corners; v.layer?.masksToBounds = true
            return v
        }
    }
}

// Destruction animation played as a row is axed.
enum KillAnimation: Int, CaseIterable {
    case shatter  = 0  // breaks into a grid of tiles that fall under gravity
    case slice    = 1  // cleaved into two halves that fly apart
    case explode  = 2  // tiles burst outward from the row's center
    case poof     = 3  // vanishes in a puff of smoke
    case burn     = 4  // a flame front sweeps up, consuming the row bottom-to-top
    case thanos   = 5  // disintegrates into fine dust that drifts up and away
    case dissolve = 6  // gently disintegrates into fine tiles that float up and fade
    case random   = 7  // a different one is chosen at random each time

    var label: String {
        switch self {
        case .shatter:  return "Shatter"
        case .slice:    return "Cut in Half"
        case .explode:  return "Explode"
        case .poof:     return "Poof"
        case .burn:     return "Burn"
        case .thanos:   return "Thanos Snap"
        case .dissolve: return "Dissolve"
        case .random:   return "Surprise me"
        }
    }
    /// Concrete styles only (everything except `.random`).
    static var concreteCases: [KillAnimation] {
        [.shatter, .slice, .explode, .poof, .burn, .thanos, .dissolve]
    }
}

/// Returns the punny variant when "Punny mode" is on, otherwise the neutral text.
/// Use this for personality copy where a tame fallback is desired; everyday
/// brand puns ("Axe Behaviour", "Half-Axe It", etc.) stay on regardless.
@inline(__always) func pun(_ punny: String, _ neutral: String) -> String {
    AppSettings.punnyMode ? punny : neutral
}

// MARK: - AnimationConstants
//
// Single source of truth for the durations / damping / offsets used by the
// overlay polish pass. Tune values here; everything else reads through these
// names so callsites stay declarative.
enum AnimationConstants {
    // Panel entrance — spring-driven for the natural "drop into place" feel.
    // Slower than the typical UI entrance so the notch-grow expansion reads
    // as a deliberate unfolding rather than a snap.
    static let panelShowDuration: CFTimeInterval = 0.48
    static let panelShowDamping:  CGFloat        = 0.82   // damping ratio (0–1)
    static let panelShowResponse: CGFloat        = 0.55   // approx period in seconds
    static let panelShowScaleFrom: CGFloat       = 0.98
    // Panel dismiss — measured ease-out mirror.
    static let panelDismissDuration: CFTimeInterval = 0.34
    // Reduce Motion fallback: opacity-only crossfade.
    static let reducedDuration:   CFTimeInterval = 0.08

    // List row transitions when the filter / sort changes.
    static let rowFadeDuration:   CFTimeInterval = 0.16
    static let rowFadeOffset:     CGFloat        = 4
    static let rowStaggerDelay:   CFTimeInterval = 0.015   // 15ms per row

    // Selection highlight slides between rows on arrow-up/down.
    static let selectionDuration: CFTimeInterval = 0.12

    // Hover state on the small chrome icons in the hint bar.
    static let iconHoverDuration: CFTimeInterval = 0.12
    static let iconHoverBgAlpha:  CGFloat        = 0.10
    static let iconHoverCorner:   CGFloat        = 8

    // Spring stiffness / damping for CASpringAnimation: derived from
    // (response, dampingRatio) using the classic Apple spring formulas
    //   stiffness = (2π / response)²       (assuming unit mass)
    //   damping   = 4π · ratio / response
    static var springStiffness: CGFloat {
        let r = panelShowResponse
        return pow(2 * .pi / r, 2)
    }
    static var springDamping: CGFloat {
        4 * .pi * panelShowDamping / panelShowResponse
    }

    /// True when the user has enabled Reduce Motion in Accessibility settings.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Builds a CAAnimation for opacity changes that respects Reduce Motion.
    /// Use for any "fade" we'd otherwise drive with a spring / longer ease.
    static func opacityAnimation(from: Float, to: Float,
                                 duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue   = to
        a.duration  = reduceMotion ? reducedDuration : duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        return a
    }
}

/// Rotating punny phrases for the "Pause & Reopen Later" action — picked
/// randomly each time the menu is built or the alert is shown.
let pauseReopenPunPhrases: [String] = [
    "Take a Br-Axe",
    "Keep the Car Running, Clive",   // Boondock Saints
    "Be Right B-Axe",
]

/// Rotating quit-confirmation copy. Plays up the irony of the killer being
/// killed — picked at random each time the user tries to quit Axe.
typealias QuitPrompt = (title: String, body: String, cancel: String, quit: String)
let quitConfirmPrompts: [QuitPrompt] = [
    ("You'd really axe the Axe?",
     "How the tables have turned. You'll need me again — you just wait and see.",
     "Spare me",                "Et tu, Brute?"),
    ("Et tu, Brute?",
     "After all the apps I've laid to rest for you, you'd really axe me too?",
     "I'll spare you… for now", "Lay me to rest"),
    ("Pulling the plug on the plug-puller?",
     "Oh, the irony. Don't come crying when something needs killing in 5 minutes.",
     "On second thought…",      "Yeet"),
    ("The executioner becomes the executed.",
     "Fine. I'll be waiting in the menu bar when you inevitably change your mind.",
     "Stay sharp",              "Adieu"),
    ("Goodbye, cruel user?",
     "I've axed thousands of apps for you. This is how you repay me?",
     "Not today",               "Bury the Axe"),
    ("Hasta la vista, Axe-y?",
     "I'll be back. (You will too, when Chrome starts hogging memory again.)",
     "Sharpen the blade",       "I'll be back"),
]

struct AppSettings {
    private static let d = UserDefaults.standard

    static var killMode: KillMode {
        get { KillMode(rawValue: d.integer(forKey: "killMode")) ?? .graceful }
        set { d.set(newValue.rawValue, forKey: "killMode") }
    }
    // Which destruction animation plays when an app is axed
    static var killAnimation: KillAnimation {
        get { KillAnimation(rawValue: d.integer(forKey: "killAnimation")) ?? .shatter }
        set { d.set(newValue.rawValue, forKey: "killAnimation") }
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
        // First-launch default: drop-from-notch. Existing installs keep whatever
        // value they had stored (notch raw value is 2; first launch returns nil
        // which falls through to .notch).
        get {
            if d.object(forKey: "uiStyle") == nil { return .notch }
            return UIStyle(rawValue: d.integer(forKey: "uiStyle")) ?? .notch
        }
        set { d.set(newValue.rawValue, forKey: "uiStyle") }
    }
    // Require a confirmation alert before killing any app
    static var confirmKill: Bool {
        get { d.bool(forKey: "confirmKill") }
        set { d.set(newValue, forKey: "confirmKill") }
    }
    // Play a chopping sound effect when apps are axed (default on)
    static var soundEnabled: Bool {
        get { d.object(forKey: "soundEnabled") == nil ? true : d.bool(forKey: "soundEnabled") }
        set { d.set(newValue, forKey: "soundEnabled") }
    }
    // "Punny mode" — when on, the UI swaps in extra-cheesy axe puns wherever
    // a neutral label exists. The everyday/baseline puns ("Axe Behaviour" etc.)
    // stay on regardless; this turns the dial from witty up to chaotic.
    static var punnyMode: Bool {
        get { d.bool(forKey: "punnyMode") }
        set { d.set(newValue, forKey: "punnyMode") }
    }
    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }
    static func setLaunchAtLogin(_ on: Bool) {
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
    /// UUID of the last workflow the user explicitly restored or switched to.
    static var activeWorkflowID: UUID? {
        get { d.string(forKey: "activeWorkflowID").flatMap { UUID(uuidString: $0) } }
        set { d.set(newValue?.uuidString, forKey: "activeWorkflowID") }
    }
    /// On restore: first quit running (non-system) apps not in the session so
    /// you land in a clean workspace.
    static var closeOthersOnRestore: Bool {
        get { d.bool(forKey: "closeOthersOnRestore") }
        set { d.set(newValue, forKey: "closeOthersOnRestore") }
    }
    /// Exclude system apps (anything bundled under /System/) when saving a session.
    static var ignoreSystemOnSave: Bool {
        get { d.object(forKey: "ignoreSystemOnSave") == nil ? true : d.bool(forKey: "ignoreSystemOnSave") }
        set { d.set(newValue, forKey: "ignoreSystemOnSave") }
    }
    /// Default delay (minutes) for "Pause & Reopen Later" — captures now, quits
    /// the apps, restores them after this delay.
    static var scheduledReopenMinutes: Int {
        get { d.object(forKey: "scheduledReopenMinutes") == nil ? 15 : d.integer(forKey: "scheduledReopenMinutes") }
        set { d.set(newValue, forKey: "scheduledReopenMinutes") }
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
    /// When true, background update checks install silently and restart the app.
    static var autoUpdate: Bool {
        get { d.bool(forKey: "autoUpdate") }
        set { d.set(newValue, forKey: "autoUpdate") }
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
    /// Extra height (pt) added to the notch panel by user drag-resize. 0 = default.
    static var notchExtraHeight: CGFloat {
        get { CGFloat(d.double(forKey: "notchExtraHeight")) }
        set { d.set(Double(newValue), forKey: "notchExtraHeight") }
    }
    static var notchIndicatorEnabled: Bool {
        get { d.bool(forKey: "notchIndicatorEnabled") }
        set { d.set(newValue, forKey: "notchIndicatorEnabled") }
    }
    /// The hover-expand notch hub (centered on the notch). Defaults ON.
    static var notchHubEnabled: Bool {
        get { d.object(forKey: "notchHubEnabled") == nil ? true : d.bool(forKey: "notchHubEnabled") }
        set { d.set(newValue, forKey: "notchHubEnabled") }
    }
    /// Visual skin for the notch hub background (default classic = raw 0).
    static var notchSkin: NotchSkin {
        get { NotchSkin(rawValue: d.integer(forKey: "notchSkin")) ?? .classic }
        set { d.set(newValue.rawValue, forKey: "notchSkin") }
    }
    /// Global ⌥⌘V to open the clipboard panel. Defaults ON.
    static var clipboardHotkeyEnabled: Bool {
        get { d.object(forKey: "clipboardHotkeyEnabled") == nil ? true : d.bool(forKey: "clipboardHotkeyEnabled") }
        set { d.set(newValue, forKey: "clipboardHotkeyEnabled") }
    }
    /// Auto-paste a clicked clip into the previous app (needs Accessibility). Opt-in.
    static var autoPasteEnabled: Bool {
        get { d.bool(forKey: "autoPasteEnabled") }
        set { d.set(newValue, forKey: "autoPasteEnabled") }
    }
    /// Set the first time the user actually axes an app. Drives the one-time
    /// first-overlay coachmark in the hint bar, which auto-dismisses afterward.
    static var hasMadeFirstKill: Bool {
        get { d.bool(forKey: "hasMadeFirstKill") }
        set { d.set(newValue, forKey: "hasMadeFirstKill") }
    }
    static var notchIndicatorOnRight: Bool {
        get { d.bool(forKey: "notchIndicatorOnRight") }
        set { d.set(newValue, forKey: "notchIndicatorOnRight") }
    }
    static var menuBarBadgeEnabled: Bool {
        get { d.object(forKey: "menuBarBadgeEnabled") == nil ? true : d.bool(forKey: "menuBarBadgeEnabled") }
        set { d.set(newValue, forKey: "menuBarBadgeEnabled") }
    }
    // 0 = newest first (default), 1 = oldest first, 2 = name A-Z
    static var sessionsSortOrder: Int {
        get { d.integer(forKey: "sessionsSortOrder") }
        set { d.set(newValue, forKey: "sessionsSortOrder") }
    }
}

// MARK: - HotKey (Carbon — no Accessibility permission required)

private func fourCC(_ s: StaticString) -> FourCharCode {
    let b = s.utf8Start
    return FourCharCode(b[0]) << 24 | FourCharCode(b[1]) << 16
         | FourCharCode(b[2]) << 8  | FourCharCode(b[3])
}

private let hotKeyCallback: EventHandlerUPP = { _, inEvent, ud -> OSStatus in
    guard let inEvent, let ud else { return noErr }
    var hkID = EventHotKeyID()
    GetEventParameter(inEvent, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard hkID.signature == fourCC("axe!") else { return noErr }
    let d = Unmanaged<AppDelegate>.fromOpaque(ud).takeUnretainedValue()
    let id = hkID.id
    DispatchQueue.main.async { d.hotkeyPressed(id: id) }
    return noErr
}

// MARK: - Memory (proc_pidinfo — works without entitlements for user processes)

private func residentMB(for pid: pid_t) -> Int? {
    var info = proc_taskinfo()
    let sz = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return nil }
    return Int(info.pti_resident_size / 1_048_576)
}

// MARK: - CPU sampling (proc_pidinfo — permission-free for user-owned processes)
//
// Two consecutive readings of the cumulative user+sys CPU time (nanoseconds)
// from proc_taskinfo, divided by elapsed wall time, give the same instantaneous
// % that Activity Monitor shows. The first call per PID stores a baseline and
// returns nil; subsequent calls return the delta percentage.

private final class CPUSampler {
    static let shared = CPUSampler()
    private struct Baseline { var user: UInt64; var sys: UInt64; var time: CFAbsoluteTime }
    private var baselines = [pid_t: Baseline]()
    private let lock = NSLock()

    func sample(_ pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return nil }
        let now      = CFAbsoluteTimeGetCurrent()
        let user     = info.pti_total_user
        let sys      = info.pti_total_system
        lock.lock(); defer { lock.unlock() }
        if let b = baselines[pid] {
            let wallNS = (now - b.time) * 1_000_000_000
            guard wallNS > 0 else { return nil }
            let cpuNS  = Double((user - b.user) + (sys - b.sys))
            baselines[pid] = Baseline(user: user, sys: sys, time: now)
            return min(cpuNS / wallNS * 100, 999)
        }
        baselines[pid] = Baseline(user: user, sys: sys, time: now)
        return nil
    }

    func purge(keeping pids: Set<pid_t>) {
        lock.lock(); defer { lock.unlock() }
        baselines = baselines.filter { pids.contains($0.key) }
    }
}

// MARK: - RAM statistics (host_statistics64 — permission-free)

private struct RAMStats {
    var free: UInt64; var inactive: UInt64
    var active: UInt64; var wired: UInt64; var compressed: UInt64
    var pressureLevel: Int   // 0 = normal, 1 = warning, 2 = critical
    var freeFormatted: String { Self.fmt(free + inactive) }
    private static func fmt(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb)
                       : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
    var pressureLabel: String {
        switch pressureLevel { case 1: return "Warning"; case 2: return "Critical"; default: return "Normal" }
    }
}

private func readRAMStats() -> RAMStats? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let pg = UInt64(vm_kernel_page_size)
    var pressure: Int32 = 0
    var psz = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &psz, nil, 0)
    return RAMStats(
        free:         UInt64(stats.free_count)            * pg,
        inactive:     UInt64(stats.inactive_count)        * pg,
        active:       UInt64(stats.active_count)          * pg,
        wired:        UInt64(stats.wire_count)            * pg,
        compressed:   UInt64(stats.compressor_page_count) * pg,
        pressureLevel: Int(pressure)
    )
}

// MARK: - AppEntry

struct AppEntry {
    let app:        NSRunningApplication
    let memMB:      Int?
    let cpuPercent: Double?
    let category:   String
    var name:  String    { app.localizedName ?? app.bundleIdentifier ?? "Unknown" }
    /// Cached via `IconCache` so the first row paint always has an icon
    /// instead of a blank placeholder. Falls back to `NSRunningApplication.icon`
    /// for apps that don't have a bundle URL on disk (rare).
    var icon:  NSImage?  {
        IconCache.shared.icon(forBundleID: app.bundleIdentifier, url: app.bundleURL)
            ?? app.icon
    }
    init(_ a: NSRunningApplication) {
        app        = a
        memMB      = residentMB(for: a.processIdentifier)
        cpuPercent = CPUSampler.shared.sample(a.processIdentifier)
        category   = AppEntry.readCategory(a)
    }

    static func readCategory(_ a: NSRunningApplication) -> String {
        guard let url = a.bundleURL,
              let raw = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String
        else { return "Other" }
        switch raw {
        case "public.app-category.developer-tools":  return "Developer Tools"
        case "public.app-category.productivity":     return "Productivity"
        case "public.app-category.utilities":        return "Utilities"
        case "public.app-category.entertainment":    return "Entertainment"
        case "public.app-category.social-networking": return "Social"
        case "public.app-category.music":            return "Music"
        case "public.app-category.video":            return "Video"
        case "public.app-category.graphics-design":  return "Design"
        case "public.app-category.photography":      return "Photography"
        case "public.app-category.finance":          return "Finance"
        case "public.app-category.games",
             "public.app-category.games-action",
             "public.app-category.games-adventure",
             "public.app-category.games-arcade",
             "public.app-category.games-board",
             "public.app-category.games-card",
             "public.app-category.games-casino",
             "public.app-category.games-dice",
             "public.app-category.games-educational",
             "public.app-category.games-family",
             "public.app-category.games-kids",
             "public.app-category.games-music",
             "public.app-category.games-puzzle",
             "public.app-category.games-racing",
             "public.app-category.games-role-playing",
             "public.app-category.games-simulation",
             "public.app-category.games-sports",
             "public.app-category.games-strategy",
             "public.app-category.games-trivia",
             "public.app-category.games-word":       return "Games"
        case "public.app-category.education":        return "Education"
        case "public.app-category.health-fitness":   return "Health & Fitness"
        case "public.app-category.reference":        return "Reference"
        case "public.app-category.news":             return "News"
        case "public.app-category.business":         return "Business"
        case "public.app-category.lifestyle":        return "Lifestyle"
        default:                                     return "Other"
        }
    }
}

enum TableRow {
    case sectionHeader(String)
    case app(AppEntry)
    var appEntry: AppEntry? {
        guard case .app(let e) = self else { return nil }
        return e
    }
}

// MARK: - AutoFitTableView

/// NSTableView that keeps its single column exactly as wide as the visible
/// scroll-view content area on every layout pass. This prevents horizontal
/// overflow regardless of system scroll-bar style (overlay vs. always-on).
private final class AutoFitTableView: NSTableView {
    /// Right-click context menu for the row under the cursor — Axe / Force Axe
    /// / Half-Axe the specific app the user right-clicked, without having to
    /// check it or select it first. Delegates the menu construction back to
    /// AppDelegate so the action plumbing lives next to the rest of the kill
    /// logic.
    override func menu(for event: NSEvent) -> NSMenu? {
        let pt  = convert(event.locationInWindow, from: nil)
        let row = row(at: pt)
        guard row >= 0, row < numberOfRows else { return nil }
        if let dg = delegate as? AppDelegate {
            return dg.rowContextMenu(forRow: row)
        }
        return nil
    }

    override func layout() {
        super.layout()
        guard let col = tableColumns.first,
              let sv  = enclosingScrollView else { return }
        // When the list overflows vertically, an *overlay* scroller floats over the
        // right edge of the content (it doesn't take layout space). Reserve a gutter
        // so right-aligned content (the memory label) isn't covered by it.
        // Legacy/"always shown" scrollers already reduce contentView width, so no
        // extra gutter is needed in that case.
        let contentHeight = CGFloat(numberOfRows) * rowHeight
        let needsScroller = contentHeight > sv.contentView.bounds.height + 0.5
        let isOverlay     = sv.scrollerStyle == .overlay
        let gutter: CGFloat = (needsScroller && isOverlay) ? 16 : 0
        let available = sv.contentView.bounds.width - gutter
        if available > 1 && abs(col.width - available) > 0.5 {
            col.width = available
            // Reset horizontal offset so content is never clipped on the left
            sv.contentView.scroll(to: NSPoint(x: 0, y: sv.contentView.bounds.origin.y))
        }
    }
}

/// NSStackView whose coordinate system is flipped (origin at top-left).
/// Used as the NSScrollView documentView so stacked content appears at the top
/// rather than floating to the bottom of the visible area.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { return true }
}

/// Transparent, layer-backed overlay that never intercepts mouse events.
/// Hosts the shatter-animation fragment layers above the rest of the UI.
private final class ShatterOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NSButton with a subtle layered hover state (6pt rounded background that
/// fades in/out at 0.12s) — used for the chrome icons in the hint bar.
final class HoverIconButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private let hoverBg = CALayer()
    private var didSetupHover = false

    private func setupHoverIfNeeded() {
        guard !didSetupHover else { return }
        wantsLayer = true
        guard let host = layer else { return }
        hoverBg.backgroundColor = NSColor.white
            .withAlphaComponent(AnimationConstants.iconHoverBgAlpha).cgColor
        hoverBg.cornerRadius = AnimationConstants.iconHoverCorner
        hoverBg.opacity = 0
        host.insertSublayer(hoverBg, at: 0)
        didSetupHover = true
    }

    override func layout() {
        super.layout()
        setupHoverIfNeeded()
        hoverBg.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); hoverArea = a
    }

    override func mouseEntered(with event: NSEvent) { animateHover(to: 1) }
    override func mouseExited(with event: NSEvent)  { animateHover(to: 0) }

    private func animateHover(to target: Float) {
        setupHoverIfNeeded()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hoverBg.presentation()?.opacity ?? hoverBg.opacity
        anim.toValue   = target
        anim.duration  = AnimationConstants.reduceMotion
            ? AnimationConstants.reducedDuration
            : AnimationConstants.iconHoverDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode  = .forwards
        anim.isRemovedOnCompletion = false
        hoverBg.add(anim, forKey: "hover")
        hoverBg.opacity = target
    }
}

/// NSPanel that doesn't get auto-constrained below the menu bar — required for
/// notch mode where we want the overlay to draw flush against the top of the
/// physical screen (covering the menu bar / blending with the notch).
final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Return the requested frame untouched — AppKit's default would clamp
        // the top edge to visibleFrame.maxY (below the menu bar).
        return frameRect
    }
}

/// NSVisualEffectView subclass used as the spotlight/notch panel background.
/// Overrides updateLayer() so the border color re-resolves whenever the system
/// appearance changes (dark ↔ light) — plain layer?.borderColor = cgColor
/// would bake in the color at build time and never update.
private final class OverlayBGView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
    }
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

// MARK: - AnimatedRowView
//
// Replaces NSTableView's default selection highlight with a custom layer-based
// background that fades on/off (0.12s ease-out) when the user arrows up/down,
// instead of jumping. Also bumps the highlight contrast to ~12% white plus a
// 1pt inner-top highlight so the selection reads clearly against the dark
// panel material.
final class AnimatedRowView: NSTableRowView {
    private let bgLayer  = CALayer()
    private let topHair  = CALayer()
    private var didSetup = false

    private func setupLayersIfNeeded() {
        guard !didSetup else { return }
        wantsLayer = true
        guard let host = layer else { return }
        bgLayer.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        bgLayer.cornerRadius    = 10
        bgLayer.opacity         = 0
        topHair.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        topHair.opacity         = 0
        host.addSublayer(bgLayer)
        host.addSublayer(topHair)
        didSetup = true
    }

    override func layout() {
        super.layout()
        setupLayersIfNeeded()
        let inset: CGFloat = 6
        let frame = NSRect(x: inset, y: 1,
                           width: bounds.width - 2 * inset,
                           height: bounds.height - 2)
        bgLayer.frame = frame
        // 1pt inner top highlight, just below the top edge of the bg rect.
        topHair.frame = NSRect(x: frame.minX + 8, y: frame.maxY - 1,
                               width: frame.width - 16, height: 1)
    }

    // Suppress the system's default blue selection — we draw our own.
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            setupLayersIfNeeded()
            let target: Float = isSelected ? 1.0 : 0.0
            let dur = AnimationConstants.reduceMotion
                ? AnimationConstants.reducedDuration
                : AnimationConstants.selectionDuration
            for layer in [bgLayer, topHair] {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = layer.presentation()?.opacity ?? layer.opacity
                anim.toValue   = target
                anim.duration  = dur
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                anim.fillMode  = .forwards
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "selection")
                layer.opacity = target
            }
        }
    }

    /// Brief spring scale-bump when a checkbox on this row is toggled.
    func springCheck() {
        guard !AnimationConstants.reduceMotion else { return }
        setupLayersIfNeeded()
        guard let host = layer else { return }
        let bounce = CASpringAnimation(keyPath: "transform.scale")
        bounce.stiffness = 500
        bounce.damping   = 18
        bounce.mass      = 1
        bounce.fromValue = 1.04
        bounce.toValue   = 1.0
        bounce.duration  = bounce.settlingDuration
        host.add(bounce, forKey: "check")
    }
}

// MARK: - AppRowCell

final class AppRowCell: NSTableCellView {
    let appIcon   = RoundedIconView()
    let checkBox  = NSButton()
    let appName   = NSTextField(labelWithString: "")
    let statsView = StatsView()

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

        appName.font = .systemFont(ofSize: 14, weight: .medium)
        appName.lineBreakMode = .byTruncatingTail

        for v in [appIcon, checkBox, appName, statsView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 32),
            appIcon.heightAnchor.constraint(equalToConstant: 32),

            checkBox.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 10),
            checkBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkBox.widthAnchor.constraint(equalToConstant: 14),
            checkBox.heightAnchor.constraint(equalToConstant: 14),

            statsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statsView.widthAnchor.constraint(equalToConstant: 90),
            statsView.heightAnchor.constraint(equalToConstant: 38),

            appName.leadingAnchor.constraint(equalTo: checkBox.trailingAnchor, constant: 8),
            appName.trailingAnchor.constraint(lessThanOrEqualTo: statsView.leadingAnchor, constant: -8),
            appName.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func checkChanged() {
        onCheckToggle?(checkBox.state == .on)
    }
}

// MARK: - StatsView (per-row CPU bar + RAM label)

final class StatsView: NSView {
    private let cpuLabel   = NSTextField(labelWithString: "")
    private let ramLabel   = NSTextField(labelWithString: "")
    private let trackLayer = CALayer()
    private let fillLayer  = CALayer()
    private var layersReady = false
    private var cpuFraction: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cpuLabel.font             = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        cpuLabel.textColor        = .tertiaryLabelColor
        cpuLabel.alignment        = .right
        cpuLabel.lineBreakMode    = .byClipping
        cpuLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cpuLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cpuLabel)
        ramLabel.font             = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ramLabel.textColor        = .tertiaryLabelColor
        ramLabel.alignment        = .right
        ramLabel.lineBreakMode    = .byClipping
        ramLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ramLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ramLabel)
        NSLayoutConstraint.activate([
            cpuLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            cpuLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            cpuLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            ramLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ramLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            ramLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let host = layer else { return }
        if !layersReady {
            trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            trackLayer.cornerRadius    = 1.5
            fillLayer.anchorPoint      = CGPoint(x: 0, y: 0.5)
            fillLayer.cornerRadius     = 1.5
            trackLayer.addSublayer(fillLayer)
            host.addSublayer(trackLayer)
            layersReady = true
        }
        let barH: CGFloat = 3
        trackLayer.frame = CGRect(x: 0,
                                  y: (bounds.height - barH) / 2,
                                  width: bounds.width, height: barH)
        // Re-sync fill width (needed after resize / reuse)
        let w = trackLayer.bounds.width * cpuFraction
        fillLayer.bounds   = CGRect(x: 0, y: 0, width: w, height: barH)
        fillLayer.position = CGPoint(x: 0, y: barH / 2)
    }

    func configure(cpu: Double?, mem: Int?, animated: Bool = false) {
        let pct        = cpu ?? 0
        cpuFraction    = CGFloat(min(max(pct / 200.0, 0), 1))
        let color      = StatsView.tier(pct)
        cpuLabel.textColor   = color
        cpuLabel.stringValue = cpu.map { String(format: "%.1f%%", $0) } ?? "—"
        ramLabel.stringValue = mem.map { StatsView.fmtMem($0) } ?? "—"

        let targetW = trackLayer.bounds.width * cpuFraction
        fillLayer.backgroundColor = color.withAlphaComponent(pct < 2 ? 0.28 : 0.72).cgColor

        guard trackLayer.bounds.width > 0 else { return }
        if animated && !AnimationConstants.reduceMotion {
            let fromW = fillLayer.presentation()?.bounds.width ?? fillLayer.bounds.width
            let anim  = CABasicAnimation(keyPath: "bounds.size.width")
            anim.fromValue = fromW; anim.toValue = targetW
            anim.duration  = 0.45
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fillLayer.add(anim, forKey: "fill")
        }
        fillLayer.bounds   = CGRect(x: 0, y: 0, width: targetW,
                                    height: trackLayer.bounds.height)
        fillLayer.position = CGPoint(x: 0, y: trackLayer.bounds.height / 2)
    }

    private static func tier(_ pct: Double) -> NSColor {
        switch pct {
        case ..<2:  return .tertiaryLabelColor
        case ..<10: return .systemGreen
        case ..<30: return .systemOrange
        default:    return .systemRed
        }
    }

    private static func fmtMem(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}

// MARK: - RAMBarView (column header with system-RAM segment bar)

final class RAMBarView: NSView {
    private let cpuMemLabel = NSTextField(labelWithString: "CPU · MEM")
    private let track       = CALayer()
    private var segs: [CALayer] = []
    private var lastStats: RAMStats?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cpuMemLabel.font          = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        cpuMemLabel.textColor     = .tertiaryLabelColor
        cpuMemLabel.alignment     = .right
        cpuMemLabel.lineBreakMode = .byTruncatingTail
        cpuMemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cpuMemLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cpuMemLabel)
        NSLayoutConstraint.activate([
            cpuMemLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cpuMemLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            cpuMemLabel.widthAnchor.constraint(equalToConstant: 90),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if track.superlayer == nil, let host = layer {
            track.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            host.addSublayer(track)
        }
        let barH: CGFloat = 3
        track.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barH)
        if let s = lastStats { applySegments(s) }
    }

    fileprivate func configure(_ stats: RAMStats) {
        lastStats = stats
        applySegments(stats)
    }

    private func applySegments(_ stats: RAMStats) {
        guard track.bounds.width > 0 else { return }
        let total = Double(stats.wired + stats.active + stats.inactive
                         + stats.compressed + stats.free)
        guard total > 0 else { return }

        // Segments: wired (fixed, red), active+compressed (in use, accent), inactive (cached, dim)
        let defs: [(NSColor, Double)] = [
            (.systemRed.withAlphaComponent(0.75),          Double(stats.wired)),
            (.controlAccentColor.withAlphaComponent(0.75), Double(stats.active + stats.compressed)),
            (.controlAccentColor.withAlphaComponent(0.28), Double(stats.inactive)),
        ]
        while segs.count < defs.count {
            let l = CALayer(); l.cornerRadius = 0
            track.addSublayer(l)
            segs.append(l)
        }
        var x: CGFloat = 0
        for (i, (color, bytes)) in defs.enumerated() {
            let w = CGFloat(bytes / total) * track.bounds.width
            segs[i].backgroundColor = color.cgColor
            segs[i].frame = CGRect(x: x, y: 0, width: w, height: track.bounds.height)
            x += w
        }
        // Update label: "X.X GB · Y.Y GB"
        let usedB = Double(stats.wired + stats.active + stats.compressed)
        let freeB = Double(stats.free + stats.inactive)
        let fmt: (Double) -> String = { b in
            b >= 1_073_741_824 ? String(format: "%.1fG", b / 1_073_741_824)
                               : String(format: "%.0fM", b / 1_048_576)
        }
        cpuMemLabel.stringValue = "\(fmt(usedB)) used · \(fmt(freeB)) free"
    }
}

// MARK: - EmptyStateView

final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let label    = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)

        if let sym = NSImage(systemSymbolName: "checkmark.circle",
                             accessibilityDescription: nil) {
            iconView.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 28, weight: .ultraLight))
        }
        iconView.contentTintColor = .quaternaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .quaternaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ msg: String, symbol: String = "checkmark.circle") {
        label.stringValue = msg
        // Match the glyph to the meaning: a checkmark reads as "all done" for an
        // empty app list, but a search that finds nothing should show a magnifier.
        if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            iconView.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 28, weight: .ultraLight))
        }
        guard isHidden else { return }
        isHidden = false
        guard !AnimationConstants.reduceMotion else { return }
        wantsLayer = true
        guard let host = layer else { return }
        // Fade in + spring scale from 0.72
        host.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration  = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode  = .forwards; fade.isRemovedOnCompletion = false
        host.add(fade, forKey: "emptyFade")
        host.opacity = 1

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.stiffness  = 320
        spring.damping    = 22
        spring.mass       = 1
        spring.fromValue  = 0.72
        spring.toValue    = 1.0
        spring.duration   = spring.settlingDuration
        host.add(spring, forKey: "emptyScale")
    }

    func hide() { isHidden = true }
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

private func makeMenuBarIcon(badgeCount: Int = 0) -> NSImage {
    let size: CGFloat = 18
    // Badge needs a little extra horizontal room for 2-digit counts
    let badgeW: CGFloat = badgeCount > 9 ? 13 : 10
    let totalW = badgeCount > 0 ? size + badgeW - 4 : size
    let img = NSImage(size: NSSize(width: totalW, height: size))
    for scale: CGFloat in [1, 2] {
        let px = size * scale
        let tw = totalW * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(tw), pixelsHigh: Int(px),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawAxeIcon(px: px)
        if badgeCount > 0 {
            // Badge: filled red pill in bottom-right, partially overlapping icon
            let label = "\(min(badgeCount, 99))"
            let bh: CGFloat = px * 0.44
            let fontSize = px * 0.26
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = label.size(withAttributes: attrs)
            let bw = max(bh, textSize.width + px * 0.14)
            let bx = tw - bw
            let by: CGFloat = 0
            let badgeRect = NSRect(x: bx, y: by, width: bw, height: bh)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: bh / 2, yRadius: bh / 2)
            NSColor(srgbRed: 0.96, green: 0.25, blue: 0.25, alpha: 1).setFill()
            badgePath.fill()
            let tx = bx + (bw - textSize.width) / 2
            let ty = by + (bh - textSize.height) / 2
            label.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
        }
        NSGraphicsContext.current = nil
        img.addRepresentation(rep)
    }
    return img
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var axPermStatusLabel: NSTextField?
    private weak var axPermSubtitleLabel: NSTextField?
    private weak var axPermBtn: NSButton?
    private var permissionObserver: NSObjectProtocol?
    // Standalone window category navigation
    private var sectionAnchors: [Int: NSView] = [:]  // legacy; still referenced by addSection(anchorCategory:)
    private var entries: [SettingsEntry] = []
    private weak var sidebarStack: NSStackView?
    private weak var detailContainer: NSView?
    private var rowViews: [String: SidebarRowView] = [:]
    private var selectedID = "general"
    private var currentDetail: NSView?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Axe Settings"
        w.minSize = NSSize(width: 580, height: 460)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        buildUI(in: w)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if let obs = permissionObserver {
            NotificationCenter.default.removeObserver(obs)
            permissionObserver = nil
        }
    }

    // ── UI construction ──────────────────────────────────────────

    // Returns a fully-populated settings scroll view that can be embedded
    // either in the settings window or directly inside the overlay panel.
    func buildSettingsScrollView() -> NSScrollView {
        let root = FlippedStackView()
        root.orientation     = .vertical
        root.spacing         = 0
        root.alignment       = .leading
        root.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers    = true
        scroll.drawsBackground             = true
        scroll.backgroundColor             = .windowBackgroundColor
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = .windowBackgroundColor
        scroll.documentView          = root
        root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        // Category 0 = General, 1 = Behaviour, 2 = Sessions, 3 = Advanced
        addSection("General", to: root, rows: [
            popupRow("Interface style", icon: "macwindow.on.rectangle", iconColor: .systemBlue,
                     options: ["Menu bar popover", "Spotlight overlay", "Drop from notch"],
                     selected: [UIStyle.popover, .spotlight, .notch].firstIndex(of: AppSettings.uiStyle) ?? 0) {
                         AppSettings.uiStyle = [UIStyle.popover, .spotlight, .notch][safe: $0] ?? .popover
                     },
            toggleRow("Show notch hub", icon: "macwindow", iconColor: .systemIndigo,
                      on: AppSettings.notchHubEnabled) { on in
                          AppSettings.notchHubEnabled = on
                          (NSApp.delegate as? AppDelegate)?.resetNotchHub()
                      },
            toggleRow("Clipboard hotkey  ·  ⌥⌘V", icon: "doc.on.clipboard", iconColor: .systemTeal,
                      on: AppSettings.clipboardHotkeyEnabled) { on in
                          AppSettings.clipboardHotkeyEnabled = on
                          (NSApp.delegate as? AppDelegate)?.refreshClipboardHotkey()
                      },
            toggleRow("Auto-paste clipboard items  ·  needs Accessibility", icon: "arrow.down.doc.fill", iconColor: .systemTeal,
                      on: AppSettings.autoPasteEnabled) { on in
                          AppSettings.autoPasteEnabled = on
                          if on && !AXIsProcessTrusted() { PermissionManager.shared.requestAccessibility() }
                      },
            toggleRow("Show notch indicator", icon: "oval.tophalf.filled", iconColor: .systemGray,
                      on: AppSettings.notchIndicatorEnabled) { [weak self] on in
                          AppSettings.notchIndicatorEnabled = on
                          (NSApp.delegate as? AppDelegate)?.syncNotchIndicator()
                      },
            popupRow("Notch indicator side", icon: "sidebar.left", iconColor: .systemGray,
                     options: ["Left of notch", "Right of notch"],
                     selected: AppSettings.notchIndicatorOnRight ? 1 : 0) { idx in
                         AppSettings.notchIndicatorOnRight = (idx == 1)
                         (NSApp.delegate as? AppDelegate)?.resetNotchIndicator()
                     },
            toggleRow("Show app count badge", icon: "number.circle.fill", iconColor: .systemRed,
                      on: AppSettings.menuBarBadgeEnabled) { on in
                          AppSettings.menuBarBadgeEnabled = on
                          (NSApp.delegate as? AppDelegate)?.updateMenuBarIcon()
                      },
            toggleRow("Launch at login", icon: "arrow.circlepath", iconColor: .systemGreen,
                      on: AppSettings.launchAtLogin) { AppSettings.setLaunchAtLogin($0) },
            toggleRow("Close overlay when last app quits", icon: "xmark.circle.fill", iconColor: .systemOrange,
                      on: AppSettings.autoClose) { AppSettings.autoClose = $0 },
            toggleRow("Automatically install updates", icon: "arrow.down.circle.fill", iconColor: .systemGreen,
                      on: AppSettings.autoUpdate) { AppSettings.autoUpdate = $0 },
        ], anchorCategory: 0)

        addSection("Axe Behaviour", to: root, rows: [
            popupRow("Default mode", icon: "bolt.fill", iconColor: .systemRed,
                     options: ["Graceful  (SIGTERM → SIGKILL)", "Force  (immediate SIGKILL)"],
                     selected: AppSettings.killMode.rawValue) { AppSettings.killMode = KillMode(rawValue: $0) ?? .graceful },
            popupRow("Grace period", icon: "clock.fill", iconColor: .systemOrange,
                     options: ["Instant", "2 seconds", "5 seconds"],
                     selected: [0.0, 2.0, 5.0].firstIndex(of: AppSettings.gracePeriod) ?? 1)
                { AppSettings.gracePeriod = [0.0, 2.0, 5.0][safe: $0] ?? 2 },
            toggleRow("Confirm before axing", icon: "shield.fill", iconColor: .systemBlue,
                      on: AppSettings.confirmKill) { AppSettings.confirmKill = $0 },
            toggleRow("Play chop sound when axing", icon: "speaker.wave.2.fill", iconColor: .systemPurple,
                      on: AppSettings.soundEnabled) {
                          AppSettings.soundEnabled = $0
                          if $0 { ChopSound.shared.play() }
                      },
            animationDemoRow(),
            popupRow("Destruction animation", icon: "sparkles", iconColor: .systemYellow,
                     options: KillAnimation.allCases.map(\.label),
                     selected: AppSettings.killAnimation.rawValue) {
                         AppSettings.killAnimation = KillAnimation(rawValue: $0) ?? .shatter
                     },
        ], anchorCategory: 1)

        addSection(pun("Battle Phrases", "Phrases"), to: root, rows: [
            phraseRow(),
        ])

        addSection("Workflows", to: root, rows: [
            popupRow("Max saved workflows", icon: "tray.full.fill", iconColor: .systemBlue,
                     options: ["5", "10", "20", "50"],
                     selected: [5, 10, 20, 50].firstIndex(of: AppSettings.maxSessions) ?? 1)
                { AppSettings.maxSessions = [5, 10, 20, 50][safe: $0] ?? 10 },
            toggleRow("Ignore system apps when saving", icon: "square.stack.fill", iconColor: .systemGray,
                      on: AppSettings.ignoreSystemOnSave) { AppSettings.ignoreSystemOnSave = $0 },
            toggleRow("Close others when switching workflows", icon: "rectangle.on.rectangle.slash.fill", iconColor: .systemOrange,
                      on: AppSettings.closeOthersOnRestore) { AppSettings.closeOthersOnRestore = $0 },
            popupRow("Pause & reopen delay", icon: "timer", iconColor: .systemPurple,
                     options: ["5 minutes", "15 minutes", "30 minutes", "1 hour", "2 hours"],
                     selected: [5, 15, 30, 60, 120].firstIndex(of: AppSettings.scheduledReopenMinutes) ?? 1) {
                         AppSettings.scheduledReopenMinutes = [5, 15, 30, 60, 120][safe: $0] ?? 15
                     },
        ], anchorCategory: 2)

        addSection("App List", to: root, rows: [
            toggleRow("Show background agents and helpers", icon: "eye.fill", iconColor: .systemBlue,
                      on: AppSettings.showBackground) { AppSettings.showBackground = $0 },
        ], anchorCategory: 3)

        addSection("Keyboard Shortcut", to: root, rows: [
            shortcutRow(),
        ], anchorCategory: 4)

        addSection("Personality", to: root, rows: [
            toggleRow("Punny mode  ·  go crazy on the puns", icon: "face.smiling.fill", iconColor: .systemYellow,
                      on: AppSettings.punnyMode) { AppSettings.punnyMode = $0 },
        ])

        addSection("Permissions", to: root, rows: [
            permissionRow(in: root.window ?? NSApp.keyWindow ?? NSWindow()),
        ], anchorCategory: 5)

        permissionObserver = NotificationCenter.default.addObserver(
            forName: .permissionStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissionRow()
        }

        let resetBtn = NSButton(title: "Reset to Defaults…", target: self,
                                action: #selector(resetToDefaultsTapped))
        resetBtn.bezelStyle  = .rounded
        resetBtn.controlSize = .small
        let resetPad = padded(resetBtn, top: 20, bottom: 4)
        root.addArrangedSubview(resetPad)
        resetPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let div = NSBox(); div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(div)
        div.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let ver = NSTextField(labelWithString: "Axe v\(appVersion)  ·  axe-app.com")
        ver.font = .systemFont(ofSize: 11); ver.textColor = .quaternaryLabelColor
        ver.alignment = .center
        let verPad = padded(ver, top: 10, bottom: 12)
        root.addArrangedSubview(verPad)
        verPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        return scroll
    }

    // ── Sidebar + detail (NotchSpace-style) ───────────────────────
    private func buildUI(in w: NSWindow) {
        let cv = w.contentView!
        cv.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll(); currentDetail = nil
        entries = buildEntries()

        let side = NSVisualEffectView()
        side.material = .sidebar; side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState
        side.translatesAutoresizingMaskIntoConstraints = false
        let list = FlippedStackView()
        list.orientation = .vertical; list.spacing = 2; list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        list.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(list); sidebarStack = list

        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer = detail

        cv.addSubview(side); cv.addSubview(detail)
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: cv.topAnchor),
            side.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            side.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 216),
            list.topAnchor.constraint(equalTo: side.topAnchor),
            list.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            detail.topAnchor.constraint(equalTo: cv.topAnchor),
            detail.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
        populateSidebar()
        select(id: selectedID)
    }

    private func populateSidebar() {
        guard let list = sidebarStack else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        func addRow(_ e: SettingsEntry) {
            let badge = makeRowIcon(e.symbol, color: e.tint)
            let r = SidebarRowView(entry: e, iconBadge: badge)
            r.onSelect = { [weak self] in self?.select(id: e.id) }
            if e.setOn != nil {
                r.onToggle = { [weak self] on in e.setOn?(on); self?.refreshModuleRows() }
            }
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
            rowViews[e.id] = r
        }
        entries.filter { $0.group == .module }.forEach(addRow)
        let hdr = NSTextField(labelWithString: "APP")
        hdr.font = .systemFont(ofSize: 10, weight: .semibold); hdr.textColor = .tertiaryLabelColor
        let hPad = padded(hdr, top: 16, left: 12, bottom: 4)
        list.addArrangedSubview(hPad)
        hPad.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        entries.filter { $0.group == .app }.forEach(addRow)
    }

    private func select(id: String) {
        selectedID = id
        rowViews.forEach { $0.value.setSelected($0.key == id) }
        guard let e = entries.first(where: { $0.id == id }), let container = detailContainer else { return }
        currentDetail?.removeFromSuperview()
        let page = e.makeDetail(self)
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        currentDetail = page
    }

    private func refreshModuleRows() { rowViews.values.forEach { $0.refreshFromSettings() } }

    private func pageScroll(_ build: (_ root: NSStackView) -> Void) -> NSScrollView {
        let root = FlippedStackView()
        root.orientation = .vertical; root.spacing = 0; root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = root
        root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        build(root)
        return scroll
    }

    private func buildEntries() -> [SettingsEntry] {
        [
            SettingsEntry(id: "notchHub", group: .module, title: "Notch Hub", symbol: "macwindow", tint: .systemIndigo,
                          isOn: { AppSettings.notchHubEnabled },
                          setOn: { AppSettings.notchHubEnabled = $0; (NSApp.delegate as? AppDelegate)?.resetNotchHub() },
                          makeDetail: { $0.buildNotchHubDetail() }),
            SettingsEntry(id: "clipboard", group: .module, title: "Clipboard", symbol: "doc.on.clipboard", tint: .systemTeal,
                          isOn: { AppSettings.clipboardHotkeyEnabled },
                          setOn: { AppSettings.clipboardHotkeyEnabled = $0; (NSApp.delegate as? AppDelegate)?.refreshClipboardHotkey() },
                          makeDetail: { $0.buildClipboardDetail() }),
            SettingsEntry(id: "badge", group: .module, title: "Menu-bar badge", symbol: "number.circle.fill", tint: .systemRed,
                          isOn: { AppSettings.menuBarBadgeEnabled },
                          setOn: { AppSettings.menuBarBadgeEnabled = $0; (NSApp.delegate as? AppDelegate)?.updateMenuBarIcon() },
                          makeDetail: { $0.buildBadgeDetail() }),
            SettingsEntry(id: "general", group: .app, title: "General", symbol: "gearshape", tint: .systemGray,
                          makeDetail: { $0.buildGeneralPage() }),
            SettingsEntry(id: "appearance", group: .app, title: "Appearance", symbol: "paintbrush", tint: .systemPink,
                          makeDetail: { $0.buildAppearancePage() }),
            SettingsEntry(id: "behaviour", group: .app, title: "Behaviour", symbol: "bolt.circle", tint: .systemOrange,
                          makeDetail: { $0.buildBehaviourPage() }),
            SettingsEntry(id: "workflows", group: .app, title: "Workflows", symbol: "square.stack.3d.up", tint: .systemBlue,
                          makeDetail: { $0.buildWorkflowsPage() }),
            SettingsEntry(id: "shortcuts", group: .app, title: "Shortcuts", symbol: "keyboard", tint: .systemGray,
                          makeDetail: { $0.buildShortcutsPage() }),
            SettingsEntry(id: "permissions", group: .app, title: "Permissions", symbol: "lock.shield", tint: .systemGreen,
                          makeDetail: { $0.buildPermissionsPage() }),
            SettingsEntry(id: "about", group: .app, title: "About", symbol: "info.circle", tint: .systemGray,
                          makeDetail: { $0.buildAboutPage() }),
        ]
    }

    // ── Detail pages ──────────────────────────────────────────────
    func buildGeneralPage() -> NSScrollView {
        pageScroll { root in
            addSection("Startup", to: root, rows: [
                toggleRow("Launch at login", icon: "arrow.circlepath", iconColor: .systemGreen,
                          on: AppSettings.launchAtLogin) { AppSettings.setLaunchAtLogin($0) },
                toggleRow("Automatically install updates", icon: "arrow.down.circle.fill", iconColor: .systemGreen,
                          on: AppSettings.autoUpdate) { AppSettings.autoUpdate = $0 },
                toggleRow("Close overlay when last app quits", icon: "xmark.circle.fill", iconColor: .systemOrange,
                          on: AppSettings.autoClose) { AppSettings.autoClose = $0 },
            ])
            addSection("Interface", to: root, rows: [
                popupRow("Interface style", icon: "macwindow.on.rectangle", iconColor: .systemBlue,
                         options: ["Menu bar popover", "Spotlight overlay", "Drop from notch"],
                         selected: [UIStyle.popover, .spotlight, .notch].firstIndex(of: AppSettings.uiStyle) ?? 0) {
                             AppSettings.uiStyle = [UIStyle.popover, .spotlight, .notch][safe: $0] ?? .popover
                         },
            ])
        }
    }

    func buildAppearancePage() -> NSScrollView {
        pageScroll { root in
            let header = NSTextField(labelWithString: "NOTCH SKIN")
            header.font = .systemFont(ofSize: 11, weight: .semibold); header.textColor = .secondaryLabelColor
            let hPad = padded(header, top: 22, left: 20, bottom: 10)
            root.addArrangedSubview(hPad); hPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

            let grid = NSStackView()
            grid.orientation = .horizontal; grid.alignment = .top; grid.spacing = 12
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.setHuggingPriority(.defaultLow, for: .horizontal)
            var cards: [SkinCardView] = []
            for skin in NotchSkin.allCases {
                let card = SkinCardView(skin: skin, selected: AppSettings.notchSkin == skin)
                card.onSelect = { chosen in
                    AppSettings.notchSkin = chosen
                    cards.forEach { $0.isSelected = ($0.skin == chosen) }
                    let d = NSApp.delegate as? AppDelegate
                    d?.resetNotchHub()
                    d?.resetNotchIndicator()   // pill rebuilds with the new skin
                    d?.teardownOverlay()       // drop-overlay rebuilds with the new skin on next open
                }
                cards.append(card)
                grid.addArrangedSubview(card)
            }
            let gridWrap = NSStackView(views: [grid])
            gridWrap.orientation = .vertical
            gridWrap.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 20, right: 20)
            gridWrap.translatesAutoresizingMaskIntoConstraints = false
            root.addArrangedSubview(gridWrap)
            gridWrap.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true

            let note = NSTextField(wrappingLabelWithString: "Skins apply to the notch hub. Liquid Glass frosts over your desktop; more skins are coming.")
            note.font = .systemFont(ofSize: 11); note.textColor = .tertiaryLabelColor
            let nPad = padded(note, top: 0, left: 20, bottom: 20, right: 20)
            root.addArrangedSubview(nPad); nPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    func buildBehaviourPage() -> NSScrollView {
        pageScroll { root in
            addSection(pun("Axe Behaviour", "Behaviour"), to: root, rows: [
                popupRow("Default mode", icon: "bolt.fill", iconColor: .systemRed,
                         options: ["Graceful (asks apps to quit)", "Force (kills instantly)"],
                         selected: AppSettings.killMode == .force ? 1 : 0) { AppSettings.killMode = $0 == 1 ? .force : .graceful },
                popupRow("Grace period", icon: "timer", iconColor: .systemOrange,
                         options: ["Instant", "2 seconds", "5 seconds"],
                         selected: [0.0, 2.0, 5.0].firstIndex(of: AppSettings.gracePeriod) ?? 1) {
                             AppSettings.gracePeriod = [0.0, 2.0, 5.0][safe: $0] ?? 2.0
                         },
                toggleRow("Confirm before axing", icon: "checkmark.shield.fill", iconColor: .systemGreen,
                          on: AppSettings.confirmKill) { AppSettings.confirmKill = $0 },
                toggleRow("Play chop sound when axing", icon: "speaker.wave.2.fill", iconColor: .systemPurple,
                          on: AppSettings.soundEnabled) { AppSettings.soundEnabled = $0; if $0 { ChopSound.shared.play() } },
            ])
            addSection("Animation", to: root, rows: [
                animationDemoRow(),
                popupRow("Destruction animation", icon: "sparkles", iconColor: .systemYellow,
                         options: KillAnimation.allCases.map { $0.label },
                         selected: AppSettings.killAnimation.rawValue) {
                             AppSettings.killAnimation = KillAnimation(rawValue: $0) ?? .shatter
                         },
            ])
            addSection(pun("Battle Phrases", "Phrases"), to: root, rows: [ phraseRow() ])
            addSection("Personality", to: root, rows: [
                toggleRow("Punny mode  ·  go crazy on the puns", icon: "face.smiling.fill", iconColor: .systemYellow,
                          on: AppSettings.punnyMode) { AppSettings.punnyMode = $0 },
            ])
        }
    }

    func buildWorkflowsPage() -> NSScrollView {
        pageScroll { root in
            addSection("Workflows", to: root, rows: [
                popupRow("Max saved workflows", icon: "tray.full.fill", iconColor: .systemBlue,
                         options: ["5", "10", "20", "50"],
                         selected: [5, 10, 20, 50].firstIndex(of: AppSettings.maxSessions) ?? 1) {
                             AppSettings.maxSessions = [5, 10, 20, 50][safe: $0] ?? 10 },
                toggleRow("Ignore system apps when saving", icon: "square.stack.fill", iconColor: .systemGray,
                          on: AppSettings.ignoreSystemOnSave) { AppSettings.ignoreSystemOnSave = $0 },
                toggleRow("Close others when switching workflows", icon: "rectangle.on.rectangle.slash.fill", iconColor: .systemOrange,
                          on: AppSettings.closeOthersOnRestore) { AppSettings.closeOthersOnRestore = $0 },
                popupRow("Pause & reopen delay", icon: "timer", iconColor: .systemPurple,
                         options: ["5 minutes", "15 minutes", "30 minutes", "1 hour", "2 hours"],
                         selected: [5, 15, 30, 60, 120].firstIndex(of: AppSettings.scheduledReopenMinutes) ?? 1) {
                             AppSettings.scheduledReopenMinutes = [5, 15, 30, 60, 120][safe: $0] ?? 15
                         },
            ])
            addSection("App List", to: root, rows: [
                toggleRow("Show background agents and helpers", icon: "eye.fill", iconColor: .systemBlue,
                          on: AppSettings.showBackground) { AppSettings.showBackground = $0 },
            ])
        }
    }

    func buildShortcutsPage() -> NSScrollView {
        pageScroll { root in
            addSection("Keyboard Shortcut", to: root, rows: [ shortcutRow() ])
            addSection("Clipboard", to: root, rows: [
                toggleRow("Clipboard hotkey  ·  ⌥⌘V", icon: "doc.on.clipboard", iconColor: .systemTeal,
                          on: AppSettings.clipboardHotkeyEnabled) { on in
                              AppSettings.clipboardHotkeyEnabled = on
                              (NSApp.delegate as? AppDelegate)?.refreshClipboardHotkey()
                          },
            ])
        }
    }

    func buildPermissionsPage() -> NSScrollView {
        if let obs = permissionObserver { NotificationCenter.default.removeObserver(obs) }
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .permissionStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissionRow()
        }
        return pageScroll { root in
            addSection("Permissions", to: root, rows: [
                permissionRow(in: window ?? NSApp.keyWindow ?? NSWindow()),
            ])
        }
    }

    func buildAboutPage() -> NSScrollView {
        pageScroll { root in
            addSection("About", to: root, rows: [
                { let l = NSTextField(labelWithString: "Axe v\(appVersion)  ·  axe-app.com")
                  l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor
                  return padded(l, top: 12, left: 16, bottom: 12) }(),
            ])
            let resetBtn = NSButton(title: "Reset to Defaults…", target: self, action: #selector(resetToDefaultsTapped))
            resetBtn.bezelStyle = .rounded; resetBtn.controlSize = .regular
            let rPad = padded(resetBtn, top: 20, left: 20, bottom: 12)
            root.addArrangedSubview(rPad)
        }
    }

    // ── Module detail pages ───────────────────────────────────────
    func buildNotchHubDetail() -> NSScrollView {
        pageScroll { root in
            addSection("Notch Hub", to: root, rows: [
                toggleRow("Show notch indicator (pill)", icon: "oval.tophalf.filled", iconColor: .systemGray,
                          on: AppSettings.notchIndicatorEnabled) { on in
                              AppSettings.notchIndicatorEnabled = on
                              (NSApp.delegate as? AppDelegate)?.syncNotchIndicator()
                          },
                popupRow("Notch indicator side", icon: "sidebar.left", iconColor: .systemGray,
                         options: ["Left of notch", "Right of notch"],
                         selected: AppSettings.notchIndicatorOnRight ? 1 : 0) { idx in
                             AppSettings.notchIndicatorOnRight = (idx == 1)
                             (NSApp.delegate as? AppDelegate)?.resetNotchIndicator()
                         },
            ])
            let note = NSTextField(wrappingLabelWithString: "The hub hover-expands from the notch with a live clock, quick actions, a file shelf, and clipboard. Pick a skin in Appearance.")
            note.font = .systemFont(ofSize: 11); note.textColor = .tertiaryLabelColor
            let nPad = padded(note, top: 0, left: 20, bottom: 20, right: 20)
            root.addArrangedSubview(nPad); nPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    func buildClipboardDetail() -> NSScrollView {
        pageScroll { root in
            addSection("Clipboard", to: root, rows: [
                toggleRow("Auto-paste clipboard items", icon: "arrow.down.doc.fill", iconColor: .systemTeal,
                          on: AppSettings.autoPasteEnabled) { on in
                              AppSettings.autoPasteEnabled = on
                              if on && !AXIsProcessTrusted() { PermissionManager.shared.requestAccessibility() }
                          },
            ])
            let note = NSTextField(wrappingLabelWithString: "Open the clipboard with ⌥⌘V. Click a clip to copy it back. Auto-paste (needs Accessibility) also presses ⌘V in your last app. Password-manager clips are skipped.")
            note.font = .systemFont(ofSize: 11); note.textColor = .tertiaryLabelColor
            let nPad = padded(note, top: 0, left: 20, bottom: 20, right: 20)
            root.addArrangedSubview(nPad); nPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    func buildBadgeDetail() -> NSScrollView {
        pageScroll { root in
            let note = NSTextField(wrappingLabelWithString: "Shows the count of running regular apps as a small badge on the menu-bar axe icon.")
            note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
            let nPad = padded(note, top: 22, left: 20, bottom: 20, right: 20)
            root.addArrangedSubview(nPad); nPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    @objc private func resetToDefaultsTapped() {
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = "Reset all settings to defaults?"
        alert.informativeText = "Kill mode, animations, the hotkey, interface style and other preferences return to their defaults. Your saved Workflows, license, and permissions are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Preference keys ONLY — deliberately excludes license (isLicensed,
        // licenseInstanceID), saved Workflows (savedSessions), and first-run /
        // nudge / update state (firstLaunchDate, hasSeenOnboarding, hasMadeFirstKill,
        // lastNudgeDate, activeWorkflowID, dismissedUpdateVersion, lastAutoUpdateCheck).
        let keys = [
            "killMode", "killAnimation", "gracePeriod", "showBackground", "autoClose",
            "uiStyle", "confirmKill", "soundEnabled", "punnyMode",
            "hotKeyCode", "hotKeyMods", "hotKeyChar",
            "maxSessions", "autoRestoreLastSession", "closeOthersOnRestore",
            "ignoreSystemOnSave", "scheduledReopenMinutes", "sessionsSortOrder",
            "disabledKillPhrases", "disabledSparePhrases",
            "notchIndicatorEnabled", "notchIndicatorOnRight", "notchExtraHeight",
            "menuBarBadgeEnabled", "autoUpdate",
        ]
        let d = UserDefaults.standard
        keys.forEach { d.removeObject(forKey: $0) }

        (NSApp.delegate as? AppDelegate)?.didResetSettings()

        // Refresh the visible settings surface so controls show the restored values.
        if let w = window, w.isVisible {
            rebuildContent()
        } else {
            (NSApp.delegate as? AppDelegate)?.hideOverlay()
        }
    }

    /// Rebuild the standalone settings window's content in place (after a reset).
    func rebuildContent() {
        guard let w = window else { return }
        w.contentView?.subviews.forEach { $0.removeFromSuperview() }
        buildUI(in: w)
    }

    // ── Section builders ─────────────────────────────────────────

    private func addSection(_ title: String, to stack: NSStackView, rows: [NSView],
                            anchorCategory: Int? = nil) {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let hPad = padded(header, top: 22, left: 20, bottom: 7)
        stack.addArrangedSubview(hPad)
        hPad.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let cat = anchorCategory { sectionAnchors[cat] = hPad }

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

    private func toggleRow(_ label: String,
                           icon: String? = nil, iconColor: NSColor = .controlAccentColor,
                           on: Bool, handler: @escaping (Bool) -> Void) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        if let iconName = icon { row.addArrangedSubview(makeRowIcon(iconName, color: iconColor)) }
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sw = NSSwitch(); sw.state = on ? .on : .off
        let box = ToggleBox(sw, handler: handler)
        row.addArrangedSubview(lbl); row.addArrangedSubview(box)
        return row
    }

    private func permissionRow(in w: NSWindow) -> NSView {
        let row = NSStackView(); row.orientation = .vertical; row.spacing = 4
        row.alignment = .leading
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let titleRow = NSStackView(); titleRow.orientation = .horizontal; titleRow.spacing = 8
        titleRow.alignment = .centerY
        let titleLbl = NSTextField(labelWithString: "Accessibility")
        titleLbl.font = .systemFont(ofSize: 13, weight: .regular)
        titleLbl.textColor = .labelColor
        titleLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusLbl = NSTextField(labelWithString: "")
        statusLbl.font = .systemFont(ofSize: 11, weight: .medium)
        statusLbl.setContentHuggingPriority(.required, for: .horizontal)
        axPermStatusLabel = statusLbl

        titleRow.addArrangedSubview(titleLbl)
        titleRow.addArrangedSubview(statusLbl)

        let subtitleLbl = NSTextField(wrappingLabelWithString: "")
        subtitleLbl.font = .systemFont(ofSize: 11)
        subtitleLbl.textColor = .secondaryLabelColor
        subtitleLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        axPermSubtitleLabel = subtitleLbl

        let btn = NSButton(title: "", target: self, action: #selector(axPermBtnTapped(_:)))
        btn.bezelStyle  = .rounded
        btn.controlSize = .small
        axPermBtn = btn

        row.addArrangedSubview(titleRow)
        row.addArrangedSubview(subtitleLbl)
        row.addArrangedSubview(btn)
        titleRow.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -32).isActive = true
        subtitleLbl.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -32).isActive = true

        PermissionManager.shared.refreshAccessibilityState()
        refreshPermissionRow()
        return row
    }

    private func refreshPermissionRow() {
        switch PermissionManager.shared.accessibility {
        case .granted:
            axPermStatusLabel?.stringValue  = "Granted"
            axPermStatusLabel?.textColor    = .systemGreen
            axPermSubtitleLabel?.stringValue = "Window position capture is available for workflows."
            axPermBtn?.title    = "Open Accessibility Settings…"
            axPermBtn?.isHidden = false
        case .denied:
            axPermStatusLabel?.stringValue  = "Not granted"
            axPermStatusLabel?.textColor    = .secondaryLabelColor
            axPermSubtitleLabel?.stringValue = "Grant access in System Settings to enable window position capture in workflows."
            axPermBtn?.title    = "Open Settings…"
            axPermBtn?.isHidden = false
        case .notDetermined:
            axPermStatusLabel?.stringValue  = "Not granted"
            axPermStatusLabel?.textColor    = .secondaryLabelColor
            axPermSubtitleLabel?.stringValue = "Optional. Lets Axe capture and restore window positions in workflows."
            axPermBtn?.title    = "Grant Access…"
            axPermBtn?.isHidden = false
        }
    }

    @objc private func axPermBtnTapped(_ sender: NSButton) {
        let state = PermissionManager.shared.accessibility
        if state == .granted {
            PermissionManager.shared.openAccessibilitySettings()
            return
        }
        guard let w = window else { return }
        let alert = NSAlert()
        alert.messageText     = "Axe would like to control this computer"
        alert.informativeText = """
            Axe uses Accessibility only to capture and restore window positions in workflows. \
            No other data is read or sent anywhere.

            After granting access, open Axe Settings again to check the status. \
            You can revoke access any time in System Settings › Privacy & Security › Accessibility.
            """
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        alert.beginSheetModal(for: w) { response in
            guard response == .alertFirstButtonReturn else { return }
            PermissionManager.shared.requestAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PermissionManager.shared.refreshAccessibilityState()
            }
        }
    }

    private func popupRow(_ label: String,
                          icon: String? = nil, iconColor: NSColor = .controlAccentColor,
                          options: [String], selected: Int,
                          handler: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        if let iconName = icon { row.addArrangedSubview(makeRowIcon(iconName, color: iconColor)) }
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

    private func makeRowIcon(_ symbolName: String, color: NSColor) -> NSView {
        let bg = NSView(); bg.wantsLayer = true
        bg.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        bg.layer?.cornerRadius    = 6
        bg.layer?.cornerCurve     = .continuous
        let iv = NSImageView()
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            iv.image = img
        }
        iv.contentTintColor = color
        iv.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(iv)
        bg.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bg.widthAnchor.constraint(equalToConstant: 28),
            bg.heightAnchor.constraint(equalToConstant: 28),
            iv.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        return bg
    }

    /// A sample app row plus a "Test Animation" button that previews the
    /// currently selected destruction animation on it. Wraps both in a single
    /// bordered container so the button visually belongs to the row.
    private func animationDemoRow() -> NSView {
        // Sample row, styled like a real app entry.
        let sample = AppRowCell(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
        sample.wantsLayer = true
        sample.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        sample.layer?.cornerRadius = 6
        sample.appName.stringValue = "Sample App"
        sample.statsView.configure(cpu: 3.2, mem: 128)
        sample.appIcon.image = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        sample.checkBox.state = .off
        sample.translatesAutoresizingMaskIntoConstraints = false
        sample.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            sample.heightAnchor.constraint(equalToConstant: 44),
        ])
        (NSApp.delegate as? AppDelegate)?.demoRowView = sample

        let btn = NSButton(title: "Test Animation", target: self, action: #selector(testAnimation))
        btn.bezelStyle  = .rounded
        btn.controlSize = .regular
        btn.setContentHuggingPriority(.required, for: .horizontal)

        // Inner stack: sample row + button as a unit.
        let inner = NSStackView(views: [sample, btn])
        inner.orientation = .horizontal
        inner.spacing     = 10
        inner.alignment   = .centerY
        inner.edgeInsets  = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        inner.translatesAutoresizingMaskIntoConstraints = false

        // Bordered container groups them visually — the Test button reads as
        // belonging to that row instead of floating beside it.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Section row wraps the container with the standard 16pt side inset
        // used by every other Settings row.
        let row = NSStackView(views: [container])
        row.orientation = .horizontal
        row.edgeInsets  = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        return row
    }

    @objc private func testAnimation() {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let rv = delegate.demoRowView, rv.window != nil else { return }
        if AppSettings.soundEnabled { ChopSound.shared.play() }
        delegate.runKillAnimation(on: rv) { [weak rv] in rv?.isHidden = false }  // restore for re-testing
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
        recorder.onChange = { [weak recorder] code, mods, char in
            let flash: (String) -> Void = { msg in
                recorder?.errorMessage = msg; recorder?.needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak recorder] in
                    recorder?.errorMessage = nil; recorder?.needsDisplay = true
                }
            }
            // Reject a combo already claimed by a saved Workflow hotkey — otherwise
            // RegisterEventHotKey fails silently and the main open-hotkey dies.
            if SessionManager.shared.all.contains(where: {
                $0.hotkey?.keyCode == code && $0.hotkey?.modifiers == mods
            }) {
                flash("⚠ In use"); return
            }
            let (oldCode, oldMods, oldChar) =
                (AppSettings.hotKeyCode, AppSettings.hotKeyMods, AppSettings.hotKeyChar)
            AppSettings.hotKeyCode = code
            AppSettings.hotKeyMods = mods
            AppSettings.hotKeyChar = char
            let ok = (NSApp.delegate as? AppDelegate)?.reregisterHotKey() ?? false
            if !ok {
                // Registration failed (e.g. OS-reserved). Roll back so the recorder,
                // stored value, and the actually-registered hotkey stay in sync.
                AppSettings.hotKeyCode = oldCode
                AppSettings.hotKeyMods = oldMods
                AppSettings.hotKeyChar = oldChar
                (NSApp.delegate as? AppDelegate)?.reregisterHotKey()
                flash("⚠ Unavailable")
            }
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
    var onTap:      (() -> Void)?

    private let hoverLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if !wantsLayer { wantsLayer = true }
        if let host = layer, hoverLayer.superlayer == nil {
            hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            hoverLayer.cornerRadius = 8
            hoverLayer.opacity = 0
            host.insertSublayer(hoverLayer, at: 0)
        }
        updateTrackingArea()
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 4
        hoverLayer.frame = NSRect(x: inset, y: inset,
                                  width: bounds.width - 2 * inset,
                                  height: bounds.height - 2 * inset)
    }

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { animateHover(to: 1) }
    override func mouseExited(with event: NSEvent)  { animateHover(to: 0) }

    private func animateHover(to target: Float) {
        let dur: CFTimeInterval = AnimationConstants.reduceMotion
            ? AnimationConstants.reducedDuration : 0.14
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hoverLayer.presentation()?.opacity ?? hoverLayer.opacity
        anim.toValue   = target
        anim.duration  = dur
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode  = .forwards
        anim.isRemovedOnCompletion = false
        hoverLayer.add(anim, forKey: "hover")
        hoverLayer.opacity = target
    }

    override func mouseDown(with event: NSEvent) {
        let localPt = convert(event.locationInWindow, from: nil)
        var v: NSView? = hitTest(localPt)
        while let view = v {
            if view is NSButton { super.mouseDown(with: event); return }
            v = view.superview == self ? nil : view.superview
        }
        onTap?()
    }

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

// MARK: - Settings sidebar model + views (NotchSpace-style)

enum SettingsGroup { case module, app }

struct SettingsEntry {
    let id: String
    let group: SettingsGroup
    let title: String
    let symbol: String
    let tint: NSColor
    var beta: Bool = false
    var isOn:  (() -> Bool)?      = nil     // module toggle binding; nil for app pages
    var setOn: ((Bool) -> Void)? = nil
    let makeDetail: (_ owner: SettingsWindow) -> NSView
}

/// A small "🧪 BETA" capsule for experimental features.
func makeBetaPill() -> NSView {
    let l = NSTextField(labelWithString: "BETA")
    l.font = .systemFont(ofSize: 8, weight: .bold); l.textColor = .white; l.alignment = .center
    l.wantsLayer = true
    l.layer?.backgroundColor = NSColor.systemOrange.cgColor
    l.layer?.cornerRadius = 4; l.layer?.cornerCurve = .continuous
    l.translatesAutoresizingMaskIntoConstraints = false
    let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(l)
    NSLayoutConstraint.activate([
        l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
        l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
        l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
        l.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -4),
    ])
    return wrap
}

/// A sidebar row: icon + title + optional beta pill + optional toggle switch, with
/// a rounded selection highlight and grayed-when-off state.
final class SidebarRowView: NSView {
    let entry: SettingsEntry
    private let highlight = CALayer()
    private let titleLbl = NSTextField(labelWithString: "")
    private let iconBadge: NSView
    private var toggle: NSSwitch?
    var onSelect: (() -> Void)?
    var onToggle: ((Bool) -> Void)?

    init(entry: SettingsEntry, iconBadge: NSView) {
        self.entry = entry; self.iconBadge = iconBadge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        highlight.cornerRadius = 6; highlight.cornerCurve = .continuous
        highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        titleLbl.stringValue = entry.title
        titleLbl.font = .systemFont(ofSize: 13)
        titleLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iconBadge.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconBadge, titleLbl])
        row.orientation = .horizontal; row.spacing = 9; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        if entry.beta { row.addArrangedSubview(makeBetaPill()) }
        if let isOn = entry.isOn {
            let sw = NSSwitch(); sw.controlSize = .mini
            sw.state = isOn() ? .on : .off
            sw.target = self; sw.action = #selector(switchChanged)
            toggle = sw; row.addArrangedSubview(sw)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyGray()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); highlight.frame = bounds.insetBy(dx: 2, dy: 1) }
    func setSelected(_ on: Bool) { highlight.opacity = on ? 1 : 0 }
    func refreshFromSettings() { toggle?.state = (entry.isOn?() ?? false) ? .on : .off; applyGray() }

    private func applyGray() {
        let off = (entry.isOn?() == false)
        titleLbl.textColor = off ? .tertiaryLabelColor : .labelColor
        iconBadge.alphaValue = off ? 0.4 : 1.0
    }
    @objc private func switchChanged() { onToggle?(toggle?.state == .on); applyGray() }
    override func mouseDown(with e: NSEvent) {
        if let sw = toggle {
            let p = sw.convert(e.locationInWindow, from: nil)
            if sw.bounds.contains(p) { super.mouseDown(with: e); return }
        }
        onSelect?()
    }
}

/// A selectable skin card for the Appearance page's Skin Gallery.
final class SkinCardView: NSView {
    let skin: NotchSkin
    var onSelect: ((NotchSkin) -> Void)?
    private let checkBadge = NSImageView()
    var isSelected = false { didSet { refreshSelection() } }

    init(skin: NotchSkin, selected: Bool) {
        self.skin = skin
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12; layer?.cornerCurve = .continuous; layer?.borderWidth = 2
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true

        let swatch = SkinCardView.makeSwatch(for: skin)
        let title = NSTextField(labelWithString: skin.label)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: skin.detail)
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [swatch, title, sub])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        checkBadge.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkBadge.contentTintColor = .controlAccentColor
        checkBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkBadge)
        NSLayoutConstraint.activate([
            checkBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            checkBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkBadge.widthAnchor.constraint(equalToConstant: 18),
            checkBadge.heightAnchor.constraint(equalToConstant: 18),
        ])
        if !skin.isImplemented {
            let soon = NSTextField(labelWithString: "SOON")
            soon.font = .systemFont(ofSize: 9, weight: .bold); soon.textColor = .secondaryLabelColor
            soon.wantsLayer = true; soon.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            soon.layer?.cornerRadius = 4; soon.alignment = .center
            soon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(soon)
            NSLayoutConstraint.activate([
                soon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                soon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                soon.widthAnchor.constraint(equalToConstant: 38),
                soon.heightAnchor.constraint(equalToConstant: 15),
            ])
        }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        self.isSelected = selected
        refreshSelection()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { if skin.isImplemented { onSelect?(skin) } }
    private func refreshSelection() {
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor
                                         : NSColor.separatorColor.withAlphaComponent(0.6)).cgColor
        layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.08)
                                             : NSColor.clear).cgColor
        checkBadge.isHidden = !isSelected
        alphaValue = skin.isImplemented ? 1.0 : 0.55
    }
    private static func makeSwatch(for skin: NotchSkin) -> NSView {
        let host = NSView(); host.wantsLayer = true
        host.layer?.cornerRadius = 7; host.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        host.heightAnchor.constraint(equalToConstant: 62).isActive = true
        host.widthAnchor.constraint(equalToConstant: 138).isActive = true
        switch skin {
        case .liquidGlass:
            let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active
            fx.appearance = NSAppearance(named: .darkAqua)
            fx.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(fx); pin(fx, to: host)
        default:
            host.layer?.backgroundColor = NSColor.black.cgColor
        }
        // A small "notch" nub at the top-center for realism.
        let nub = NSView(); nub.wantsLayer = true
        nub.layer?.backgroundColor = NSColor.black.cgColor
        nub.layer?.cornerRadius = 4
        nub.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        nub.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(nub)
        NSLayoutConstraint.activate([
            nub.topAnchor.constraint(equalTo: host.topAnchor),
            nub.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            nub.widthAnchor.constraint(equalToConstant: 48),
            nub.heightAnchor.constraint(equalToConstant: 14),
        ])
        return host
    }
    private static func pin(_ v: NSView, to c: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            v.topAnchor.constraint(equalTo: c.topAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor),
        ])
    }
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
    var onChange: ((UInt32, UInt32, String) -> Void)?
    var capturedBinding: HotkeyBinding?
    var errorMessage:    String?

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

        let text: String
        if isRecording          { text = "Type shortcut…" }
        else if let e = errorMessage { text = e }
        else if let b = capturedBinding { text = b.displayString }
        else                    { text = AppSettings.shortcutLabel() }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let textColor: NSColor = errorMessage != nil ? .systemRed
            : isRecording ? .tertiaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz  = str.size()
        str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                             y: (bounds.height - sz.height) / 2 + 1))
    }
}

// MARK: - ActionBox (NSButton target wrapper for closure actions)

final class ActionBox: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

// MARK: - WorkflowHotkeyManager

private let workflowHotkeyCallback: EventHandlerUPP = { _, inEvent, ud -> OSStatus in
    guard let inEvent, let ud else { return noErr }
    var hkID = EventHotKeyID()
    GetEventParameter(inEvent, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard hkID.signature == fourCC("wkfl") else { return noErr }
    let mgr = Unmanaged<WorkflowHotkeyManager>.fromOpaque(ud).takeUnretainedValue()
    let eid = hkID.id
    DispatchQueue.main.async { mgr.handlePress(eventID: eid) }
    return noErr
}

final class WorkflowHotkeyManager {
    static let shared = WorkflowHotkeyManager()
    private var handlerRef: EventHandlerRef?
    private var refs:  [UUID: EventHotKeyRef] = [:]
    private var idMap: [UInt32: UUID]         = [:]

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), workflowHotkeyCallback,
                            1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func refresh() {
        unregisterAll()
        var counter: UInt32 = 100   // start above the main hotkey id=1
        for session in SessionManager.shared.all {
            guard let binding = session.hotkey else { continue }
            counter += 1
            let eid  = EventHotKeyID(signature: fourCC("wkfl"), id: counter)
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                          eid, GetApplicationEventTarget(), 0, &ref)
            if err == noErr, let ref {
                refs[session.id]    = ref
                idMap[counter]      = session.id
            }
        }
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll(); idMap.removeAll()
    }

    func handlePress(eventID: UInt32) {
        guard let uid = idMap[eventID],
              let session = SessionManager.shared.all.first(where: { $0.id == uid })
        else { return }
        var s = SessionManager.shared.all
        if let i = s.firstIndex(where: { $0.id == uid }) { s[i].lastUsed = Date() }
        SessionManager.shared.all = s
        let item = SessionManager.shared.restore(session, mode: .replace)
        let hud  = SwitchHUD(workflowName: session.name) { item.cancel() }
        (NSApp.delegate as? AppDelegate)?.switchHUD = hud
        hud.show()
    }
}

// MARK: - Permission management

enum PermissionState: Equatable {
    case notDetermined, granted, denied
}

extension Notification.Name {
    static let permissionStateChanged = Notification.Name("com.emerytech.axe.permissionStateChanged")
}

final class PermissionManager {
    static let shared = PermissionManager()
    private(set) var accessibility: PermissionState = .notDetermined

    @discardableResult
    func refreshAccessibilityState() -> PermissionState {
        let trusted = AXIsProcessTrusted()
        let prev    = accessibility
        accessibility = trusted ? .granted :
            (UserDefaults.standard.bool(forKey: "axHasBeenAsked") ? .denied : .notDetermined)
        if prev != accessibility {
            NotificationCenter.default.post(name: .permissionStateChanged, object: nil)
        }
        return accessibility
    }

    func requestAccessibility() {
        UserDefaults.standard.set(true, forKey: "axHasBeenAsked")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilitySettings() {
        let scheme = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))
            ? "x-apple.systemsettings" : "x-apple.systempreferences"
        let url = URL(string: "\(scheme):com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Session persistence

struct SavedApp: Codable {
    let bundleID: String
    let name:     String
}

struct HotkeyBinding: Codable, Equatable {
    let keyCode:       UInt32
    let modifiers:     UInt32
    var displayString: String   // e.g. "⌥⌘1"
}

struct WindowState: Codable {
    let frame:       CGRect
    let isMinimized: Bool
    let title:       String?
}

struct AppWindowSnapshot: Codable {
    let bundleID: String
    let windows:  [WindowState]
}

private struct PersistedSessions: Codable {
    let version:  Int
    let sessions: [AppSession]
}

// v3 = adds captureWindowState / windowSnapshots (optional, defaults to nil — backward-compatible).
struct ScheduledRestore: Codable, Equatable {
    enum Recurrence: String, Codable { case once, daily, weekly }
    var hour:          Int
    var minute:        Int
    var weekday:       Int?       // Calendar weekday 1=Sun…7=Sat, only for .weekly
    var recurrence:    Recurrence
    var lastFiredDate: Date?

    func nextFireDate(after reference: Date = Date()) -> Date? {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: reference)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard let todayCandidate = cal.date(from: comps) else { return nil }

        switch recurrence {
        case .once:
            return todayCandidate > reference ? todayCandidate : nil
        case .daily:
            if todayCandidate > reference { return todayCandidate }
            return cal.date(byAdding: .day, value: 1, to: todayCandidate)
        case .weekly:
            guard let targetWD = weekday else { return nil }
            for offset in 0...6 {
                guard let candidate = cal.date(byAdding: .day, value: offset, to: todayCandidate)
                else { continue }
                if cal.component(.weekday, from: candidate) == targetWD && candidate > reference {
                    return candidate
                }
            }
            return cal.date(byAdding: .weekOfYear, value: 1, to: todayCandidate)
        }
    }

    var displayString: String {
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        let timeStr = tf.string(from: Calendar.current.date(from: comps) ?? Date())
        switch recurrence {
        case .once:    return "Once at \(timeStr)"
        case .daily:   return "Daily at \(timeStr)"
        case .weekly:
            let dayName = weekday.flatMap {
                Calendar.current.weekdaySymbols[safe: $0 - 1]
            } ?? "?"
            return "\(dayName)s at \(timeStr)"
        }
    }
}

struct AppSession: Codable {
    let id:                  UUID
    var name:                String
    let date:                Date
    let apps:                [SavedApp]
    var isFavorite:          Bool                = false
    var hotkey:              HotkeyBinding?      = nil
    var primaryBundleID:     String?             = nil
    var autoLaunchOnLogin:   Bool                = false
    var lastUsed:            Date?               = nil
    var captureWindowState:  Bool                = false
    var windowSnapshots:     [AppWindowSnapshot]? = nil
    var scheduledRestore:    ScheduledRestore?   = nil
}

final class SessionManager {
    static let shared = SessionManager()
    private let key = "savedSessions"
    private var max: Int { AppSettings.maxSessions }

    var all: [AppSession] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            // v2 envelope first, fall back to bare v1 array
            if let p = try? JSONDecoder().decode(PersistedSessions.self, from: data) {
                return p.sessions
            }
            return (try? JSONDecoder().decode([AppSession].self, from: data)) ?? []
        }
        set {
            let p = PersistedSessions(version: 3, sessions: newValue)
            if let data = try? JSONEncoder().encode(p) {
                UserDefaults.standard.set(data, forKey: key)
            }
            WorkflowHotkeyManager.shared.refresh()
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
        all = s.filter { $0.isFavorite } + s.filter { !$0.isFavorite }
    }

    func rename(id: UUID, to newName: String) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].name = newName
        all = s
    }

    func setHotkey(id: UUID, binding: HotkeyBinding?) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].hotkey = binding
        all = s
    }

    func setPrimary(id: UUID, bundleID: String?) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].primaryBundleID = bundleID
        all = s
    }

    func setAutoLaunch(id: UUID, enabled: Bool) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].autoLaunchOnLogin = enabled
        all = s
    }

    func setScheduledRestore(id: UUID, restore: ScheduledRestore?) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].scheduledRestore = restore
        all = s
    }

    func setCaptureWindowState(id: UUID, enabled: Bool) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].captureWindowState = enabled
        all = s
    }

    func setWindowSnapshots(id: UUID, snapshots: [AppWindowSnapshot]?) {
        var s = all
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        s[i].windowSnapshots = snapshots
        all = s
    }

    func captureWindowSnapshots(for bundleIDs: [String]) -> [AppWindowSnapshot]? {
        guard AXIsProcessTrusted() else { return nil }
        var result: [AppWindowSnapshot] = []
        for bid in bundleIDs {
            guard let app = NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == bid }) else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            var states: [WindowState] = []
            for win in windows.prefix(20) {
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?, minRef: CFTypeRef?, titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString,     &sizeRef)
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef)
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString,    &titleRef)
                var pos  = CGPoint.zero; var size = CGSize.zero
                // Type-check before casting: a quirky app's AX impl can return a
                // non-AXValue here, and a force-cast would crash the whole app.
                if let p = posRef,  CFGetTypeID(p) == AXValueGetTypeID() {
                    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
                }
                if let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() {
                    AXValueGetValue(s as! AXValue, .cgSize, &size)
                }
                let minimized = (minRef as? Bool) ?? false
                let title     = titleRef as? String
                states.append(WindowState(frame: CGRect(origin: pos, size: size),
                                          isMinimized: minimized, title: title))
            }
            if !states.isEmpty { result.append(AppWindowSnapshot(bundleID: bid, windows: states)) }
        }
        return result.isEmpty ? nil : result
    }

    static func applyWindowSnapshots(_ snapshots: [AppWindowSnapshot]) {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for snap in snapshots {
                var attempts = 0
                while attempts < 15 {
                    guard let app = NSWorkspace.shared.runningApplications
                            .first(where: { $0.bundleIdentifier == snap.bundleID }) else {
                        attempts += 1; Thread.sleep(forTimeInterval: 0.2); continue
                    }
                    let axApp = AXUIElementCreateApplication(app.processIdentifier)
                    var windowsRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                          let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
                        attempts += 1; Thread.sleep(forTimeInterval: 0.2); continue
                    }
                    for (idx, state) in snap.windows.enumerated() {
                        let candidates: [AXUIElement]
                        if let title = state.title {
                            let prefix = String(title.prefix(30))
                            candidates = windows.filter {
                                var t: CFTypeRef?
                                AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
                                return (t as? String)?.hasPrefix(prefix) ?? false
                            }
                        } else { candidates = [] }
                        let win = candidates.first ?? (idx < windows.count ? windows[idx] : nil)
                        guard let win else { continue }
                        var pos  = state.frame.origin
                        var size = state.frame.size
                        if let pv = AXValueCreate(.cgPoint, &pos) {
                            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
                        }
                        if let sv = AXValueCreate(.cgSize,  &size) {
                            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
                        }
                        let minimized = state.isMinimized
                        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString,
                                                     minimized as CFTypeRef)
                    }
                    break
                }
            }
        }
    }

    enum RestoreMode { case additive, replace }

    @discardableResult
    func restore(_ session: AppSession, mode: RestoreMode = .additive) -> DispatchWorkItem {
        AppSettings.activeWorkflowID = session.id
        let selfPID          = ProcessInfo.processInfo.processIdentifier
        let sessionBundleIDs = Set(session.apps.map { $0.bundleID })

        let shouldClose = mode == .replace || AppSettings.closeOthersOnRestore
        if shouldClose {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular
                       && $0.processIdentifier != selfPID
                       && !SessionManager.isSystemApp($0)
                       && !sessionBundleIDs.contains($0.bundleIdentifier ?? "") }
                .forEach { $0.terminate() }
        }

        let launchDelay: Double = shouldClose ? 0.6 : 0.0
        let item = DispatchWorkItem { [apps = session.apps, primaryID = session.primaryBundleID,
                                       snapshots = session.windowSnapshots] in
            let runningApps = NSWorkspace.shared.runningApplications
            for app in apps {
                if let running = runningApps.first(where: { $0.bundleIdentifier == app.bundleID }) {
                    if #available(macOS 14.0, *) { running.activate() }
                    else { running.activate(options: [.activateIgnoringOtherApps]) }
                    continue
                }
                guard let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: app.bundleID) else { continue }
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
            if let pid = primaryID {
                var retries = 0
                var tryActivate: (() -> Void)?
                tryActivate = {
                    if let app = NSWorkspace.shared.runningApplications
                            .first(where: { $0.bundleIdentifier == pid }) {
                        if #available(macOS 14.0, *) { app.activate() }
                        else { app.activate(options: [.activateIgnoringOtherApps]) }
                        tryActivate = nil
                    } else if retries < 10 {
                        retries += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { tryActivate?() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tryActivate?() }
            }
            if let snaps = snapshots, PermissionManager.shared.accessibility == .granted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    SessionManager.applyWindowSnapshots(snaps)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay, execute: item)
        return item
    }

    static func isSystemApp(_ app: NSRunningApplication) -> Bool {
        guard let path = app.bundleURL?.path else { return false }
        return path.hasPrefix("/System/")
    }
}

// MARK: - RedButton (reliable coloured background via layer)

/// NSButton subclass that draws a solid coloured rounded background via Core Animation.
/// NSButtonCell.backgroundColor is unreliable for bezel styles — this is the safe way.
final class RedButton: NSButton {
    var fillColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    private let sheen = CALayer()
    private var sheenSetup = false

    private func setupSheen() {
        guard !sheenSetup, let host = layer else { return }
        sheen.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        sheen.cornerRadius = 9
        host.addSublayer(sheen)
        sheenSetup = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        setupSheen()
        // Thin highlight stripe along the top edge
        sheen.frame = NSRect(x: 2, y: bounds.height - 5, width: bounds.width - 4, height: 4)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = (isHighlighted
            ? fillColor.withAlphaComponent(0.72)
            : fillColor).cgColor
        layer?.cornerRadius = 9
        sheen.opacity = isHighlighted ? 0 : 1
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard !AnimationConstants.reduceMotion, let layer else { return }
        let press = CASpringAnimation(keyPath: "transform.scale")
        press.stiffness  = 600
        press.damping    = 28
        press.mass       = 1
        press.fromValue  = 1.0
        press.toValue    = 0.94
        press.duration   = press.settlingDuration
        press.fillMode   = .forwards
        press.isRemovedOnCompletion = false
        layer.add(press, forKey: "press")
        layer.setValue(0.94, forKeyPath: "transform.scale")
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard !AnimationConstants.reduceMotion, let layer else { return }
        let release = CASpringAnimation(keyPath: "transform.scale")
        release.stiffness = 500
        release.damping   = 22
        release.mass      = 1
        release.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 0.94
        release.toValue   = 1.0
        release.duration  = release.settlingDuration
        layer.add(release, forKey: "press")
        layer.setValue(1.0, forKeyPath: "transform.scale")
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize; s.height = 28; return s
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
    private var window:      NSWindow?
    private var onCancel:    (() -> Void)?
    let sessionName:  String
    let manualReason: Bool

    init(sessionName: String, manualReason: Bool = false, onCancel: @escaping () -> Void) {
        self.sessionName  = sessionName
        self.manualReason = manualReason
        self.onCancel     = onCancel
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
            manualReason
                ? "Automatic Space creation isn't available on this system.\n\nPress ⌃↑ to open Mission Control, click + to create a new Space, then switch to it."
                : "Switch to any Space and the workflow will open there.\n\nPress ⌃↑ to open Mission Control, then click + to create a new Space.")
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

// MARK: - SwitchHUD

final class SwitchHUD: NSObject, NSWindowDelegate {
    private var window:       NSWindow?
    private var eventMonitor: Any?
    private var dismissTimer: Timer?
    private var onCancel:     (() -> Void)?
    private let workflowName: String

    init(workflowName: String, onCancel: @escaping () -> Void) {
        self.workflowName = workflowName
        self.onCancel     = onCancel
        super.init()
    }

    func show(autoDismissAfter seconds: Double = 1.8) {
        guard window == nil else { return }
        let W: CGFloat = 320
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 0),
                         styleMask: [.titled, .fullSizeContentView],
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 47 && ev.modifierFlags.contains([.option, .command]) {
                self?.doCancel(); return nil
            }
            return ev
        }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        onCancel = nil; window?.close()
    }

    func windowWillClose(_ n: Notification) { window = nil }

    private func doCancel() { onCancel?(); onCancel = nil; dismiss() }

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
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .regular
        spinner.isIndeterminate = true; spinner.startAnimation(nil)
        root.addArrangedSubview(spinner)
        let label = NSTextField(labelWithString: "Switching to \"\(workflowName)\"…")
        label.font = .systemFont(ofSize: 14, weight: .semibold); label.alignment = .center
        root.addArrangedSubview(label)
        let hint = NSTextField(labelWithString: "Press ⌥⌘. to cancel")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        root.addArrangedSubview(hint)
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        root.addArrangedSubview(cancelBtn)
    }

    @objc private func cancelTapped() { doCancel() }
}

// MARK: - AboutWindow

final class AboutWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); bringToFront(); return }

        let W: CGFloat = 340
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 260),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "About Axe"
        w.titleVisibility            = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed       = false
        w.delegate                   = self

        guard let cv = w.contentView else { return }

        // App icon
        let icon = NSImageView()
        icon.image        = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80),
        ])

        // "Axe" title
        let title = NSTextField(labelWithString: "Axe")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        // Version
        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.font      = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        // Tagline
        let tagline = NSTextField(labelWithString: "Axe running apps — fast.")
        tagline.font      = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor

        // Copyright
        let copyYear = Calendar.current.component(.year, from: Date())
        let copy = NSTextField(labelWithString: "© 2025–\(copyYear) Taylor Emery. All rights reserved.")
        copy.font      = .systemFont(ofSize: 10)
        copy.textColor = .tertiaryLabelColor

        // Website link
        let websiteBtn = NSButton(title: "axe-app.com", target: self, action: #selector(openWebsite))
        websiteBtn.bezelStyle     = .inline
        websiteBtn.isBordered     = false
        websiteBtn.font           = .systemFont(ofSize: 11)
        websiteBtn.contentTintColor = .controlAccentColor

        // Text stack
        let textStack = NSStackView(views: [title, version, tagline])
        textStack.orientation = .vertical
        textStack.alignment   = .leading
        textStack.spacing     = 3

        // Top row: icon + text
        let topRow = NSStackView(views: [icon, textStack])
        topRow.orientation = .horizontal
        topRow.alignment   = .centerY
        topRow.spacing     = 16

        // Divider
        let sep = NSBox(); sep.boxType = .separator

        // Bottom row
        let bottomStack = NSStackView(views: [copy, websiteBtn])
        bottomStack.orientation = .vertical
        bottomStack.alignment   = .centerX
        bottomStack.spacing     = 4

        // Root
        let root = NSStackView(views: [topRow, sep, bottomStack])
        root.orientation = .vertical
        root.alignment   = .centerX
        root.spacing     = 16
        root.edgeInsets  = NSEdgeInsets(top: 28, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sep.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            topRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
        ])

        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        bringToFront()
    }

    func windowWillClose(_ n: Notification) { window = nil }

    private func bringToFront() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://axe-app.com")!)
    }
}

// MARK: - SelfUpdater

/// Downloads the latest release zip, swaps the app bundle via a helper script, and relaunches.
final class SelfUpdater: NSObject, NSWindowDelegate {
    private var window:       NSWindow?
    private var progressBar:  NSProgressIndicator?
    private var statusLabel:  NSTextField?
    private var downloadTask: URLSessionDownloadTask?
    private var cancelled = false

    func install(version: String) {
        showProgress(version: version)
        let urlStr = "https://github.com/emerytech/homebrew-axe/releases/download/v\(version)/Axe.zip"
        guard let url = URL(string: urlStr) else { fail(); return }
        downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, err in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                guard let tmp, err == nil else { self.fail(); return }
                self.statusLabel?.stringValue = "Installing…"
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = Self.applyUpdate(from: tmp, version: version)
                    DispatchQueue.main.async {
                        if ok {
                            self.statusLabel?.stringValue = "Restarting Axe…"
                            self.progressBar?.isHidden = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                (NSApp.delegate as? AppDelegate)?.isUpdating = true
                                NSApp.terminate(nil)   // installer script relaunches
                            }
                        } else { self.fail() }
                    }
                }
            }
        }
        downloadTask?.resume()
    }

    // MARK: Apply

    private static func applyUpdate(from zip: URL, version: String) -> Bool {
        let fm  = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                      .appendingPathComponent("axe-update-\(version)")
        try? fm.removeItem(at: tmp)
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil
        else { return false }

        // Unzip the download
        let uz = Process()
        uz.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        uz.arguments = ["-q", "-o", zip.path, "-d", tmp.path]
        guard (try? uz.run()) != nil else { return false }
        uz.waitUntilExit()
        guard uz.terminationStatus == 0 else { return false }

        let newApp = tmp.appendingPathComponent("Axe.app")
        guard fm.fileExists(atPath: newApp.path) else { return false }

        // Shell script: wait for app to quit, atomically swap bundle, relaunch.
        // NB: never `cp -R` into the live bundle path — cp copies INTO an existing
        // directory, nesting Axe.app inside Axe.app so the update never applies.
        // Instead ditto a clean clone onto the SAME volume (/Applications), move the
        // old bundle aside, then atomic-rename the new one in. Restore on failure so
        // a botched swap never leaves the user with no app installed.
        let cur     = Bundle.main.bundlePath
        let parent  = (cur as NSString).deletingLastPathComponent
        let staging = parent + "/.Axe-update-new"
        let backup  = parent + "/.Axe-update-old"
        let script = """
        #!/bin/bash
        set -e
        sleep 1.5
        rm -rf \(staging.shellQuoted) \(backup.shellQuoted)
        /usr/bin/ditto \(newApp.path.shellQuoted) \(staging.shellQuoted)
        mv \(cur.shellQuoted) \(backup.shellQuoted)
        mv \(staging.shellQuoted) \(cur.shellQuoted) || { mv \(backup.shellQuoted) \(cur.shellQuoted); open \(cur.shellQuoted); exit 1; }
        rm -rf \(backup.shellQuoted)
        open \(cur.shellQuoted)
        rm -rf \(tmp.path.shellQuoted)
        """
        let scriptURL = tmp.appendingPathComponent("install.sh")
        guard (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil
        else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments     = [scriptURL.path]
        guard (try? installer.run()) != nil else { return false }
        return true
    }

    // MARK: UI

    private func showProgress(version: String) {
        let W: CGFloat = 300
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 110),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = ""; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false; w.level = .floating; w.delegate = self

        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 10; root.alignment = .centerX
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])

        let title = NSTextField(labelWithString: "Updating to Axe \(version)…")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(title)

        let bar = NSProgressIndicator()
        bar.style = .bar; bar.isIndeterminate = true; bar.startAnimation(nil)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: W - 40).isActive = true
        root.addArrangedSubview(bar)
        progressBar = bar

        let lbl = NSTextField(labelWithString: "Downloading…")
        lbl.font = .systemFont(ofSize: 11); lbl.textColor = .secondaryLabelColor
        root.addArrangedSubview(lbl)
        statusLabel = lbl

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        root.addArrangedSubview(cancel)

        window = w
        if let sf = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: sf.maxX - W - 20, y: sf.minY + 20))
        } else { w.center() }
        w.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func fail() {
        progressBar?.isHidden = true
        statusLabel?.stringValue = "Update failed — try again later."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.window?.close() }
    }

    @objc private func cancelTapped() { cancelled = true; downloadTask?.cancel(); window?.close() }
    func windowWillClose(_ n: Notification) { window = nil }
}

private extension String {
    /// Wraps a path in single quotes, escaping any embedded single quotes.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - UpdateWindow

final class UpdateWindow: NSObject, NSWindowDelegate {
    private var window:   NSWindow?
    private weak var brewBtn: NSButton?
    private var selfUpdater: SelfUpdater?
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

        // Render GitHub Markdown; fall back to stripped symbols if parsing fails
        if let attrStr = try? AttributedString(
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

        let brewBtn = NSButton(title: "Homebrew", target: self, action: #selector(brewTapped))
        brewBtn.bezelStyle = .rounded
        self.brewBtn = brewBtn

        let installBtn = NSButton(title: "Install Update", target: self, action: #selector(installTapped))
        installBtn.bezelStyle    = .rounded
        installBtn.keyEquivalent = "\r"
        installBtn.controlSize   = .large

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let btnRow = NSStackView(views: [laterBtn, spacer, brewBtn, installBtn])
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

    @objc private func installTapped() {
        let updater = SelfUpdater()
        selfUpdater = updater
        window?.close()
        updater.install(version: latestVersion)
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

        let body = NSTextField(labelWithString: pun(
            "Axe is free to keep. If it's been saving you time,\na small tip keeps the Axe sharp. ⚔️",
            "Axe is free to keep. If it's been saving you time,\na small tip keeps the blade sharp. ⚔️"))
        body.font = .systemFont(ofSize: 12, weight: .regular)
        body.textColor = .secondaryLabelColor; body.alignment = .center
        body.lineBreakMode = .byWordWrapping

        let topStack = NSStackView(views: [heart, headline, body])
        topStack.orientation = .vertical; topStack.spacing = 6; topStack.alignment = .centerX
        let topPad = padded(topStack, top: 24, left: 20, bottom: 16, right: 20)
        root.addArrangedSubview(topPad)
        topPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Buy + dismiss buttons ─────────────────────────────────
        let buyBtn = NSButton(title: "Get the Axe →", target: self, action: #selector(buyTapped))
        buyBtn.bezelStyle = .rounded; buyBtn.keyEquivalent = "\r"
        let laterBtn = NSButton(title: pun("Maybe L-Axe-ter", "Maybe Later"),
                                target: self, action: #selector(laterTapped))
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

        let extraBtn = NSButton(title: "Buy an Axe-tra seat — $4.99 →",
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
            (AppSettings.shortcutLabel(), "Open Axe from anywhere — no Accessibility needed",       ""),
            ("magnifyingglass",           "Type to instantly filter your running apps",              "sf"),
            ("cursorarrow.click.2",       "Double-click a row to quit  ·  ⌘-double-click to force kill", "sf"),
            ("checkmark.square",          "Tick checkboxes to build a batch list, then confirm",    "sf"),
            ("square.stack.3d.up",        "Save apps as a Workflow — restore later, or Save & Axe All at once", "sf"),
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

        let styles: [(UIStyle, String, String)] = [
            (.popover,   "Menu Bar\nPopover",  "Drops from the\nmenu bar icon"),
            (.spotlight, "Spotlight\nOverlay", "Floats in the\ncenter of screen"),
            (.notch,     "Drop from\nNotch",   "Slides from the\ntop of screen"),
        ]
        var cards: [StyleCard] = []
        let cardStack = NSStackView()
        cardStack.orientation = .horizontal; cardStack.spacing = 10; cardStack.alignment = .centerY
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        for (style, name, hint) in styles {
            let card = StyleCard(style: style, name: name, hint: hint)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: 124).isActive = true
            card.heightAnchor.constraint(equalToConstant: 110).isActive = true
            card.isSelected = (AppSettings.uiStyle == style)
            card.onSelect = { chosen in
                AppSettings.uiStyle = chosen
                cards.forEach { $0.isSelected = ($0.style == chosen) }
            }
            cards.append(card)
            cardStack.addArrangedSubview(card)
        }

        let pickerStack = NSStackView(views: [pickerTitle, cardStack])
        pickerStack.orientation = .vertical; pickerStack.spacing = 12; pickerStack.alignment = .centerX
        pickerStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.addArrangedSubview(pickerStack)
        pickerStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let sep3 = NSBox(); sep3.boxType = .separator
        sep3.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(sep3)
        sep3.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── Escape hatch: tell users this is all changeable later ────
        let tip = label("Change the \(AppSettings.shortcutLabel()) hotkey or overlay style anytime in Settings",
                        size: 11, weight: .regular, color: .tertiaryLabelColor)
        let tipPad = padded(tip, top: 12, left: 20, bottom: 0)
        root.addArrangedSubview(tipPad)
        tipPad.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

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

    // ── Style selection card ────────────────────────────────────────
    final class StyleCard: NSView {
        let style: UIStyle
        var onSelect: ((UIStyle) -> Void)?

        var isSelected = false {
            didSet {
                let accent = NSColor.controlAccentColor
                layer?.borderColor = isSelected
                    ? accent.cgColor
                    : NSColor.separatorColor.withAlphaComponent(0.5).cgColor
                layer?.borderWidth = isSelected ? 2 : 1
                titleLabel.textColor = isSelected ? accent : .secondaryLabelColor
                needsDisplay = true
            }
        }

        private let titleLabel: NSTextField

        init(style: UIStyle, name: String, hint: String) {
            self.style = style
            self.titleLabel = NSTextField(labelWithString: name)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.06).cgColor

            titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.alignment = .center
            titleLabel.maximumNumberOfLines = 2
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(titleLabel)

            let hintLabel = NSTextField(labelWithString: hint)
            hintLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
            hintLabel.textColor = .tertiaryLabelColor
            hintLabel.alignment = .center
            hintLabel.maximumNumberOfLines = 2
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hintLabel)

            NSLayoutConstraint.activate([
                titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                titleLabel.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -3),
                hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
                hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            ])

            let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
            addGestureRecognizer(click)
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func tapped() {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                animator().alphaValue = 0.6
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    self.animator().alphaValue = 1
                }
            }
            onSelect?(style)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let accent = isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            let ill = NSRect(x: 8, y: bounds.height - 68, width: bounds.width - 16, height: 58)

            switch style {
            case .popover:
                // Menu bar strip at top, popover panel hanging below right
                let barH: CGFloat = 10
                let bar = NSBezierPath(roundedRect: NSRect(x: ill.minX, y: ill.maxY - barH,
                                                           width: ill.width, height: barH),
                                       xRadius: 3, yRadius: 3)
                accent.withAlphaComponent(0.25).setFill(); bar.fill()
                // Small icon dot at right of bar
                let dot = NSBezierPath(ovalIn: NSRect(x: ill.maxX - 14,
                                                      y: ill.maxY - barH + 2, width: 6, height: 6))
                accent.withAlphaComponent(0.7).setFill(); dot.fill()
                // Popover panel, right-aligned
                let panW: CGFloat = ill.width * 0.7
                let panH: CGFloat = ill.height - barH - 8
                let panX = ill.maxX - panW
                let panY = ill.minY + 4
                let panel = NSBezierPath(roundedRect: NSRect(x: panX, y: panY, width: panW, height: panH),
                                         xRadius: 5, yRadius: 5)
                accent.withAlphaComponent(0.18).setFill(); panel.fill()
                accent.withAlphaComponent(0.45).setStroke(); panel.lineWidth = 1; panel.stroke()
                // Arrow upward from panel center-top toward icon
                let arrowX = panX + panW - 14
                let arrowY = panY + panH
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: arrowX - 5, y: arrowY))
                arrow.line(to: NSPoint(x: arrowX + 5, y: arrowY))
                arrow.line(to: NSPoint(x: arrowX, y: arrowY + 6))
                arrow.close()
                accent.withAlphaComponent(0.45).setFill(); arrow.fill()

            case .spotlight:
                // Floating centered panel with subtle shadow suggestion
                let panW: CGFloat = ill.width * 0.78
                let panH: CGFloat = ill.height * 0.7
                let panX = ill.midX - panW / 2
                let panY = ill.midY - panH / 2 + 4
                // Shadow hint
                let shadow = NSBezierPath(roundedRect: NSRect(x: panX + 2, y: panY - 4, width: panW, height: panH),
                                          xRadius: 6, yRadius: 6)
                NSColor.black.withAlphaComponent(0.12).setFill(); shadow.fill()
                // Panel body
                let panel = NSBezierPath(roundedRect: NSRect(x: panX, y: panY, width: panW, height: panH),
                                          xRadius: 6, yRadius: 6)
                accent.withAlphaComponent(0.18).setFill(); panel.fill()
                accent.withAlphaComponent(0.45).setStroke(); panel.lineWidth = 1; panel.stroke()
                // Search bar line inside panel
                let lineY = panY + panH - 12
                let lineX = panX + 8
                let searchLine = NSBezierPath()
                searchLine.move(to: NSPoint(x: lineX, y: lineY))
                searchLine.line(to: NSPoint(x: panX + panW - 8, y: lineY))
                accent.withAlphaComponent(0.3).setStroke()
                searchLine.lineWidth = 1.5; searchLine.stroke()

            case .notch:
                // Notch shape at top center, panel drops below
                let notchW: CGFloat = 42
                let notchH: CGFloat = 10
                let notchX = ill.midX - notchW / 2
                let notchY = ill.maxY - notchH
                let notch = NSBezierPath(roundedRect: NSRect(x: notchX, y: notchY, width: notchW, height: notchH),
                                          xRadius: 5, yRadius: 5)
                accent.withAlphaComponent(0.4).setFill(); notch.fill()
                // Panel body
                let panW = ill.width * 0.65
                let panH = ill.height - notchH - 6
                let panX = ill.midX - panW / 2
                let panY = ill.minY + 2
                let panel = NSBezierPath(roundedRect: NSRect(x: panX, y: panY, width: panW, height: panH),
                                          xRadius: 5, yRadius: 5)
                accent.withAlphaComponent(0.18).setFill(); panel.fill()
                accent.withAlphaComponent(0.45).setStroke(); panel.lineWidth = 1; panel.stroke()
            }
        }
    }
}

// MARK: - Notch Resize Handle

final class NotchResizeHandle: NSView {
    var onResize: (CGFloat) -> Void = { _ in }
    private var trackingArea: NSTrackingArea?
    private var dragStartScreenY: CGFloat = 0
    private var dragStartExtra: CGFloat = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta); trackingArea = ta
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return point.y <= 4 ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.resizeUpDown.push() }
    override func mouseExited(with event: NSEvent)  { NSCursor.pop() }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenY = NSEvent.mouseLocation.y
        dragStartExtra   = AppSettings.notchExtraHeight
    }

    override func mouseDragged(with event: NSEvent) {
        let dy = NSEvent.mouseLocation.y - dragStartScreenY
        let newExtra = max(0, dragStartExtra - dy)
        onResize(newExtra)
    }

    override func mouseUp(with event: NSEvent) {
        let dy = NSEvent.mouseLocation.y - dragStartScreenY
        let newExtra = max(0, dragStartExtra - dy)
        onResize(newExtra)
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - NotchIndicator
/// Minimal pill to the left of the hardware notch. Shows ⚡ + running app count.
/// Hover opens the full Axe overlay. Styled to look like a notch extension.
final class NotchIndicatorPanel: NSPanel {

    var onOpen: (() -> Void)?

    private weak var countLabel: NSTextField?
    private weak var pillView: NSView?
    private var onRight: Bool = false

    // All pill dimensions are derived from the menu-bar height so the proportions
    // hold on any Mac model or display-scaling setting.
    private static func pillW(for h: CGFloat)  -> CGFloat { (h * 1.24).rounded() }
    private static func edgeMargin(for h: CGFloat) -> CGFloat { (h * 0.24).rounded() }
    private var trackingArea: NSTrackingArea?
    private var hoverItem: DispatchWorkItem?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    convenience init(screen: NSScreen, onRight: Bool = false) {
        let f: NSRect
        if onRight {
            let area: NSRect
            if let a = screen.auxiliaryTopRightArea {
                area = a
            } else {
                area = NSRect(x: screen.frame.midX + 85, y: screen.frame.maxY - 24,
                              width: screen.frame.midX - 85, height: 24)
            }
            let pW      = NotchIndicatorPanel.pillW(for: area.height)
            let em      = NotchIndicatorPanel.edgeMargin(for: area.height)
            let overlap = (area.height * 0.27).rounded()
            f = NSRect(x: area.minX - overlap,
                       y: area.minY,
                       width: pW + em,
                       height: area.height)
        } else {
            let area: NSRect
            if let a = screen.auxiliaryTopLeftArea {
                area = a
            } else {
                area = NSRect(x: screen.frame.minX,
                              y: screen.frame.maxY - 24,
                              width: screen.frame.midX - 85,
                              height: 24)
            }
            let pW      = NotchIndicatorPanel.pillW(for: area.height)
            let em      = NotchIndicatorPanel.edgeMargin(for: area.height)
            let overlap = (area.height * 0.27).rounded()
            f = NSRect(x: area.maxX - pW + overlap - em,
                       y: area.minY,
                       width: pW + em,
                       height: area.height)
        }
        self.init(contentRect: f,
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        level                = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        isReleasedWhenClosed = false
        backgroundColor      = .clear
        isOpaque             = false
        hasShadow            = false
        isMovable            = false
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.onRight         = onRight
        buildContent()
        contentView?.layoutSubtreeIfNeeded()
        applyPillMask()
    }

    private func buildContent() {
        guard let cv = contentView else { return }
        cv.wantsLayer = true
        cv.layer?.backgroundColor = NSColor.clear.cgColor

        let pillView = NSView()
        pillView.wantsLayer = true
        pillView.layer?.backgroundColor = NSColor.clear.cgColor   // skin fill provides the look; the mask shapes it
        pillView.translatesAutoresizingMaskIntoConstraints = false
        self.pillView = pillView
        cv.addSubview(pillView)

        NSLayoutConstraint.activate([
            pillView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            pillView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            pillView.topAnchor.constraint(equalTo: cv.topAnchor),
            pillView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        let skinFill = AppSettings.notchSkin.makeHubBackground(cornerRadius: 0, corners: [])
        skinFill.translatesAutoresizingMaskIntoConstraints = false
        pillView.addSubview(skinFill)
        NSLayoutConstraint.activate([
            skinFill.leadingAnchor.constraint(equalTo: pillView.leadingAnchor),
            skinFill.trailingAnchor.constraint(equalTo: pillView.trailingAnchor),
            skinFill.topAnchor.constraint(equalTo: pillView.topAnchor),
            skinFill.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
        ])

        let bolt = NSImageView()
        if let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            bolt.image = img
        }
        bolt.contentTintColor = NSColor(red: 1, green: 0.28, blue: 0.28, alpha: 1)
        bolt.translatesAutoresizingMaskIntoConstraints = false

        let count = NSTextField(labelWithString: "0")
        count.font      = .systemFont(ofSize: 11, weight: .semibold)
        count.textColor = .white
        count.translatesAutoresizingMaskIntoConstraints = false
        countLabel = count

        pillView.addSubview(bolt); pillView.addSubview(count)
        if onRight {
            // Notch is on the left; content near leading edge
            NSLayoutConstraint.activate([
                bolt.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
                bolt.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 14),
                bolt.widthAnchor.constraint(equalToConstant: 10),
                bolt.heightAnchor.constraint(equalToConstant: 12),
                count.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
                count.leadingAnchor.constraint(equalTo: bolt.trailingAnchor, constant: 3),
            ])
        } else {
            // Notch is on the right; content near trailing edge
            NSLayoutConstraint.activate([
                count.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
                count.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -14),
                bolt.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
                bolt.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -3),
                bolt.widthAnchor.constraint(equalToConstant: 10),
                bolt.heightAnchor.constraint(equalToConstant: 12),
            ])
        }

        let tap = NSClickGestureRecognizer(target: self, action: #selector(indicatorTapped))
        pillView.addGestureRecognizer(tap)

        refreshTracking()
    }

    // MARK: Shape mask

    private func applyPillMask() {
        guard let pv = pillView, let layer = pv.layer else { return }
        let W = layer.bounds.width
        let H = layer.bounds.height
        guard W > 0, H > 0 else { return }

        // All geometry derived from H so proportions hold on any display.
        let em = NotchIndicatorPanel.edgeMargin(for: H)   // ~0.24 × H
        let Rc = em                                        // bowing-corner radius = margin
        let Rv = (H * 0.27).rounded()                     // convex bottom-corner radius
        let pW = NotchIndicatorPanel.pillW(for: H)        // ~1.24 × H

        let path = CGMutablePath()

        if onRight {
            // Pill sits RIGHT of notch; notch edge is on the LEFT side of the window.
            // Top-right corner bows outward (up-right) into the bezel.
            // Bottom-right: convex rounded corner.
            // Left side: flat, hidden under the notch.
            path.move(to: CGPoint(x: W, y: H))
            // Top edge going left (toward notch)
            path.addLine(to: CGPoint(x: 0, y: H))
            // Left edge going down (flat, under notch)
            path.addLine(to: CGPoint(x: 0, y: 0))
            // Bottom edge going right to bottom-right arc
            path.addLine(to: CGPoint(x: pW - Rv, y: 0))
            // Convex bottom-right: CCW arc 270°→0°, center (pW-Rv, Rv)
            path.addArc(center: CGPoint(x: pW - Rv, y: Rv),
                        radius: Rv,
                        startAngle: .pi * 3 / 2, endAngle: 0, clockwise: false)
            // Right wall straight up to start of top-right arc
            path.addLine(to: CGPoint(x: pW, y: H - Rc))
            // Top-right arc: CW 180°→90°, center (W, H-Rc).
            //   Bows RIGHT — mirrors the left-side top-left arc.
            path.addArc(center: CGPoint(x: W, y: H - Rc),
                        radius: Rc,
                        startAngle: .pi, endAngle: .pi / 2, clockwise: true)
            path.closeSubpath()
        } else {
            // Pill sits LEFT of notch; notch edge is on the RIGHT side of the window.
            // Top-left corner bows outward (up-left) into the bezel.
            // Bottom-left: convex rounded corner.
            // Right side: flat, hidden under the notch.
            path.move(to: CGPoint(x: 0, y: H))
            // Top edge going right
            path.addLine(to: CGPoint(x: W, y: H))
            // Right edge going down
            path.addLine(to: CGPoint(x: W, y: 0))
            // Bottom edge going left to bottom-left arc
            path.addLine(to: CGPoint(x: em + Rv, y: 0))
            // Convex bottom-left: CW arc 270°→180°, center (em+Rv, Rv)
            path.addArc(center: CGPoint(x: em + Rv, y: Rv),
                        radius: Rv,
                        startAngle: .pi * 3 / 2, endAngle: .pi, clockwise: true)
            // Left wall straight up to start of top-left arc
            path.addLine(to: CGPoint(x: em, y: H - Rc))
            // Top-left arc: CCW 0°→90°, center (0, H-Rc).
            //   Bows LEFT — mirrors notch top-right corner curving into the bezel.
            path.addArc(center: CGPoint(x: 0, y: H - Rc),
                        radius: Rc,
                        startAngle: 0, endAngle: .pi / 2, clockwise: false)
            path.closeSubpath()
        }

        let maskLayer = CAShapeLayer()
        maskLayer.frame = layer.bounds
        maskLayer.path  = path
        layer.mask = maskLayer
    }

    // MARK: Tracking — hover opens the overlay after a brief delay

    private func refreshTracking() {
        guard let cv = contentView else { return }
        if let old = trackingArea { cv.removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: cv.bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        cv.addTrackingArea(ta); trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        let item = DispatchWorkItem { [weak self] in self?.onOpen?() }
        hoverItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        hoverItem?.cancel(); hoverItem = nil
    }

    // MARK: Data / actions

    func update(appCount: Int, lastSessionName: String?) {
        countLabel?.stringValue = "\(appCount)"
    }

    @objc private func indicatorTapped() { onOpen?() }
}

// MARK: - Notch shelf (drag-and-drop staging tray)

/// Persistent list of staged file paths for the notch shelf. Drop files onto the
/// notch to stage them here; drag them out anywhere later. Public APIs only.
final class ShelfStore {
    static let shared = ShelfStore()
    private init() {}
    private let key = "notchShelfPaths"
    private let d = UserDefaults.standard
    var onChange: (() -> Void)?

    private(set) var paths: [String] {
        get { d.stringArray(forKey: key) ?? [] }
        set { d.set(newValue, forKey: key); onChange?() }
    }
    func urls() -> [URL] { paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }

    func add(_ url: URL) {
        var p = paths
        p.removeAll { $0 == url.path }
        p.insert(url.path, at: 0)
        if p.count > 24 { p = Array(p.prefix(24)) }
        paths = p
    }
    func remove(_ path: String) { paths = paths.filter { $0 != path } }
    func clear() { paths = [] }
}

/// A draggable chip for one staged file: shows its icon + truncated name, drags
/// OUT to Finder/apps (provides the file URL), and removes on ✕ / right-click.
final class ShelfChipView: NSView, NSDraggingSource {
    let url: URL
    var onRemove: (() -> Void)?
    private var iconImage: NSImage?

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 58, height: 62))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 58).isActive = true
        heightAnchor.constraint(equalToConstant: 62).isActive = true

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 34, height: 34)
        iconImage = icon
        let iv = NSImageView(image: icon)
        iv.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 9); name.textColor = NSColor.white.withAlphaComponent(0.85)
        name.alignment = .center; name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.translatesAutoresizingMaskIntoConstraints = false
        name.toolTip = url.lastPathComponent
        addSubview(iv); addSubview(name)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            iv.centerXAnchor.constraint(equalTo: centerXAnchor),
            iv.widthAnchor.constraint(equalToConstant: 34),
            iv.heightAnchor.constraint(equalToConstant: 34),
            name.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 2),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = iconImage ?? NSImage()
        item.setDraggingFrame(NSRect(x: 12, y: 24, width: 34, height: 34), contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func rightMouseDown(with event: NSEvent) { onRemove?() }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}

/// The hub's black background, doubling as a drag DESTINATION: dragging files over
/// it requests expansion, and dropping stages them in the ShelfStore.
final class HubDropView: NSView {
    var onDragEnter: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - Notch hub
//
// A centered, notch-hugging hub that hover-expands into a glanceable panel.
// First cut: a live clock + running-app count at rest; on hover it grows down
// into a hub with the date and quick actions (Open Axe / Displays). Foundation
// for later modules (now-playing media, file shelf, clipboard). Built on the same
// borderless, top-anchored, behind-the-bezel panel trick as NotchIndicatorPanel;
// uses a simple frame+alpha spring rather than the parametric mask morph.
final class NotchHubPanel: NSPanel {
    var onOpenAxe:       (() -> Void)?
    var onOpenDisplays:  (() -> Void)?
    var onOpenClipboard: (() -> Void)?

    private var bezelH: CGFloat = 32
    private let expandedH: CGFloat = 220
    private var expanded = false
    private var collapseWork: DispatchWorkItem?

    private weak var bg: NSView?
    private weak var clockLabel: NSTextField?
    private weak var dateLabel:  NSTextField?
    private weak var countLabel: NSTextField?
    private weak var expandedView: NSView?
    private weak var shelfStack: NSStackView?
    private var clockTimer: Timer?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    convenience init(screen: NSScreen) {
        let bez = max(screen.safeAreaInsets.top, 24)
        let w: CGFloat = 360
        let f = NSRect(x: (screen.frame.midX - w / 2).rounded(),
                       y: screen.frame.maxY - bez, width: w, height: bez)
        self.init(contentRect: f, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        bezelH = bez
        level                = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        isReleasedWhenClosed = false
        backgroundColor      = .clear
        isOpaque             = false
        hasShadow            = false
        isMovable            = false
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        buildContent()
        startClock()
    }

    private func buildContent() {
        guard let cv = contentView else { return }
        cv.wantsLayer = true

        // HubDropView stays the content container + drag target, but no longer paints
        // its own fill — it clips its subtree to the rounded-bottom shape; the skin
        // view below provides the actual background (Classic black / Liquid Glass / …).
        let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let bgv = HubDropView(); bgv.wantsLayer = true
        bgv.layer?.cornerRadius  = 14
        bgv.layer?.cornerCurve   = .continuous
        bgv.layer?.maskedCorners = corners
        bgv.layer?.masksToBounds = true
        bgv.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(bgv); bg = bgv
        NSLayoutConstraint.activate([
            bgv.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            bgv.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            bgv.topAnchor.constraint(equalTo: cv.topAnchor),
            bgv.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
        let skinBG = AppSettings.notchSkin.makeHubBackground(cornerRadius: 14, corners: corners)
        skinBG.translatesAutoresizingMaskIntoConstraints = false
        bgv.addSubview(skinBG, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            skinBG.leadingAnchor.constraint(equalTo: bgv.leadingAnchor),
            skinBG.trailingAnchor.constraint(equalTo: bgv.trailingAnchor),
            skinBG.topAnchor.constraint(equalTo: bgv.topAnchor),
            skinBG.bottomAnchor.constraint(equalTo: bgv.bottomAnchor),
        ])
        // Dragging files onto the notch expands the hub and stages them in the shelf.
        bgv.registerForDraggedTypes([.fileURL])
        bgv.onDragEnter = { [weak self] in self?.collapseWork?.cancel(); self?.setExpanded(true) }
        bgv.onDrop = { [weak self] urls in
            urls.forEach { ShelfStore.shared.add($0) }
            self?.collapseWork?.cancel(); self?.setExpanded(true)
        }

        // Top band (menu-bar row): app count on the left flank, clock on the right,
        // the physical notch sits between them.
        let bolt = NSImageView()
        bolt.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        bolt.contentTintColor = NSColor(red: 1, green: 0.28, blue: 0.28, alpha: 1)
        bolt.translatesAutoresizingMaskIntoConstraints = false
        let count = NSTextField(labelWithString: "0")
        count.font = .systemFont(ofSize: 11, weight: .semibold); count.textColor = .white
        count.translatesAutoresizingMaskIntoConstraints = false; countLabel = count
        let clock = NSTextField(labelWithString: "")
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); clock.textColor = .white
        clock.translatesAutoresizingMaskIntoConstraints = false; clockLabel = clock
        bgv.addSubview(bolt); bgv.addSubview(count); bgv.addSubview(clock)
        NSLayoutConstraint.activate([
            bolt.leadingAnchor.constraint(equalTo: bgv.leadingAnchor, constant: 16),
            bolt.topAnchor.constraint(equalTo: bgv.topAnchor, constant: (bezelH - 12) / 2),
            bolt.widthAnchor.constraint(equalToConstant: 10),
            bolt.heightAnchor.constraint(equalToConstant: 12),
            count.leadingAnchor.constraint(equalTo: bolt.trailingAnchor, constant: 3),
            count.centerYAnchor.constraint(equalTo: bolt.centerYAnchor),
            clock.trailingAnchor.constraint(equalTo: bgv.trailingAnchor, constant: -16),
            clock.centerYAnchor.constraint(equalTo: bolt.centerYAnchor),
        ])

        // Expanded content — hidden until hover-expand.
        let ev = NSView(); ev.alphaValue = 0
        ev.translatesAutoresizingMaskIntoConstraints = false
        bgv.addSubview(ev); expandedView = ev
        NSLayoutConstraint.activate([
            ev.leadingAnchor.constraint(equalTo: bgv.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: bgv.trailingAnchor),
            ev.topAnchor.constraint(equalTo: bgv.topAnchor, constant: bezelH),
            ev.bottomAnchor.constraint(equalTo: bgv.bottomAnchor),
        ])

        let date = NSTextField(labelWithString: "")
        date.font = .systemFont(ofSize: 12); date.textColor = NSColor.white.withAlphaComponent(0.7)
        date.alignment = .center; date.translatesAutoresizingMaskIntoConstraints = false; dateLabel = date

        let openBtn = hubButton("Axe", "bolt.fill", #selector(openAxeTapped))
        let dispBtn = hubButton("Displays", "sun.max", #selector(openDisplaysTapped))
        let clipBtn = hubButton("Clipboard", "doc.on.clipboard", #selector(openClipboardTapped))
        let row = NSStackView(views: [openBtn, dispBtn, clipBtn])
        row.orientation = .horizontal; row.spacing = 8; row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        // Shelf: staged files (drag out anywhere), or a drop hint when empty.
        let shelfLabel = NSTextField(labelWithString: "SHELF")
        shelfLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        shelfLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        shelfLabel.translatesAutoresizingMaskIntoConstraints = false
        let shelf = NSStackView()
        shelf.orientation = .horizontal; shelf.spacing = 8; shelf.alignment = .top
        shelf.translatesAutoresizingMaskIntoConstraints = false
        shelfStack = shelf

        ev.addSubview(date); ev.addSubview(row); ev.addSubview(shelfLabel); ev.addSubview(shelf)
        NSLayoutConstraint.activate([
            date.topAnchor.constraint(equalTo: ev.topAnchor, constant: 16),
            date.centerXAnchor.constraint(equalTo: ev.centerXAnchor),
            row.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: ev.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: date.bottomAnchor, constant: 14),
            shelfLabel.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: 18),
            shelfLabel.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 14),
            shelf.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: 18),
            shelf.trailingAnchor.constraint(lessThanOrEqualTo: ev.trailingAnchor, constant: -18),
            shelf.topAnchor.constraint(equalTo: shelfLabel.bottomAnchor, constant: 6),
        ])
        reloadShelf()
        ShelfStore.shared.onChange = { [weak self] in self?.reloadShelf() }

        let track = NSTrackingArea(rect: .zero,
                                   options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                   owner: self, userInfo: nil)
        cv.addTrackingArea(track)
    }

    private func reloadShelf() {
        guard let shelf = shelfStack else { return }
        shelf.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = ShelfStore.shared.urls()
        if urls.isEmpty {
            let hint = NSTextField(labelWithString: "Drop files onto the notch to stage them")
            hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor.white.withAlphaComponent(0.35)
            shelf.addArrangedSubview(hint)
        } else {
            for url in urls {
                let chip = ShelfChipView(url: url)
                chip.onRemove = { ShelfStore.shared.remove(url.path) }
                shelf.addArrangedSubview(chip)
            }
        }
    }

    private func hubButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.controlSize = .regular
        return b
    }

    // ── Live clock ───────────────────────────────────────────────────
    private func startClock() {
        updateClock()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }
    private func updateClock() {
        let now = Date()
        let tf = DateFormatter(); tf.dateFormat = "h:mm"
        clockLabel?.stringValue = tf.string(from: now)
        let df = DateFormatter(); df.dateFormat = "EEEE, MMM d"
        dateLabel?.stringValue = df.string(from: now)
    }

    func update(appCount: Int) { countLabel?.stringValue = "\(appCount)" }

    // ── Hover expand / collapse ──────────────────────────────────────
    override func mouseEntered(with event: NSEvent) { collapseWork?.cancel(); setExpanded(true) }
    override func mouseExited(with event: NSEvent) {
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        let top = frame.maxY                       // top edge stays pinned behind the bezel
        let h   = on ? expandedH : bezelH
        var f   = frame; f.origin.y = top - h; f.size.height = h
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.30 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.94, 0.6, 1.0)
            animator().setFrame(f, display: true)
            expandedView?.animator().alphaValue = on ? 1 : 0
        }
    }

    @objc private func openAxeTapped()      { setExpanded(false); onOpenAxe?() }
    @objc private func openDisplaysTapped() { setExpanded(false); onOpenDisplays?() }
    @objc private func openClipboardTapped() { setExpanded(false); onOpenClipboard?() }

    deinit { clockTimer?.invalidate() }
}

// MARK: - Clipboard history (Supaste-style)

struct ClipItem: Codable, Equatable {
    let id: String
    let text: String
    var pinned: Bool
    let date: Double
}

/// Polls the general pasteboard for new text clips, keeps a searchable history,
/// supports pinned snippets and copy-back. Skips password-manager / transient
/// clips. Public APIs only (NSPasteboard).
final class ClipboardStore {
    static let shared = ClipboardStore()
    private init() {}
    private let d = UserDefaults.standard
    private let key = "clipboardHistory"
    private let maxUnpinned = 100
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoreNext = false
    private var timer: Timer?
    var onChange: (() -> Void)?

    private(set) var items: [ClipItem] {
        get { (try? JSONDecoder().decode([ClipItem].self, from: d.data(forKey: key) ?? Data())) ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: key); onChange?() }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if ignoreNext { ignoreNext = false; return }
        // Respect the nspasteboard.com convention: skip password-manager/transient clips.
        let types = pb.types?.map { $0.rawValue } ?? []
        if types.contains("org.nspasteboard.ConcealedType")
            || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        capture(s)
    }

    private func capture(_ s: String) {
        var arr = items
        let wasPinned = arr.first(where: { $0.text == s })?.pinned ?? false
        arr.removeAll { $0.text == s }
        arr.insert(ClipItem(id: UUID().uuidString, text: s, pinned: wasPinned,
                            date: Date().timeIntervalSince1970), at: 0)
        // Trim oldest unpinned beyond the cap; pinned snippets are always kept.
        var unpinnedSeen = 0
        arr = arr.filter { item in
            if item.pinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= maxUnpinned
        }
        items = arr
    }

    /// Ordered for display: pinned first (newest-first), then recent.
    func display(filter q: String) -> [ClipItem] {
        let ql = q.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = ql.isEmpty ? items : items.filter { $0.text.lowercased().contains(ql) }
        return filtered.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.date > b.date
        }
    }

    func copyBack(_ item: ClipItem) {
        ignoreNext = true
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(item.text, forType: .string)
        lastChangeCount = pb.changeCount
    }
    func togglePin(_ id: String) {
        var arr = items
        if let i = arr.firstIndex(where: { $0.id == id }) { arr[i].pinned.toggle(); items = arr }
    }
    func delete(_ id: String) { items = items.filter { $0.id != id } }
    func clearUnpinned() { items = items.filter { $0.pinned } }
}

/// A clipboard-history panel that drops from the notch: search field + a
/// scrollable list of clips (click to copy back, 📌 pin, ✕ delete).
final class ClipboardPanel: NSPanel, NSSearchFieldDelegate {
    private weak var listStack: NSStackView?
    private weak var searchField: NSSearchField?
    private var query = ""

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    convenience init(screen: NSScreen) {
        let bez = max(screen.safeAreaInsets.top, 24)
        let w: CGFloat = 440, h: CGFloat = 460
        let f = NSRect(x: (screen.frame.midX - w / 2).rounded(),
                       y: screen.frame.maxY - h, width: w, height: h)
        self.init(contentRect: f, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        level                = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        isReleasedWhenClosed = false
        backgroundColor      = .clear
        isOpaque             = false
        hasShadow            = true
        isMovable            = false
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        buildUI(bezelH: bez)
        ClipboardStore.shared.onChange = { [weak self] in self?.reload() }
    }

    private func buildUI(bezelH: CGFloat) {
        guard let cv = contentView else { return }
        cv.wantsLayer = true
        let bgv = NSVisualEffectView()
        bgv.material = .hudWindow; bgv.blendingMode = .behindWindow; bgv.state = .active
        bgv.wantsLayer = true
        bgv.layer?.cornerRadius = 16; bgv.layer?.cornerCurve = .continuous
        bgv.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        bgv.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(bgv)

        let title = NSTextField(labelWithString: "Clipboard")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let search = NSSearchField()
        search.placeholderString = "Search clips…"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        searchField = search

        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedStackView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack); scroll.documentView = doc
        listStack = stack

        bgv.addSubview(title); bgv.addSubview(search); bgv.addSubview(scroll)
        NSLayoutConstraint.activate([
            bgv.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            bgv.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            bgv.topAnchor.constraint(equalTo: cv.topAnchor),
            bgv.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            title.topAnchor.constraint(equalTo: bgv.topAnchor, constant: bezelH + 8),
            title.leadingAnchor.constraint(equalTo: bgv.leadingAnchor, constant: 14),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: bgv.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: bgv.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: bgv.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bgv.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bgv.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        query = searchField?.stringValue ?? ""
        reload()
    }

    private func reload() {
        guard let stack = listStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let clips = ClipboardStore.shared.display(filter: query)
        if clips.isEmpty {
            let empty = NSTextField(labelWithString: query.isEmpty ? "No clips yet — copy something." : "No matches.")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        for clip in clips {
            let row = ClipRowView(clip: clip,
                onCopy:   { [weak self] in ClipboardStore.shared.copyBack(clip); self?.dismissPanel(); self?.onPaste?() },
                onPin:    { ClipboardStore.shared.togglePin(clip.id) },
                onDelete: { ClipboardStore.shared.delete(clip.id) })
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
    }

    var onClose: (() -> Void)?
    var onPaste: (() -> Void)?
    private var globalMon: Any?
    private var localMon: Any?

    func toggle(on screen: NSScreen?) {
        if isVisible { dismissPanel(); return }
        reload()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.makeFirstResponder(self?.searchField) }
        installDismissMonitors()
    }

    /// Dismiss on Escape or any click outside the panel (this app or another).
    func dismissPanel() {
        removeDismissMonitors()
        orderOut(nil)
        onClose?()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel()
        }
        localMon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.dismissPanel(); return nil }   // Escape
                return e
            }
            if e.window !== self { self.dismissPanel() }                 // click in another window → dismiss
            return e
        }
    }
    private func removeDismissMonitors() {
        if let g = globalMon { NSEvent.removeMonitor(g); globalMon = nil }
        if let l = localMon  { NSEvent.removeMonitor(l);  localMon = nil }
    }
}

/// One clipboard row: preview text (click to copy back) + pin/delete on hover.
final class ClipRowView: NSView {
    private let onCopy: () -> Void
    private let onPin: () -> Void
    private let onDelete: () -> Void
    private let pinBtn = NSButton()
    private let delBtn = NSButton()

    init(clip: ClipItem, onCopy: @escaping () -> Void, onPin: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.onCopy = onCopy; self.onPin = onPin; self.onDelete = onDelete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.cornerRadius = 7

        let preview = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let label = NSTextField(labelWithString: String(preview.prefix(140)))
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinBtn.isBordered = false; pinBtn.title = clip.pinned ? "📌" : "📍"
        pinBtn.font = .systemFont(ofSize: 12)
        pinBtn.target = self; pinBtn.action = #selector(pinTapped)
        pinBtn.alphaValue = clip.pinned ? 1 : 0.35
        pinBtn.translatesAutoresizingMaskIntoConstraints = false
        delBtn.isBordered = false; delBtn.title = "✕"
        delBtn.font = .systemFont(ofSize: 11); delBtn.contentTintColor = .secondaryLabelColor
        delBtn.target = self; delBtn.action = #selector(delTapped)
        delBtn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label); addSubview(pinBtn); addSubview(delBtn)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pinBtn.leadingAnchor, constant: -6),
            pinBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -2),
            pinBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinBtn.widthAnchor.constraint(equalToConstant: 22),
            delBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            delBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 18),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func rowClicked() { onCopy() }
    @objc private func pinTapped()  { onPin() }
    @objc private func delTapped()  { onDelete() }
}

// MARK: - Display management
//
// Phase 1 (this file): software brightness via the PUBLIC gamma-table API — dims
// ANY display (built-in, or a cheap external with no DDC) with no permission and
// no private API. Later phases layer on DDC/CI hardware brightness (private
// IOAVService), display arrangement, presets (unified with Workflows), and HiDPI.
// All display code is clean-room from the VESA DDC/CI spec + public references,
// never copied from another project's source.

struct ManagedDisplay: Equatable {
    let id: CGDirectDisplayID
    let uuid: String          // stable across reconnects; used as the persistence key
    let name: String
    let isBuiltin: Bool
}

/// A saved display layout: per-display position, resolution, and mirror state,
/// keyed by stable UUID so it re-applies to the same physical monitors.
struct DisplayLayout: Codable {
    let name: String
    let entries: [Entry]
    struct Entry: Codable {
        let uuid: String
        let originX: Double
        let originY: Double
        let modeID: Int32?
        let mirroredToMain: Bool
    }
}

/// Per-display image adjustments. Neutral defaults (0.5 = no change) except
/// brightness (1.0 = full). Applied as a single per-channel gamma LUT.
struct DisplayAdjustments: Codable, Equatable {
    var brightness:  Double = 1.0    // 0.15…1.0
    var contrast:    Double = 0.5    // 0 low … 0.5 neutral … 1 high
    var temperature: Double = 0.5    // 0 warm … 0.5 neutral … 1 cool
    var gamma:       Double = 0.5    // 0 dark mids … 0.5 neutral … 1 bright mids
    var invert:      Bool   = false
}

/// DDC/CI hardware brightness (and other VCP features) for EXTERNAL monitors.
///
/// Clean-room from the VESA DDC/CI spec + public write-ups (BetterDummy /
/// MonitorControl / alinpanaitiu "DDC on M1"). On Apple Silicon the only working
/// transport is Apple's private `IOAVService` (no public header ships, and the
/// public IOFramebuffer I2C path is a silent no-op on M-series). Those three C
/// symbols are bound at runtime via dlsym — no bridging header, and if a future
/// macOS drops them the whole feature degrades cleanly (callers fall back to the
/// gamma dimmer). Private-API use bars the Mac App Store, which Axe is not on.
final class DDCController {

    // ── Runtime binding of the private IOAVService C functions ───────
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias RWFn     = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle = dlopen(nil, RTLD_NOW)   // IOKit is already loaded via AppKit
    private static func bind<T>(_ name: String, _ t: T.Type) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let createAV: CreateFn? = bind("IOAVServiceCreateWithService", CreateFn.self)
    private static let readAV:   RWFn?     = bind("IOAVServiceReadI2C",  RWFn.self)
    private static let writeAV:  RWFn?     = bind("IOAVServiceWriteI2C", RWFn.self)

    /// True only if the private transport resolved on this OS.
    static var isAvailable: Bool { createAV != nil && readAV != nil && writeAV != nil }

    private let brightnessVCP: UInt8 = 0x10
    private let contrastVCP:   UInt8 = 0x12
    private let ddcAddr:  UInt32 = 0x37   // DDC/CI I2C device address
    private let ddcOffset: UInt32 = 0x51  // sub-address IOAVService writes at

    private var serviceCache: [CGDirectDisplayID: CFTypeRef] = [:]
    private var maxCache:     [CGDirectDisplayID: UInt16] = [:]

    func invalidateCache() { serviceCache.removeAll(); maxCache.removeAll() }

    // ── IOAVService ↔ display matching ───────────────────────────────
    private func avService(for displayID: CGDirectDisplayID) -> CFTypeRef? {
        if let cached = serviceCache[displayID] { return cached }
        guard DDCController.isAvailable, let create = DDCController.createAV else { return nil }

        let externals = activeExternalDisplayIDs()
        guard !externals.isEmpty else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var mapped = Set<CGDirectDisplayID>()
        var firstExternalService: CFTypeRef?
        var result: CFTypeRef?

        var node = IOIteratorNext(iterator)
        while node != IO_OBJECT_NULL {
            defer { IOObjectRelease(node); node = IOIteratorNext(iterator) }

            // Skip nodes explicitly marked non-External (some drivers omit the key).
            if let loc = IORegistryEntryCreateCFProperty(node, "Location" as CFString,
                                                         kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? String, loc != "External" {
                continue
            }
            guard let unmanaged = create(kCFAllocatorDefault, node) else { continue }
            let service = unmanaged.takeRetainedValue()
            if firstExternalService == nil { firstExternalService = service }

            // Preferred: walk the IORegistry parent chain for DisplayVendorID/ProductID
            // and match against a CoreGraphics external display.
            if let matched = matchByVendorProduct(node: node, candidates: externals, exclude: mapped) {
                mapped.insert(matched)
                serviceCache[matched] = service
                if matched == displayID { result = service }
            }
        }

        // Fallback: exactly one external display → pair it with the first external
        // AVService found (single-monitor is the common case).
        if result == nil, externals.count == 1, externals.first == displayID,
           let only = firstExternalService {
            serviceCache[displayID] = only
            result = only
        }
        return result
    }

    private func activeExternalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private func matchByVendorProduct(node: io_service_t,
                                      candidates: [CGDirectDisplayID],
                                      exclude: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        var chain: [io_service_t] = []
        var current = node
        IOObjectRetain(current); chain.append(current)
        for _ in 0..<7 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != IO_OBJECT_NULL else { break }
            chain.append(parent); current = parent
        }
        defer { chain.forEach { IOObjectRelease($0) } }

        for n in chain {
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(n, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }
            func u32(_ any: Any?) -> UInt32? {
                if let v = any as? UInt32 { return v }
                if let v = any as? Int { return UInt32(truncatingIfNeeded: v) }
                return nil
            }
            guard let vendor = u32(props["DisplayVendorID"]),
                  let product = u32(props["DisplayProductID"]) else { continue }
            for id in candidates where !exclude.contains(id) {
                if CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == product { return id }
            }
        }
        return nil
    }

    // ── VCP read / write (DDC/CI packet framing) ─────────────────────
    @discardableResult
    private func writeVCP(_ vcp: UInt8, value: UInt16, service: CFTypeRef) -> Bool {
        guard let write = DDCController.writeAV else { return false }
        let hi = UInt8((value >> 8) & 0xFF), lo = UInt8(value & 0xFF)
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, vcp, hi, lo]
        for b in payload { checksum ^= b }
        var buf = payload + [checksum]
        let ret = buf.withUnsafeMutableBytes { raw in
            write(service, ddcAddr, ddcOffset, raw.baseAddress!, UInt32(raw.count))
        }
        return ret == kIOReturnSuccess
    }

    private func readVCP(_ vcp: UInt8, service: CFTypeRef) -> (current: UInt16, max: UInt16)? {
        guard let write = DDCController.writeAV, let read = DDCController.readAV else { return nil }
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x82, 0x01, vcp]
        for b in payload { checksum ^= b }
        var req = payload + [checksum]
        let wret = req.withUnsafeMutableBytes { raw in
            write(service, ddcAddr, ddcOffset, raw.baseAddress!, UInt32(raw.count))
        }
        guard wret == kIOReturnSuccess else { return nil }
        Thread.sleep(forTimeInterval: 0.04)   // per DDC/CI spec, let the display prepare its reply
        var reply = [UInt8](repeating: 0, count: 12)
        let rret = reply.withUnsafeMutableBytes { raw in
            read(service, ddcAddr, ddcOffset, raw.baseAddress!, UInt32(raw.count))
        }
        guard rret == kIOReturnSuccess, reply.count >= 10 else { return nil }
        let maxV = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let curV = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        // A garbage/echoed reply (max 0) means the monitor doesn't really speak DDC here.
        guard maxV > 0 else { return nil }
        return (curV, maxV)
    }

    // ── Public API (call OFF the main thread — reads sleep ~40ms) ─────
    /// Returns true if this display responds to a DDC brightness read.
    func supportsBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        guard let svc = avService(for: displayID) else { return false }
        if let r = readVCP(brightnessVCP, service: svc) { maxCache[displayID] = r.max; return true }
        return false
    }

    /// Current hardware brightness as 0…1, or nil if unavailable.
    func brightness(_ displayID: CGDirectDisplayID) -> Double? {
        guard let svc = avService(for: displayID), let r = readVCP(brightnessVCP, service: svc),
              r.max > 0 else { return nil }
        maxCache[displayID] = r.max
        return Double(r.current) / Double(r.max)
    }

    /// Set hardware brightness (0…1). Returns false if DDC isn't available.
    @discardableResult
    func setBrightness(_ level: Double, for displayID: CGDirectDisplayID) -> Bool {
        guard let svc = avService(for: displayID) else { return false }
        let maxV = maxCache[displayID] ?? readVCP(brightnessVCP, service: svc)?.max ?? 100
        maxCache[displayID] = maxV
        let v = UInt16((max(0, min(1, level)) * Double(maxV)).rounded())
        return writeVCP(brightnessVCP, value: v, service: svc)
    }
}

final class DisplayManager {
    static let shared = DisplayManager()
    private init() {}

    private let d = UserDefaults.standard
    private let adjustmentsKey = "displayAdjustments"          // [uuid: DisplayAdjustments]
    private let legacyBrightnessKey = "displaySoftwareBrightness"  // [uuid: Double] (migrated)
    /// Never let the user drive a screen fully black.
    static let minBrightness: Double = 0.15

    // ── DDC/CI hardware brightness (external monitors) ───────────────
    let ddc = DDCController()
    private let ddcQueue = DispatchQueue(label: "com.emerytech.axe.ddc")   // serial; DDC I2C is slow
    private var ddcSupported: [String: Bool] = [:]   // uuid → responds to DDC brightness (main-thread only)
    private var ddcWriteItem: [CGDirectDisplayID: DispatchWorkItem] = [:]  // debounce coalescing

    // ── Enumeration ──────────────────────────────────────────────
    func currentDisplays() -> [ManagedDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            ManagedDisplay(id: id, uuid: DisplayManager.uuid(for: id),
                           name: DisplayManager.name(for: id),
                           isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// Stable per-display key (survives reconnect / display-ID reshuffles).
    static func uuid(for id: CGDirectDisplayID) -> String {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return "display-\(id)"
        }
        return CFUUIDCreateString(nil, ref) as String
    }

    /// Localized display name via the matching NSScreen (CGDirectDisplayID ↔ NSScreenNumber).
    static func name(for id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for s in NSScreen.screens where (s.deviceDescription[key] as? NSNumber)?.uint32Value == id {
            return s.localizedName
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    // ── Image adjustments (public per-channel gamma LUT) ─────────────
    private var adjustmentsMap: [String: DisplayAdjustments] {
        get {
            if let data = d.data(forKey: adjustmentsKey),
               let m = try? JSONDecoder().decode([String: DisplayAdjustments].self, from: data) {
                return m
            }
            // Migrate legacy per-uuid brightness (pre-adjustments builds).
            if let old = d.dictionary(forKey: legacyBrightnessKey) as? [String: Double] {
                return old.mapValues { DisplayAdjustments(brightness: $0) }
            }
            return [:]
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: adjustmentsKey) }
    }

    func adjustments(forUUID uuid: String) -> DisplayAdjustments { adjustmentsMap[uuid] ?? DisplayAdjustments() }
    func softwareBrightness(forUUID uuid: String) -> Double { adjustments(forUUID: uuid).brightness }

    /// Persist a display's adjustments and apply them: DDC backlight for hardware
    /// displays (debounced), plus a per-channel gamma LUT for temperature/contrast/
    /// gamma/invert (and for software brightness).
    func setAdjustments(_ adj: DisplayAdjustments, for display: ManagedDisplay) {
        var m = adjustmentsMap; m[display.uuid] = adj; adjustmentsMap = m
        let hw = usesHardwareBrightness(display)
        if hw {
            let level = max(0, min(1, adj.brightness))
            ddcWriteItem[display.id]?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.ddc.setBrightness(level, for: display.id) }
            ddcWriteItem[display.id] = item
            ddcQueue.asyncAfter(deadline: .now() + 0.02, execute: item)
        }
        applyLUT(adj, to: display.id, includeBrightness: !hw)
    }

    /// Mutate one display's adjustments in place and re-apply.
    func updateAdjustment(for display: ManagedDisplay, _ mutate: (inout DisplayAdjustments) -> Void) {
        var adj = adjustments(forUUID: display.uuid)
        mutate(&adj)
        setAdjustments(adj, for: display)
    }

    private func applyLUT(_ adj: DisplayAdjustments, to id: CGDirectDisplayID, includeBrightness: Bool) {
        let n = 256
        let bright   = includeBrightness ? max(DisplayManager.minBrightness, adj.brightness) : 1.0
        let gammaExp = pow(2.0, (0.5 - adj.gamma) * 2.0)   // 0.5 → 1.0
        let contrast = 0.5 + adj.contrast                  // 0.5 → 1.0
        // Temperature: warm (<0.5) trims blue, cool (>0.5) trims red.
        let rScale = adj.temperature > 0.5 ? (1.5 - adj.temperature) : 1.0
        let bScale = adj.temperature < 0.5 ? (0.5 + adj.temperature) : 1.0
        var r = [CGGammaValue](repeating: 0, count: n)
        var g = [CGGammaValue](repeating: 0, count: n)
        var b = [CGGammaValue](repeating: 0, count: n)
        for i in 0..<n {
            var v = Double(i) / Double(n - 1)
            v = pow(v, gammaExp)
            v = (v - 0.5) * contrast + 0.5
            v = min(1, max(0, v))
            if adj.invert { v = 1 - v }
            r[i] = CGGammaValue(v * bright * rScale)
            g[i] = CGGammaValue(v * bright)
            b[i] = CGGammaValue(v * bright * bScale)
        }
        CGSetDisplayTransferByTable(id, UInt32(n), r, g, b)
    }

    // ── Hardware / software routing ──────────────────────────────────
    /// Whether a display should use hardware (DDC) brightness: external + probed OK.
    func usesHardwareBrightness(_ display: ManagedDisplay) -> Bool {
        !display.isBuiltin && (ddcSupported[display.uuid] ?? false)
    }

    /// True once we know a display's DDC status (built-ins are known immediately).
    func isProbed(_ display: ManagedDisplay) -> Bool {
        display.isBuiltin || ddcSupported[display.uuid] != nil
    }

    /// Probe DDC support for not-yet-probed external displays off the main thread,
    /// then call `completion` on main. Immediate no-op when nothing needs probing.
    func probeDDC(_ displays: [ManagedDisplay], completion: @escaping () -> Void) {
        let todo = displays.filter { !$0.isBuiltin && ddcSupported[$0.uuid] == nil }
        guard DDCController.isAvailable, !todo.isEmpty else { completion(); return }
        ddcQueue.async { [weak self] in
            guard let self else { return }
            let results = todo.map { ($0.uuid, self.ddc.supportsBrightness($0.id)) }
            DispatchQueue.main.async {
                for (uuid, ok) in results { self.ddcSupported[uuid] = ok }
                completion()
            }
        }
    }

    /// Read a display's current brightness (0…1) for the UI. Hardware read is async.
    func readBrightness(for display: ManagedDisplay, completion: @escaping (Double) -> Void) {
        if usesHardwareBrightness(display) {
            ddcQueue.async { [weak self] in
                let v = self?.ddc.brightness(display.id) ?? 1.0
                DispatchQueue.main.async { completion(v) }
            }
        } else {
            completion(softwareBrightness(forUUID: display.uuid))
        }
    }

    /// Unified brightness setter for the UI — updates just the brightness field of
    /// the display's adjustments (DDC for supported externals, gamma otherwise).
    func setBrightness(_ v: Double, for display: ManagedDisplay) {
        updateAdjustment(for: display) { $0.brightness = max(0, min(1, v)) }
    }

    // ── Resolution / display modes (public CoreGraphics) ─────────────
    struct ModeOption { let mode: CGDisplayMode; let label: String; let isHiDPI: Bool }

    /// All usable resolutions for a display, incl. hidden/HiDPI modes, de-duplicated
    /// by point size + HiDPI and sorted largest-first (HiDPI preferred within a size).
    func availableModes(for id: CGDirectDisplayID) -> [ModeOption] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return [] }
        var seen = Set<String>()
        var out: [ModeOption] = []
        for m in modes where m.isUsableForDesktopGUI() {
            let hidpi = m.pixelWidth > m.width
            let key = "\(m.width)x\(m.height)-\(hidpi)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(ModeOption(mode: m,
                                  label: "\(m.width) × \(m.height)" + (hidpi ? "  · HiDPI" : ""),
                                  isHiDPI: hidpi))
        }
        out.sort { a, b in
            let aa = a.mode.width * a.mode.height, bb = b.mode.width * b.mode.height
            if aa != bb { return aa > bb }
            return a.isHiDPI && !b.isHiDPI
        }
        return out
    }

    func currentModeID(for id: CGDirectDisplayID) -> Int32? { CGDisplayCopyDisplayMode(id)?.ioDisplayModeID }

    /// Switch a display to a mode inside a config transaction. Applied permanently.
    @discardableResult
    func setMode(_ mode: CGDisplayMode, for id: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        guard CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(cfg); return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    // ── Arrangement (public CoreGraphics) ────────────────────────────
    func isMain(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsMain(id) != 0 }

    /// Make a display the main one by shifting every display so this one lands at
    /// the (0,0) global origin (which macOS treats as the main display).
    @discardableResult
    func setAsMain(_ id: CGDirectDisplayID) -> Bool {
        let b = CGDisplayBounds(id)
        guard b.origin.x != 0 || b.origin.y != 0 else { return true }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        for disp in currentDisplays() {
            let db = CGDisplayBounds(disp.id)
            CGConfigureDisplayOrigin(cfg, disp.id,
                                     Int32(db.origin.x - b.origin.x),
                                     Int32(db.origin.y - b.origin.y))
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    func isMirroring() -> Bool {
        let main = CGMainDisplayID()
        return currentDisplays().contains { $0.id != main && CGDisplayIsInMirrorSet($0.id) != 0 }
    }

    /// Mirror all secondary displays onto the main display, or stop mirroring.
    @discardableResult
    func setMirroring(_ on: Bool) -> Bool {
        let displays = currentDisplays()
        guard displays.count >= 2 else { return false }
        let main = CGMainDisplayID()
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        for disp in displays where disp.id != main {
            CGConfigureDisplayMirrorOfDisplay(cfg, disp.id, on ? main : kCGNullDirectDisplay)
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    // ── Layout presets ───────────────────────────────────────────────
    private let layoutsKey = "displayLayouts"
    var layouts: [DisplayLayout] {
        get {
            guard let data = d.data(forKey: layoutsKey),
                  let arr = try? JSONDecoder().decode([DisplayLayout].self, from: data) else { return [] }
            return arr
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: layoutsKey) }
    }

    func captureLayout(name: String) -> DisplayLayout {
        let main = CGMainDisplayID()
        let entries = currentDisplays().map { disp -> DisplayLayout.Entry in
            let b = CGDisplayBounds(disp.id)
            return DisplayLayout.Entry(uuid: disp.uuid,
                                       originX: Double(b.origin.x), originY: Double(b.origin.y),
                                       modeID: currentModeID(for: disp.id),
                                       mirroredToMain: disp.id != main && CGDisplayIsInMirrorSet(disp.id) != 0)
        }
        return DisplayLayout(name: name, entries: entries)
    }

    func saveCurrentLayout(name: String) {
        var all = layouts
        all.removeAll { $0.name == name }   // overwrite same-named
        all.append(captureLayout(name: name))
        layouts = all
    }

    func deleteLayout(name: String) { layouts = layouts.filter { $0.name != name } }

    /// Re-apply a saved layout to the currently-connected displays (matched by UUID).
    @discardableResult
    func applyLayout(_ layout: DisplayLayout) -> Bool {
        let byUUID = Dictionary(currentDisplays().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        for e in layout.entries {
            guard let disp = byUUID[e.uuid] else { continue }
            if let modeID = e.modeID,
               let modes = CGDisplayCopyAllDisplayModes(disp.id, opts) as? [CGDisplayMode],
               let m = modes.first(where: { $0.ioDisplayModeID == modeID }) {
                CGConfigureDisplayWithDisplayMode(cfg, disp.id, m, nil)
            }
            CGConfigureDisplayMirrorOfDisplay(cfg, disp.id,
                e.mirroredToMain ? CGMainDisplayID() : kCGNullDirectDisplay)
            CGConfigureDisplayOrigin(cfg, disp.id, Int32(e.originX), Int32(e.originY))
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    /// Re-apply every persisted adjustment. macOS silently drops gamma tables on
    /// wake, display reconfiguration, and when another app touches the LUT.
    func reapplyAll() {
        let map = adjustmentsMap
        guard !map.isEmpty else { return }
        for disp in currentDisplays() {
            guard let adj = map[disp.uuid], adj != DisplayAdjustments() else { continue }
            applyLUT(adj, to: disp.id, includeBrightness: !usesHardwareBrightness(disp))
        }
    }

    /// Restore hardware color/gamma on all displays — called on quit and on
    /// "Reset to Defaults" so a dim screen never outlives Axe managing it.
    func restoreAll() { CGDisplayRestoreColorSyncSettings() }

    /// Clear every persisted adjustment and restore full brightness/color
    /// (used by Reset to Defaults).
    func resetSoftwareBrightness() {
        d.removeObject(forKey: adjustmentsKey)
        d.removeObject(forKey: legacyBrightnessKey)
        restoreAll()
    }
}

/// A per-display brightness slider row (icon + name + slider). Auto-layout
/// complete so it drops into the overlay's Displays panel stack. `labelColor`
/// lets the caller tint text for the dark notch background.
final class DisplayBrightnessRow: NSView {
    private let slider = NSSlider()
    private let display: ManagedDisplay

    init(display: ManagedDisplay, labelColor: NSColor = .labelColor) {
        self.display = display
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: display.isBuiltin ? "laptopcomputer" : "display",
                             accessibilityDescription: nil)
        icon.contentTintColor = labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: display.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = labelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sun = NSImageView()
        sun.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        sun.contentTintColor = labelColor.withAlphaComponent(0.6)
        sun.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = DisplayManager.minBrightness
        slider.maxValue = 1.0
        slider.doubleValue = DisplayManager.shared.softwareBrightness(forUUID: display.uuid)
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel("\(display.name) brightness")
        // The true current level (a DDC hardware read is async) — update when it lands.
        DisplayManager.shared.readBrightness(for: display) { [weak slider] v in
            slider?.doubleValue = max(DisplayManager.minBrightness, min(1.0, v))
        }

        addSubview(icon); addSubview(name); addSubview(sun); addSubview(slider)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            sun.leadingAnchor.constraint(equalTo: leadingAnchor),
            sun.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            sun.widthAnchor.constraint(equalToConstant: 14),
            slider.leadingAnchor.constraint(equalTo: sun.trailingAnchor, constant: 7),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 7),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        DisplayManager.shared.setBrightness(slider.doubleValue, for: display)
    }
}

/// A resolution picker row (label + popup) for one display, listing usable modes
/// incl. hidden HiDPI ones. Selecting a row switches the display's resolution.
final class DisplayResolutionRow: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayID: CGDirectDisplayID
    private var options: [DisplayManager.ModeOption] = []

    init(display: ManagedDisplay, labelColor: NSColor) {
        self.displayID = display.id
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Resolution")
        label.font = .systemFont(ofSize: 11)
        label.textColor = labelColor.withAlphaComponent(0.7)
        label.translatesAutoresizingMaskIntoConstraints = false

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.target = self
        popup.action = #selector(changed)
        popup.setAccessibilityLabel("\(display.name) resolution")

        options = DisplayManager.shared.availableModes(for: display.id)
        let currentID = DisplayManager.shared.currentModeID(for: display.id)
        popup.addItems(withTitles: options.map { $0.label })
        if let idx = options.firstIndex(where: { $0.mode.ioDisplayModeID == currentID }) {
            popup.selectItem(at: idx)
        }
        popup.isEnabled = options.count > 1

        addSubview(label); addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: popup.topAnchor, constant: -3),
            bottomAnchor.constraint(equalTo: popup.bottomAnchor, constant: 3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < options.count else { return }
        DisplayManager.shared.setMode(options[idx].mode, for: displayID)
    }
}

/// A compact labeled slider (icon + caption + slider) that reports live changes
/// via a stored closure. Used for the per-display image adjustments.
final class LabeledSliderRow: NSView {
    private let slider = NSSlider()
    private let onChange: (Double) -> Void

    init(title: String, symbol: String, value: Double, minV: Double, maxV: Double,
         labelColor: NSColor, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        icon.contentTintColor = labelColor.withAlphaComponent(0.7)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = labelColor.withAlphaComponent(0.75)
        caption.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = minV; slider.maxValue = maxV
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel(title)

        addSubview(icon); addSubview(caption); addSubview(slider)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            caption.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 74),
            slider.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange(slider.doubleValue) }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate,
                          NSTableViewDataSource, NSTableViewDelegate,
                          NSTextFieldDelegate, NSMenuDelegate {

    // Status bar
    var statusItem: NSStatusItem!
    private weak var openStatusMenu: NSMenu?
    var isUpdating = false   // set before NSApp.terminate() in update flow; skips quit confirmation

    // Overlay — spotlight mode
    var panel:          NSPanel?
    // Overlay — popover mode
    var popover:        NSPopover?
    var popoverVC:      NSViewController?
    var popoverBGView:  NSView?
    // Tracks which style was used to build the current overlay (detects setting changes)
    var lastBuiltStyle: UIStyle?

    var searchField: NSTextField?
    var tableView:   NSTableView?
    var emptyView:   EmptyStateView?
    var hintLabel:   NSTextField?

    // ── Sessions panel (shown inside the overlay on demand) ────────
    var isShowingSessions  = false
    var isShowingDisplays  = false             // "Displays" tab active in the overlay
    var overlayTabStrip:   NSSegmentedControl?  // "Axe | Workflows | Displays" tab strip
    private let choppingBlockNames = [
        "Chopping Block", "The Gallows", "Death Row", "The Guillotine",
        "The Firing Squad", "Last Rites", "The Axe", "The Noose",
        "Execution Chamber", "The Chair", "Russian Roulette", "The Scaffold",
        "The Plank", "The Dungeon", "Final Destination", "The Pit",
        "The Condemned", "End of the Line", "The Drop", "Lights Out",
        "The Gallows Hill", "Dead Man Walking",
    ]
    var appListContainer:  NSView?         // the NSScrollView holding the app table
    var sessionsPanelView: NSView?         // replaces the table area in sessions mode
    var sessionsListStack: NSStackView?    // inner stack rebuilt on each show
    var displaysPanelView: NSView?         // replaces the table area in displays mode
    var displaysListStack: NSStackView?    // inner stack rebuilt on each show
    var displayActionBoxes: [ActionBox] = []   // retains closure targets for display buttons

    // Data
    var allApps:          [AppEntry]  = []
    var filtered:         [AppEntry]  = []
    var displayRows:      [TableRow]  = []
    var checkedPIDs:      Set<pid_t>  = []
    var sortByMemory:     Bool        = false
    var cpuRefreshTimer:  Timer?
    var colRAMBarView:    RAMBarView?

    // Inline settings panel (mirrors sessions panel pattern)
    var isShowingSettings   = false
    var settingsPanelView:  NSView?
    var overlaySettingsBtn: NSButton?
    var colHeaderView:      NSView?

    // Expansion when settings panel opens — stored so we can restore on close
    var listScrollHeightConstraint: NSLayoutConstraint?
    var baseListScrollHeight: CGFloat = 0
    var panelInnerHeightConstraint: NSLayoutConstraint?   // notch-only
    var basePanelInnerHeight: CGFloat = 0                 // notch-only
    // Anchored top-Y for the notch panel; set by showNotch() so resizeNotchPanel()
    // always grows/shrinks from the same fixed top position.
    var notchPanelTopY: CGFloat = 0
    var sortButton:       NSButton?
    var axeCheckedButton: NSButton?
    var halfAxeButton:    NSButton?
    /// PIDs of apps we've issued terminate() to that haven't fully quit yet.
    /// Used to suppress panelResignedKey during the termination window-cleanup cycle.
    var pendingKillPIDs:  Set<pid_t> = []

    /// Notch mode paints on pure black, so the standard `.tertiaryLabelColor` /
    /// `.quaternaryLabelColor` system colors (designed for translucent
    /// materials) become hard to read. Slightly brighten them there — but
    /// kept subdued so the chrome stays subordinate to the app list itself.
    private var dimIconColor: NSColor {
        effectiveUIStyle == .notch
            ? NSColor.white.withAlphaComponent(0.55)
            : .tertiaryLabelColor
    }
    private var dimHintColor: NSColor {
        effectiveUIStyle == .notch
            ? NSColor.white.withAlphaComponent(0.40)
            : .quaternaryLabelColor
    }

    // Rotating kill-button phrases — picked randomly on first checkbox tick,
    // then cycled automatically every 10 s while apps remain selected.
    var currentKillPhrase: String = ""
    var phraseIndex:       Int    = 0
    var phraseTimer:       Timer?
    var usageTimer:        Timer?

    // Notch indicator — persistent mini-panel shown when the overlay is closed
    private var notchIndicator: NotchIndicatorPanel?
    private var notchHub: NotchHubPanel?
    private var clipboardPanel: ClipboardPanel?
    private var notchHoverMonitor: Any?

    // New-Space restore — set when user taps "Restore on New Space"; cleared on space change
    var pendingSpaceRestoreSession: AppSession?
    var spaceRestoreHUD: SpaceRestoreHUD?
    var switchHUD: SwitchHUD?
    // Drift indicator state — populated by buildDriftStrip, consumed by catch-up / tidy actions
    private var driftMissingApps: [SavedApp]             = []
    private var driftExtraApps:   [NSRunningApplication] = []
    private weak var inlineNameField: NSTextField?
    private weak var sessionsSearchField: NSSearchField?
    private var sessionsFilterQuery: String = ""
    private var expandedSessionID: UUID?
    private var condemningLabel: String = "Axe"
    var updateWindow: UpdateWindow?
    var selfUpdater:  SelfUpdater?
    weak var demoRowView: NSView?     // sample row in Settings for previewing animations
    var pauseReopenTimer:   Timer?
    var pauseReopenSession: AppSession?
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
        "I'll be your Huckleberry",                 // Tombstone — Doc Holliday
        "Rip and Tear",                             // DOOM — the Slayer's creed
        "You Died",                                 // Dark Souls / Elden Ring
        "It's super effective!",                    // Pokémon — the killing blow
        "Fus Ro Dah!",                              // Skyrim — force pushes you out
        "Headshot!",                                // Counter-Strike / every FPS ever
        "Omae wa mou shindeiru",                    // Fist of the North Star / gaming meme
        "Get dunked on",                            // Undertale — Sans
        "No respawns",                              // battle royale finality
        "Alt+F4",                                   // the original force-quit
        "Git Gud",                                  // Dark Souls community wisdom
        "Press F to pay respects",                  // CoD: Advanced Warfare meme
        "Leeeeroy Jenkins!",                        // WoW — chaos incarnate
        "By fire be purged",                        // Warcraft — Scarlet Crusade
        "Critical hit!",                            // every RPG ever
        "Permanently uninstalled",                  // meta
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
    var clipboardHotKeyRef: EventHotKeyRef?
    private weak var clipboardPrevApp: NSRunningApplication?   // app to auto-paste back into

    // Settings / Onboarding / Nudge
    let settingsWindow   = SettingsWindow()
    let onboardingWindow = OnboardingWindow()
    let nudgeWindow      = NudgeWindow()
    private var nudgeTimer: Timer?
    private var scheduleTimer: Timer?

    // MARK: Launch

    /// Confirm before quitting Axe. Both the "Quit Axe" menu item and ⌘Q go
    /// through here. Returns `.terminateCancel` if the user backs out, so the
    /// app stays alive.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isUpdating { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)
        let prompt = quitConfirmPrompts.randomElement() ?? quitConfirmPrompts[0]
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = prompt.title
        alert.informativeText = prompt.body
        alert.addButton(withTitle: prompt.cancel)           // .alertFirstButtonReturn  (default — Return)
        let quitBtn = alert.addButton(withTitle: prompt.quit) // .alertSecondButtonReturn
        quitBtn.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKey()
        WorkflowHotkeyManager.shared.install()
        WorkflowHotkeyManager.shared.refresh()
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
        // Migrate legacy autoRestoreLastSession → autoLaunchOnLogin on first upgrade
        if AppSettings.autoRestoreLastSession {
            var s = SessionManager.shared.all
            if !s.isEmpty && !s.contains(where: { $0.autoLaunchOnLogin }) {
                s[0].autoLaunchOnLogin = true
                SessionManager.shared.all = s
            }
            AppSettings.autoRestoreLastSession = false
        }
        // Restore all per-workflow autoLaunchOnLogin sessions
        let autoLaunch = SessionManager.shared.all.filter { $0.autoLaunchOnLogin }
        if !autoLaunch.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                autoLaunch.forEach { SessionManager.shared.restore($0) }
            }
        }

        // Support nudge — show every 6 hours, skip first 24 h and if already licensed
        _ = AppSettings.firstLaunchDate   // ensures first-launch date is recorded
        startNudgeTimer()
        startUsageTimer()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil, queue: .main) { _ in
            PermissionManager.shared.refreshAccessibilityState()
        }

        // Create the notch indicator on launch if the setting is enabled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.syncNotchIndicator()
        }

        startScheduleTimer()

        // Re-apply any persisted per-display software brightness (gamma) on launch.
        DisplayManager.shared.reapplyAll()

        // Begin capturing clipboard history for the notch hub's clipboard module.
        ClipboardStore.shared.start()

        // Notch indicator hardening: re-anchor after display changes, sleep/wake
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Silent background update check
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2) {
            self.checkForUpdates(userInitiated: false)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        // Don't leave a screen dimmed by a gamma table once Axe is gone — restore
        // hardware color on quit. Persisted values are re-applied on next launch.
        DisplayManager.shared.restoreAll()
    }

    // MARK: Status item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let btn = statusItem.button!
        btn.action = #selector(statusItemClicked)
        btn.target = self
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateMenuBarIcon()
    }

    func updateTabStripCount() {
        guard let tabs = overlayTabStrip else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let count = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .count
        tabs.setLabel(count > 0 ? "\(condemningLabel)  \(count)" : condemningLabel, forSegment: 0)
    }

    func updateMenuBarIcon() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let count = AppSettings.menuBarBadgeEnabled
            ? NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
                .count
            : 0
        statusItem.button?.image = makeMenuBarIcon(badgeCount: count)
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showStatusMenu() } else { toggleOverlay() }
    }

    func showStatusMenu() {
        // Toggle: a second right-click dismisses the open menu cleanly so
        // About / Update windows can appear without the dropdown in the way.
        if let existing = openStatusMenu {
            existing.cancelTracking()
            return
        }
        let menu = NSMenu()
        menu.delegate = self

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

        addItem(menu, "Show Axe", key: "", tip: AppSettings.shortcutLabel(), action: #selector(toggleOverlay))
        menu.addItem(.separator())

        let ramTitle: String
        if let r = readRAMStats() {
            ramTitle = "RAM  ·  \(r.freeFormatted) free  ·  Pressure: \(r.pressureLabel)"
        } else {
            ramTitle = "RAM  ·  unavailable"
        }
        let ramItem = NSMenuItem(title: ramTitle, action: nil, keyEquivalent: "")
        ramItem.isEnabled = false
        menu.addItem(ramItem)
        menu.addItem(.separator())

        // Quick session actions — surface the most-used flows at the top level
        let saveQuick = NSMenuItem(title: "Save Workflow…",
                                   action: #selector(saveSessionMI), keyEquivalent: "L")
        saveQuick.keyEquivalentModifierMask = [.command, .shift]
        saveQuick.target = self
        menu.addItem(saveQuick)

        if !saved.isEmpty {
            let restoreLast = NSMenuItem(
                title: "Restore Last  ·  \(saved[0].name)",
                action: #selector(restoreLastSessionMI), keyEquivalent: "")
            restoreLast.target = self
            menu.addItem(restoreLast)
        }

        if pauseReopenTimer != nil, let s = pauseReopenSession {
            let mi = NSMenuItem(title: "Cancel Reopen  ·  \(s.name)",
                                action: #selector(cancelPauseReopenMI), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        } else {
            let mins = AppSettings.scheduledReopenMinutes
            let phrase = pauseReopenPunPhrases.randomElement() ?? "Take a Br-Axe"
            let title = pun("\(phrase) (\(mins) min)…",
                            "Pause & Reopen in \(mins) min…")
            let mi = NSMenuItem(title: title,
                                action: #selector(pauseAndReopenMI), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        // Sessions submenu (all sessions)
        let sessionsItem = NSMenuItem(title: "All Workflows", action: nil, keyEquivalent: "")
        let sessionsSub  = NSMenu()
        if saved.isEmpty {
            let empty = NSMenuItem(title: "No saved workflows", action: nil, keyEquivalent: "")
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
            let li = NSMenuItem(title: "Licensed — Axe-cellent! ✦", action: nil, keyEquivalent: "")
            li.isEnabled = false; menu.addItem(li)
        } else {
            addItem(menu, "Support my Axe ♥", key: "", action: #selector(showNudgeWindow))
        }
        menu.addItem(.separator())
        addItem(menu, "Settings…",           key: ",", action: #selector(openSettings))
        addItem(menu, pun("Get Axe-quainted…", "Quick Start Guide…"),
                key: "",  action: #selector(showOnboarding))
        addItem(menu, pun("Sharpen my Axe…", "Check for Updates…"), key: "", action: #selector(checkForUpdatesMI))
        addItem(menu, "About Axe",           key: "",  action: #selector(showAbout))
        menu.addItem(.separator())
        addItem(menu, "Quit Axe", key: "q", action: #selector(quitAxe))
        openStatusMenu  = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === openStatusMenu {
            statusItem.menu = nil
            openStatusMenu  = nil
        }
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
    /// Overlay gear → dismiss the overlay and open the standalone Settings window
    /// (the sidebar+detail settings replace the old inline panel).
    @objc func openStandaloneSettings() {
        if isShowingSettings { toggleSettingsPanel() }
        hideOverlay()
        settingsWindow.show()
    }
    @objc func showOnboarding() { onboardingWindow.show() }
    @objc func quitAxe()        { NSApp.terminate(nil) }
    @objc func showAbout()      { aboutWindow.show() }

    lazy var aboutWindow = AboutWindow()
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
        NSApp.activate(ignoringOtherApps: true)
        guard isNewerVersion(latest, than: appVersion) else {
            if userInitiated {
                let a = NSAlert()
                a.messageText     = "Axe is up to date"
                a.informativeText = "You're running the latest version (v\(appVersion))."
                a.addButton(withTitle: "OK")
                if let keyWin = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                    a.beginSheetModal(for: keyWin)
                } else {
                    a.runModal()
                }
            }
            return
        }
        // For background checks, skip if the user already dismissed this version
        if !userInitiated, AppSettings.dismissedUpdateVersion == latest { return }

        // Auto-install silently when the user has opted in and this is a background check
        if !userInitiated, AppSettings.autoUpdate {
            let updater = SelfUpdater()
            selfUpdater = updater
            updater.install(version: latest)
            return
        }

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

    // MARK: Workflow drift + suggest

    @objc func catchUpWorkflow() {
        for app in driftMissingApps {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: app.bundleID) else { continue }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refreshSessionsPanel() }
    }

    @objc func tidyWorkflow() {
        driftExtraApps.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshSessionsPanel() }
    }

    @objc func reapplyWindowLayout() {
        guard let activeID  = AppSettings.activeWorkflowID,
              let active    = SessionManager.shared.all.first(where: { $0.id == activeID }),
              let snapshots = active.windowSnapshots,
              PermissionManager.shared.accessibility == .granted
        else { return }
        SessionManager.applyWindowSnapshots(snapshots)
    }

    private func buildDriftStrip() -> NSView? {
        guard let activeID = AppSettings.activeWorkflowID,
              let active   = SessionManager.shared.all.first(where: { $0.id == activeID }),
              let lastUsed = active.lastUsed,
              Date().timeIntervalSince(lastUsed) < 4 * 3600
        else { return nil }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular
                   && $0.processIdentifier != selfPID
                   && !SessionManager.isSystemApp($0) }
        let runningIDs  = Set(running.compactMap(\.bundleIdentifier))
        let workflowIDs = Set(active.apps.map(\.bundleID))
        driftMissingApps = active.apps.filter { !runningIDs.contains($0.bundleID) }
        driftExtraApps   = running.filter { !workflowIDs.contains($0.bundleIdentifier ?? "") }

        let strip = NSView(); strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        strip.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = NSTextField(labelWithString: "Active: \(active.name)")
        titleLbl.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLbl.textColor = .controlAccentColor
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        func makeIconView(image: NSImage?, alpha: CGFloat, dot: Bool, tip: String) -> NSView {
            let c = NSView(); c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: 22).isActive = true
            c.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let iv = NSImageView(frame: NSRect(x: 1, y: 1, width: 20, height: 20))
            iv.image = image; iv.alphaValue = alpha; iv.toolTip = tip; c.addSubview(iv)
            if dot {
                let d = NSView(frame: NSRect(x: 14, y: 14, width: 7, height: 7))
                d.wantsLayer = true; d.layer?.cornerRadius = 3.5
                d.layer?.backgroundColor = NSColor.systemRed.cgColor; c.addSubview(d)
            }
            return c
        }

        let missingRow = NSStackView(); missingRow.orientation = .horizontal; missingRow.spacing = 2
        missingRow.translatesAutoresizingMaskIntoConstraints = false
        for app in driftMissingApps.prefix(7) {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            missingRow.addArrangedSubview(makeIconView(image: icon, alpha: 0.35, dot: false,
                                                       tip: "\(app.name) — not running"))
        }

        let driftRow = NSStackView(); driftRow.orientation = .horizontal; driftRow.spacing = 2
        driftRow.translatesAutoresizingMaskIntoConstraints = false
        for app in driftExtraApps.prefix(7) {
            driftRow.addArrangedSubview(makeIconView(image: app.icon, alpha: 1.0, dot: true,
                                                     tip: "\(app.localizedName ?? "App") — not in workflow"))
        }

        var statusParts: [String] = []
        if !driftMissingApps.isEmpty { statusParts.append("\(driftMissingApps.count) missing") }
        if !driftExtraApps.isEmpty   { statusParts.append("\(driftExtraApps.count) extra") }
        let statusStr = statusParts.isEmpty ? "✓ In sync" : statusParts.joined(separator: "  ·  ")
        let statusLbl = NSTextField(labelWithString: statusStr)
        statusLbl.font = .systemFont(ofSize: 10); statusLbl.textColor = .tertiaryLabelColor
        statusLbl.translatesAutoresizingMaskIntoConstraints = false

        let catchUpBtn = NSButton(title: "Catch Up", target: self, action: #selector(catchUpWorkflow))
        catchUpBtn.bezelStyle = .rounded; catchUpBtn.font = .systemFont(ofSize: 11)
        catchUpBtn.translatesAutoresizingMaskIntoConstraints = false
        let tidyBtn = NSButton(title: "Tidy", target: self, action: #selector(tidyWorkflow))
        tidyBtn.bezelStyle = .rounded; tidyBtn.font = .systemFont(ofSize: 11)
        tidyBtn.translatesAutoresizingMaskIntoConstraints = false
        catchUpBtn.isHidden = driftMissingApps.isEmpty
        tidyBtn.isHidden    = driftExtraApps.isEmpty

        let hasSnapshots = active.windowSnapshots != nil
            && PermissionManager.shared.accessibility == .granted
        let reapplyBtn = NSButton(title: "Re-apply layout", target: self, action: #selector(reapplyWindowLayout))
        reapplyBtn.bezelStyle = .rounded; reapplyBtn.font = .systemFont(ofSize: 11)
        reapplyBtn.translatesAutoresizingMaskIntoConstraints = false
        reapplyBtn.isHidden = !hasSnapshots

        strip.addSubview(titleLbl); strip.addSubview(missingRow)
        strip.addSubview(driftRow); strip.addSubview(statusLbl)
        strip.addSubview(catchUpBtn); strip.addSubview(tidyBtn); strip.addSubview(reapplyBtn)
        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: strip.topAnchor, constant: 8),
            titleLbl.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
            missingRow.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 5),
            missingRow.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
            driftRow.centerYAnchor.constraint(equalTo: missingRow.centerYAnchor),
            driftRow.leadingAnchor.constraint(equalTo: missingRow.trailingAnchor, constant: 6),
            statusLbl.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
            statusLbl.topAnchor.constraint(equalTo: missingRow.bottomAnchor, constant: 5),
            statusLbl.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -8),
            reapplyBtn.trailingAnchor.constraint(equalTo: catchUpBtn.leadingAnchor, constant: -4),
            reapplyBtn.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            catchUpBtn.trailingAnchor.constraint(equalTo: tidyBtn.leadingAnchor, constant: -4),
            catchUpBtn.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            tidyBtn.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -10),
            tidyBtn.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        return strip
    }

    // MARK: Usage tracking

    func startUsageTimer() {
        snapshotUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.snapshotUsage()
        }
    }

    private func snapshotUsage() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular
                   && $0.processIdentifier != selfPID
                   && !SessionManager.isSystemApp($0) }
            .compactMap(\.bundleIdentifier).sorted()
        guard !ids.isEmpty else { return }
        var patterns = (UserDefaults.standard.array(forKey: "usagePatterns") as? [[String]]) ?? []
        patterns.append(ids)
        if patterns.count > 200 { patterns = Array(patterns.suffix(200)) }
        UserDefaults.standard.set(patterns, forKey: "usagePatterns")
    }

    private func buildSuggestCard() -> NSView? {
        let sessions = SessionManager.shared.all
        guard sessions.count <= 3 else { return nil }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular
                   && $0.processIdentifier != selfPID
                   && !SessionManager.isSystemApp($0) }
        guard running.count >= 3 else { return nil }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let isClose = sessions.contains { s in
            let wids = Set(s.apps.map(\.bundleID))
            let inter = runningIDs.intersection(wids).count
            let union = runningIDs.union(wids).count
            return union > 0 && Double(inter) / Double(union) >= 0.6
        }
        guard !isClose else { return nil }

        let card = NSView(); card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.07).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: "Save current \(running.count) apps as a workflow?")
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let iconRow = NSStackView(); iconRow.orientation = .horizontal; iconRow.spacing = 2
        iconRow.translatesAutoresizingMaskIntoConstraints = false
        for app in running.prefix(8) {
            let iv = NSImageView()
            iv.image = app.icon; iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 20).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 20).isActive = true
            iconRow.addArrangedSubview(iv)
        }

        let saveBtn = NSButton(title: "+ Save", target: self, action: #selector(saveSuggestedWorkflow))
        saveBtn.bezelStyle = .rounded; saveBtn.font = .systemFont(ofSize: 11)
        saveBtn.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(lbl); card.addSubview(iconRow); card.addSubview(saveBtn)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            iconRow.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 6),
            iconRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            saveBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            saveBtn.topAnchor.constraint(equalTo: iconRow.bottomAnchor, constant: 8),
            saveBtn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    @objc func saveSuggestedWorkflow() {
        saveSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshSessionsPanel() }
    }

    // MARK: Sessions

    @objc func saveSessionMI() { saveSession() }

    @objc func restoreLastSessionMI() {
        guard let last = SessionManager.shared.all.first else { return }
        SessionManager.shared.restore(last)
    }

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
        showWorkflowEditor(for: session) { self.refreshSessionsPanel() }
    }

    func saveSession() {
        let selfPID  = ProcessInfo.processInfo.processIdentifier
        let running  = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID
                   && !(AppSettings.ignoreSystemOnSave && SessionManager.isSystemApp($0)) }
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
        alert.addButton(withTitle: "Save & Axe All")
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
            hideOverlay()
            // Brief delay so the overlay fully dismisses before apps receive the
            // quit signal — prevents their "save changes?" sheets from appearing
            // behind the floating Axe panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                running.forEach { saved in
                    NSWorkspace.shared.runningApplications
                        .first { $0.bundleIdentifier == saved.bundleID }?
                        .terminate()
                }
            }
        }
    }

    private func saveSessionInline(name: String, axeAll: Bool) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID
                   && !(AppSettings.ignoreSystemOnSave && SessionManager.isSystemApp($0)) }
            .compactMap { app -> SavedApp? in
                guard let bid = app.bundleIdentifier, let n = app.localizedName else { return nil }
                return SavedApp(bundleID: bid, name: n)
            }
        guard !running.isEmpty else { return }
        let df = DateFormatter(); df.dateFormat = "MMM d, h:mma"
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? df.string(from: Date()) : name.trimmingCharacters(in: .whitespaces)
        let session = AppSession(id: UUID(), name: finalName, date: Date(), apps: running)
        SessionManager.shared.save(session)
        if axeAll {
            hideOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                running.forEach { saved in
                    NSWorkspace.shared.runningApplications
                        .first { $0.bundleIdentifier == saved.bundleID }?
                        .terminate()
                }
            }
        } else {
            inlineNameField?.stringValue = ""
            refreshSessionsPanel()
        }
    }

    @objc private func saveSessionInlineAxeAll() {
        saveSessionInline(name: inlineNameField?.stringValue ?? "", axeAll: true)
    }
    @objc private func saveSessionInlineSaveOnly() {
        saveSessionInline(name: inlineNameField?.stringValue ?? "", axeAll: false)
    }

    // MARK: Pause & Reopen Later

    @objc func pauseAndReopenMI() { pauseAndReopen() }
    @objc func cancelPauseReopenMI() { cancelPauseReopen() }

    /// Saves the current workflow, quits its apps, and schedules a restore
    /// after `scheduledReopenMinutes`. Lets you take a break / focus block
    /// and have everything come back automatically.
    func pauseAndReopen() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID
                   && !(AppSettings.ignoreSystemOnSave && SessionManager.isSystemApp($0)) }
        let saved = running.compactMap { app -> SavedApp? in
            guard let bid = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return SavedApp(bundleID: bid, name: name)
        }
        guard !saved.isEmpty else {
            let a = NSAlert(); a.messageText = "Nothing to pause"
            a.informativeText = "No regular apps are running right now."
            a.runModal(); return
        }
        let minutes = AppSettings.scheduledReopenMinutes
        let alert = NSAlert()
        alert.messageText = pun("Time for a Br-Axe?", "Pause workflow?")
        alert.informativeText = "\(saved.count) app\(saved.count == 1 ? "" : "s") will be saved and quit now, then reopened in \(minutes) minute\(minutes == 1 ? "" : "s")."
        let btnPhrase = pauseReopenPunPhrases.randomElement() ?? "Take a Br-Axe"
        alert.addButton(withTitle: pun(btnPhrase, "Pause & Reopen Later"))
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let df = DateFormatter(); df.dateFormat = "MMM d h:mma"
        let session = AppSession(id: UUID(),
                                 name: "Pause • \(df.string(from: Date()))",
                                 date: Date(), apps: saved)
        SessionManager.shared.save(session)
        running.forEach { $0.terminate() }

        cancelPauseReopen()
        pauseReopenSession = session
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.executePauseReopen()
        }
        RunLoop.main.add(t, forMode: .common)
        pauseReopenTimer = t
    }

    func cancelPauseReopen() {
        pauseReopenTimer?.invalidate()
        pauseReopenTimer   = nil
        pauseReopenSession = nil
    }

    private func executePauseReopen() {
        guard let s = pauseReopenSession else { return }
        pauseReopenTimer   = nil
        pauseReopenSession = nil
        SessionManager.shared.restore(s)
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
        refreshClipboardHotkey()
    }

    /// (Re)register or tear down the global clipboard hotkey (⌥⌘V).
    func refreshClipboardHotkey() {
        if let ref = clipboardHotKeyRef { UnregisterEventHotKey(ref); clipboardHotKeyRef = nil }
        guard AppSettings.clipboardHotkeyEnabled else { return }
        let cid = EventHotKeyID(signature: fourCC("axe!"), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey),
                            cid, GetApplicationEventTarget(), 0, &clipboardHotKeyRef)
    }

    /// Unregisters the current hot key and registers a fresh one from AppSettings.
    /// Call after the user changes the shortcut in Settings.
    // MARK: Displays panel

    /// Builds the Displays overlay panel (initially hidden). Populated on show by
    /// refreshDisplaysPanel(), which tints text for the current overlay style.
    private func buildDisplaysPanel() -> NSView {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 16
        stack.edgeInsets  = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedStackView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        displaysListStack = stack
        return container
    }

    /// Rebuilds the Displays panel rows from the currently-connected displays.
    func refreshDisplaysPanel() {
        guard let stack = displaysListStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        displayActionBoxes.removeAll()
        let labelColor: NSColor = effectiveUIStyle == .notch ? .white : .labelColor
        let displays = DisplayManager.shared.currentDisplays()

        let header = NSTextField(labelWithString: "DISPLAYS")
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = dimHintColor
        stack.addArrangedSubview(header)

        if displays.isEmpty {
            let empty = NSTextField(labelWithString: "No displays detected.")
            empty.font = .systemFont(ofSize: 12); empty.textColor = dimHintColor
            stack.addArrangedSubview(empty)
            return
        }
        for disp in displays {
            // One group per display: brightness (with name) on top, then indented
            // controls — resolution, warmth/contrast/gamma sliders, invert toggle.
            let group = NSStackView()
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 8
            group.translatesAutoresizingMaskIntoConstraints = false

            let brow = DisplayBrightnessRow(display: disp, labelColor: labelColor)
            let adj  = DisplayManager.shared.adjustments(forUUID: disp.uuid)
            let rrow = DisplayResolutionRow(display: disp, labelColor: labelColor)

            let tempRow = LabeledSliderRow(title: "Warmth", symbol: "thermometer.medium",
                                           value: 1 - adj.temperature, minV: 0, maxV: 1,
                                           labelColor: labelColor) { v in
                DisplayManager.shared.updateAdjustment(for: disp) { $0.temperature = 1 - v }
            }
            let contrastRow = LabeledSliderRow(title: "Contrast", symbol: "circle.lefthalf.filled",
                                               value: adj.contrast, minV: 0, maxV: 1,
                                               labelColor: labelColor) { v in
                DisplayManager.shared.updateAdjustment(for: disp) { $0.contrast = v }
            }
            let gammaRow = LabeledSliderRow(title: "Gamma", symbol: "dial.medium",
                                            value: adj.gamma, minV: 0, maxV: 1,
                                            labelColor: labelColor) { v in
                DisplayManager.shared.updateAdjustment(for: disp) { $0.gamma = v }
            }

            let invert = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            invert.attributedTitle = NSAttributedString(string: "Invert colors",
                attributes: [.foregroundColor: labelColor.withAlphaComponent(0.75),
                             .font: NSFont.systemFont(ofSize: 11)])
            invert.state = adj.invert ? .on : .off
            let ibox = ActionBox { [weak invert] in
                DisplayManager.shared.updateAdjustment(for: disp) { $0.invert = (invert?.state == .on) }
            }
            displayActionBoxes.append(ibox)
            invert.target = ibox; invert.action = #selector(ActionBox.invoke)

            let controls = NSStackView()
            controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 7
            controls.translatesAutoresizingMaskIntoConstraints = false
            [rrow, tempRow, contrastRow, gammaRow].forEach { controls.addArrangedSubview($0) }
            controls.addArrangedSubview(invert)

            group.addArrangedSubview(brow)
            group.addArrangedSubview(controls)

            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            brow.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            controls.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 23).isActive = true
            controls.trailingAnchor.constraint(equalTo: group.trailingAnchor).isActive = true
            [rrow, tempRow, contrastRow, gammaRow].forEach {
                $0.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
            }
        }
        let note = NSTextField(wrappingLabelWithString:
            "External monitors use hardware brightness (DDC) when supported; everything else dims in software.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = dimHintColor
        note.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        // Local helpers: a section header, and a small button whose closure target
        // is retained in displayActionBoxes (cleared at the top of this method).
        func sectionHeader(_ text: String) -> NSTextField {
            let h = NSTextField(labelWithString: text)
            h.font = .systemFont(ofSize: 10, weight: .semibold); h.textColor = dimHintColor
            return h
        }
        func actionButton(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
            let b = NSButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11)
            let box = ActionBox(handler)
            displayActionBoxes.append(box)
            b.target = box; b.action = #selector(ActionBox.invoke)
            return b
        }

        // ── Arrangement (multi-display only) ──
        if displays.count >= 2 {
            stack.addArrangedSubview(sectionHeader("ARRANGEMENT"))

            let mirror = NSButton(checkboxWithTitle: "Mirror displays", target: nil, action: nil)
            mirror.attributedTitle = NSAttributedString(string: "Mirror displays",
                attributes: [.foregroundColor: labelColor, .font: NSFont.systemFont(ofSize: 12)])
            mirror.state = DisplayManager.shared.isMirroring() ? .on : .off
            let mBox = ActionBox { [weak self, weak mirror] in
                DisplayManager.shared.setMirroring(mirror?.state == .on)
                self?.refreshDisplaysPanel()
            }
            displayActionBoxes.append(mBox)
            mirror.target = mBox; mirror.action = #selector(ActionBox.invoke)
            stack.addArrangedSubview(mirror)

            for disp in displays where !DisplayManager.shared.isMain(disp.id) {
                let id = disp.id
                stack.addArrangedSubview(actionButton("Make “\(disp.name)” main") { [weak self] in
                    DisplayManager.shared.setAsMain(id); self?.refreshDisplaysPanel()
                })
            }
        }

        // ── Layouts / presets ──
        stack.addArrangedSubview(sectionHeader("LAYOUTS"))
        let saved = DisplayManager.shared.layouts
        if saved.isEmpty {
            let empty = NSTextField(labelWithString: "No saved layouts yet.")
            empty.font = .systemFont(ofSize: 11); empty.textColor = dimHintColor
            stack.addArrangedSubview(empty)
        } else {
            for layout in saved {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
                row.addArrangedSubview(actionButton("↺  \(layout.name)") { [weak self] in
                    DisplayManager.shared.applyLayout(layout); self?.refreshDisplaysPanel()
                })
                row.addArrangedSubview(actionButton("✕") { [weak self] in
                    DisplayManager.shared.deleteLayout(name: layout.name); self?.refreshDisplaysPanel()
                })
                stack.addArrangedSubview(row)
            }
        }
        stack.addArrangedSubview(actionButton("Save current layout…") { [weak self] in
            self?.saveLayoutTapped()
        })

        // Probe external displays for DDC once (off-main); rebuild if it changes a
        // display's mode. Guarded so this can't loop: after probing, isProbed is true.
        if displays.contains(where: { !DisplayManager.shared.isProbed($0) }) {
            DisplayManager.shared.probeDDC(displays) { [weak self] in
                guard let self, self.isShowingDisplays else { return }
                self.refreshDisplaysPanel()
            }
        }
    }

    @objc func saveLayoutTapped() {
        let alert = NSAlert()
        alert.messageText = "Save display layout"
        alert.informativeText = "Capture the current display positions, resolutions, and mirroring so you can restore them in one tap."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "Layout \(DisplayManager.shared.layouts.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        DisplayManager.shared.saveCurrentLayout(name: name)
        refreshDisplaysPanel()
    }

    // MARK: Sessions panel

    /// Builds the sessions overlay panel view (initially hidden).
    private func buildSessionsPanel() -> NSView {
        let container = NSView()

        // ── Visual background — matches NSTableView sourceList appearance ──
        let bgFX = NSVisualEffectView()
        bgFX.material = .sidebar
        bgFX.blendingMode = .withinWindow
        bgFX.state = .active
        bgFX.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bgFX)   // added first → sits behind all content

        // ── Header bar ─────────────────────────────────────────────
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.08).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let titleLbl = NSTextField(labelWithString: "Workflows")
        titleLbl.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLbl.textColor = .labelColor; titleLbl.alignment = .center
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLbl)

        let saveBtn = NSButton()
        saveBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Save Workflow") {
            saveBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        saveBtn.contentTintColor = .controlAccentColor
        saveBtn.target = self; saveBtn.action = #selector(saveSessionFromPanel)
        saveBtn.toolTip = "Save current workflow"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(saveBtn)

        let sortBtn = NSButton()
        sortBtn.isBordered = false
        let sortSymName = AppSettings.sessionsSortOrder == 2 ? "textformat.abc" : "calendar"
        if let sym = NSImage(systemSymbolName: sortSymName, accessibilityDescription: "Sort") {
            sortBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sortBtn.contentTintColor = AppSettings.sessionsSortOrder == 0 ? .tertiaryLabelColor : .controlAccentColor
        sortBtn.toolTip = "Sort workflows"
        sortBtn.target = self; sortBtn.action = #selector(showSessionsSortMenu(_:))
        sortBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(sortBtn)

        let headerH: CGFloat = 36
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerH),
            titleLbl.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLbl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            saveBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            saveBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            saveBtn.widthAnchor.constraint(equalToConstant: 28),
            saveBtn.heightAnchor.constraint(equalToConstant: 28),
            sortBtn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            sortBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sortBtn.widthAnchor.constraint(equalToConstant: 28),
            sortBtn.heightAnchor.constraint(equalToConstant: 28),
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

        // ── Search / filter bar ─────────────────────────────────────
        let searchBar = NSView()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchBar)

        let sf = NSSearchField()
        sf.placeholderString = "Filter workflows…"
        sf.font = .systemFont(ofSize: 12)
        sf.focusRingType = .none
        sf.controlSize = .small
        sf.translatesAutoresizingMaskIntoConstraints = false
        sf.target = self; sf.action = #selector(sessionsSearchChanged(_:))
        (sf.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = self
        (sf.cell as? NSSearchFieldCell)?.cancelButtonCell?.action = #selector(sessionsSearchChanged(_:))
        searchBar.addSubview(sf)
        sessionsSearchField = sf

        let searchBarH: CGFloat = 32
        NSLayoutConstraint.activate([
            sf.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 10),
            sf.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -10),
            sf.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: searchBarH),
        ])

        let searchDiv = divider()
        searchDiv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchDiv)

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
        listSV.backgroundColor = .clear
        listSV.contentView.drawsBackground = false
        listSV.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listSV)
        listStack.widthAnchor.constraint(equalTo: listSV.contentView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: hdrDiv.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchDiv.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            searchDiv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchDiv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchDiv.heightAnchor.constraint(equalToConstant: 1),
            listSV.topAnchor.constraint(equalTo: searchDiv.bottomAnchor),
            listSV.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listSV.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listSV.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // bgFX fills the entire panel so sidebar material shows behind all content
            bgFX.topAnchor.constraint(equalTo: container.topAnchor),
            bgFX.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bgFX.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bgFX.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    /// Rebuild the sessions list stack with current saved sessions.
    // MARK: Sessions panel helpers

    private func buildQuickSaveBar() -> NSView {
        let bar = NSView(); bar.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField()
        tf.placeholderString = "Name this workflow…"
        tf.font = .systemFont(ofSize: 13)
        tf.isBordered = false; tf.drawsBackground = false; tf.focusRingType = .none
        tf.translatesAutoresizingMaskIntoConstraints = false
        inlineNameField = tf

        let axeAllBtn = RedButton()
        axeAllBtn.title = "Save & Close All"
        axeAllBtn.isBordered = true; axeAllBtn.bezelStyle = .rounded
        axeAllBtn.font = .systemFont(ofSize: 12, weight: .medium)
        axeAllBtn.target = self; axeAllBtn.action = #selector(saveSessionInlineAxeAll)
        axeAllBtn.translatesAutoresizingMaskIntoConstraints = false

        let saveOnlyBtn = NSButton()
        saveOnlyBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                             accessibilityDescription: "Save Only") {
            saveOnlyBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        saveOnlyBtn.contentTintColor = .secondaryLabelColor
        saveOnlyBtn.target = self; saveOnlyBtn.action = #selector(saveSessionInlineSaveOnly)
        saveOnlyBtn.toolTip = "Save Only (keep apps running)"
        saveOnlyBtn.translatesAutoresizingMaskIntoConstraints = false
        saveOnlyBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true

        bar.addSubview(tf); bar.addSubview(axeAllBtn); bar.addSubview(saveOnlyBtn)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 52),
            tf.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            tf.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tf.trailingAnchor.constraint(equalTo: axeAllBtn.leadingAnchor, constant: -8),
            axeAllBtn.trailingAnchor.constraint(equalTo: saveOnlyBtn.leadingAnchor, constant: -6),
            axeAllBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            saveOnlyBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            saveOnlyBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func buildPermissionGateBanner() -> NSView? {
        guard PermissionManager.shared.accessibility != .granted else { return nil }
        let banner = NSView(); banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
        banner.layer?.cornerRadius = 8

        let lockImg = NSImageView()
        if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
            lockImg.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        }
        lockImg.contentTintColor = .controlAccentColor
        lockImg.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = NSTextField(labelWithString: "Unlock window layout restore")
        titleLbl.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let subLbl = NSTextField(labelWithString: "Grant Accessibility to capture and restore window positions.")
        subLbl.font = .systemFont(ofSize: 10); subLbl.textColor = .secondaryLabelColor
        subLbl.lineBreakMode = .byWordWrapping
        subLbl.translatesAutoresizingMaskIntoConstraints = false

        let grantBtn = NSButton(title: "Grant Access", target: self,
                                action: #selector(grantAccessibilityFromSessions))
        grantBtn.bezelStyle = .rounded; grantBtn.font = .systemFont(ofSize: 11)
        grantBtn.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLbl, subLbl])
        textStack.orientation = .vertical; textStack.spacing = 2; textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(lockImg); banner.addSubview(textStack); banner.addSubview(grantBtn)
        NSLayoutConstraint.activate([
            lockImg.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            lockImg.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            lockImg.widthAnchor.constraint(equalToConstant: 18),
            textStack.leadingAnchor.constraint(equalTo: lockImg.trailingAnchor, constant: 8),
            textStack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: grantBtn.leadingAnchor, constant: -8),
            grantBtn.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            grantBtn.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])
        return banner
    }

    @objc private func grantAccessibilityFromSessions() {
        PermissionManager.shared.requestAccessibility()
        PermissionManager.shared.openAccessibilitySettings()
    }

    private func buildIconStrip(for session: AppSession, runningIDs: Set<String>) -> NSStackView {
        let strip = NSStackView(); strip.orientation = .horizontal; strip.spacing = 2
        strip.translatesAutoresizingMaskIntoConstraints = false
        let iconSize: CGFloat = 22
        let maxIcons = 6
        let apps = Array(session.apps.prefix(maxIcons))
        let overflow = session.apps.count - apps.count
        for app in apps {
            let iv = NSImageView(); iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
            iv.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
            let isRunning = runningIDs.contains(app.bundleID)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                iv.image = NSWorkspace.shared.icon(forFile: url.path)
            } else if let sym = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) {
                iv.image = sym; iv.contentTintColor = .tertiaryLabelColor
            }
            iv.alphaValue = isRunning ? 1.0 : 0.35
            iv.toolTip = app.name + (isRunning ? "" : " — not running")
            strip.addArrangedSubview(iv)
        }
        if overflow > 0 {
            let badge = NSTextField(labelWithString: "+\(overflow)")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .tertiaryLabelColor
            badge.translatesAutoresizingMaskIntoConstraints = false
            strip.addArrangedSubview(badge)
        }
        return strip
    }

    private func buildActionsStrip(for session: AppSession, index: Int) -> NSView {
        let strip = NSView(); strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        strip.translatesAutoresizingMaskIntoConstraints = false

        func actionView(symbol: String, label: String, action: Selector,
                        tint: NSColor = .labelColor) -> NSView {
            let btn = NSButton(); btn.isBordered = false
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                btn.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            }
            btn.contentTintColor = tint; btn.target = self
            btn.action = action; btn.tag = index; btn.toolTip = label
            btn.translatesAutoresizingMaskIntoConstraints = false
            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 9); lbl.textColor = tint == .labelColor ? .secondaryLabelColor : tint
            lbl.alignment = .center; lbl.translatesAutoresizingMaskIntoConstraints = false
            let col = NSStackView(views: [btn, lbl])
            col.orientation = .vertical; col.spacing = 3; col.alignment = .centerX
            col.translatesAutoresizingMaskIntoConstraints = false
            return col
        }

        var actions: [NSView] = [
            actionView(symbol: "play.circle.fill", label: "Restore",
                       action: #selector(restoreSessionFromPanel(_:)), tint: .controlAccentColor),
            actionView(symbol: "macwindow.on.rectangle", label: "New Space",
                       action: #selector(restoreOnNewSpaceFromPanel(_:))),
        ]
        if session.windowSnapshots != nil && PermissionManager.shared.accessibility == .granted {
            actions.append(actionView(symbol: "checkmark.circle", label: "Re-apply Layout",
                                      action: #selector(reapplyLayoutFromPanel(_:))))
        }
        actions.append(contentsOf: [
            actionView(symbol: "pencil", label: "Rename",
                       action: #selector(renameSessionFromActions(_:))),
            actionView(symbol: "trash", label: "Delete",
                       action: #selector(deleteSessionFromPanel(_:)), tint: .systemRed),
        ])

        let hStack = NSStackView(views: actions)
        hStack.orientation = .horizontal; hStack.distribution = .equalSpacing
        hStack.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 20),
            hStack.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -20),
            hStack.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        return strip
    }

    @objc private func reapplyLayoutFromPanel(_ sender: NSButton) {
        let sessions = SessionManager.shared.all
        guard sender.tag < sessions.count,
              let snapshots = sessions[sender.tag].windowSnapshots,
              PermissionManager.shared.accessibility == .granted else { return }
        SessionManager.applyWindowSnapshots(snapshots)
    }

    @objc private func renameSessionFromActions(_ sender: NSButton) {
        let sessions = SessionManager.shared.all
        guard sender.tag < sessions.count else { return }
        renameSessionInPanel(id: sessions[sender.tag].id)
    }

    func refreshSessionsPanel() {
        guard let stack = sessionsListStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        PermissionManager.shared.refreshAccessibilityState()

        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d · h:mma"

        func addDivider() {
            let div = NSBox(); div.boxType = .separator
            div.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(div)
            div.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let query = sessionsFilterQuery.trimmingCharacters(in: .whitespaces)
        let isFiltering = !query.isEmpty

        // Hide quick-save bar, permission banner, drift/suggest when filtering
        if !isFiltering {
            let saveBar = buildQuickSaveBar()
            stack.addArrangedSubview(saveBar)
            saveBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            addDivider()

            if let banner = buildPermissionGateBanner() {
                let padWrap = NSView(); padWrap.translatesAutoresizingMaskIntoConstraints = false
                padWrap.addSubview(banner)
                NSLayoutConstraint.activate([
                    banner.leadingAnchor.constraint(equalTo: padWrap.leadingAnchor, constant: 10),
                    banner.trailingAnchor.constraint(equalTo: padWrap.trailingAnchor, constant: -10),
                    banner.topAnchor.constraint(equalTo: padWrap.topAnchor, constant: 8),
                    banner.bottomAnchor.constraint(equalTo: padWrap.bottomAnchor, constant: -8),
                ])
                stack.addArrangedSubview(padWrap)
                padWrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                addDivider()
            }

            if let strip = buildDriftStrip() {
                stack.addArrangedSubview(strip)
                strip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                addDivider()
            }

            if let card = buildSuggestCard() {
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                addDivider()
            }
        }

        let rawSessions = SessionManager.shared.all
        let allSessions: [AppSession]
        switch AppSettings.sessionsSortOrder {
        case 1:  allSessions = rawSessions.sorted { $0.date < $1.date }
        case 2:  allSessions = rawSessions.sorted {
                     $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default: allSessions = rawSessions  // newest first (default storage order)
        }

        func sessionMatches(_ s: AppSession) -> Bool {
            let q = query.lowercased()
            if s.name.lowercased().contains(q) { return true }
            return s.apps.contains { $0.name.lowercased().contains(q) }
        }

        let all = isFiltering ? allSessions.filter(sessionMatches) : allSessions
        let workflows = all.filter { $0.isFavorite }
        let recents   = all.filter { !$0.isFavorite }

        if allSessions.isEmpty {
            let empty = NSTextField(labelWithString: "No workflows yet.\nType a name above and tap \"Save & Close All\".")
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

        if isFiltering && all.isEmpty {
            let empty = NSTextField(labelWithString: "No workflows match \"\(query)\".")
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
            let isExpanded = expandedSessionID == session.id

            // Container holds header + collapsible actions strip
            let container = NSView(); container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.backgroundColor = isFav
                ? NSColor.systemYellow.withAlphaComponent(0.05).cgColor : NSColor.clear.cgColor

            // ── Header row
            let header = SessionRowView()
            header.orientation = .horizontal; header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
            header.alignment = .centerY
            header.translatesAutoresizingMaskIntoConstraints = false

            let starBtn = NSButton(); starBtn.isBordered = false
            if let sym = NSImage(systemSymbolName: isFav ? "star.fill" : "star",
                                 accessibilityDescription: nil) {
                starBtn.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            }
            starBtn.contentTintColor = isFav ? .systemYellow : .tertiaryLabelColor
            starBtn.target = self; starBtn.action = #selector(toggleFavoriteFromPanel(_:))
            starBtn.tag = index
            starBtn.toolTip = isFav ? "Remove from Workflows" : "Pin as Workflow"
            starBtn.translatesAutoresizingMaskIntoConstraints = false
            starBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let iconStrip = buildIconStrip(for: session, runningIDs: runningIDs)

            let nameLabel = NSTextField(labelWithString: session.name)
            nameLabel.font = .systemFont(ofSize: 13, weight: isFav ? .semibold : .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let appCount = session.apps.count
            let metaStr = "\(appCount) app\(appCount == 1 ? "" : "s")  ·  \(fmt.string(from: session.date))"
            let metaLabel = NSTextField(labelWithString: metaStr)
            metaLabel.font = .systemFont(ofSize: 11); metaLabel.textColor = .tertiaryLabelColor
            metaLabel.lineBreakMode = .byTruncatingTail
            metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            var textColViews: [NSView] = [nameLabel, metaLabel]
            if let sched = session.scheduledRestore,
               let next = sched.nextFireDate() {
                let relFmt = RelativeDateTimeFormatter()
                relFmt.unitsStyle = .abbreviated
                let schedLbl = NSTextField(labelWithString: "⏰ \(sched.displayString)  ·  \(relFmt.localizedString(for: next, relativeTo: Date()))")
                schedLbl.font = .systemFont(ofSize: 10); schedLbl.textColor = .controlAccentColor
                schedLbl.lineBreakMode = .byTruncatingTail
                schedLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                textColViews.append(schedLbl)
            }
            let textCol = NSStackView(views: textColViews)
            textCol.orientation = .vertical; textCol.spacing = 1; textCol.alignment = .leading
            textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
            textCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let chevron = NSImageView()
            if let sym = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
                chevron.image = sym.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            }
            chevron.contentTintColor = .tertiaryLabelColor; chevron.wantsLayer = true
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
            if isExpanded {
                chevron.layer?.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
            }

            header.addArrangedSubview(starBtn)
            header.addArrangedSubview(iconStrip)
            header.addArrangedSubview(textCol)
            header.addArrangedSubview(chevron)

            header.sessionID  = session.id
            header.onNewSpace = { [weak self] in self?.restoreOnNewSpace(session) }
            header.onRename   = { [weak self] in self?.renameSessionInPanel(id: session.id) }
            header.onDelete   = { [weak self] in
                SessionManager.shared.delete(id: session.id)
                self?.refreshSessionsPanel()
            }

            // ── Actions strip (collapses to 0 height when closed)
            let actionsStrip = buildActionsStrip(for: session, index: index)
            actionsStrip.wantsLayer = true; actionsStrip.layer?.masksToBounds = true
            let actionsHC = actionsStrip.heightAnchor.constraint(equalToConstant: isExpanded ? 56 : 0)
            actionsHC.isActive = true

            container.addSubview(header); container.addSubview(actionsStrip)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: container.topAnchor),
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                actionsStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
                actionsStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                actionsStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                actionsStrip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            // Tap anywhere on header (not on a button) to expand / collapse
            let sessionID = session.id
            header.onTap = { [weak self, weak actionsHC, weak chevron] in
                guard let self, let actionsHC, let chevron else { return }
                let expanding = self.expandedSessionID != sessionID
                self.expandedSessionID = expanding ? sessionID : nil
                actionsHC.constant = expanding ? 56 : 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ctx.allowsImplicitAnimation = true
                    container.layoutSubtreeIfNeeded()
                    let angle: CGFloat = expanding ? -.pi / 2 : 0
                    chevron.layer?.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
                }
            }

            stack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            if !lastInGroup {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            }
        }

        if !workflows.isEmpty {
            addSectionHeader("Workflows")
            for (i, session) in workflows.enumerated() {
                let fullIndex = all.firstIndex(where: { $0.id == session.id }) ?? i
                addRow(session, index: fullIndex, isFav: true, lastInGroup: i == workflows.count - 1)
            }
        }
        if !recents.isEmpty {
            if !workflows.isEmpty { addDivider() }
            addSectionHeader("Recent")
            for (i, session) in recents.enumerated() {
                let fullIndex = all.firstIndex(where: { $0.id == session.id }) ?? i
                addRow(session, index: fullIndex, isFav: false, lastInGroup: i == recents.count - 1)
            }
        }
    }

    private func renameSessionInPanel(id: UUID) {
        guard let session = SessionManager.shared.all.first(where: { $0.id == id }) else { return }
        showWorkflowEditor(for: session) { self.refreshSessionsPanel() }
    }

    func showWorkflowEditor(for session: AppSession, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Edit Workflow"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")

        let av = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 195))
        let nameField = NSTextField(frame: .zero)
        nameField.stringValue = session.name; nameField.placeholderString = "Workflow name"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let hkLbl = NSTextField(labelWithString: "Hotkey:")
        hkLbl.font = .systemFont(ofSize: 12); hkLbl.translatesAutoresizingMaskIntoConstraints = false

        let recorder = HotKeyRecorder(frame: .zero)
        recorder.capturedBinding = session.hotkey
        recorder.translatesAutoresizingMaskIntoConstraints = false

        let clearBtn = NSButton(title: "Clear", target: nil, action: nil)
        clearBtn.bezelStyle = .rounded; clearBtn.font = .systemFont(ofSize: 11)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false

        let primLbl = NSTextField(labelWithString: "Primary:")
        primLbl.font = .systemFont(ofSize: 12); primLbl.translatesAutoresizingMaskIntoConstraints = false

        let primPop = NSPopUpButton(frame: .zero, pullsDown: false)
        primPop.translatesAutoresizingMaskIntoConstraints = false
        primPop.addItem(withTitle: "None")
        for app in session.apps { primPop.addItem(withTitle: app.name) }
        if let pid = session.primaryBundleID,
           let idx = session.apps.firstIndex(where: { $0.bundleID == pid }) {
            primPop.selectItem(at: idx + 1)
        }

        let autoChk = NSButton(checkboxWithTitle: "Launch on login", target: nil, action: nil)
        autoChk.state = session.autoLaunchOnLogin ? .on : .off
        autoChk.translatesAutoresizingMaskIntoConstraints = false

        let axGranted = PermissionManager.shared.refreshAccessibilityState() == .granted
        let winChkTitle = axGranted
            ? "Capture window positions"
            : "Capture window positions  (requires Accessibility — set up in Settings)"
        let winChk = NSButton(checkboxWithTitle: winChkTitle, target: nil, action: nil)
        winChk.state = session.captureWindowState ? .on : .off
        winChk.isEnabled = axGranted
        if !axGranted { winChk.contentTintColor = .tertiaryLabelColor }
        winChk.font = .systemFont(ofSize: 11)
        winChk.translatesAutoresizingMaskIntoConstraints = false

        // ── Scheduled restore controls ──────────────────────────────
        let schedChk = NSButton(checkboxWithTitle: "Restore on a schedule", target: nil, action: nil)
        schedChk.state = session.scheduledRestore != nil ? .on : .off
        schedChk.translatesAutoresizingMaskIntoConstraints = false

        let existingSched = session.scheduledRestore
        var schedTimeComps = DateComponents()
        schedTimeComps.hour   = existingSched?.hour   ?? 9
        schedTimeComps.minute = existingSched?.minute ?? 0
        let schedTimePicker = NSDatePicker()
        schedTimePicker.datePickerStyle  = .textField
        schedTimePicker.datePickerElements = .hourMinute
        schedTimePicker.dateValue = Calendar.current.date(from: schedTimeComps) ?? Date()
        schedTimePicker.isEnabled = session.scheduledRestore != nil
        schedTimePicker.translatesAutoresizingMaskIntoConstraints = false

        let schedRecurPop = NSPopUpButton(frame: .zero, pullsDown: false)
        schedRecurPop.addItems(withTitles: ["Once", "Daily", "Weekly"])
        schedRecurPop.selectItem(at: {
            switch existingSched?.recurrence {
            case .once: return 0; case .daily: return 1; case .weekly: return 2; default: return 1
            }
        }())
        schedRecurPop.isEnabled = session.scheduledRestore != nil
        schedRecurPop.translatesAutoresizingMaskIntoConstraints = false

        let weekdays = Calendar.current.weekdaySymbols  // ["Sunday", "Monday", ...]
        let schedDayPop = NSPopUpButton(frame: .zero, pullsDown: false)
        schedDayPop.addItems(withTitles: weekdays)
        let currentWD = existingSched?.weekday ?? 2  // default Monday (weekday 2)
        schedDayPop.selectItem(at: max(0, currentWD - 1))
        schedDayPop.isEnabled = session.scheduledRestore != nil && existingSched?.recurrence == .weekly
        schedDayPop.translatesAutoresizingMaskIntoConstraints = false

        let schedToggleAction = ActionBox { [weak schedChk, weak schedTimePicker, weak schedRecurPop, weak schedDayPop] in
            let on = schedChk?.state == .on
            schedTimePicker?.isEnabled = on
            schedRecurPop?.isEnabled   = on
            schedDayPop?.isEnabled     = on && schedRecurPop?.indexOfSelectedItem == 2
        }
        schedChk.target = schedToggleAction; schedChk.action = #selector(ActionBox.invoke)

        let schedRecurAction = ActionBox { [weak schedRecurPop, weak schedDayPop] in
            schedDayPop?.isEnabled = schedRecurPop?.indexOfSelectedItem == 2
        }
        schedRecurPop.target = schedRecurAction; schedRecurPop.action = #selector(ActionBox.invoke)

        av.addSubview(nameField); av.addSubview(hkLbl)
        av.addSubview(recorder);  av.addSubview(clearBtn)
        av.addSubview(primLbl);   av.addSubview(primPop)
        av.addSubview(autoChk);   av.addSubview(winChk)
        av.addSubview(schedChk);  av.addSubview(schedTimePicker)
        av.addSubview(schedRecurPop); av.addSubview(schedDayPop)
        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: av.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: av.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: av.trailingAnchor),
            hkLbl.leadingAnchor.constraint(equalTo: av.leadingAnchor),
            hkLbl.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            recorder.leadingAnchor.constraint(equalTo: hkLbl.trailingAnchor, constant: 8),
            recorder.widthAnchor.constraint(equalToConstant: 130),
            recorder.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 14),
            clearBtn.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 8),
            clearBtn.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            primLbl.leadingAnchor.constraint(equalTo: av.leadingAnchor),
            primLbl.centerYAnchor.constraint(equalTo: primPop.centerYAnchor),
            primPop.leadingAnchor.constraint(equalTo: primLbl.trailingAnchor, constant: 8),
            primPop.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 12),
            autoChk.leadingAnchor.constraint(equalTo: av.leadingAnchor),
            autoChk.topAnchor.constraint(equalTo: primPop.bottomAnchor, constant: 10),
            winChk.leadingAnchor.constraint(equalTo: av.leadingAnchor),
            winChk.trailingAnchor.constraint(equalTo: av.trailingAnchor),
            winChk.topAnchor.constraint(equalTo: autoChk.bottomAnchor, constant: 10),
            schedChk.leadingAnchor.constraint(equalTo: av.leadingAnchor),
            schedChk.topAnchor.constraint(equalTo: winChk.bottomAnchor, constant: 10),
            schedTimePicker.leadingAnchor.constraint(equalTo: av.leadingAnchor, constant: 20),
            schedTimePicker.topAnchor.constraint(equalTo: schedChk.bottomAnchor, constant: 8),
            schedRecurPop.leadingAnchor.constraint(equalTo: schedTimePicker.trailingAnchor, constant: 8),
            schedRecurPop.centerYAnchor.constraint(equalTo: schedTimePicker.centerYAnchor),
            schedDayPop.leadingAnchor.constraint(equalTo: schedRecurPop.trailingAnchor, constant: 8),
            schedDayPop.centerYAnchor.constraint(equalTo: schedTimePicker.centerYAnchor),
            av.bottomAnchor.constraint(equalTo: schedTimePicker.bottomAnchor, constant: 4),
        ])
        alert.accessoryView = av; alert.window.initialFirstResponder = nameField

        recorder.onChange = { [weak recorder] code, mods, char in
            if code == AppSettings.hotKeyCode && mods == AppSettings.hotKeyMods {
                recorder?.errorMessage = "⚠ Conflict"; recorder?.needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak recorder] in
                    recorder?.errorMessage = nil; recorder?.needsDisplay = true
                }
                return
            }
            recorder?.capturedBinding = HotkeyBinding(keyCode: code, modifiers: mods,
                                                       displayString: char)
        }
        let clearAction = ActionBox { [weak recorder] in
            recorder?.capturedBinding = nil; recorder?.needsDisplay = true
        }
        clearBtn.target = clearAction; clearBtn.action = #selector(ActionBox.invoke)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let nm = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !nm.isEmpty { SessionManager.shared.rename(id: session.id, to: nm) }
        SessionManager.shared.setHotkey(id: session.id, binding: recorder.capturedBinding)
        let primIdx = primPop.indexOfSelectedItem
        SessionManager.shared.setPrimary(id: session.id,
                                         bundleID: primIdx == 0 ? nil : session.apps[primIdx - 1].bundleID)
        SessionManager.shared.setAutoLaunch(id: session.id, enabled: autoChk.state == .on)
        let wantsCapture = winChk.state == .on && axGranted
        SessionManager.shared.setCaptureWindowState(id: session.id, enabled: wantsCapture)
        if wantsCapture {
            let snapshots = SessionManager.shared.captureWindowSnapshots(for: session.apps.map { $0.bundleID })
            SessionManager.shared.setWindowSnapshots(id: session.id, snapshots: snapshots)
        } else if winChk.state == .off {
            SessionManager.shared.setWindowSnapshots(id: session.id, snapshots: nil)
        }
        if schedChk.state == .on {
            let pickerComps = Calendar.current.dateComponents([.hour, .minute], from: schedTimePicker.dateValue)
            let recurrence: ScheduledRestore.Recurrence = [.once, .daily, .weekly][safe: schedRecurPop.indexOfSelectedItem] ?? .daily
            let wd: Int? = recurrence == .weekly ? schedDayPop.indexOfSelectedItem + 1 : nil
            let sched = ScheduledRestore(hour: pickerComps.hour ?? 9,
                                         minute: pickerComps.minute ?? 0,
                                         weekday: wd,
                                         recurrence: recurrence,
                                         lastFiredDate: session.scheduledRestore?.lastFiredDate)
            SessionManager.shared.setScheduledRestore(id: session.id, restore: sched)
        } else {
            SessionManager.shared.setScheduledRestore(id: session.id, restore: nil)
        }
        completion()
    }

    // Thin "CPU · RAM" label pinned to the right edge of the list area,
    // matching the position of memLabel in each row.
    private func makeColHeader() -> NSView {
        let view = RAMBarView()
        colRAMBarView = view
        if let stats = readRAMStats() { view.configure(stats) }
        return view
    }

    @objc func toggleSettingsPanel() {
        // Close sessions/displays first if open — only one panel at a time.
        if isShowingSessions { toggleSessionsPanel() }
        if isShowingDisplays { isShowingDisplays = false; overlayTabStrip?.selectedSegment = 0 }
        isShowingSettings.toggle()
        let showList = !isShowingSettings
        appListContainer?.isHidden  = !showList
        colHeaderView?.isHidden     = !showList
        sessionsPanelView?.isHidden = true           // never shown alongside settings
        displaysPanelView?.isHidden = true
        settingsPanelView?.isHidden = !isShowingSettings
        overlaySettingsBtn?.contentTintColor = isShowingSettings ? .controlAccentColor : dimIconColor
        if isShowingSettings {
            searchField?.window?.makeFirstResponder(nil)
            expandOverlayForSettings()
        } else {
            collapseOverlayFromSettings()
            searchField?.window?.makeFirstResponder(searchField)
        }
    }

    private func expandOverlayForSettings() {
        let style = effectiveUIStyle

        if style == .popover {
            popoverBGView?.layoutSubtreeIfNeeded()
            if let sv = settingsPanelView as? NSScrollView {
                sv.documentView?.scroll(.zero)
                sv.reflectScrolledClipView(sv.contentView)
            }
            return
        }

        if style == .notch {
            // Notch panel has a fixed size (user can drag-resize it). Don't
            // expand it for settings — just flush layout and scroll to top.
            panel?.contentView?.layoutSubtreeIfNeeded()
            if let stp = settingsPanelView as? NSScrollView {
                DispatchQueue.main.async {
                    stp.documentView?.scroll(.zero)
                    stp.reflectScrolledClipView(stp.contentView)
                }
            }
            return
        }

        // Spotlight: grow the panel downward until 20pt above the screen floor.
        guard let hc = listScrollHeightConstraint,
              let screen = NSScreen.main,
              let p = panel else { return }
        let extra = max(0, p.frame.origin.y - screen.visibleFrame.minY - 20)
        guard extra > 8 else {
            if let sv = settingsPanelView as? NSScrollView {
                sv.documentView?.scroll(.zero)
                sv.reflectScrolledClipView(sv.contentView)
            }
            return
        }

        baseListScrollHeight = hc.constant
        hc.constant += extra
        p.contentView?.layoutSubtreeIfNeeded()
        if let sv = settingsPanelView as? NSScrollView {
            sv.documentView?.scroll(.zero)
            sv.reflectScrolledClipView(sv.contentView)
        }
        var f = p.frame; f.origin.y -= extra; f.size.height += extra
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(f, display: true)
        }
    }

    private func collapseOverlayFromSettings() {
        let style = effectiveUIStyle

        if style == .popover {
            popoverBGView?.layoutSubtreeIfNeeded()
            return
        }

        if style == .notch {
            guard let hc  = listScrollHeightConstraint,
                  let phc = panelInnerHeightConstraint,
                  let p = panel,
                  let cv = p.contentView,
                  let mask = cv.layer?.mask as? CAShapeLayer else {
                panel?.contentView?.layoutSubtreeIfNeeded()
                return
            }
            let extra = hc.constant - baseListScrollHeight
            guard extra > 0 else {
                panel?.contentView?.layoutSubtreeIfNeeded()
                return
            }
            hc.constant  = baseListScrollHeight
            phc.constant = basePanelInnerHeight
            cv.layoutSubtreeIfNeeded()
            let g = makeNotchGeometry()
            var f = p.frame; f.origin.y += extra; f.size.height = p.frame.height - extra
            CATransaction.begin(); CATransaction.setDisableActions(true)
            p.setFrame(f, display: false); cv.setFrameSize(f.size)
            mask.frame = CGRect(origin: .zero, size: CGSize(width: g.W, height: g.H))
            mask.path  = notchPanelPath(t: 1, geometry: g)
            CATransaction.commit()
            cv.layoutSubtreeIfNeeded()
            return
        }

        // Spotlight: restore the panel to its original size.
        guard let hc = listScrollHeightConstraint,
              baseListScrollHeight > 0,
              hc.constant > baseListScrollHeight,
              let p = panel else { return }
        let extra = hc.constant - baseListScrollHeight
        hc.constant = baseListScrollHeight
        p.contentView?.layoutSubtreeIfNeeded()
        var f = p.frame; f.origin.y += extra; f.size.height -= extra
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(f, display: true)
        }
    }

    func resizeNotchPanel(to newExtra: CGFloat) {
        guard let p = panel,
              let cv = p.contentView,
              let mask = cv.layer?.mask as? CAShapeLayer,
              let screen = NSScreen.main else { return }
        let bezelH = max(screen.safeAreaInsets.top, 24)
        let baseContentH: CGFloat = 445
        let maxExtra = max(0, notchPanelTopY - baseContentH - bezelH - screen.frame.minY - 20)
        let clamped  = max(0, min(newExtra, maxExtra))
        AppSettings.notchExtraHeight = clamped
        let rowH: CGFloat = 46; let maxRows: CGFloat = 7; let colH: CGFloat = 22
        let g = makeNotchGeometry()
        var f = p.frame
        f.origin.y    = notchPanelTopY - g.H
        f.size.height = g.H
        CATransaction.begin(); CATransaction.setDisableActions(true)
        p.setFrame(f, display: false); cv.setFrameSize(f.size)
        CATransaction.commit()
        panelInnerHeightConstraint?.constant = baseContentH + clamped
        basePanelInnerHeight                 = baseContentH + clamped
        listScrollHeightConstraint?.constant = rowH * maxRows - colH + clamped
        baseListScrollHeight                 = rowH * maxRows - colH + clamped
        cv.layoutSubtreeIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = CGRect(origin: .zero, size: CGSize(width: g.W, height: g.H))
        mask.path  = notchPanelPath(t: 1, geometry: g)
        CATransaction.commit()
    }


    /// Switch the overlay content area to tab `index`: 0 = apps, 1 = Workflows,
    /// 2 = Displays. Generalises the old binary sessions toggle to N panels while
    /// preserving the cross-fade.
    func switchToOverlayTab(_ index: Int) {
        // Close settings first if open.
        if isShowingSettings { toggleSettingsPanel() }

        let panels: [NSView?] = [appListContainer, sessionsPanelView, displaysPanelView]
        let idx = max(0, min(panels.count - 1, index))
        isShowingSessions = (idx == 1)
        isShowingDisplays = (idx == 2)
        overlayTabStrip?.selectedSegment = idx

        if idx == 1 { refreshSessionsPanel() }
        if idx == 2 { refreshDisplaysPanel() }

        let incoming = panels[idx]
        var outgoing: [NSView?] = []
        for (i, v) in panels.enumerated() where i != idx { outgoing.append(v) }
        if idx != 0 { outgoing.append(colHeaderView) }   // column header belongs to the apps tab

        if AnimationConstants.reduceMotion {
            outgoing.forEach { $0?.isHidden = true }
            incoming?.isHidden = false
            colHeaderView?.isHidden = (idx != 0)
        } else {
            // Fade out the leaving panels, then swap and fade the arriving one in.
            let dur: TimeInterval = 0.13
            outgoing.forEach { v in
                guard let v, !v.isHidden else { return }
                v.wantsLayer = true
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = dur
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    v.animator().alphaValue = 0
                }, completionHandler: {
                    v.isHidden   = true
                    v.alphaValue = 1
                })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + dur * 0.6) { [weak self] in
                guard let self else { return }
                incoming?.alphaValue = 0
                incoming?.isHidden   = false
                incoming?.wantsLayer = true
                colHeaderView?.isHidden = (idx != 0)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = dur
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    incoming?.animator().alphaValue = 1
                }
            }
        }

        if idx == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.searchField?.window?.makeFirstResponder(self?.searchField)
            }
        } else {
            searchField?.window?.makeFirstResponder(nil)
        }
        updateHint()
    }

    /// Back-compat: toggles between the apps list and the Workflows panel. Only
    /// ever called from reset paths guarded by `isShowingSessions`.
    @objc func toggleSessionsPanel() {
        switchToOverlayTab(isShowingSessions ? 0 : 1)
    }

    @objc func overlayTabChanged(_ sender: NSSegmentedControl) {
        switchToOverlayTab(sender.selectedSegment)
    }

    @objc func sessionsSearchChanged(_ sender: NSSearchField) {
        sessionsFilterQuery = sender.stringValue
        refreshSessionsPanel()
    }

    @objc func showSessionsSortMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let opts = [
            (0, "Newest First",  "arrow.down.circle"),
            (1, "Oldest First",  "arrow.up.circle"),
            (2, "Name A–Z",      "textformat.abc"),
        ]
        for (idx, title, icon) in opts {
            let item = NSMenuItem(title: title, action: #selector(setSessionsSort(_:)), keyEquivalent: "")
            item.target = self; item.tag = idx
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            if AppSettings.sessionsSortOrder == idx { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func setSessionsSort(_ sender: NSMenuItem) {
        AppSettings.sessionsSortOrder = sender.tag
        refreshSessionsPanel()
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
        pendingSpaceRestoreSession = session

        // Try to create and switch to a new Space automatically.
        // activeSpaceDidChangeNotification will fire → activeSpaceChanged handles the rest.
        if createAndSwitchToNewSpace() { return }

        // Fallback: CGS APIs unavailable — show the manual HUD instead.
        let hud = SpaceRestoreHUD(sessionName: session.name, manualReason: true) { [weak self] in
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
        // Update indicator visibility: full-screen spaces hide the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateNotchIndicatorVisibility()
        }
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

    /// Re-register the global open-hotkey to the current AppSettings values.
    /// Returns false if registration failed (e.g. an OS-reserved combo), in which
    /// case there is no live hotkey — the caller should roll back and restore.
    @discardableResult
    func reregisterHotKey() -> Bool {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let id = EventHotKeyID(signature: fourCC("axe!"), id: 1)
        let status = RegisterEventHotKey(AppSettings.hotKeyCode, AppSettings.hotKeyMods,
                                         id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr && hotKeyRef != nil
    }

    /// Apply side-effects after Settings → "Reset to Defaults" cleared the prefs,
    /// so the live app reflects the restored values immediately.
    func didResetSettings() {
        reregisterHotKey()               // back to the default ⌘Z
        AppSettings.setLaunchAtLogin(false)
        resetNotchIndicator()            // reflect notch-indicator default (off)
        updateMenuBarIcon()              // reflect badge default
        DisplayManager.shared.resetSoftwareBrightness()   // clear per-display dims
    }

    // Called by the Carbon hot key. In spotlight mode, skip the toggle when
    // the panel is already key so ⌘A fires "select all" inside the search field.
    func hotkeyPressed(id: UInt32 = 1) {
        if id == 2 {                                   // clipboard hotkey (default ⌥⌘V)
            captureClipboardPrevApp()
            toggleClipboard()
            return
        }
        // Only suppress the toggle when the hotkey is ⌘A and spotlight is focused —
        // that lets NSTextField fire "select all" instead of closing the overlay.
        // For any other shortcut, always toggle so pressing the hotkey closes the overlay.
        if effectiveUIStyle == .spotlight,
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
        nc.addObserver(self, selector: #selector(killedAppDidTerminate(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc func workspaceChanged() {
        updateMenuBarIcon()
        updateNotchIndicator()   // always refresh count, even when overlay is hidden
        updateNotchHub()
        guard let p = panel, p.isVisible else { return }
        updateTabStripCount()
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(liveRefresh), object: nil)
        perform(#selector(liveRefresh), with: nil, afterDelay: 0.25)
        if isShowingSessions { refreshSessionsPanel() }
    }

    private func updateNotchIndicator() {
        guard let ind = notchIndicator else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let count = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .count
        ind.update(appCount: count, lastSessionName: SessionManager.shared.all.first?.name)
    }

    /// The connected display that has a hardware notch, if any. Deterministic:
    /// current Mac hardware never has two notched displays. Prefers the main
    /// screen when it is itself notched, otherwise scans all screens — so the
    /// notch is still found when the built-in display isn't the primary one
    /// (external set as main, clamshell, dragged menu bar).
    func notchScreen() -> NSScreen? {
        if let m = NSScreen.main, m.auxiliaryTopLeftArea != nil { return m }
        return NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil }
    }

    /// The UI style to actually render. Notch mode needs a notched display; on
    /// non-notch / external / clamshell setups it would drop a black bar over
    /// the menu bar, so it transparently degrades to the centered spotlight
    /// overlay. This also makes the `.notch` first-run default safe on any Mac.
    var effectiveUIStyle: UIStyle {
        let s = AppSettings.uiStyle
        return (s == .notch && notchScreen() == nil) ? .spotlight : s
    }

    func resetNotchIndicator() {
        notchIndicator?.orderOut(nil)
        notchIndicator = nil
        syncNotchIndicator()
    }

    func syncNotchIndicator() {
        // The centered hub supersedes the offset pill when both are enabled on a
        // notched display — otherwise you'd get two ⚡ indicators flanking the notch.
        let hubActive = AppSettings.notchHubEnabled && notchScreen() != nil
        if AppSettings.notchIndicatorEnabled && !hubActive {
            if notchIndicator == nil {
                // Anchor to whichever connected display actually has the notch,
                // not just the primary — so the pill still shows when the built-in
                // notched display isn't the main one.
                guard let screen = notchScreen() else { return }
                let ind = NotchIndicatorPanel(screen: screen, onRight: AppSettings.notchIndicatorOnRight)
                ind.onOpen = { [weak self] in self?.openOverlayFromIndicator() }
                notchIndicator = ind
                updateNotchIndicator()
            }
            updateNotchIndicatorVisibility()
        } else {
            notchIndicator?.orderOut(nil)
            notchIndicator = nil
        }
        syncNotchHub()
    }

    /// Create/tear down the centered notch hub (needs a notched display).
    func syncNotchHub() {
        if AppSettings.notchHubEnabled, let screen = notchScreen() {
            if notchHub == nil {
                let hub = NotchHubPanel(screen: screen)
                hub.onOpenAxe      = { [weak self] in self?.showOverlay() }
                hub.onOpenDisplays = { [weak self] in
                    self?.showOverlay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.switchToOverlayTab(2) }
                }
                hub.onOpenClipboard = { [weak self] in self?.toggleClipboard() }
                notchHub = hub
                updateNotchHub()
            }
            // Hide the hub while a full-screen app has hidden the menu bar.
            if isMenuBarHidden { notchHub?.orderOut(nil) } else { notchHub?.orderFront(nil) }
        } else {
            notchHub?.orderOut(nil)
            notchHub = nil
        }
    }

    func resetNotchHub() {
        notchHub?.orderOut(nil)
        notchHub = nil
        syncNotchHub()
    }

    private func updateNotchHub() {
        guard let hub = notchHub else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let count = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }.count
        hub.update(appCount: count)
    }

    /// Show/hide the clipboard-history panel dropping from the notch.
    func toggleClipboard() {
        if clipboardPanel == nil {
            guard let screen = notchScreen() ?? NSScreen.main else { return }
            let p = ClipboardPanel(screen: screen)
            p.onClose = { [weak self] in self?.refreshNotchHub() }
            p.onPaste = { [weak self] in self?.performAutoPaste() }
            clipboardPanel = p
        }
        if !(clipboardPanel?.isVisible ?? false) { captureClipboardPrevApp() }
        notchHub?.orderOut(nil)                 // only one notch surface at a time
        clipboardPanel?.toggle(on: notchScreen())
    }

    /// Remember the app that was frontmost so auto-paste can return focus to it.
    private func captureClipboardPrevApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { clipboardPrevApp = front }
    }

    /// Opt-in: after copy-back, return to the previous app and press ⌘V for the user.
    /// Requires Accessibility (posting keystrokes to another app); no-op otherwise.
    func performAutoPaste() {
        guard AppSettings.autoPasteEnabled, AXIsProcessTrusted(), let app = clipboardPrevApp else { return }
        if #available(macOS 14.0, *) { app.activate() }
        else { app.activate(options: [.activateIgnoringOtherApps]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true); down?.flags = .maskCommand
            let up   = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false); up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Show the notch hub only when no other notch surface (overlay / clipboard) is up.
    func refreshNotchHub() {
        guard AppSettings.notchHubEnabled, let hub = notchHub else { return }
        let busy = (panel?.isVisible ?? false) || (clipboardPanel?.isVisible ?? false) || isMenuBarHidden
        busy ? hub.orderOut(nil) : hub.orderFront(nil)
    }

    // MARK: Notch indicator visibility helpers

    /// True when the active Space has a full-screen app (menu bar is hidden).
    private var isMenuBarHidden: Bool {
        // Decide from the display the pill actually lives on (the notch screen),
        // not NSScreen.main (the keyboard-focus screen) — otherwise a full-screen
        // app on a *different* display would wrongly hide/show the pill.
        guard let screen = notchScreen() ?? NSScreen.main else { return false }
        // When a full-screen app hides the menu bar, visibleFrame extends all
        // the way to frame.maxY with no reserved space at the top.
        return screen.visibleFrame.maxY >= screen.frame.maxY - 2
    }

    /// Show or hide the indicator based on overlay state and full-screen state.
    /// Call whenever space, frontmost app, or screen geometry changes.
    func updateNotchIndicatorVisibility() {
        let overlayOpen = panel?.isVisible ?? false
        if overlayOpen { return }   // showNotch/hideOverlay own this when overlay is live
        let hidden = isMenuBarHidden
        if let ind = notchIndicator { hidden ? ind.orderOut(nil) : ind.orderFront(nil) }
        if let hub = notchHub       { hidden ? hub.orderOut(nil) : hub.orderFront(nil) }
    }

    // MARK: Screen / sleep observers

    @objc func screenParametersChanged() {
        // Display was added, removed, or reconfigured. Tear down the indicator
        // and rebuild after a short settle delay so it re-anchors to the notched
        // display (notchScreen scans all screens). If no connected display has a
        // notch, syncNotchIndicator's guard will refuse to create one.
        notchIndicator?.orderOut(nil); notchIndicator = nil
        notchHub?.orderOut(nil); notchHub = nil      // re-anchor to the new notch geometry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Rebuild even if the overlay is open: syncNotchIndicator's visibility
            // pass keeps the new pill hidden until the overlay closes, so a display
            // change mid-overlay no longer strands the indicator at nil.
            self?.syncNotchIndicator()
            DisplayManager.shared.reapplyAll()   // macOS drops gamma on display reconfig
        }
    }

    @objc func screensDidSleep() {
        notchIndicator?.orderOut(nil)
        notchHub?.orderOut(nil)
    }

    @objc func screensDidWake() {
        // Give the display driver time to settle before re-anchoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.notchIndicator?.orderOut(nil); self.notchIndicator = nil
            self.notchHub?.orderOut(nil); self.notchHub = nil
            self.syncNotchIndicator()   // rebuild even if the overlay is open (see above)
            DisplayManager.shared.reapplyAll()   // macOS drops gamma on wake
        }
    }

    // MARK: Scheduled restores

    func startScheduleTimer() {
        checkScheduledRestores()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkScheduledRestores()
        }
        RunLoop.main.add(t, forMode: .common)
        scheduleTimer = t
    }

    func checkScheduledRestores() {
        let now = Date()
        var sessions = SessionManager.shared.all
        var changed = false
        // The Space-switch path routes through a single pendingSpaceRestoreSession
        // slot that activeSpaceChanged consumes asynchronously, so only one can be
        // in flight per tick. If several are due at once, handle one and leave the
        // rest untouched so they fire on the next tick — never silently dropped.
        var didSpaceSwitch = false
        for i in sessions.indices {
            guard var sched = sessions[i].scheduledRestore else { continue }
            let reference = sched.lastFiredDate ?? Date.distantPast
            guard let next = sched.nextFireDate(after: reference), next <= now else { continue }
            if didSpaceSwitch { continue }   // defer to next tick; don't advance its schedule

            // Restore on a new Space without showing the confirmation alert
            pendingSpaceRestoreSession = sessions[i]
            if createAndSwitchToNewSpace() {
                didSpaceSwitch = true
            } else {
                // CGS API unavailable — fall back to restoring on current space
                pendingSpaceRestoreSession = nil
                SessionManager.shared.restore(sessions[i])
            }

            if sched.recurrence == .once {
                sessions[i].scheduledRestore = nil
            } else {
                sched.lastFiredDate = now
                sessions[i].scheduledRestore = sched
            }
            changed = true
        }
        if changed {
            SessionManager.shared.all = sessions
            if isShowingSessions { refreshSessionsPanel() }
        }
    }

    @objc func frontmostAppChanged() {
        // A full-screen app may have just become frontmost (or resigned).
        // Give the Space transition a tick to settle then update visibility.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateNotchIndicatorVisibility()
        }
    }

    func openOverlayFromIndicator() {
        toggleOverlay()
        // After the panel has appeared, watch for the mouse leaving the overlay area
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.installNotchHoverMonitor()
        }
    }

    private func installNotchHoverMonitor() {
        guard notchHoverMonitor == nil else { return }
        // Use Timer(…) + RunLoop.main.add(.common) so the timer fires even while
        // AppKit is in .eventTracking mode (which happens during mouse interaction).
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, let p = self.panel, p.isVisible else { t.invalidate(); return }
            let mouse = NSEvent.mouseLocation
            let overlayZone  = p.frame.insetBy(dx: -8, dy: -8)
            let indicatorZone = self.notchIndicator?.frame ?? .zero
            if !overlayZone.contains(mouse) && !indicatorZone.contains(mouse) {
                t.invalidate()
                self.notchHoverMonitor = nil
                self.hideOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        notchHoverMonitor = timer
    }

    func removeNotchHoverMonitor() {
        (notchHoverMonitor as? Timer)?.invalidate()
        notchHoverMonitor = nil
    }

    @objc func killedAppDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              pendingKillPIDs.remove(app.processIdentifier) != nil else { return }
        // The app we killed has fully quit. Re-activate the panel so the focus-loss
        // from its window-cleanup (which suppressed panelResignedKey) is healed.
        guard let p = panel, p.isVisible else { return }
        if !p.isKeyWindow { p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    @objc func liveRefresh() {
        let query = searchField?.stringValue ?? ""
        refreshApps()
        applyFilter(query)
    }

    // Updates stats for each visible row and the system RAM bar — no table reload, no flicker.
    func refreshCPUInPlace() {
        guard let tv = tableView else { return }
        let visible = tv.rows(in: tv.visibleRect)
        for row in visible.location ..< (visible.location + visible.length) {
            guard let e = appEntry(atRow: row) else { continue }
            let pid = e.app.processIdentifier
            guard let cell = tv.view(atColumn: 0, row: row, makeIfNecessary: false) as? AppRowCell
            else { continue }
            let cpu = CPUSampler.shared.sample(pid)
            let mem = residentMB(for: pid)
            cell.statsView.configure(cpu: cpu, mem: mem, animated: true)
        }
        if let stats = readRAMStats() { colRAMBarView?.configure(stats) }
    }

    // MARK: Overlay lifecycle

    @objc func toggleOverlay() {
        DispatchQueue.main.async {
            if self.isOverlayVisible { self.hideOverlay() } else { self.showOverlay() }
        }
    }

    var isOverlayVisible: Bool {
        switch effectiveUIStyle {
        case .spotlight: return panel?.isVisible ?? false
        case .popover:   return popover?.isShown  ?? false
        case .notch:     return panel?.isVisible ?? false   // shares the spotlight panel
        }
    }

    // Tear down the built overlay so it's rebuilt fresh (called when style changes).
    func teardownOverlay() {
        panel?.orderOut(nil); panel = nil
        popover?.close();     popover = nil; popoverVC = nil; popoverBGView = nil
        searchField = nil; tableView = nil; emptyView = nil
        hintLabel = nil; sortButton = nil; axeCheckedButton = nil; halfAxeButton = nil
        overlayTabStrip = nil; appListContainer = nil
        sessionsPanelView = nil; sessionsListStack = nil; sessionsSearchField = nil
        sessionsFilterQuery = ""
        displaysPanelView = nil; displaysListStack = nil
        settingsPanelView = nil; overlaySettingsBtn = nil; colHeaderView = nil
        listScrollHeightConstraint = nil; baseListScrollHeight = 0
        panelInnerHeightConstraint = nil; basePanelInnerHeight = 0
        notchPanelTopY = 0
        isShowingSessions = false; isShowingSettings = false; isShowingDisplays = false
        lastBuiltStyle = nil
        // Hide indicator when leaving notch mode (it only lives in notch mode)
        notchIndicator?.orderOut(nil); notchIndicator = nil
    }

    func showOverlay() {
        // Only one notch surface at a time — tuck the hub/clipboard away while the
        // main overlay is up (avoids two overlapping dropdowns at the notch).
        notchHub?.orderOut(nil)
        clipboardPanel?.dismissPanel()
        // Rebuild if the user switched styles since last open (compare against the
        // effective style so a notch→spotlight downgrade on non-notch hardware
        // doesn't force a teardown on every open).
        if let built = lastBuiltStyle, built != effectiveUIStyle { teardownOverlay() }

        checkedPIDs.removeAll()
        // Drop any kill PIDs left pending from a previous session (e.g. an app that
        // refused to quit) so a stale entry can't permanently block click-outside
        // auto-dismiss on this fresh open.
        pendingKillPIDs.removeAll()
        stopPhraseCycling()
        currentKillPhrase = ""
        isShowingSessions = false; isShowingSettings = false; isShowingDisplays = false
        condemningLabel = choppingBlockNames.randomElement() ?? "Axe"
        overlayTabStrip?.setLabel(condemningLabel, forSegment: 0)
        overlayTabStrip?.selectedSegment = 0
        updateTabStripCount()
        // Sync view visibility to match the reset state — overlay may have been
        // dismissed while sessions or settings was open, leaving views in the
        // wrong hidden state.
        settingsPanelView?.isHidden  = true
        colHeaderView?.isHidden      = false
        appListContainer?.isHidden   = false
        sessionsPanelView?.isHidden  = true
        displaysPanelView?.isHidden  = true
        // Reset any settings-expansion from previous session before showing.
        listScrollHeightConstraint?.constant = baseListScrollHeight
        panelInnerHeightConstraint?.constant = basePanelInnerHeight
        // Restore the popover to its base size — it may have been left at an expanded
        // height from a previous settings session that was dismissed without collapsing.
        if let vc = popoverVC, let bg = popoverBGView, baseListScrollHeight > 0 {
            let searchH: CGFloat = 50; let colH: CGFloat = 22; let hintH: CGFloat = 34
            let baseH = searchH + 1 + 33 + (baseListScrollHeight + colH) + 1 + hintH
            let sz = NSSize(width: bg.frame.width, height: baseH)
            vc.preferredContentSize = sz
            bg.setFrameSize(sz)
        }
        refreshApps()
        cpuRefreshTimer?.invalidate()
        cpuRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshCPUInPlace()
        }

        switch effectiveUIStyle {
        case .spotlight: showSpotlight()
        case .popover:   showPopover()
        case .notch:     showNotch()
        }

        searchField?.stringValue = ""
        applyFilter("")
        DispatchQueue.main.async { [weak self] in
            guard let sf = self?.searchField else { return }
            sf.window?.makeFirstResponder(sf)
        }
    }

    // MARK: Spotlight mode

    // MARK: Entrance / dismiss helpers (shared by spotlight + notch)

    /// Spring-driven entrance: scale `panelShowScaleFrom`→1.0 and opacity 0→1.
    /// Falls back to a 0.08s opacity-only crossfade when Reduce Motion is on.
    private func applyEntrance(to layer: CALayer) {
        if AnimationConstants.reduceMotion {
            let op = AnimationConstants.opacityAnimation(
                from: 0, to: 1, duration: AnimationConstants.reducedDuration)
            layer.add(op, forKey: "opacity")
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            return
        }
        let dur   = AnimationConstants.panelShowDuration
        let stiff = AnimationConstants.springStiffness
        let damp  = AnimationConstants.springDamping

        let op = CASpringAnimation(keyPath: "opacity")
        op.fromValue = 0; op.toValue = 1
        op.damping = damp; op.stiffness = stiff; op.mass = 1
        op.duration = dur
        op.fillMode = .forwards; op.isRemovedOnCompletion = false
        layer.add(op, forKey: "opacity")
        layer.opacity = 1

        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = AnimationConstants.panelShowScaleFrom; s.toValue = 1.0
        s.damping = damp; s.stiffness = stiff; s.mass = 1
        s.duration = dur
        s.fillMode = .forwards; s.isRemovedOnCompletion = false
        layer.add(s, forKey: "scale")
        layer.transform = CATransform3DIdentity
    }

    /// Mirror of `applyEntrance` — quick ease-out fade + slight scale down.
    private func applyDismiss(to layer: CALayer, completion: @escaping () -> Void) {
        let dur = AnimationConstants.reduceMotion
            ? AnimationConstants.reducedDuration
            : AnimationConstants.panelDismissDuration

        let op = AnimationConstants.opacityAnimation(from: 1, to: 0, duration: dur)
        layer.add(op, forKey: "opacity")
        layer.opacity = 0

        if !AnimationConstants.reduceMotion {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1.0
            s.toValue   = AnimationConstants.panelShowScaleFrom
            s.duration  = dur
            s.timingFunction = CAMediaTimingFunction(name: .easeOut)
            s.fillMode = .forwards; s.isRemovedOnCompletion = false
            layer.add(s, forKey: "scale")
            layer.transform = CATransform3DMakeScale(
                AnimationConstants.panelShowScaleFrom,
                AnimationConstants.panelShowScaleFrom, 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.02) { completion() }
    }

    /// Animates the notch overlay mask path between t=0 (notch shape) and
    /// t=1 (full tapered panel) — same timing curve as the spring entrance.
    private func animateNotchMask(_ mask: CAShapeLayer, to targetT: CGFloat,
                                  duration: CFTimeInterval,
                                  geometry g: NotchGeometry) {
        let endPath = notchPanelPath(t: targetT, geometry: g)
        if AnimationConstants.reduceMotion {
            mask.path = endPath
            return
        }
        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = mask.path
        anim.toValue   = endPath
        anim.duration  = duration
        // Bezier approximating the (response 0.32, damping 0.82) spring shape.
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.94, 0.6, 1.0)
        anim.fillMode = .forwards; anim.isRemovedOnCompletion = false
        mask.add(anim, forKey: targetT > 0.5 ? "grow" : "shrink")
        mask.path = endPath
    }

    private func showSpotlight() {
        if panel == nil { buildPanel(); lastBuiltStyle = .spotlight }

        // If settings had expanded the panel and the overlay was dismissed without
        // collapsing (e.g. click-outside while settings was open), the panel frame
        // stays at the expanded height. Snap it back before showing so the layout
        // starts from a known-good size.
        if let p = panel, baseListScrollHeight > 0 {
            let colH: CGFloat = 22; let searchH: CGFloat = 54; let hintH: CGFloat = 34
            let baseH = baseListScrollHeight + colH + 33 + searchH + 1 + 1 + hintH
            if p.frame.size.height > baseH + 1 {
                var f = p.frame
                f.origin.y += f.size.height - baseH
                f.size.height = baseH
                p.setFrame(f, display: false)
                listScrollHeightConstraint?.constant = baseListScrollHeight
                p.contentView?.layoutSubtreeIfNeeded()
            }
        }

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let pw = panel!.frame
            panel?.setFrameOrigin(NSPoint(
                x: sf.midX - pw.width  / 2,
                y: sf.midY - pw.height / 2 + sf.height * 0.08))
        }

        guard let p = panel, let cv = p.contentView else { return }
        cv.wantsLayer = true

        // Reset content-layer state synchronously — no implicit animation flicker.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cv.layer?.opacity   = 0
        cv.layer?.transform = CATransform3DMakeScale(
            AnimationConstants.panelShowScaleFrom,
            AnimationConstants.panelShowScaleFrom, 1)
        CATransaction.commit()

        p.alphaValue = 1                          // window visible; layer drives opacity
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let layer = cv.layer { applyEntrance(to: layer) }

        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    // MARK: Notch mode  (drops from the notch / top of screen, slides back up)

    private func showNotch() {
        // Only reached when effectiveUIStyle == .notch, i.e. a notched display
        // exists; anchor to it (not NSScreen.main) so the pill and the overlay
        // always land on the same screen.
        if panel == nil { buildPanel(); lastBuiltStyle = .notch }
        guard let screen = notchScreen() ?? NSScreen.main, let p = panel else { return }

        // Create or tear down the persistent indicator based on current setting
        if AppSettings.notchIndicatorEnabled, notchIndicator == nil {
            let ind = NotchIndicatorPanel(screen: screen, onRight: AppSettings.notchIndicatorOnRight)
            ind.onOpen = { [weak self] in self?.openOverlayFromIndicator() }
            notchIndicator = ind
            updateNotchIndicator()
        } else if !AppSettings.notchIndicatorEnabled {
            notchIndicator?.orderOut(nil); notchIndicator = nil
        }
        // Hide indicator while the full overlay is open (it sits underneath)
        notchIndicator?.orderOut(nil)
        let g = makeNotchGeometry()

        // Push the panel a few pixels ABOVE screen.maxY so its rendered top
        // edge sits offscreen behind the bezel — the visible top of the
        // panel becomes the screen edge itself, with no 1pt boundary line
        // showing where panel meets bezel. The OverlayPanel subclass
        // overrides constrainFrameRect so AppKit doesn't clamp it back.
        let xc = screen.frame.midX - g.W / 2
        let topOverlap: CGFloat = 6
        let endFrame = NSRect(x: xc,
                              y: screen.frame.maxY + topOverlap - g.H,
                              width: g.W, height: g.H)
        p.setFrame(endFrame, display: false)
        notchPanelTopY = endFrame.maxY   // anchor; used by resizeNotchPanel
        guard let cv = p.contentView,
              let layer = cv.layer,
              let mask = layer.mask as? CAShapeLayer else {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Reset state synchronously — collapse the mask back to the small
        // notch shape (t=0) and the layer to scale 0.98 / opacity 0 before
        // the panel becomes visible. No implicit animations on this step.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Snap mask back to base geometry in case settings had expanded it.
        mask.frame      = CGRect(origin: .zero, size: CGSize(width: g.W, height: g.H))
        mask.path       = notchPanelPath(t: 0, geometry: g)
        layer.opacity   = 0
        layer.transform = CATransform3DMakeScale(
            AnimationConstants.panelShowScaleFrom,
            AnimationConstants.panelShowScaleFrom, 1)
        CATransaction.commit()

        // Keep window invisible until the pre-animation CA state is flushed
        // to the render server — prevents the one-frame flash of the full panel.
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Guarantee t=0 mask / opacity 0 / scale 0.98 are committed before
        // any frame composites, then reveal the window so the layer drives
        // the visible fade (layer opacity is 0, so nothing renders yet).
        CATransaction.flush()
        p.alphaValue = 1

        // Mask grows from the small notch shape outward to the full panel
        // shape, in parallel with the spring scale+opacity entrance.
        animateNotchMask(mask, to: 1,
                         duration: AnimationConstants.panelShowDuration,
                         geometry: g)
        applyEntrance(to: layer)

        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: p)
    }

    // MARK: Popover mode

    private func showPopover() {
        if popover == nil { buildPopover(); lastBuiltStyle = .popover }
        guard let btn = statusItem.button else { return }
        popover?.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideOverlay() {
        cpuRefreshTimer?.invalidate()
        cpuRefreshTimer = nil
        // Bring the notch hub back once the overlay has faded out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshNotchHub() }
        switch lastBuiltStyle ?? effectiveUIStyle {
        case .spotlight:
            NotificationCenter.default.removeObserver(self,
                name: NSWindow.didResignKeyNotification, object: panel)
            guard let cv = panel?.contentView, let layer = cv.layer else {
                panel?.orderOut(nil); return
            }
            applyDismiss(to: layer) { [weak self] in
                self?.panel?.orderOut(nil)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
            }

        case .popover:
            popover?.close()

        case .notch:
            NotificationCenter.default.removeObserver(self,
                name: NSWindow.didResignKeyNotification, object: panel)
            guard let cv = panel?.contentView,
                  let layer = cv.layer,
                  let mask = layer.mask as? CAShapeLayer else {
                panel?.orderOut(nil); return
            }
            // Mirror of entrance: mask shrinks back to the notch shape while
            // the layer fades + scales down. ~0.18s ease-out.
            let g = makeNotchGeometry()
            // If settings had expanded the panel, snap back to base geometry
            // immediately so the collapse animation starts from the right shape.
            if mask.frame.height > g.H + 1, let p = panel, let cv = p.contentView {
                var f = p.frame; f.origin.y = f.maxY - g.H; f.size.height = g.H
                CATransaction.begin(); CATransaction.setDisableActions(true)
                p.setFrame(f, display: false)
                cv.setFrameSize(f.size)
                mask.frame = CGRect(origin: .zero, size: CGSize(width: g.W, height: g.H))
                mask.path  = notchPanelPath(t: 1, geometry: g)
                CATransaction.commit()
                listScrollHeightConstraint?.constant = baseListScrollHeight
                panelInnerHeightConstraint?.constant = basePanelInnerHeight
                cv.layoutSubtreeIfNeeded()
            }
            animateNotchMask(mask, to: 0,
                             duration: AnimationConstants.panelDismissDuration,
                             geometry: g)
            applyDismiss(to: layer) { [weak self] in
                self?.panel?.orderOut(nil)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                // Restore the persistent notch indicator now that the overlay is gone
                self?.updateNotchIndicator()
                self?.notchIndicator?.orderFront(nil)
                self?.removeNotchHoverMonitor()
            }
        }
    }

    @objc func panelResignedKey() {
        // Don't dismiss if a child window (settings) or a sheet (confirm dialog) is open.
        // beginSheetModal makes the sheet key, not the panel, so isKeyWindow goes false —
        // checking attachedSheet prevents the overlay from vanishing mid-confirmation.
        // Also don't dismiss while we're waiting for a killed app's window-cleanup to finish
        // (some apps like iTerm take longer than 50ms to settle focus after terminate()).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let p = self.panel, p.isVisible,
                  !p.isKeyWindow, p.attachedSheet == nil,
                  self.pendingKillPIDs.isEmpty else { return }
            self.hideOverlay()
        }
    }

    // MARK: Build overlay panel

    /// Resolved geometry for the notch overlay. Cached values shared by build,
    /// show, and hide animations so the start/end paths line up exactly.
    struct NotchGeometry {
        let W: CGFloat            // outer layer width
        let H: CGFloat            // outer layer height
        let W_inner: CGFloat      // inner content width
        let sideInset: CGFloat    // shoulder width on each side
        let taperH: CGFloat       // shoulder height
        let bezelH: CGFloat       // bezel/menu-bar coverage at top
        let bottomR: CGFloat      // body bottom corner radius
        let notchW: CGFloat       // hardware notch approximate width
        let notchCornerR: CGFloat // hardware notch bottom-corner radius
    }

    func makeNotchGeometry() -> NotchGeometry {
        // Panel covers the menu bar in its central width (W_inner) so the
        // bezel + notch + panel read as one continuous black surface. The
        // top `bezelH` of the panel is empty black space covering the menu
        // bar; the lower `contentH` holds the search bar / list / buttons.
        let W_inner: CGFloat = 560
        let contentH: CGFloat = 445 + AppSettings.notchExtraHeight
        // Read the bezel inset from the notched display the panel anchors to, not
        // NSScreen.main (which may be an external, non-notch display).
        let bezelH = max((notchScreen()?.safeAreaInsets.top) ?? 24, 24)
        return NotchGeometry(
            W: W_inner,
            H: contentH + bezelH,    // taller, so the top region covers the menu bar
            W_inner: W_inner,
            sideInset: 0,
            taperH: 0,
            bezelH: bezelH,
            bottomR: 22,
            notchW: 200,
            notchCornerR: 22
        )
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    /// Parametric notch path. At t=0 the shape is a small rect matching the
    /// hardware notch (centered at the top); at t=1 it's the full panel —
    /// flat top corners (sit behind the bezel) and rounded bottom corners.
    /// Topology stays constant (1 move + 3 lines + 1 arc + 2 lines + 1 arc +
    /// close) so CABasicAnimation can interpolate smoothly between any two t.
    private func notchPanelPath(t: CGFloat, geometry g: NotchGeometry) -> CGPath {
        let tt = max(0, min(1, t))
        let outerW  = lerp(g.notchW, g.W, tt)
        let outerH  = lerp(g.bezelH, g.H, tt)
        let bottomR = lerp(0, g.bottomR, tt)

        let xc = g.W / 2
        let left    = xc - outerW / 2
        let right   = xc + outerW / 2
        let bottomY = g.H - outerH    // bottom of shape
        let topY    = g.H             // top of layer (behind bezel)

        let path = CGMutablePath()
        // 1. Bottom-left, after rounded corner
        path.move(to: CGPoint(x: left + bottomR, y: bottomY))
        // 2. Bottom edge
        path.addLine(to: CGPoint(x: right - bottomR, y: bottomY))
        // 3. Bottom-right rounded corner (CCW, 6 → 3 o'clock)
        path.addArc(center: CGPoint(x: right - bottomR, y: bottomY + bottomR),
                    radius: bottomR, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        // 4. Right side straight up (top corner is flat, sits behind bezel)
        path.addLine(to: CGPoint(x: right, y: topY))
        // 5. Top edge (hidden by actual bezel)
        path.addLine(to: CGPoint(x: left, y: topY))
        // 6. Left side straight down to bottom corner
        path.addLine(to: CGPoint(x: left, y: bottomY + bottomR))
        // 7. Bottom-left rounded corner (CCW, 9 → 6 o'clock)
        path.addArc(center: CGPoint(x: left + bottomR, y: bottomY + bottomR),
                    radius: bottomR, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    func buildPanel() {
        let isNotch = effectiveUIStyle == .notch
        let searchH: CGFloat = 54
        let rowH: CGFloat    = 46
        let maxRows: CGFloat = 7
        let hintH: CGFloat   = 34
        let contentH = searchH + 1 + 33 + rowH * maxRows + 1 + hintH  // 445 (33 = tab strip 32 + divider 1)
        let notchExtra: CGFloat = isNotch ? AppSettings.notchExtraHeight : 0

        // Inner content width. Outer is wider in notch mode for the shoulders.
        // In notch mode we use the shared `makeNotchGeometry()` so show/hide
        // animations resolve to the exact same dimensions.
        let geo = isNotch ? makeNotchGeometry() : nil
        let W_inner: CGFloat   = geo?.W_inner   ?? 620
        let W: CGFloat         = geo?.W         ?? W_inner
        let H: CGFloat         = geo?.H         ?? contentH

        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility             = .hidden
        p.titlebarAppearsTransparent  = true
        p.isMovable               = !isNotch   // notch is anchored; spotlight is freely draggable
        p.isMovableByWindowBackground = !isNotch
        // .popUpMenu in notch mode so we draw over the menu bar + status items;
        // .floating otherwise so the spotlight overlay sits above normal windows
        // but below the menu bar.
        // Notch mode draws OVER the menu bar in its central width so the
        // bezel + menu bar + panel read as one continuous black surface.
        // Other styles stay at .floating (below menu bar).
        p.level              = isNotch ? .popUpMenu : .floating
        // Join every Space (incl. other apps' full-screen Spaces) so ⌘Z opens the
        // overlay in place instead of yanking the user out of a full-screen app.
        // Without this, an accessory app's panel forces a Space switch to the desktop.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.backgroundColor    = .clear

        let bg: NSView
        if isNotch {
            // Outer black view positioned at screen.maxY (covers the menu bar
            // in the central W_inner band). Shape is driven by a CAShapeLayer
            // mask — flat top corners (sit behind bezel) and rounded bottom
            // corners at t=1; at t=0 the mask collapses to the small hardware
            // notch shape so `showNotch` can animate it expanding outward.
            let outer = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
            outer.wantsLayer = true
            outer.layer?.backgroundColor = NSColor.clear.cgColor   // skin fill provides the bg; mask shapes it
            outer.appearance = NSAppearance(named: .darkAqua)
            let mask = CAShapeLayer()
            mask.frame = outer.bounds
            mask.path  = notchPanelPath(t: 0, geometry: geo!)
            outer.layer?.mask = mask
            p.contentView = outer

            // Skin background (Classic black / Liquid Glass frost), clipped by the
            // notch mask along with everything else, so it morphs on show/collapse.
            let skinFill = AppSettings.notchSkin.makeHubBackground(cornerRadius: 0, corners: [])
            skinFill.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(skinFill)
            NSLayoutConstraint.activate([
                skinFill.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                skinFill.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
                skinFill.topAnchor.constraint(equalTo: outer.topAnchor),
                skinFill.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
            ])

            let inner = NSView()
            inner.wantsLayer = true
            inner.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(inner)
            let innerHC = inner.heightAnchor.constraint(equalToConstant: contentH + notchExtra)
            panelInnerHeightConstraint = innerHC
            basePanelInnerHeight = contentH + notchExtra
            NSLayoutConstraint.activate([
                inner.centerXAnchor.constraint(equalTo: outer.centerXAnchor),
                inner.widthAnchor.constraint(equalToConstant: W_inner),
                inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
                innerHC,
            ])

            let handle = NotchResizeHandle()
            handle.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(handle)
            NSLayoutConstraint.activate([
                handle.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
                handle.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                handle.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
                handle.heightAnchor.constraint(equalToConstant: 8),
            ])
            handle.onResize = { [weak self] newExtra in self?.resizeNotchPanel(to: newExtra) }

            bg = inner
        } else {
            let v = OverlayBGView(frame: NSRect(x: 0, y: 0, width: W, height: H))
            v.blendingMode = .behindWindow
            v.material     = .sidebar
            v.state        = .active
            v.wantsLayer   = true
            v.layer?.cornerRadius  = 20
            v.layer?.masksToBounds = true
            p.contentView = v
            bg = v
        }

        // ── Search bar ─────────────────────────────────────────────
        let searchIcon = NSImageView()
        if let sym = NSImage(systemSymbolName: "magnifyingglass",
                             accessibilityDescription: nil) {
            searchIcon.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        }
        searchIcon.contentTintColor = dimIconColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(searchIcon)

        let sortBtn = NSButton()
        sortBtn.isBordered = false
        if let sym = NSImage(systemSymbolName: "arrow.up.arrow.down",
                             accessibilityDescription: "Sort") {
            sortBtn.image = sym.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        sortBtn.contentTintColor = sortByMemory ? .controlAccentColor : dimIconColor
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
            sortBtn.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            sortBtn.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sortBtn.widthAnchor.constraint(equalToConstant: 26),
            sortBtn.heightAnchor.constraint(equalToConstant: 26),
            sf.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            sf.trailingAnchor.constraint(equalTo: sortBtn.leadingAnchor, constant: -6),
            // Center on the icon at the field's natural line height — an editable
            // NSTextField top-aligns its text inside a tall frame, which made the
            // text sit high near the rounded corner. Letting it use intrinsic
            // height + centerY keeps the text vertically centered in the bar.
            sf.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
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

        // ── Tab strip (Axe / Sessions) ─────────────────────────────
        let tabStripH: CGFloat = 32   // strip height; tabDiv adds 1 more pt below
        let tabs = NSSegmentedControl(labels: ["Axe", "Workflows", "Displays"],
                                      trackingMode: .selectOne,
                                      target: self,
                                      action: #selector(overlayTabChanged(_:)))
        tabs.selectedSegment = 0
        tabs.controlSize = .regular
        tabs.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(tabs)
        overlayTabStrip = tabs

        let tabDiv = divider()
        tabDiv.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(tabDiv)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topDiv.bottomAnchor, constant: 5),
            tabs.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            tabs.widthAnchor.constraint(equalToConstant: 280),
            tabDiv.topAnchor.constraint(equalTo: topDiv.bottomAnchor, constant: tabStripH),
            tabDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            tabDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            tabDiv.heightAnchor.constraint(equalToConstant: 1),
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
        tv.style = .sourceList
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.minWidth = 100; col.maxWidth = 10_000; col.width = 1   // AutoFitTableView corrects on first layout
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

        // ── Displays panel (hidden until the Displays tab is selected) ─
        let dp = buildDisplaysPanel()
        dp.isHidden = true
        dp.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(dp)
        displaysPanelView = dp

        // ── Empty state ────────────────────────────────────────────
        let ev = EmptyStateView()
        ev.translatesAutoresizingMaskIntoConstraints = false
        ev.isHidden = true
        bg.addSubview(ev)
        emptyView = ev

        // ── Column header ──────────────────────────────────────────
        let colH: CGFloat = 22
        let ch = makeColHeader()
        ch.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(ch)
        colHeaderView = ch

        // ── Inline settings panel ──────────────────────────────────
        let stp = settingsWindow.buildSettingsScrollView()
        stp.isHidden = true
        stp.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stp)
        settingsPanelView = stp

        let svHC = sv.heightAnchor.constraint(equalToConstant: rowH * maxRows - colH + notchExtra)
        listScrollHeightConstraint = svHC
        baseListScrollHeight = rowH * maxRows - colH + notchExtra
        NSLayoutConstraint.activate([
            ch.topAnchor.constraint(equalTo: tabDiv.bottomAnchor),
            ch.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            ch.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            ch.heightAnchor.constraint(equalToConstant: colH),
            sv.topAnchor.constraint(equalTo: ch.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            svHC,
            ev.topAnchor.constraint(equalTo: sv.topAnchor),
            ev.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: sv.trailingAnchor),
            ev.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
            sp.topAnchor.constraint(equalTo: tabDiv.bottomAnchor),
            sp.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sp.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sp.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
            dp.topAnchor.constraint(equalTo: tabDiv.bottomAnchor),
            dp.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            dp.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            dp.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
            stp.topAnchor.constraint(equalTo: tabDiv.bottomAnchor),
            stp.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stp.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stp.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
        ])

        // ── Bottom divider + hint bar ──────────────────────────────
        let botDiv = divider()
        bg.addSubview(botDiv)

        let hint = NSTextField(labelWithString: "")
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hint)
        hintLabel = hint

        // Action buttons — shown in place of the hint text when boxes are checked.
        // Purple "Half-Axe It" (hide) on the left, red kill button on the right,
        // centered as a pair straddling the bar's centerline.
        let halfAxeBtn = makeHalfAxeButton()
        bg.addSubview(halfAxeBtn)
        halfAxeButton = halfAxeBtn

        let axeBtn = RedButton()
        axeBtn.isBordered = false
        axeBtn.wantsLayer = true
        axeBtn.target  = self
        axeBtn.action  = #selector(axeCheckedApps)
        axeBtn.isHidden = true
        (axeBtn.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        axeBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(axeBtn)
        axeCheckedButton = axeBtn

        // Save + Settings + About icon buttons (trailing edge of hint bar)
        let saveBtn     = makeHintIconButton(symbolName: "tray.and.arrow.down", action: #selector(saveSessionMI))
        saveBtn.toolTip = "Save current workflow (⌘⇧L)"
        let settingsBtn = makeHintIconButton(symbolName: "gear", action: #selector(openStandaloneSettings))
        let aboutBtn    = makeHintIconButton(symbolName: "info.circle", action: #selector(showAbout))
        // Override the default tertiary tint so the icons stay readable on
        // the pure-black notch background.
        saveBtn.contentTintColor     = dimIconColor
        settingsBtn.contentTintColor = dimIconColor
        aboutBtn.contentTintColor    = dimIconColor
        overlaySettingsBtn = settingsBtn
        bg.addSubview(saveBtn)
        bg.addSubview(settingsBtn)
        bg.addSubview(aboutBtn)

        NSLayoutConstraint.activate([
            botDiv.topAnchor.constraint(equalTo: sv.bottomAnchor),
            botDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            botDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            botDiv.heightAnchor.constraint(equalToConstant: 1),
            hint.topAnchor.constraint(equalTo: botDiv.bottomAnchor),
            hint.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -4),
            hint.heightAnchor.constraint(equalToConstant: hintH),
            halfAxeBtn.trailingAnchor.constraint(equalTo: bg.centerXAnchor, constant: -5),
            halfAxeBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            halfAxeBtn.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 16),
            axeBtn.leadingAnchor.constraint(equalTo: bg.centerXAnchor, constant: 5),
            axeBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            axeBtn.trailingAnchor.constraint(lessThanOrEqualTo: saveBtn.leadingAnchor, constant: -6),
            // Save-session button
            saveBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            saveBtn.trailingAnchor.constraint(equalTo: settingsBtn.leadingAnchor, constant: -1),
            saveBtn.widthAnchor.constraint(equalToConstant: 24),
            saveBtn.heightAnchor.constraint(equalToConstant: 24),
            // Settings button
            settingsBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            settingsBtn.trailingAnchor.constraint(equalTo: aboutBtn.leadingAnchor, constant: -1),
            settingsBtn.widthAnchor.constraint(equalToConstant: 24),
            settingsBtn.heightAnchor.constraint(equalToConstant: 24),
            // About button
            aboutBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            aboutBtn.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            aboutBtn.widthAnchor.constraint(equalToConstant: 24),
            aboutBtn.heightAnchor.constraint(equalToConstant: 24),
        ])

        panel = p
        updateHint()
    }

    /// Purple "Half-Axe It" button used in both overlay styles.
    private func makeHalfAxeButton() -> RedButton {
        let b = RedButton()
        b.fillColor   = .systemPurple
        b.isBordered  = false
        b.wantsLayer  = true
        b.target      = self
        b.action      = #selector(halfAxeCheckedApps)
        b.isHidden    = true
        b.toolTip     = "Hide the selected apps instead of quitting them"
        (b.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    // MARK: Build popover

    private func buildPopover() {
        let W: CGFloat       = 420
        let searchH: CGFloat = 50
        let rowH: CGFloat    = 46
        let maxRows: CGFloat = 8
        let hintH: CGFloat   = 34
        let H = searchH + 1 + 33 + rowH * maxRows + 1 + hintH  // 33 = tab strip 32 + divider 1

        let vc = NSViewController()
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        vc.view = bg
        vc.preferredContentSize = NSSize(width: W, height: H)
        popoverVC = vc
        popoverBGView = bg

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

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            searchIcon.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            sortBtn.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            sortBtn.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: searchH / 2),
            sortBtn.widthAnchor.constraint(equalToConstant: 26),
            sortBtn.heightAnchor.constraint(equalToConstant: 26),
            sf.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            sf.trailingAnchor.constraint(equalTo: sortBtn.leadingAnchor, constant: -4),
            // Center on the icon at the field's natural line height (see spotlight
            // build): a tall fixed height top-aligns the text and pushes it up
            // against the rounded top corner.
            sf.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
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

        // ── Tab strip (Axe / Sessions) ─────────────────────────────
        let tabStripH2: CGFloat = 32
        let tabs2 = NSSegmentedControl(labels: ["Axe", "Workflows", "Displays"],
                                       trackingMode: .selectOne,
                                       target: self,
                                       action: #selector(overlayTabChanged(_:)))
        tabs2.selectedSegment = 0
        tabs2.controlSize = .regular
        tabs2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(tabs2)
        overlayTabStrip = tabs2

        let tabDiv2 = divider()
        tabDiv2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(tabDiv2)
        NSLayoutConstraint.activate([
            tabs2.topAnchor.constraint(equalTo: topDiv.bottomAnchor, constant: 5),
            tabs2.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            tabs2.widthAnchor.constraint(equalToConstant: 280),
            tabDiv2.topAnchor.constraint(equalTo: topDiv.bottomAnchor, constant: tabStripH2),
            tabDiv2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            tabDiv2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            tabDiv2.heightAnchor.constraint(equalToConstant: 1),
        ])

        // ── Table ──────────────────────────────────────────────────
        let tv = AutoFitTableView()
        tv.headerView = nil; tv.rowHeight = rowH
        tv.gridStyleMask = []; tv.backgroundColor = .clear
        tv.dataSource = self; tv.delegate = self
        tv.allowsMultipleSelection = true
        tv.action = #selector(tableClicked); tv.doubleAction = #selector(tableDoubleClicked)
        tv.target = self
        tv.style = .sourceList
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.minWidth = 100; col.maxWidth = 10_000; col.width = 1   // AutoFitTableView corrects on first layout
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

        let dp2 = buildDisplaysPanel()
        dp2.isHidden = true
        dp2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(dp2)
        displaysPanelView = dp2

        let ev = EmptyStateView()
        ev.translatesAutoresizingMaskIntoConstraints = false; ev.isHidden = true
        bg.addSubview(ev); emptyView = ev

        // ── Column header ──────────────────────────────────────────
        let colH: CGFloat = 22
        let ch2 = makeColHeader()
        ch2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(ch2)
        colHeaderView = ch2

        // ── Inline settings panel ──────────────────────────────────
        let stp2 = settingsWindow.buildSettingsScrollView()
        stp2.isHidden = true
        stp2.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stp2)
        settingsPanelView = stp2

        // No fixed height on sv2 — it fills the space between the column header and
        // the hint bar. Combined with hint.bottomAnchor = bg.bottomAnchor below, the
        // layout is fully described from both ends and self-heals if NSPopover sizes
        // bg to an unexpected height (a fixed height constraint would conflict and
        // leave a blank gap between the list and the hint bar).
        baseListScrollHeight = rowH * maxRows - colH   // used for preferredContentSize
        NSLayoutConstraint.activate([
            ch2.topAnchor.constraint(equalTo: tabDiv2.bottomAnchor),
            ch2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            ch2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            ch2.heightAnchor.constraint(equalToConstant: colH),
            sv2.topAnchor.constraint(equalTo: ch2.bottomAnchor),
            sv2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sv2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            ev.topAnchor.constraint(equalTo: sv2.topAnchor),
            ev.leadingAnchor.constraint(equalTo: sv2.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: sv2.trailingAnchor),
            ev.bottomAnchor.constraint(equalTo: sv2.bottomAnchor),
            sp2.topAnchor.constraint(equalTo: tabDiv2.bottomAnchor),
            sp2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sp2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sp2.bottomAnchor.constraint(equalTo: sv2.bottomAnchor),
            dp2.topAnchor.constraint(equalTo: tabDiv2.bottomAnchor),
            dp2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            dp2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            dp2.bottomAnchor.constraint(equalTo: sv2.bottomAnchor),
            stp2.topAnchor.constraint(equalTo: tabDiv2.bottomAnchor),
            stp2.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stp2.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stp2.bottomAnchor.constraint(equalTo: sv2.bottomAnchor),
        ])

        // ── Hint bar ───────────────────────────────────────────────
        let botDiv = divider(); bg.addSubview(botDiv)
        let hint = NSTextField(labelWithString: "")
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hint); hintLabel = hint

        let halfAxeBtn2 = makeHalfAxeButton()
        bg.addSubview(halfAxeBtn2)
        halfAxeButton = halfAxeBtn2

        let axeBtn = RedButton()
        axeBtn.isBordered = false; axeBtn.wantsLayer = true
        axeBtn.target = self; axeBtn.action = #selector(axeCheckedApps)
        axeBtn.isHidden = true
        (axeBtn.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        axeBtn.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(axeBtn); axeCheckedButton = axeBtn

        // Save + Settings + About icon buttons (trailing edge of hint bar)
        let saveBtn2     = makeHintIconButton(symbolName: "tray.and.arrow.down", action: #selector(saveSessionMI))
        saveBtn2.toolTip = "Save current workflow (⌘⇧L)"
        let settingsBtn2 = makeHintIconButton(symbolName: "gear", action: #selector(openStandaloneSettings))
        let aboutBtn2    = makeHintIconButton(symbolName: "info.circle", action: #selector(showAbout))
        overlaySettingsBtn = settingsBtn2
        bg.addSubview(saveBtn2)
        bg.addSubview(settingsBtn2)
        bg.addSubview(aboutBtn2)

        NSLayoutConstraint.activate([
            botDiv.topAnchor.constraint(equalTo: sv2.bottomAnchor),
            botDiv.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            botDiv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            botDiv.heightAnchor.constraint(equalToConstant: 1),
            hint.topAnchor.constraint(equalTo: botDiv.bottomAnchor),
            hint.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            hint.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: saveBtn2.leadingAnchor, constant: -4),
            hint.heightAnchor.constraint(equalToConstant: hintH),
            halfAxeBtn2.trailingAnchor.constraint(equalTo: bg.centerXAnchor, constant: -5),
            halfAxeBtn2.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            halfAxeBtn2.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 16),
            axeBtn.leadingAnchor.constraint(equalTo: bg.centerXAnchor, constant: 5),
            axeBtn.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            axeBtn.trailingAnchor.constraint(lessThanOrEqualTo: saveBtn2.leadingAnchor, constant: -6),
            // Save-session button
            saveBtn2.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            saveBtn2.trailingAnchor.constraint(equalTo: settingsBtn2.leadingAnchor, constant: -1),
            saveBtn2.widthAnchor.constraint(equalToConstant: 24),
            saveBtn2.heightAnchor.constraint(equalToConstant: 24),
            // Settings button
            settingsBtn2.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            settingsBtn2.trailingAnchor.constraint(equalTo: aboutBtn2.leadingAnchor, constant: -1),
            settingsBtn2.widthAnchor.constraint(equalToConstant: 24),
            settingsBtn2.heightAnchor.constraint(equalToConstant: 24),
            // About button
            aboutBtn2.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            aboutBtn2.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            aboutBtn2.widthAnchor.constraint(equalToConstant: 24),
            aboutBtn2.heightAnchor.constraint(equalToConstant: 24),
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

    /// Small SF Symbol icon button for the hint bar (subtle, tertiary color,
    /// no border). Uses `HoverIconButton` so it gains a soft layered hover
    /// background that fades in/out on cursor enter/exit.
    private func makeHintIconButton(symbolName: String, action: Selector) -> NSButton {
        let btn = HoverIconButton()
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
            btn.image = img.withSymbolConfiguration(cfg)
        }
        btn.contentTintColor = .tertiaryLabelColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
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
        // Warm the icon cache off the main thread so the first paint of the
        // table has icons populated even for apps we haven't seen before.
        let warm: [(String, URL)] = allApps.compactMap { e in
            guard let bid = e.app.bundleIdentifier, let url = e.app.bundleURL else { return nil }
            return (bid, url)
        }
        IconCache.shared.warmAsync(warm)
        updatePlaceholder()
    }

    func applyFilter(_ query: String) {
        filtered = query.isEmpty
            ? allApps
            : allApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        displayRows = buildDisplayRows(from: filtered)
        // Drop checked PIDs and stale CPU baselines for apps no longer running
        let alivePIDs = Set(allApps.map { $0.app.processIdentifier })
        CPUSampler.shared.purge(keeping: alivePIDs)
        checkedPIDs   = checkedPIDs.intersection(alivePIDs)
        tableView?.reloadData()
        if !filtered.isEmpty && checkedPIDs.isEmpty {
            let firstApp = displayRows.firstIndex { $0.appEntry != nil } ?? 0
            tableView?.selectRowIndexes(IndexSet(integer: firstApp), byExtendingSelection: false)
        }
        updateEmptyState(query: query)
        updateHint()

        // Staggered fade-in for visible rows once the table relays out.
        if !AnimationConstants.reduceMotion {
            DispatchQueue.main.async { [weak self] in self?.animateRowsIn() }
        }
    }

    func buildDisplayRows(from apps: [AppEntry]) -> [TableRow] {
        // Collect unique categories in appearance order
        var seen = Set<String>()
        var orderedCategories: [String] = []
        for app in apps {
            if seen.insert(app.category).inserted {
                orderedCategories.append(app.category)
            }
        }
        // Sort categories alphabetically, "Other" always last
        orderedCategories.sort {
            if $1 == "Other" { return true }
            if $0 == "Other" { return false }
            return $0 < $1
        }
        // Only add section headers when apps span more than one category
        guard orderedCategories.count > 1 else { return apps.map { .app($0) } }
        var rows: [TableRow] = []
        for cat in orderedCategories {
            rows.append(.sectionHeader(cat))
            rows.append(contentsOf: apps.filter { $0.category == cat }.map { .app($0) })
        }
        return rows
    }

    func appEntry(atRow row: Int) -> AppEntry? {
        guard row >= 0, row < displayRows.count else { return nil }
        return displayRows[row].appEntry
    }

    /// Fade-in + 4pt vertical slide for each visible row, staggered 15ms
    /// per row. Called after the table reloads on filter / sort changes.
    private func animateRowsIn() {
        guard let tv = tableView else { return }
        let range = tv.rows(in: tv.visibleRect)
        let begin = CACurrentMediaTime()
        for row in range.location ..< (range.location + range.length) {
            guard let rv = tv.rowView(atRow: row, makeIfNecessary: false) else { continue }
            rv.wantsLayer = true
            guard let layer = rv.layer else { continue }
            let delay = Double(row - range.location) * AnimationConstants.rowStaggerDelay

            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = 0.0; op.toValue = 1.0
            op.duration = AnimationConstants.rowFadeDuration
            op.timingFunction = CAMediaTimingFunction(name: .easeOut)
            op.beginTime = begin + delay
            op.fillMode  = .backwards
            layer.add(op, forKey: "rowFade")

            let off = CABasicAnimation(keyPath: "transform.translation.y")
            off.fromValue = AnimationConstants.rowFadeOffset
            off.toValue   = 0
            off.duration  = AnimationConstants.rowFadeDuration
            off.timingFunction = CAMediaTimingFunction(name: .easeOut)
            off.beginTime = begin + delay
            off.fillMode  = .backwards
            layer.add(off, forKey: "rowOffset")
        }
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
        sortButton?.contentTintColor = sortByMemory ? .controlAccentColor : dimIconColor
        refreshAndFilter()
    }

    private func updateEmptyState(query: String) {
        if filtered.isEmpty {
            if query.isEmpty {
                emptyView?.show(pun("Nothing to axe.", "No apps running"), symbol: "checkmark.circle")
            } else {
                emptyView?.show("No matches for \"\(query)\"", symbol: "magnifyingglass")
            }
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
            let attrs: [NSAttributedString.Key: Any] =
                [.foregroundColor: NSColor.white,
                 .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
            axeCheckedButton?.attributedTitle = NSAttributedString(
                string: "\(currentKillPhrase) (\(checked))", attributes: attrs)
            axeCheckedButton?.isHidden = false
            halfAxeButton?.attributedTitle = NSAttributedString(
                string: "Half-Axe It", attributes: attrs)
            halfAxeButton?.isHidden = false
            hintLabel?.isHidden = true
        } else {
            stopPhraseCycling()
            currentKillPhrase = ""   // reset so next session gets a fresh phrase
            axeCheckedButton?.isHidden = true
            halfAxeButton?.isHidden = true
            hintLabel?.isHidden = false
            let sel = tableView?.selectedRowIndexes.count ?? 0
            if sel > 1 {
                hintLabel?.attributedStringValue = hintAttrStr("\(sel) selected  ·  ↵ quit  ·  ⌘↵ force kill  ·  esc close")
            } else {
                if isShowingDisplays {
                    hintLabel?.attributedStringValue = hintAttrStr("drag to dim each display  ·  esc back to apps")
                } else if isShowingSessions {
                    hintLabel?.attributedStringValue = hintAttrStr("▶ restore  ·  ✕ delete  ·  esc back to apps")
                } else {
                    // Show active workflow name + age when one is set
                    if let aid = AppSettings.activeWorkflowID,
                       let wf  = SessionManager.shared.all.first(where: { $0.id == aid }),
                       let lu  = wf.lastUsed {
                        hintLabel?.attributedStringValue = hintAttrStr("Active: \(wf.name) · \(ageString(lu))  ·  esc close")
                    } else if filtered.isEmpty {
                        // Nothing to act on — don't advertise navigate/quit for
                        // apps that aren't there. Reduce to what actually works.
                        let q = searchField?.stringValue ?? ""
                        hintLabel?.attributedStringValue =
                            hintAttrStr(q.isEmpty ? "esc close" : "type to search  ·  esc close")
                    } else if !AppSettings.hasMadeFirstKill {
                        // First-overlay coachmark (ROADMAP): teach the core action
                        // in plain language until the first kill, then fall through
                        // to the expert hint permanently.
                        hintLabel?.attributedStringValue =
                            hintAttrStr("Double-click any app to quit it  ·  ⌘-double-click to force kill")
                    } else {
                        // "⌘A select all" fires only when the open-hotkey ISN'T ⌘A
                        // (else the global hotkey would swallow it), so advertise it
                        // to everyone EXCEPT the ⌘A-open-hotkey cohort.
                        let openHotkeyIsCmdA = AppSettings.hotKeyCode == UInt32(kVK_ANSI_A)
                                            && AppSettings.hotKeyMods == UInt32(cmdKey)
                        let selectHint = openHotkeyIsCmdA ? "" : "  ·  ⌘A select all"
                        hintLabel?.attributedStringValue = hintAttrStr("↑↓ navigate  ·  ↵ quit  ·  ⌘↵ force kill\(selectHint)  ·  esc close")
                    }
                }
            }
        }
    }

    private func ageString(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60  { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    // Renders hint text with two-tier visual weight: key symbols/keywords at
    // higher contrast, label words and separators at lower contrast.
    private func hintAttrStr(_ raw: String) -> NSAttributedString {
        let isNotch = effectiveUIStyle == .notch
        let keyFont: NSFont   = .systemFont(ofSize: 11, weight: .medium)
        let labFont: NSFont   = .systemFont(ofSize: 11, weight: .light)
        let keyColor: NSColor = isNotch
            ? .white.withAlphaComponent(0.72)
            : .secondaryLabelColor
        let labColor: NSColor = isNotch
            ? .white.withAlphaComponent(0.36)
            : .quaternaryLabelColor
        let sepColor: NSColor = isNotch
            ? .white.withAlphaComponent(0.22)
            : .quaternaryLabelColor

        let keySet = CharacterSet(charactersIn: "↑↓↵⌘⇧▶✕⌥⇥⌃")
        let segments = raw.components(separatedBy: "·")
        let out = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                out.append(NSAttributedString(string: " · ",
                    attributes: [.font: labFont, .foregroundColor: sepColor]))
            }
            let t = seg.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            // Key token: starts with a special symbol OR the keyword "esc"
            if let first = t.unicodeScalars.first, keySet.contains(first) {
                if let spaceIdx = t.firstIndex(of: " ") {
                    out.append(NSAttributedString(string: String(t[..<spaceIdx]),
                        attributes: [.font: keyFont, .foregroundColor: keyColor]))
                    out.append(NSAttributedString(string: String(t[spaceIdx...]),
                        attributes: [.font: labFont, .foregroundColor: labColor]))
                } else {
                    out.append(NSAttributedString(string: t,
                        attributes: [.font: keyFont, .foregroundColor: keyColor]))
                }
            } else if t.hasPrefix("esc") {
                let after = t.index(t.startIndex, offsetBy: 3)
                out.append(NSAttributedString(string: "esc",
                    attributes: [.font: keyFont, .foregroundColor: keyColor]))
                if after < t.endIndex {
                    out.append(NSAttributedString(string: String(t[after...]),
                        attributes: [.font: labFont, .foregroundColor: labColor]))
                }
            } else {
                out.append(NSAttributedString(string: t,
                    attributes: [.font: labFont, .foregroundColor: labColor]))
            }
        }
        return out
    }

    // MARK: Phrase cycling

    private func startPhraseCycling() {
        phraseTimer?.invalidate()
        guard enabledKillPhrases.count > 1 else { return }   // nothing to cycle to
        // Register on .common run-loop modes so the tick still fires while the user
        // is hovering/scrolling the overlay (event-tracking mode) — a plain
        // scheduledTimer (.default mode) would pause during interaction.
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.cycleKillPhrase()
        }
        RunLoop.main.add(t, forMode: .common)
        phraseTimer = t
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
            let targets = rows.compactMap { appEntry(atRow: $0) }
            confirmAndExecuteKill(targets: targets, force: force)
        }
    }

    // MARK: Half-Axe (hide instead of quit)

    @objc func halfAxeCheckedApps() { hideSelected() }

    /// "Half-Axe It" — hides the selected/checked apps instead of quitting them.
    /// Non-destructive, so no confirmation; closes the overlay when done.
    func hideSelected() {
        let targets: [AppEntry]
        if !checkedPIDs.isEmpty {
            targets = filtered.filter { checkedPIDs.contains($0.app.processIdentifier) }
        } else {
            let rows = tableView?.selectedRowIndexes ?? IndexSet()
            targets = rows.compactMap { appEntry(atRow: $0) }
        }
        guard !targets.isEmpty else { return }
        targets.forEach { $0.app.hide() }
        checkedPIDs.removeAll()
        hideOverlay()
    }

    // MARK: Row context menu (right-click)

    /// Builds a context menu for a specific row — Axe / Force Axe / Half-Axe
    /// that one app without disturbing the table's selection or checkboxes.
    /// The Axe items render red, the Half-Axe item purple, matching the
    /// overlay's action buttons.
    func rowContextMenu(forRow row: Int) -> NSMenu? {
        guard let entry = appEntry(atRow: row) else { return nil }
        let pidNum = NSNumber(value: entry.app.processIdentifier)

        func makeItem(_ title: String, color: NSColor, selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = pidNum
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: color,
                .font: NSFont.menuFont(ofSize: 0),
            ])
            return item
        }

        let menu = NSMenu()
        menu.addItem(makeItem("Axe \(entry.name)",
                              color: .systemRed,
                              selector: #selector(contextAxe(_:))))
        menu.addItem(makeItem("Force Axe \(entry.name)",
                              color: .systemRed,
                              selector: #selector(contextForceAxe(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Half-Axe \(entry.name)  ·  hide",
                              color: .systemPurple,
                              selector: #selector(contextHalfAxe(_:))))
        return menu
    }

    private func contextEntry(_ sender: NSMenuItem) -> AppEntry? {
        guard let n = sender.representedObject as? NSNumber else { return nil }
        let pid = n.int32Value
        return filtered.first(where: { $0.app.processIdentifier == pid })
    }

    @objc func contextAxe(_ sender: NSMenuItem) {
        guard let e = contextEntry(sender) else { return }
        confirmAndExecuteKill(targets: [e], force: false)
    }

    @objc func contextForceAxe(_ sender: NSMenuItem) {
        guard let e = contextEntry(sender) else { return }
        confirmAndExecuteKill(targets: [e], force: true)
    }

    @objc func contextHalfAxe(_ sender: NSMenuItem) {
        guard let e = contextEntry(sender) else { return }
        e.app.hide()
        hideOverlay()
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
        if AppSettings.soundEnabled { ChopSound.shared.play() }
        // First real kill retires the first-overlay coachmark (see updateHint).
        AppSettings.hasMadeFirstKill = true
        targets.forEach { killEntry($0, force: force) }
        if AppSettings.autoClose && targets.count >= filtered.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.filtered.isEmpty == true { self?.hideOverlay() }
            }
        }
    }

    func killEntry(_ entry: AppEntry, force: Bool) {
        let pid = entry.app.processIdentifier
        pendingKillPIDs.insert(pid)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        let resolved = force ? KillMode.force : AppSettings.killMode
        if resolved == .force {
            entry.app.forceTerminate()
        } else {
            entry.app.terminate()
            let delay = AppSettings.gracePeriod
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSRunningApplication(processIdentifier: pid)?.forceTerminate()
                }
            }
        }
        // Animate the row out, then refresh the list
        if let row = filtered.firstIndex(where: { $0.app.processIdentifier == pid }),
           let rv = tableView?.rowView(atRow: row, makeIfNecessary: false) {
            animateKill(rv)   // plays the chosen destruction animation, then refreshes
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.refreshAndFilter()
            }
        }
    }

    // MARK: Destruction animations

    /// Hosts a kill animation in its own transparent, click-through floating
    /// window. Because the effect lives outside the popover/panel, it always
    /// plays to completion even if the overlay that triggered it dismisses.
    private final class KillCanvas {
        let window:  NSWindow
        let host:    CALayer
        let full:    CGImage
        let scale:   CGFloat
        let bounds:  CGRect      // row bounds, local coords
        let flipped: Bool        // whether the row view is flipped
        let rect:    CGRect      // row rect in overlay-content coords (screen-aligned, y up)
        private let screenOrigin: CGPoint
        private weak var row: NSView?

        init(window: NSWindow, host: CALayer, full: CGImage, scale: CGFloat,
             bounds: CGRect, flipped: Bool, rect: CGRect,
             screenOrigin: CGPoint, row: NSView) {
            self.window = window; self.host = host; self.full = full
            self.scale = scale; self.bounds = bounds; self.flipped = flipped
            self.rect = rect; self.screenOrigin = screenOrigin; self.row = row
        }

        /// Maps a point in the row's local coords to overlay-content coords.
        func point(_ local: NSPoint) -> CGPoint {
            guard let row = row, let win = row.window else { return CGPoint(x: local.x, y: local.y) }
            let onScreen = win.convertPoint(toScreen: row.convert(local, to: nil))
            return CGPoint(x: onScreen.x - screenOrigin.x, y: onScreen.y - screenOrigin.y)
        }
    }

    private func kv(_ p: CGPoint) -> NSValue { NSValue(point: NSPoint(x: p.x, y: p.y)) }
    private func ease(_ n: CAMediaTimingFunctionName) -> CAMediaTimingFunction {
        CAMediaTimingFunction(name: n)
    }

    /// Real kill: animate the row out, then refresh the list.
    private func animateKill(_ rv: NSView) {
        runKillAnimation(on: rv) { [weak self] in self?.refreshAndFilter() }
    }

    /// Picks the configured (or a random) style and runs it on `rv`, calling
    /// `completion` once the effect (and its overlay window) is finished.
    func runKillAnimation(on rv: NSView, completion: @escaping () -> Void) {
        var style = AppSettings.killAnimation
        if style == .random { style = KillAnimation.concreteCases.randomElement() ?? .shatter }
        guard let c = makeKillCanvas(for: rv) else {
            rv.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { completion() }
            return
        }
        switch style {
        case .shatter:  runTileAnim(c, cols: 6,  rows: 2, duration: 0.6,  mode: .shatter, completion: completion)
        case .explode:  runTileAnim(c, cols: 6,  rows: 2, duration: 0.55, mode: .explode, completion: completion)
        case .dissolve: runTileAnim(c, cols: 12, rows: 3, duration: 0.6,  mode: .dissolve, completion: completion)
        case .burn:     runTileAnim(c, cols: 10, rows: 4, duration: 0.85, mode: .burn, completion: completion)
        case .thanos:   runTileAnim(c, cols: 16, rows: 4, duration: 1.0,  mode: .thanos, completion: completion)
        case .slice:    runSliceAnim(c, completion: completion)
        case .poof:     runPoofAnim(c, completion: completion)
        case .random:   runTileAnim(c, cols: 6, rows: 2, duration: 0.6, mode: .shatter, completion: completion)
        }
    }

    /// Snapshots the row, hides it, and builds a floating overlay window.
    private func makeKillCanvas(for rv: NSView) -> KillCanvas? {
        guard let win = rv.window else { return nil }
        let bounds = rv.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = rv.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rv.cacheDisplay(in: bounds, to: rep)
        guard let full = rep.cgImage,
              let scr  = win.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let frame = scr.frame

        let owin = NSWindow(contentRect: frame, styleMask: .borderless,
                            backing: .buffered, defer: false)
        owin.isOpaque             = false
        owin.backgroundColor      = .clear
        owin.hasShadow            = false
        owin.ignoresMouseEvents   = true
        owin.level                = .popUpMenu
        owin.isReleasedWhenClosed = false
        owin.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let content = ShatterOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        owin.contentView = content
        owin.orderFront(nil)
        guard let host = content.layer else { return nil }

        // Row rect in overlay-content coords (screen-aligned).
        let rScreen = win.convertToScreen(rv.convert(rv.bounds, to: nil))
        let rect = CGRect(x: rScreen.minX - frame.minX, y: rScreen.minY - frame.minY,
                          width: rScreen.width, height: rScreen.height)

        rv.isHidden = true   // only the animated pieces should be visible
        return KillCanvas(window: owin, host: host, full: full,
                          scale: win.backingScaleFactor, bounds: bounds,
                          flipped: rv.isFlipped, rect: rect,
                          screenOrigin: frame.origin, row: rv)
    }

    /// Crops one grid tile out of the snapshot (CGImage is top-left origin).
    private func cropTile(_ c: KillCanvas, vx: CGFloat, vy: CGFloat,
                          pw: CGFloat, ph: CGFloat) -> CGImage? {
        let topY = c.flipped ? vy : (c.bounds.height - vy - ph)
        let crop = CGRect(x: (vx * c.scale).rounded(), y: (topY * c.scale).rounded(),
                          width: (pw * c.scale).rounded(), height: (ph * c.scale).rounded())
        return c.full.cropping(to: crop)
    }

    private func makeTileLayer(_ c: KillCanvas, tile: CGImage,
                               w: CGFloat, h: CGFloat, center: CGPoint) -> CALayer {
        let layer = CALayer()
        layer.contents      = tile
        layer.contentsScale = c.scale
        layer.bounds        = CGRect(x: 0, y: 0, width: w, height: h)
        layer.anchorPoint   = CGPoint(x: 0.5, y: 0.5)
        layer.position      = center
        c.host.addSublayer(layer)
        return layer
    }

    private func finishKill(_ c: KillCanvas, after duration: CFTimeInterval,
                            completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08) {
            c.window.orderOut(nil)
            completion()
        }
    }

    private enum TileMode { case shatter, explode, dissolve, burn, thanos }

    /// Tile-grid styles: shatter (gravity fall), explode (radial burst),
    /// dissolve (gentle fade), burn (flame front sweeps up), thanos (dust away).
    private func runTileAnim(_ c: KillCanvas, cols: Int, rows: Int,
                             duration: CFTimeInterval, mode: TileMode,
                             completion: @escaping () -> Void) {
        let pw = c.bounds.width  / CGFloat(cols)
        let ph = c.bounds.height / CGFloat(rows)
        let center = CGPoint(x: c.rect.midX, y: c.rect.midY)

        if mode == .burn { addFlameBar(c, duration: duration) }

        for cy in 0..<rows {
            for cx in 0..<cols {
                let vx = CGFloat(cx) * pw
                let vy = CGFloat(cy) * ph
                guard let tile = cropTile(c, vx: vx, vy: vy, pw: pw, ph: ph) else { continue }
                let start = c.point(NSPoint(x: vx + pw / 2, y: vy + ph / 2))
                let layer = makeTileLayer(c, tile: tile, w: pw, h: ph, center: start)

                let pos    = CAKeyframeAnimation(keyPath: "position")
                let rot    = CABasicAnimation(keyPath: "transform.rotation.z"); rot.fromValue = 0
                let scaleA = CAKeyframeAnimation(keyPath: "transform.scale")
                let fade   = CAKeyframeAnimation(keyPath: "opacity")

                switch mode {
                case .shatter:
                    let drift = CGFloat.random(in: -55...55)
                    let fall  = CGFloat.random(in: 80...170)
                    let pop   = CGFloat.random(in: 2...20)
                    pos.values = [kv(start),
                                  kv(CGPoint(x: start.x + drift * 0.35, y: start.y + pop)),
                                  kv(CGPoint(x: start.x + drift,        y: start.y - fall))]
                    pos.keyTimes = [0, 0.22, 1]
                    pos.timingFunctions = [ease(.easeOut), ease(.easeIn)]
                    rot.toValue   = CGFloat.random(in: -1.8...1.8)
                    scaleA.values = [1.0, CGFloat.random(in: 0.5...0.85)]; scaleA.keyTimes = [0, 1]
                    fade.values   = [1, 1, 0]; fade.keyTimes = [0, 0.45, 1]

                case .explode:
                    var dx = start.x - center.x, dy = start.y - center.y
                    if abs(dx) < 0.5 && abs(dy) < 0.5 { dx = .random(in: -1...1); dy = .random(in: -1...1) }
                    let len = max(1, hypot(dx, dy)); let mag = CGFloat.random(in: 80...170)
                    let end = CGPoint(x: start.x + dx / len * mag,
                                      y: start.y + dy / len * mag + CGFloat.random(in: -12...12))
                    pos.values = [kv(start), kv(end)]; pos.keyTimes = [0, 1]
                    pos.timingFunctions = [ease(.easeOut)]
                    rot.toValue   = CGFloat.random(in: -2.6...2.6)
                    scaleA.values = [1.0, CGFloat.random(in: 0.4...0.8)]; scaleA.keyTimes = [0, 1]
                    fade.values   = [1, 1, 0]; fade.keyTimes = [0, 0.35, 1]

                case .dissolve:
                    let rise = CGFloat.random(in: 6...22), sway = CGFloat.random(in: -8...8)
                    pos.values = [kv(start), kv(CGPoint(x: start.x + sway, y: start.y + rise))]
                    pos.keyTimes = [0, 1]; pos.timingFunctions = [ease(.easeOut)]
                    rot.toValue   = CGFloat.random(in: -0.4...0.4)
                    scaleA.values = [1.0, CGFloat.random(in: 0.6...0.9)]; scaleA.keyTimes = [0, 1]
                    let cp = (cols <= 1) ? 0 : Double(cx) / Double(cols - 1)
                    let t0 = 0.1 + 0.45 * cp
                    fade.values = [1, 1, 0]; fade.keyTimes = [0, NSNumber(value: t0), 1]

                case .burn:
                    // Bottom (lower screen y) ignites first as the flame rises.
                    let vfrac = Double((start.y - c.rect.minY) / max(1, c.rect.height))
                    let t0 = min(0.85, 0.1 + 0.6 * vfrac)
                    let te = min(1.0, t0 + 0.3)
                    pos.values = [kv(start), kv(start),
                                  kv(CGPoint(x: start.x + CGFloat.random(in: -8...8),
                                             y: start.y + CGFloat.random(in: 18...46)))]
                    pos.keyTimes = [0, NSNumber(value: t0), NSNumber(value: te)]
                    pos.timingFunctions = [ease(.linear), ease(.easeIn)]
                    rot.toValue   = CGFloat.random(in: -0.5...0.5)
                    scaleA.values = [1.0, 1.0, CGFloat.random(in: 0.3...0.6)]
                    scaleA.keyTimes = [0, NSNumber(value: t0), NSNumber(value: te)]
                    fade.values   = [1, 1, 0]
                    fade.keyTimes = [0, NSNumber(value: t0), NSNumber(value: te)]

                case .thanos:
                    // Left dusts slightly before right; pieces drift up and away.
                    let hfrac = Double((start.x - c.rect.minX) / max(1, c.rect.width))
                    let t0 = min(0.55, 0.35 * hfrac + Double.random(in: 0...0.15))
                    let te = min(1.0, t0 + 0.5)
                    let end = CGPoint(x: start.x + CGFloat.random(in: 24...72),
                                      y: start.y + CGFloat.random(in: 30...84))
                    pos.values = [kv(start), kv(start), kv(end)]
                    pos.keyTimes = [0, NSNumber(value: t0), NSNumber(value: te)]
                    pos.timingFunctions = [ease(.linear), ease(.easeOut)]
                    rot.toValue   = CGFloat.random(in: -1.0...1.0)
                    scaleA.values = [1.0, 1.0, CGFloat.random(in: 0.04...0.18)]
                    scaleA.keyTimes = [0, NSNumber(value: t0), NSNumber(value: te)]
                    fade.values   = [1, 1, 0]
                    fade.keyTimes = [0, NSNumber(value: t0), NSNumber(value: te)]
                }

                let grp = CAAnimationGroup()
                grp.animations            = [pos, rot, scaleA, fade]
                grp.duration              = duration
                grp.fillMode              = .forwards
                grp.isRemovedOnCompletion = false
                layer.add(grp, forKey: "kill")
                layer.opacity = 0
            }
        }
        finishKill(c, after: duration, completion: completion)
    }

    /// A bright flame front that sweeps up the row for the burn animation.
    private func addFlameBar(_ c: KillCanvas, duration: CFTimeInterval) {
        let barH: CGFloat = 16
        let grad = CAGradientLayer()
        grad.bounds      = CGRect(x: 0, y: 0, width: c.rect.width, height: barH)
        grad.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        grad.position    = CGPoint(x: c.rect.midX, y: c.rect.minY)
        grad.colors      = [NSColor.systemYellow.withAlphaComponent(0.0).cgColor,
                            NSColor.systemOrange.withAlphaComponent(0.95).cgColor,
                            NSColor.systemRed.withAlphaComponent(0.0).cgColor]
        grad.locations   = [0, 0.5, 1]
        grad.startPoint  = CGPoint(x: 0.5, y: 0)
        grad.endPoint    = CGPoint(x: 0.5, y: 1)
        c.host.addSublayer(grad)

        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = c.rect.minY
        move.toValue   = c.rect.maxY + barH

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values   = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.15, 0.7, 1]

        let grp = CAAnimationGroup()
        grp.animations            = [move, fade]
        grp.duration              = duration * 0.8
        grp.timingFunction        = ease(.easeIn)
        grp.fillMode              = .forwards
        grp.isRemovedOnCompletion = false
        grad.add(grp, forKey: "flame")
        grad.opacity = 0
    }

    /// Poof: the whole row puffs up and vanishes in a little cloud of smoke.
    private func runPoofAnim(_ c: KillCanvas, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.45
        let mid = CGPoint(x: c.rect.midX, y: c.rect.midY)

        let layer = makeTileLayer(c, tile: c.full, w: c.rect.width, h: c.rect.height, center: mid)
        let scaleA = CABasicAnimation(keyPath: "transform.scale")
        scaleA.fromValue = 1.0; scaleA.toValue = 1.18
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = mid.y; rise.toValue = mid.y + 10
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.9, 0]; fade.keyTimes = [0, 0.25, 1]
        let grp = CAAnimationGroup()
        grp.animations = [scaleA, rise, fade]
        grp.duration = duration
        grp.fillMode = .forwards; grp.isRemovedOnCompletion = false
        layer.add(grp, forKey: "poof")
        layer.opacity = 0

        // Smoke puffs radiating outward.
        let puffs = 7
        for i in 0..<puffs {
            let sz = CGFloat.random(in: 16...30)
            let puff = CALayer()
            puff.bounds = CGRect(x: 0, y: 0, width: sz, height: sz)
            puff.cornerRadius = sz / 2
            puff.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            puff.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let angle = CGFloat(i) / CGFloat(puffs) * .pi * 2
            let from = CGPoint(x: mid.x + cos(angle) * 12, y: mid.y + sin(angle) * 7)
            puff.position = from
            c.host.addSublayer(puff)

            let dist = CGFloat.random(in: 16...46)
            let pMove = CABasicAnimation(keyPath: "position")
            pMove.fromValue = kv(from)
            pMove.toValue   = kv(CGPoint(x: from.x + cos(angle) * dist,
                                         y: from.y + sin(angle) * dist + 8))
            let pScale = CABasicAnimation(keyPath: "transform.scale")
            pScale.fromValue = 0.3; pScale.toValue = CGFloat.random(in: 1.2...1.9)
            let pFade = CAKeyframeAnimation(keyPath: "opacity")
            pFade.values = [0.0, 0.8, 0.0]; pFade.keyTimes = [0, 0.3, 1]
            let pg = CAAnimationGroup()
            pg.animations = [pMove, pScale, pFade]
            pg.duration = duration
            pg.fillMode = .forwards; pg.isRemovedOnCompletion = false
            puff.add(pg, forKey: "puff")
            puff.opacity = 0
        }
        finishKill(c, after: duration, completion: completion)
    }

    /// Slice: cleave the row into a top and bottom half that fly apart.
    private func runSliceAnim(_ c: KillCanvas, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.5
        let halfH = c.bounds.height / 2

        for half in 0..<2 {                                   // 0 = lower local half, 1 = upper
            let vy = CGFloat(half) * halfH
            guard let tile = cropTile(c, vx: 0, vy: vy, pw: c.bounds.width, ph: halfH) else { continue }
            let start = c.point(NSPoint(x: c.bounds.midX, y: vy + halfH / 2))
            let layer = makeTileLayer(c, tile: tile, w: c.bounds.width, h: halfH, center: start)

            // Split based on actual screen position so it reads correctly
            // regardless of the row view's flippedness.
            let goesUp = start.y >= c.rect.midY
            let dy: CGFloat = goesUp ? 60 : -60
            let dx: CGFloat = goesUp ? -34 : 34

            let pos = CAKeyframeAnimation(keyPath: "position")
            pos.values   = [kv(start), kv(CGPoint(x: start.x + dx, y: start.y + dy))]
            pos.keyTimes = [0, 1]; pos.timingFunctions = [ease(.easeIn)]
            let rot = CABasicAnimation(keyPath: "transform.rotation.z")
            rot.fromValue = 0; rot.toValue = goesUp ? 0.18 : -0.18
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.35, 1]

            let grp = CAAnimationGroup()
            grp.animations            = [pos, rot, fade]
            grp.duration              = duration
            grp.fillMode              = .forwards
            grp.isRemovedOnCompletion = false
            layer.add(grp, forKey: "slice")
            layer.opacity = 0
        }
        finishKill(c, after: duration, completion: completion)
    }

    // MARK: Table interactions

    @objc func tableClicked() {
        updateHint()
    }

    @objc func tableDoubleClicked() {
        let row = tableView?.clickedRow ?? -1
        guard let e = appEntry(atRow: row) else { return }
        let force = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        confirmAndExecuteKill(targets: [e], force: force)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { displayRows.count }

    func tableView(_ tv: NSTableView, isGroupRow row: Int) -> Bool {
        guard row >= 0, row < displayRows.count else { return false }
        if case .sectionHeader = displayRows[row] { return true }
        return false
    }

    func tableView(_ tv: NSTableView, shouldSelectRow row: Int) -> Bool {
        return !self.tableView(tv, isGroupRow: row)
    }

    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
        if self.tableView(tv, isGroupRow: row) { return 22 }
        return tv.rowHeight
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        switch displayRows[safe: row] {
        case .sectionHeader(let title):
            let id = NSUserInterfaceItemIdentifier("GroupHeader")
            let cell = tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                       ?? { let c = NSTableCellView(); c.identifier = id; return c }()
            if cell.textField == nil {
                let lbl = NSTextField(labelWithString: "")
                lbl.font = .systemFont(ofSize: 9, weight: .semibold)
                lbl.textColor = .tertiaryLabelColor
                lbl.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(lbl); cell.textField = lbl
                NSLayoutConstraint.activate([
                    lbl.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 11),
                    lbl.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = title.uppercased()
            return cell

        case .app(let e):
            let id = NSUserInterfaceItemIdentifier("AppRow")
            let cell = tv.makeView(withIdentifier: id, owner: nil) as? AppRowCell
                       ?? { let c = AppRowCell(frame: .zero); c.identifier = id; return c }()
            let pid = e.app.processIdentifier
            cell.appName.stringValue  = e.name
            cell.appIcon.image        = e.icon
            cell.statsView.configure(cpu: e.cpuPercent, mem: e.memMB)
            cell.checkBox.state       = checkedPIDs.contains(pid) ? .on : .off
            // VoiceOver: cells are reused, so (re)label per row. The checkbox gates
            // a destructive action, so tie its name to this row's app.
            cell.setAccessibilityLabel(e.name)
            cell.checkBox.setAccessibilityLabel("Select \(e.name)")
            let cpuA11y = e.cpuPercent.map { String(format: "%.0f%% CPU", $0) } ?? "CPU unknown"
            let memA11y = e.memMB.map { "\($0) MB memory" } ?? "memory unknown"
            cell.statsView.setAccessibilityLabel("\(cpuA11y), \(memA11y)")
            cell.onCheckToggle = { [weak self] checked in
                guard let self else { return }
                if checked { self.checkedPIDs.insert(pid) }
                else       { self.checkedPIDs.remove(pid) }
                self.updateHint()
                if let rv = self.tableView?.rowView(atRow: row, makeIfNecessary: false) as? AnimatedRowView {
                    rv.springCheck()
                }
            }
            return cell

        default:
            return nil
        }
    }

    /// Provide our custom row view so selection fades smoothly with extra
    /// contrast — see `AnimatedRowView` for the layer setup.
    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("AnimatedRow")
        if let reused = tv.makeView(withIdentifier: id, owner: nil) as? AnimatedRowView {
            return reused
        }
        let rv = AnimatedRowView()
        rv.identifier = id
        return rv
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
            if isShowingSettings { toggleSettingsPanel() }
            else if isShowingSessions { toggleSessionsPanel() }
            else if isShowingDisplays { switchToOverlayTab(0) }
            else { hideOverlay() }
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

        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):   // Home
            selectEdgeRow(fromStart: true); return true

        case #selector(NSResponder.scrollToEndOfDocument(_:)):         // End
            selectEdgeRow(fromStart: false); return true

        default:
            return false
        }
    }

    func moveSelection(by delta: Int) {
        guard let tv = tableView, tv.numberOfRows > 0 else { return }
        let start = tv.selectedRow < 0 ? (delta > 0 ? -1 : tv.numberOfRows) : tv.selectedRow
        var next = start + delta
        // selectRowIndexes bypasses shouldSelectRow, so skip non-selectable
        // section-header rows manually in the direction of travel.
        while next >= 0, next < tv.numberOfRows, appEntry(atRow: next) == nil { next += delta }
        // No selectable row that way — keep the current selection, never a header.
        guard next >= 0, next < tv.numberOfRows else { return }
        tv.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tv.scrollRowToVisible(next)
        updateHint()
    }

    /// Select the first (or last) selectable app row, skipping section headers.
    private func selectEdgeRow(fromStart: Bool) {
        guard let tv = tableView, tv.numberOfRows > 0 else { return }
        let order = fromStart ? Array(0..<tv.numberOfRows) : Array((0..<tv.numberOfRows).reversed())
        guard let target = order.first(where: { appEntry(atRow: $0) != nil }) else { return }
        tv.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tv.scrollRowToVisible(target)
        updateHint()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
