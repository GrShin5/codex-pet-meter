import AppKit
import Foundation
import SQLite3
import CryptoKit
import CoreFoundation

private let codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
private let globalStateURL = codexHome.appendingPathComponent(".codex-global-state.json")
private let configURL = codexHome.appendingPathComponent("config.toml")
private let authURL = codexHome.appendingPathComponent("auth.json")
private let logsURL = codexHome.appendingPathComponent("logs_2.sqlite")
private let foodBowlResourceName = "food_bowl_meter"
private let sizeAdjustmentDefaultsKey = "meterSizeAdjustment"
private let minimumPetWidth: CGFloat = 80
private let maximumPetWidth: CGFloat = 224
private let baselinePetWidth: CGFloat = 99
private let minimumSizeAdjustment: CGFloat = 0.85
private let maximumSizeAdjustment: CGFloat = 1.20
private let defaultSizeAdjustment: CGFloat = 1.0

private enum DataSource: String {
    case live = "Live"
    case cached = "Cached"
    case unavailable = "Unavailable"
}

private enum Period: Equatable {
    case limited(Double, Date?)
    case noLimit
    case unknown
    var remaining: Double { if case let .limited(used, _) = self { return 100 - used }; return 0 }
    var reset: Date? { if case let .limited(_, reset) = self { return reset }; return nil }
    var text: String { switch self { case .limited: return "\(Int(remaining.rounded()))%"; case .noLimit: return "No Limit"; case .unknown: return "—" } }
    var resetText: String { switch self { case .noLimit: return "---"; case .unknown: return "—"; case .limited: return resetTimeText(reset) } }
    func valid(at now: Date) -> Period { if let reset, reset <= now { return .unknown }; return self }
}
private struct MeterSnapshot {
    var fiveHour: Period
    var weekly: Period
    var planType: String
    var source: DataSource
    var updatedAt: Date
    var failure: String? = nil
    var fiveHourRemaining: Double { fiveHour.remaining }
    var weeklyRemaining: Double { weekly.remaining }
    var fiveHourResetAt: Date? { fiveHour.reset }
    var weeklyResetAt: Date? { weekly.reset }
    static let unavailable = MeterSnapshot(fiveHour: .unknown, weekly: .unknown, planType: "unknown", source: .unavailable, updatedAt: .distantPast)
}

private struct PetAnchor {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

private enum LabelSide: Equatable {
    case left
    case right
}

private struct OverlayLayout: Equatable {
    static let baseWidth: CGFloat = 310
    static let baseHeight: CGFloat = 240
    static let baseBottomControlSpace: CGFloat = 38
    static let baseRingDiameter: CGFloat = 210
    static let baseLabelWidth: CGFloat = 128
    static let baseLabelHeight: CGFloat = 30

    var labelSide: LabelSide
    var scale: CGFloat

    var width: CGFloat { Self.baseWidth * scale }
    // Reserve a dedicated top lane while keeping ringCenter (and its pet alignment) unchanged.
    var height: CGFloat { (Self.baseHeight + Self.baseBottomControlSpace + 24) * scale }
    var cachedBadgeRect: NSRect {
        NSRect(x: resetBadgeRect.minX, y: resetBadgeRect.maxY + 4 * scale, width: 150 * scale, height: 18 * scale)
    }
    var bottomControlSpace: CGFloat { Self.baseBottomControlSpace * scale }
    var ringDiameter: CGFloat { Self.baseRingDiameter * scale }
    var labelWidth: CGFloat { Self.baseLabelWidth * scale }
    var labelHeight: CGFloat { Self.baseLabelHeight * scale }
    var ringCenterX: CGFloat {
        switch labelSide {
        case .left:
            return width - 118 * scale
        case .right:
            return 118 * scale
        }
    }

    var ringCenter: CGPoint {
        CGPoint(x: ringCenterX, y: Self.baseHeight / 2 * scale + bottomControlSpace)
    }

    var weeklyLabelRect: NSRect {
        switch labelSide {
        case .left:
            return NSRect(x: ringCenterX - 104 * scale, y: ringCenter.y + 28 * scale, width: labelWidth, height: labelHeight)
        case .right:
            return NSRect(x: ringCenterX + 52 * scale, y: ringCenter.y + 28 * scale, width: labelWidth, height: labelHeight)
        }
    }

    var fiveHourLabelRect: NSRect {
        switch labelSide {
        case .left:
            return NSRect(x: ringCenterX - 100 * scale, y: ringCenter.y - 28 * scale, width: labelWidth - 8 * scale, height: labelHeight)
        case .right:
            return NSRect(x: ringCenterX + 48 * scale, y: ringCenter.y - 28 * scale, width: labelWidth - 8 * scale, height: labelHeight)
        }
    }

    var resetBadgeRect: NSRect {
        switch labelSide {
        case .left:
            return NSRect(x: 8 * scale, y: ringCenter.y + 72 * scale, width: 150 * scale, height: 38 * scale)
        case .right:
            return NSRect(x: width - 158 * scale, y: ringCenter.y + 72 * scale, width: 150 * scale, height: 38 * scale)
        }
    }
}

private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

private func jsonObject(from data: Data) -> Any? {
    try? JSONSerialization.jsonObject(with: data)
}

private func firstJSONObjectString(in text: String, startingAt start: String.Index) -> String? {
    var depth = 0
    var inString = false
    var isEscaped = false
    var index = start

    while index < text.endIndex {
        let character = text[index]
        if inString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString = false
            }
        } else {
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }
        index = text.index(after: index)
    }

    return nil
}

private func dictionary(at path: [String], in value: Any) -> [String: Any]? {
    var current = value
    for key in path {
        guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
        current = next
    }
    return current as? [String: Any]
}

// JSON booleans bridge to NSNumber too: reject before numeric conversion.
private func number(_ key: String, in dict: [String: Any]) -> Double? {
    guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}
private func unixDate(_ key: String, in dict: [String: Any]) -> Date? {
    guard let n = number(key, in: dict), n > 0, n < 253402300800 else { return nil }
    return Date(timeIntervalSince1970: n)
}
private func parseSnapshot(from value: Any, source: DataSource, updatedAt: Date = Date()) -> MeterSnapshot? {
    guard let root = value as? [String: Any], let limits = root["rate_limit"] as? [String: Any] else { return nil }
    var periods: [Int: Period] = [:]
    var conflict = false
    for key in ["primary_window", "secondary_window"] {
        guard let raw = limits[key], !(raw is NSNull) else { continue }
        guard let window = raw as? [String: Any], let duration = number("limit_window_seconds", in: window),
              duration == 18000 || duration == 604800 else { conflict = true; continue }
        let id = Int(duration)
        guard let used = number("used_percent", in: window), (0...100).contains(used) else { periods[id] = .unknown; conflict = true; continue }
        if let rawReset = window["reset_at"], !(rawReset is NSNull), unixDate("reset_at", in: window) == nil {
            periods[id] = .unknown; conflict = true; continue
        }
        let period = Period.limited(used, unixDate("reset_at", in: window))
        if let prior = periods[id], prior != period { periods[id] = .unknown; conflict = true }
        else { periods[id] = period }
    }
    let plan = root["plan_type"] as? String ?? "unknown"
    var five = periods[18000] ?? .unknown
    let weekly = periods[604800] ?? .unknown
    if periods[18000] == nil, case .limited = weekly, !conflict, source == .live,
       ["prolite", "pro", "promax"].contains(plan.lowercased()) { five = .noLimit }
    return MeterSnapshot(fiveHour: five, weekly: weekly, planType: plan, source: source, updatedAt: updatedAt)
}
private struct Credentials { let token: String; let identity: String }
private func credentials() -> Credentials? {
    guard let data = try? Data(contentsOf: authURL), let root = jsonObject(from: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
    let identity = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    return Credentials(token: token, identity: identity)
}
private enum UsageFailure: String, Error { case transport = "Connection failed", http = "HTTP request failed", invalid = "Usage response unavailable", auth = "Access token unavailable" }
private func decodeResponse(data: Data?, status: Int?, error: Error?, now: Date) -> Result<MeterSnapshot, UsageFailure> {
    if error != nil { return .failure(.transport) }
    guard let status, (200..<300).contains(status) else { return .failure(.http) }
    guard let data, let value = jsonObject(from: data), let snapshot = parseSnapshot(from: value, source: .live, updatedAt: now) else { return .failure(.invalid) }
    return .success(snapshot)
}
private typealias UsageRequest = (Credentials, @escaping (Result<MeterSnapshot, UsageFailure>) -> Void) -> Void
private func requestUsage(_ auth: Credentials, completion: @escaping (Result<MeterSnapshot, UsageFailure>) -> Void) {
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 8
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    let session = URLSession(configuration: config)
    session.dataTask(with: request) { data, response, error in
        completion(decodeResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error, now: Date()))
        session.finishTasksAndInvalidate()
    }.resume()
}
// Main-queue state machine. Account generations invalidate old responses.
private final class MeterStore {
    private var storedSnapshot = MeterSnapshot.unavailable
    private(set) var snapshot: MeterSnapshot {
        get { normalized(storedSnapshot) }
        set { storedSnapshot = newValue }
    }
    private func normalized(_ value: MeterSnapshot) -> MeterSnapshot {
        guard value.source != .unavailable else { return value }
        let now = clock()
        guard (0...300).contains(now.timeIntervalSince(value.updatedAt)) else {
            var expired = MeterSnapshot.unavailable
            expired.failure = value.failure
            return expired
        }
        var valid = value
        valid.fiveHour = value.fiveHour.valid(at: now)
        valid.weekly = value.weekly.valid(at: now)
        return valid
    }
    // Polling is cheap; publish only a semantic transition, never on every tracking tick.
    func expireIfNeeded() {
        let current = snapshot
        if current.fiveHour != storedSnapshot.fiveHour || current.weekly != storedSnapshot.weekly || current.source != storedSnapshot.source {
            storedSnapshot = current
            onChange?()
        }
    }
    private var identity: String?
    private var generation = 0
    private var active: Int?
    private var pending = false
    private var good: MeterSnapshot?
    private let clock: () -> Date
    private let auth: () -> Credentials?
    private let request: UsageRequest
    var onChange: (() -> Void)?
    init(clock: @escaping () -> Date = Date.init, auth: @escaping () -> Credentials? = credentials, request: @escaping UsageRequest = requestUsage) {
        self.clock = clock; self.auth = auth; self.request = request
    }
    func refresh() {
        let current = auth()
        if identity != current?.identity {
            identity = current?.identity; generation += 1; active = nil; good = nil; pending = false
            snapshot = .unavailable; onChange?()
        }
        guard let current else { fail(.auth); return }
        if active != nil { pending = true; return }
        let ticket = generation
        active = ticket
        request(current) { [weak self] result in
            let apply = {
                guard let self, self.generation == ticket, self.identity == current.identity else { return }
                guard self.auth()?.identity == current.identity else { self.refresh(); return }
                self.active = nil
                switch result {
                case .success(let value): self.good = value; self.snapshot = value
                case .failure(let reason): self.fail(reason)
                }
                self.onChange?()
                if self.pending { self.pending = false; self.refresh() }
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
    }
    private func fail(_ reason: UsageFailure) {
        if var cached = good, (0...300).contains(clock().timeIntervalSince(cached.updatedAt)) {
            cached.fiveHour = cached.fiveHour.valid(at: clock()); cached.weekly = cached.weekly.valid(at: clock())
            cached.source = .cached; cached.failure = reason.rawValue; snapshot = cached
        } else { snapshot = .unavailable; snapshot.failure = reason.rawValue }
        onChange?()
    }
}
private func legacyEvent(_ body: String, at date: Date) -> MeterSnapshot? {
    guard let marker = body.range(of: "websocket event:"), let start = body[marker.upperBound...].firstIndex(of: "{"),
          let text = firstJSONObjectString(in: body, startingAt: start), let data = text.data(using: .utf8),
          var root = jsonObject(from: data) as? [String: Any], root["type"] as? String == "codex.rate_limits" else { return nil }
    if var limits = root["rate_limits"] as? [String: Any] {
        for (old, new) in [("primary", "primary_window"), ("secondary", "secondary_window")] {
            if var window = (limits[old] ?? limits[new]) as? [String: Any] {
                if window["limit_window_seconds"] == nil, let minutes = number("window_minutes", in: window) { window["limit_window_seconds"] = minutes * 60 }
                if window["reset_at"] == nil { window["reset_at"] = window["resets_at"] }
                limits[new] = window
            }
        }
        root["rate_limit"] = limits
    }
    return parseSnapshot(from: root, source: .cached, updatedAt: date)
}
private func cachedSnapshot() -> MeterSnapshot? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(logsURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if db != nil { sqlite3_close(db) }; return nil }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let query = "SELECT ts, feedback_log_body FROM logs WHERE target = 'codex_api::endpoint::responses_websocket' AND feedback_log_body LIKE '%websocket event:%' ORDER BY ts DESC, ts_nanos DESC, id DESC LIMIT 200"
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let text = sqlite3_column_text(statement, 1) else { continue }
        if let value = legacyEvent(String(cString: text), at: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)))) { return value }
    }
    return nil
}
// Focused TOML reader for one desktop numeric preference. It never exposes other values.
// Quoted/multiline user text is scanned before recognizing tables or keys.
private enum DesktopWidthRead { case valid(Double?), invalid }
private func desktopPetWidth(in text: String) -> Double? {
    if case .valid(let width) = desktopPetWidthRead(in: text) { return width }
    return nil
}
private func desktopPetWidthRead(in text: String) -> DesktopWidthRead {
    var multiline: String?
    var desktop = false
    var result: Double?
    for line in text.components(separatedBy: .newlines) {
        var index = line.startIndex
        var quote: Character?
        var escaped = false
        var clean = ""
        var containsMultiline = multiline != nil
        while index < line.endIndex {
            let tail = line[index...]
            if let delimiter = multiline {
                if tail.hasPrefix(delimiter), !(delimiter == "\"\"\"" && escaped) {
                    multiline = nil
                    index = line.index(index, offsetBy: 3)
                    escaped = false
                } else {
                    let character = line[index]
                    escaped = delimiter == "\"\"\"" && character == "\\" && !escaped
                    index = line.index(after: index)
                }
                continue
            }
            let character = line[index]
            if let current = quote {
                clean.append(character)
                if character == current && !escaped { quote = nil }
                escaped = current == "\"" && character == "\\" && !escaped
                index = line.index(after: index)
                continue
            }
            if character == "#" { break }
            if tail.hasPrefix("\"\"\"") || tail.hasPrefix("'''") {
                multiline = tail.hasPrefix("\"\"\"") ? "\"\"\"" : "'''"
                containsMultiline = true
                index = line.index(index, offsetBy: 3)
                continue
            }
            if character == "\"" || character == "'" { quote = character; escaped = false }
            clean.append(character)
            index = line.index(after: index)
        }
        if quote != nil { return .invalid }
        guard !containsMultiline else { continue }
        let code = clean.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("[") {
            guard code.hasSuffix("]") else { return .invalid }
            desktop = ["[desktop]", "[\"desktop\"]", "['desktop']"].contains(code)
            continue
        }
        guard desktop, let equal = code.firstIndex(of: "=") else { continue }
        let key = code[..<equal].trimmingCharacters(in: .whitespaces)
        guard ["avatar-overlay-mascot-width-px", "\"avatar-overlay-mascot-width-px\"", "'avatar-overlay-mascot-width-px'"].contains(key) else { continue }
        let raw = code[code.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        let decimal = #"^[+-]?[0-9]+(?:_[0-9]+)*(?:\.[0-9]+(?:_[0-9]+)*)?(?:[eE][+-]?[0-9]+(?:_[0-9]+)*)?$"#
        guard raw.range(of: decimal, options: .regularExpression) != nil,
              let width = Double(raw.replacingOccurrences(of: "_", with: "")), width.isFinite else { return .invalid }
        result = clamp(width.rounded(), 80, 224)
    }
    return multiline == nil ? .valid(result) : .invalid
}

// The renderer special-cases nominal112 as7.04rem. Current Reset/drag metadata
// bounds its rounded half-size to57x61;113x122 is the source-informed pixel pair.
// This is not a direct DOM measurement; legacy measured rectangles bypass it.
private func currentPetDimensions(nominalWidth: Double) -> CGSize {
    let nominal = clamp(nominalWidth.rounded(), 80, 224)
    if nominal == 112 { return CGSize(width: 113, height: 122) }
    return CGSize(width: nominal, height: ceil(nominal / (192.0 / 208.0)))
}

private func parsePetAnchor(_ root: [String: Any], configWidth: Double? = nil, screens: [ScreenGeometry] = []) -> PetAnchor? {
    let atoms = root["electron-persisted-atom-state"] as? [String: Any] ?? [:]
    func pref(_ key: String) -> Any? { root[key] ?? atoms[key] }
    guard pref("electron-avatar-overlay-open") as? Bool == true,
          let bounds = pref("electron-avatar-overlay-bounds") as? [String: Any],
          let savedX = number("x", in: bounds), let savedY = number("y", in: bounds) else { return nil }
    var selected = bounds
    var x = savedX, y = savedY
    if !screens.isEmpty {
        let savedID = number("displayId", in: bounds).map { String(format: "%.0f", $0) }
        let display = screens.first { $0.id == savedID } ?? screens[0]
        if savedID != display.id {
            let byID = bounds["byDisplayId"] as? [String: Any]
            let byResolution = bounds["byResolution"] as? [String: Any]
            let resolution = "\(Int(display.frame.width))x\(Int(display.frame.height))"
            if let saved = byID?[display.id] as? [String: Any] ?? byResolution?[resolution] as? [String: Any],
               let sx = number("x", in: saved), let sy = number("y", in: saved) {
                selected = saved; x = sx; y = sy
            }
        }
        if let old = selected["displayBounds"] as? [String: Any], let oldX = number("x", in: old), let oldY = number("y", in: old) {
            let primaryTop = screens[0].frame.maxY
            x += display.frame.minX - oldX
            y += primaryTop - display.frame.maxY - oldY
        }
    }
    let activeOwner = root["electron-renderer-content-owner"] as? String
    let ownerAtoms = activeOwner.flatMap { root["electron-owner-atoms:" + $0] as? [String: Any] }
    let ownerWidth = ownerAtoms.flatMap { number("avatar-overlay-mascot-width-px", in: $0) }
    // The atom-container route is retained only for the older persisted state shape.
    let legacyWidth = root["electron-persisted-atom-state"] != nil || selected["mascot"] != nil
        ? number("width", in: ["width": pref("avatar-overlay-mascot-width-px") as Any]) : nil
    if let saved = selected["anchor"] as? [String: Any], let ax = number("x", in: saved), let ay = number("y", in: saved) {
        let currentSize = (ownerWidth ?? configWidth).map(currentPetDimensions)
        let width = currentSize?.width ?? number("width", in: saved) ?? 112
        let height = currentSize?.height ?? number("height", in: saved) ?? ceil(width / (192.0 / 208.0))
        if width > 0, height > 0 { return PetAnchor(x: ax + x - (number("x", in: selected) ?? x), y: ay + y - (number("y", in: selected) ?? y), width: width, height: height) }
    }
    if let mascot = selected["mascot"] as? [String: Any], let left = number("left", in: mascot), let top = number("top", in: mascot),
       let width = number("width", in: mascot), let height = number("height", in: mascot), width > 0, height > 0 {
        return PetAnchor(x: x + left, y: y + top, width: width, height: height)
    }
    let rawWidth = ownerWidth ?? configWidth ?? legacyWidth ?? 112
    let size = currentPetDimensions(nominalWidth: rawWidth)
    return PetAnchor(x: x, y: y, width: size.width, height: size.height)
}
private struct StateFileSignature: Equatable {
    let modified: TimeInterval
    let size: UInt64
    let inode: UInt64
    init(_ attributes: [FileAttributeKey: Any]) {
        modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
private func stateSignature(at url: URL) -> StateFileSignature? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)).map(StateFileSignature.init)
}
private struct NativePetWindow {
    var pid: Int32
    var layer: Int
    var frame: CGRect
}
private struct NativePetLayout {
    var left: CGFloat
    var top: CGFloat
    var width: CGFloat
    var height: CGFloat
    var expanded: Bool
}
private func jsRound(_ value: CGFloat) -> CGFloat { floor(value + 0.5) }
private func clampedRound(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    lower > upper ? jsRound((lower + upper) / 2) : clamp(jsRound(value), lower, upper)
}
// Inverse of the shipped app's getLayoutForDisplay physics padding, restricted to one screen.
private func nativePetLayout(displayWidth: CGFloat, displayHeight: CGFloat, expanded: Bool) -> NativePetLayout {
    let drawWidth: CGFloat = 80, drawHeight: CGFloat = 87, padding: CGFloat = 28
    let viewport: CGFloat = expanded ? 386 : 384
    let span = max(0, min(viewport, displayWidth) - padding)
    var minimum = CGFloat.infinity, maximum = -CGFloat.infinity
    for range in [CGFloat(0), span] {
        for position in [CGFloat(0), displayWidth - drawWidth] {
            let offset = clampedRound(position + (drawWidth - range) / 2, 16, displayWidth - range - 16) - position
            minimum = min(minimum, offset); maximum = max(maximum, offset)
        }
    }
    let spring = exp(-CGFloat.pi * 37.7 / sqrt(4 * 720 - 37.7 * 37.7))
    let overshoot = ceil((maximum - minimum) * spring / (1 - spring))
    let labelWidth = min(displayWidth, max(CGFloat(188), CGFloat(160)))
    let left = floor(min(0, minimum - span - overshoot - padding, min((drawWidth - labelWidth) / 2, drawWidth - labelWidth) - padding))
    let extent = max(displayHeight, drawHeight)
    let top = floor(drawHeight - extent - padding)
    let right = ceil(max(drawWidth + padding, maximum + span + overshoot + padding, max((drawWidth + labelWidth) / 2, labelWidth) + padding))
    let bottom = ceil(extent + padding)
    return NativePetLayout(left: left, top: top, width: right-left, height: bottom-top, expanded: expanded)
}
private func nativePetCenter(windows: [NativePetWindow], pids: Set<Int32>, screens: [ScreenGeometry], anchor: PetAnchor) -> CGPoint? {
    guard screens.count == 1 else { return nil }
    let screen = screens[0]
    let height = screen.visible.maxY - screen.frame.minY
    guard screen.visible.width > 0, height > 0 else { return nil }
    let layouts = [false, true].map { nativePetLayout(displayWidth: screen.visible.width, displayHeight: height, expanded: $0) }
    var matches: [CGPoint] = []
    for window in windows where pids.contains(window.pid) && window.layer == 3 {
        for layout in layouts where abs(window.frame.width - layout.width) <= 1 && abs(window.frame.height - layout.height) <= 1 {
            let x = window.frame.minX - layout.left + 40 + anchor.width / 2 - jsRound(anchor.width / 2)
            let y = window.frame.minY - layout.top + (layout.expanded ? anchor.height / 2 : 44 + anchor.height / 2 - jsRound(anchor.height / 2))
            matches.append(CGPoint(x: x, y: y))
        }
    }
    return matches.count == 1 ? matches[0] : nil
}
private func currentNativePetWindows() -> (Set<Int32>, [NativePetWindow]) {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map { $0.processIdentifier })
    guard !pids.isEmpty, let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return (pids, []) }
    let windows = rows.compactMap { row -> NativePetWindow? in
        guard let rawPID = number(kCGWindowOwnerPID as String, in: row), rawPID >= 0, rawPID <= Double(Int32.max), pids.contains(Int32(rawPID)),
              let layer = number(kCGWindowLayer as String, in: row), layer == 3,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let x = number("X", in: bounds), let y = number("Y", in: bounds),
              let width = number("Width", in: bounds), let height = number("Height", in: bounds), width > 0, height > 0 else { return nil }
        return NativePetWindow(pid: Int32(rawPID), layer: 3, frame: CGRect(x: x, y: y, width: width, height: height))
    }
    return (pids, windows)
}
private final class NativePetGeometryCache {
    private var queriedAt: TimeInterval = -.infinity
    private var lastSize = CGSize.zero
    private var lastScreen: CGRect?
    private var lastVisible: CGRect?
    private var pids: Set<Int32> = []
    private var windows: [NativePetWindow] = []
    func center(for anchor: PetAnchor, screens: [ScreenGeometry]) -> CGPoint? {
        guard screens.count == 1 else { return nil }
        let now = Date.timeIntervalSinceReferenceDate
        let size = CGSize(width: anchor.width, height: anchor.height)
        if now - queriedAt >= 1.0 / 30 || size != lastSize || screens[0].frame != lastScreen || screens[0].visible != lastVisible {
            queriedAt = now; lastSize = size; lastScreen = screens[0].frame; lastVisible = screens[0].visible
            (pids, windows) = currentNativePetWindows()
        }
        return nativePetCenter(windows: windows, pids: pids, screens: screens, anchor: anchor)
    }
}
private let nativePetGeometry = NativePetGeometryCache()

// Codex preserves its live center on a size-only change without persisting x/y.
// Mirror its positive-dimension Math.round(half) adjustment until a real saved move arrives.
private final class PetAnchorTracker {
    private var saved: PetAnchor?
    private var resolved: PetAnchor?
    func resolve(_ incoming: PetAnchor?, nativeCenter: CGPoint? = nil) -> PetAnchor? {
        guard let incoming else { saved = nil; resolved = nil; return nil }
        defer { saved = incoming }
        if let nativeCenter {
            let native = PetAnchor(x: nativeCenter.x - incoming.width / 2, y: nativeCenter.y - incoming.height / 2, width: incoming.width, height: incoming.height)
            resolved = native
            return native
        }
        guard let previous = saved, var live = resolved,
              previous.x == incoming.x, previous.y == incoming.y else {
            resolved = incoming
            return incoming
        }
        if previous.width != incoming.width || previous.height != incoming.height {
            live.x += floor(previous.width / 2 + 0.5) - floor(incoming.width / 2 + 0.5)
            live.y += floor(previous.height / 2 + 0.5) - floor(incoming.height / 2 + 0.5)
            live.width = incoming.width; live.height = incoming.height
        }
        resolved = live
        return live
    }
}

private final class AnchorCache {
    private var signature: StateFileSignature?
    private var configSignature: StateFileSignature?
    private var root: [String: Any]?
    private var width: Double?
    private let tracker = PetAnchorTracker()
    private(set) var geometrySource = "Saved anchor / size-only tracking fallback"
    private let stateURL: URL
    private let settingsURL: URL
    private let signatureAt: (URL) -> StateFileSignature?
    private let read: (URL) -> Data?
    private let screens: () -> [ScreenGeometry]
    init(stateURL: URL = globalStateURL, settingsURL: URL = configURL,
         signatureAt: @escaping (URL) -> StateFileSignature? = stateSignature,
         read: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) },
         screens: @escaping () -> [ScreenGeometry] = screenGeometries) {
        self.stateURL = stateURL; self.settingsURL = settingsURL
        self.signatureAt = signatureAt; self.read = read; self.screens = screens
    }
    func anchor() -> PetAnchor? {
        guard let next = signatureAt(stateURL) else { root = nil; signature = nil; return tracker.resolve(nil) }
        if next != signature, let data = read(stateURL), let parsedRoot = jsonObject(from: data) as? [String: Any] {
            root = parsedRoot
            signature = next
        }
        let nextConfig = signatureAt(settingsURL)
        if let nextConfig, nextConfig != configSignature,
           let data = read(settingsURL), let text = String(data: data, encoding: .utf8),
           case .valid(let parsedWidth) = desktopPetWidthRead(in: text) {
            width = parsedWidth
            configSignature = nextConfig
        }
        // Missing attributes or failed/partial reads keep the last successful value.
        // Commit only successful reads so recovery retries even with an unchanged signature.
        let currentScreens = screens()
        let incoming = root.flatMap { parsePetAnchor($0, configWidth: width, screens: currentScreens) }
        let center = incoming.flatMap { nativePetGeometry.center(for: $0, screens: currentScreens) }
        geometrySource = center == nil ? "Saved anchor / size-only tracking fallback" : "Verified single-screen native geometry"
        return tracker.resolve(incoming, nativeCenter: center)
    }
}
private let anchorCache = AnchorCache()
private func currentPetAnchor() -> PetAnchor? { anchorCache.anchor() }

private func savedSizeAdjustment() -> CGFloat {
    let stored = UserDefaults.standard.object(forKey: sizeAdjustmentDefaultsKey) as? Double
    return clamp(CGFloat(stored ?? Double(defaultSizeAdjustment)), minimumSizeAdjustment, maximumSizeAdjustment)
}

private func meterScale(for anchor: PetAnchor, adjustment: CGFloat) -> CGFloat {
    let petWidth = clamp(anchor.width, minimumPetWidth, maximumPetWidth)
    return (petWidth / baselinePetWidth) * clamp(adjustment, minimumSizeAdjustment, maximumSizeAdjustment)
}

private struct ScreenGeometry {
    var frame: CGRect
    var visible: CGRect
    var id: String
}
private func screenGeometries() -> [ScreenGeometry] {
    NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visible: $0.visibleFrame, id: String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "")) }
}
private func targetScreen(for anchor: PetAnchor, screens: [ScreenGeometry]) -> ScreenGeometry? {
    let origin = screens.first?.frame.maxY ?? 900
    let point = CGPoint(x: anchor.x + anchor.width / 2, y: origin - anchor.y - anchor.height / 2)
    return screens.first { $0.frame.contains(point) } ?? screens.min { a, b in
        hypot(a.frame.midX - point.x, a.frame.midY - point.y) < hypot(b.frame.midX - point.x, b.frame.midY - point.y)
    }
}
private func overlayLayout(for anchor: PetAnchor, sizeAdjustment: CGFloat, screens: [ScreenGeometry] = screenGeometries()) -> OverlayLayout {
    let scale = meterScale(for: anchor, adjustment: sizeAdjustment)
    let edge = targetScreen(for: anchor, screens: screens)?.visible.maxX ?? 1440
    let requiredRightEdge = anchor.x + anchor.width / 2 + (OverlayLayout.baseWidth - 118) * scale
    return OverlayLayout(labelSide: requiredRightEdge > edge ? .left : .right, scale: scale)
}
private func appKitFrame(for anchor: PetAnchor, layout: OverlayLayout, screens: [ScreenGeometry] = screenGeometries()) -> NSRect {
    let origin = screens.first?.frame.maxY ?? 900
    return NSRect(x: anchor.x + anchor.width / 2 - layout.ringCenterX,
                  y: origin - anchor.y - anchor.height / 2 - layout.ringCenter.y,
                  width: layout.width, height: layout.height)
}

private class MeterView: NSView {
    var snapshot = MeterSnapshot.unavailable { didSet { needsDisplay = true } }
    var layout = OverlayLayout(labelSide: .right, scale: 1.0) {
        didSet {
            guard oldValue != layout else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var sizeAdjustment = defaultSizeAdjustment {
        didSet { if oldValue != sizeAdjustment { needsDisplay = true } }
    }
    var isSizeControlVisible = false {
        didSet {
            guard oldValue != isSizeControlVisible else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onFoodBadgeClick: (() -> Void)?
    var onSizeAdjustmentChange: ((CGFloat) -> Void)?
    var animationClock: () -> Date = Date.init
    private var manualRefreshAnimationStart: Date?
    private var isDraggingSizeControl = false
    var isSizeControlDragging: Bool { isDraggingSizeControl }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMeter(in: bounds, snapshot: snapshot, layout: layout, animation: currentManualRefreshAnimation(), showSizeControl: isSizeControlVisible || isDraggingSizeControl, sizeAdjustment: sizeAdjustment)
    }

    func startManualRefreshAnimation() {
        manualRefreshAnimationStart = animationClock()
        needsDisplay = true
    }

    // Tracking ticks redraw only the bounded manual confirmation animation.
    // The terminal tick also redraws once to restore the fully settled state.
    func tickManualRefreshAnimation() {
        guard manualRefreshAnimationStart != nil else { return }
        _ = currentManualRefreshAnimation()
        needsDisplay = true
    }

    private func currentManualRefreshAnimation() -> ManualRefreshAnimation? {
        guard let start = manualRefreshAnimationStart else { return nil }
        let elapsed = animationClock().timeIntervalSince(start)
        guard let state = animationState(elapsed: elapsed) else {
            manualRefreshAnimationStart = nil
            return nil
        }
        return state
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveHitRect(layout: layout, includeSizeControl: isSizeControlVisible || isDraggingSizeControl).contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if (isSizeControlVisible || isDraggingSizeControl), sizeControlHitRect(layout: layout).contains(point) {
            isDraggingSizeControl = true
            updateSizeAdjustment(from: point)
            return
        }
        guard foodBadgeHitRect(layout: layout).contains(point) else { return }
        onFoodBadgeClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSizeControl else { return }
        updateSizeAdjustment(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingSizeControl else { return }
        updateSizeAdjustment(from: convert(event.locationInWindow, from: nil))
        isDraggingSizeControl = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(foodBadgeHitRect(layout: layout), cursor: .pointingHand)
        if isSizeControlVisible || isDraggingSizeControl {
            addCursorRect(sizeControlHitRect(layout: layout), cursor: .resizeLeftRight)
        }
    }

    private func updateSizeAdjustment(from point: NSPoint) {
        let track = sizeControlTrackRect(layout: layout)
        let progress = clamp((point.x - track.minX) / track.width, 0.0, 1.0)
        let next = minimumSizeAdjustment + progress * (maximumSizeAdjustment - minimumSizeAdjustment)
        sizeAdjustment = next
        onSizeAdjustmentChange?(next)
    }
}

private func colorForRemaining(_ remaining: Double, kind: RingKind) -> NSColor {
    switch remaining {
    case 66...100:
        return kind == .weekly ? NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.86, alpha: 1.0) : NSColor(calibratedRed: 0.56, green: 0.92, blue: 0.68, alpha: 1.0)
    case 34..<66:
        return kind == .weekly ? NSColor(calibratedRed: 0.42, green: 0.65, blue: 0.98, alpha: 1.0) : NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.28, alpha: 1.0)
    default:
        return kind == .weekly ? NSColor(calibratedRed: 0.97, green: 0.42, blue: 0.50, alpha: 1.0) : NSColor(calibratedRed: 0.98, green: 0.48, blue: 0.30, alpha: 1.0)
    }
}

private enum RingKind {
    case weekly
    case fiveHour
}

private struct ManualRefreshAnimation {
    var ringAlpha: CGFloat
    var labelAlpha: CGFloat
    var ringProgress: CGFloat
}

private let manualRefreshAnimationDuration: TimeInterval = 0.9

private func easeOutCubic(_ value: CGFloat) -> CGFloat {
    let clamped = clamp(value, 0.0, 1.0)
    let remaining = 1.0 - clamped
    return 1.0 - remaining * remaining * remaining
}

private func animationState(elapsed: TimeInterval) -> ManualRefreshAnimation? {
    guard elapsed >= 0, elapsed < manualRefreshAnimationDuration else { return nil }
    let fadeOutDuration: CGFloat = 0.25
    let refillStart: CGFloat = 0.25
    let refillEnd: CGFloat = 0.65
    let labelFadeStart: CGFloat = 0.45
    let elapsed = CGFloat(elapsed)

    if elapsed < fadeOutDuration {
        let fade = elapsed / fadeOutDuration
        let alpha = 1.0 - fade * 0.84
        return ManualRefreshAnimation(ringAlpha: alpha, labelAlpha: alpha, ringProgress: 1.0)
    }

    let refillProgress = easeOutCubic((elapsed - refillStart) / (refillEnd - refillStart))
    let labelAlpha = easeOutCubic((elapsed - labelFadeStart) / (CGFloat(manualRefreshAnimationDuration) - labelFadeStart))
    return ManualRefreshAnimation(ringAlpha: 1.0, labelAlpha: labelAlpha, ringProgress: refillProgress)
}

private func drawMeter(in rect: NSRect, snapshot: MeterSnapshot, layout: OverlayLayout, animation: ManualRefreshAnimation?, showSizeControl: Bool, sizeAdjustment: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.setShouldAntialias(true)

    let center = layout.ringCenter
    let outerRadius = layout.ringDiameter * 0.43
    let innerRadius = layout.ringDiameter * 0.31

    let ringProgress = animation?.ringProgress ?? 1.0
    let ringAlpha = animation?.ringAlpha ?? 1.0
    let labelAlpha = animation?.labelAlpha ?? 1.0

    drawPeriodRing(snapshot.weekly, center: center, radius: outerRadius, lineWidth: 13 * layout.scale, remaining: snapshot.weeklyRemaining * Double(ringProgress), colorRemaining: snapshot.weeklyRemaining, kind: .weekly, alpha: ringAlpha)
    drawPeriodRing(snapshot.fiveHour, center: center, radius: innerRadius, lineWidth: 7 * layout.scale, remaining: snapshot.fiveHourRemaining * Double(ringProgress), colorRemaining: snapshot.fiveHourRemaining, kind: .fiveHour, alpha: ringAlpha)
    drawFoodBadge(center: foodBadgeCenter(layout: layout), scale: layout.scale)
    drawRingLabels(layout: layout, snapshot: snapshot, alpha: labelAlpha)
    if showSizeControl {
        drawSizeControl(layout: layout, adjustment: sizeAdjustment)
    }

    context.restoreGState()
}

private func foodBadgeCenter(layout: OverlayLayout) -> CGPoint {
    let outerRadius = layout.ringDiameter * 0.43
    return CGPoint(x: layout.ringCenter.x, y: layout.ringCenter.y - outerRadius - 3 * layout.scale)
}

private func foodBadgeRect(layout: OverlayLayout) -> NSRect {
    let center = foodBadgeCenter(layout: layout)
    return NSRect(x: center.x - 34 * layout.scale, y: center.y - 20 * layout.scale, width: 68 * layout.scale, height: 48 * layout.scale)
}

private func foodBadgeHitRect(layout: OverlayLayout) -> NSRect {
    foodBadgeRect(layout: layout).insetBy(dx: -max(4, 4 * layout.scale), dy: -max(4, 4 * layout.scale))
}

private func sizeControlTrackRect(layout: OverlayLayout) -> NSRect {
    let foodRect = foodBadgeRect(layout: layout)
    let width = max(78 * layout.scale, 64)
    let height = max(5 * layout.scale, 4)
    return NSRect(x: foodRect.midX - width / 2, y: foodRect.minY - 20 * layout.scale, width: width, height: height)
}

private func sizeControlHitRect(layout: OverlayLayout) -> NSRect {
    sizeControlTrackRect(layout: layout).insetBy(dx: -10 * layout.scale, dy: -9 * layout.scale)
}

private func interactiveHitRect(layout: OverlayLayout, includeSizeControl: Bool) -> NSRect {
    let foodRect = foodBadgeHitRect(layout: layout)
    guard includeSizeControl else { return foodRect }
    return foodRect.union(sizeControlHitRect(layout: layout))
}

private func sizeControlHoverRect(layout: OverlayLayout) -> NSRect {
    foodBadgeHitRect(layout: layout).union(sizeControlHitRect(layout: layout)).insetBy(dx: -8 * layout.scale, dy: -6 * layout.scale)
}

private func drawPeriodRing(_ period: Period, center: CGPoint, radius: CGFloat, lineWidth: CGFloat, remaining: Double, colorRemaining: Double?, kind: RingKind, alpha: CGFloat) {
    switch period {
    case .limited:
        drawRing(center: center, radius: radius, lineWidth: lineWidth, remaining: remaining, colorRemaining: colorRemaining, kind: kind, alpha: alpha)
    case .unknown:
        NSColor(calibratedWhite: 0.55, alpha: 0.30).setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
        path.lineWidth = lineWidth; path.stroke()
    case .noLimit:
        // Overlapping tiny arcs interpolate a closed pastel circle; no end caps or animation.
        let colors: [NSColor] = [NSColor(red: 1, green: 0.72, blue: 0.82, alpha: 1), NSColor(red: 1, green: 0.80, blue: 0.65, alpha: 1), NSColor(red: 1, green: 0.92, blue: 0.66, alpha: 1), NSColor(red: 0.69, green: 0.94, blue: 0.80, alpha: 1), NSColor(red: 0.67, green: 0.86, blue: 1, alpha: 1), NSColor(red: 0.84, green: 0.74, blue: 0.98, alpha: 1), NSColor(red: 1, green: 0.72, blue: 0.82, alpha: 1)]
        for i in 0..<720 {
            let t = Double(i) / 720 * 6
            let n = min(Int(t), 5)
            let color = colors[n].blended(withFraction: t - Double(n), of: colors[n+1])!
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90-CGFloat(i)*0.5, endAngle: 90-CGFloat(i)*0.5-0.65, clockwise: true)
            arc.lineWidth = lineWidth + 4
            color.withAlphaComponent(0.12).setStroke(); arc.stroke()
            arc.lineWidth = lineWidth
            color.setStroke(); arc.stroke()
        }
    }
}

private func drawRing(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, remaining: Double, colorRemaining: Double? = nil, kind: RingKind, alpha: CGFloat = 1.0) {
    let colorValue = colorRemaining ?? remaining
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    NSColor(calibratedWhite: 1.0, alpha: (kind == .weekly ? 0.14 : 0.10) * alpha).setStroke()
    track.stroke()

    let startAngle: CGFloat = 90
    let endAngle = startAngle - CGFloat(remaining / 100.0) * 360.0
    let glow = NSBezierPath()
    glow.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    glow.lineCapStyle = .round
    glow.lineWidth = lineWidth + (kind == .weekly ? lineWidth * 0.70 : lineWidth * 0.86)
    colorForRemaining(colorValue, kind: kind).withAlphaComponent((kind == .weekly ? 0.20 : 0.16) * alpha).setStroke()
    glow.stroke()

    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ring.lineCapStyle = .round
    ring.lineWidth = lineWidth
    colorForRemaining(colorValue, kind: kind).withAlphaComponent(alpha).setStroke()
    ring.stroke()

    let capAngle = endAngle * .pi / 180
    let cap = CGPoint(x: center.x + cos(capAngle) * radius, y: center.y + sin(capAngle) * radius)
    let capSize = lineWidth + 4
    colorForRemaining(colorValue, kind: kind).withAlphaComponent(0.92 * alpha).setFill()
    NSBezierPath(ovalIn: NSRect(x: cap.x - capSize / 2, y: cap.y - capSize / 2, width: capSize, height: capSize)).fill()
    NSColor.white.withAlphaComponent(0.45 * alpha).setStroke()
    let capStroke = NSBezierPath(ovalIn: NSRect(x: cap.x - capSize / 2, y: cap.y - capSize / 2, width: capSize, height: capSize))
    capStroke.lineWidth = 1
    capStroke.stroke()
}

private func drawFoodBadge(center: CGPoint, scale: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let rect = NSRect(x: center.x - 34 * scale, y: center.y - 20 * scale, width: 68 * scale, height: 48 * scale)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 9, color: NSColor(calibratedRed: 0.80, green: 0.43, blue: 0.12, alpha: 0.28).cgColor)
    if let image = foodBowlImage() {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    } else {
        NSColor(calibratedRed: 0.96, green: 0.68, blue: 0.32, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 6 * scale, dy: 10 * scale), xRadius: 10 * scale, yRadius: 8 * scale).fill()
    }
    context.restoreGState()
}

private func drawSizeControl(layout: OverlayLayout, adjustment: CGFloat) {
    let track = sizeControlTrackRect(layout: layout)
    let progress = clamp((adjustment - minimumSizeAdjustment) / (maximumSizeAdjustment - minimumSizeAdjustment), 0.0, 1.0)
    let centerX = track.minX + track.width * progress
    let knobDiameter = max(13 * layout.scale, 11)
    let glowRect = track.insetBy(dx: -7 * layout.scale, dy: -7 * layout.scale)

    NSColor(calibratedWhite: 0.02, alpha: 0.42).setFill()
    NSBezierPath(roundedRect: glowRect, xRadius: glowRect.height / 2, yRadius: glowRect.height / 2).fill()

    NSColor(calibratedWhite: 1.0, alpha: 0.22).setFill()
    NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

    let activeWidth = centerX - track.minX
    if activeWidth > 1 {
        let active = NSRect(x: track.minX, y: track.minY, width: activeWidth, height: track.height)
        NSColor(calibratedRed: 0.37, green: 0.88, blue: 0.96, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: active, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }

    let knobRect = NSRect(x: centerX - knobDiameter / 2, y: track.midY - knobDiameter / 2, width: knobDiameter, height: knobDiameter)
    NSColor(calibratedRed: 0.89, green: 0.99, blue: 1.0, alpha: 0.96).setFill()
    NSBezierPath(ovalIn: knobRect).fill()
    NSColor(calibratedRed: 0.20, green: 0.76, blue: 0.82, alpha: 0.82).setStroke()
    let knobStroke = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
    knobStroke.lineWidth = max(1, layout.scale)
    knobStroke.stroke()
}

private func foodBowlImage() -> NSImage? {
    if let resourceURL = Bundle.main.url(forResource: foodBowlResourceName, withExtension: "png") {
        return NSImage(contentsOf: resourceURL)
    }

    let fallbackURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("reference")
        .appendingPathComponent("\(foodBowlResourceName).png")
    return NSImage(contentsOf: fallbackURL)
}

private func drawRingLabels(layout: OverlayLayout, snapshot: MeterSnapshot, alpha: CGFloat = 1.0) {
    let weeklyColor = snapshot.weekly == .unknown ? NSColor.gray : colorForRemaining(snapshot.weeklyRemaining, kind: .weekly)
    let fiveHourColor = snapshot.fiveHour == .unknown ? NSColor.gray : snapshot.fiveHour == .noLimit ? NSColor(calibratedRed: 0.93, green: 0.79, blue: 0.92, alpha: 1) : colorForRemaining(snapshot.fiveHourRemaining, kind: .fiveHour)
    let weeklyAngle: CGFloat = layout.labelSide == .right ? 28 : 152
    let fiveHourAngle: CGFloat = layout.labelSide == .right ? -18 : 198

    drawConnector(from: pointOnRing(center: layout.ringCenter, radius: layout.ringDiameter * 0.43, degrees: weeklyAngle), to: layout.weeklyLabelRect, side: layout.labelSide, color: weeklyColor, scale: layout.scale, alpha: alpha)
    drawConnector(from: pointOnRing(center: layout.ringCenter, radius: layout.ringDiameter * 0.31, degrees: fiveHourAngle), to: layout.fiveHourLabelRect, side: layout.labelSide, color: fiveHourColor, scale: layout.scale, alpha: alpha)

    drawCompactLabel(rect: layout.weeklyLabelRect, label: "Weekly", value: snapshot.weekly.text, color: weeklyColor, scale: layout.scale, alpha: alpha)
    drawCompactLabel(rect: layout.fiveHourLabelRect, label: "5h", value: snapshot.fiveHour.text, color: fiveHourColor, scale: layout.scale, alpha: alpha)
    drawResetBadge(rect: layout.resetBadgeRect, weeklyResetAt: snapshot.weeklyResetAt, fiveHourResetAt: snapshot.fiveHourResetAt, scale: layout.scale, alpha: alpha, fiveText: snapshot.fiveHour.resetText, weeklyUnknown: snapshot.weekly == .unknown)
    if snapshot.source == .cached {
        let badge = layout.cachedBadgeRect
        NSColor(calibratedWhite: 0.03, alpha: 0.84).setFill()
        let capsule = NSBezierPath(roundedRect: badge, xRadius: 8 * layout.scale, yRadius: 8 * layout.scale)
        capsule.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        capsule.lineWidth = max(0.6, layout.scale * 0.8); capsule.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9 * layout.scale, weight: .semibold), .foregroundColor: NSColor.white]
        "Cached " .appending(resetTimeText(snapshot.updatedAt)).draw(at: CGPoint(x: badge.minX + 8 * layout.scale, y: badge.minY + 4 * layout.scale), withAttributes: attrs)
    }
}

private func pointOnRing(center: CGPoint, radius: CGFloat, degrees: CGFloat) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
}

private func drawConnector(from start: CGPoint, to rect: NSRect, side: LabelSide, color: NSColor, scale: CGFloat, alpha: CGFloat = 1.0) {
    let end = CGPoint(x: side == .right ? rect.minX : rect.maxX, y: rect.midY)
    let mid = CGPoint(x: (start.x + end.x) / 2, y: end.y)
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: mid)
    path.line(to: end)
    path.lineWidth = 1.2 * scale
    path.setLineDash([3 * scale, 3 * scale], count: 2, phase: 0)
    color.withAlphaComponent(0.62 * alpha).setStroke()
    path.stroke()
    color.withAlphaComponent(0.92 * alpha).setFill()
    NSBezierPath(ovalIn: NSRect(x: start.x - 2 * scale, y: start.y - 2 * scale, width: 4 * scale, height: 4 * scale)).fill()
}

private struct LabelTextLayout {
    var font: NSFont
    var frame: NSRect
    var measuredSize: NSSize
}
private func centeredLabelText(_ text: String, font: NSFont, in region: NSRect) -> LabelTextLayout {
    let measured = (text as NSString).size(withAttributes: [.font: font])
    return LabelTextLayout(font: font, frame: NSRect(x: region.minX, y: region.midY - measured.height / 2, width: region.width, height: measured.height), measuredSize: measured)
}
private func compactLabelText(rect: NSRect, label: String, value: String, scale: CGFloat) -> (LabelTextLayout, LabelTextLayout) {
    let caption = centeredLabelText(label, font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium), in: NSRect(x: rect.minX + 9 * scale, y: rect.minY, width: (label == "5h" ? 24 : 45) * scale, height: rect.height))
    let amount = centeredLabelText(value, font: NSFont.monospacedDigitSystemFont(ofSize: (value == "No Limit" ? 14.5 : 18) * scale, weight: .bold), in: NSRect(x: rect.minX + 42 * scale, y: rect.minY, width: rect.width - 50 * scale, height: rect.height))
    return (caption, amount)
}

private func drawCompactLabel(rect: NSRect, label: String, value: String, color: NSColor, scale: CGFloat, alpha: CGFloat = 1.0) {
    let panel = NSBezierPath(roundedRect: rect, xRadius: 9 * scale, yRadius: 9 * scale)
    NSColor(calibratedWhite: 0.02, alpha: 0.58 * alpha).setFill()
    panel.fill()
    color.withAlphaComponent(0.48 * alpha).setStroke()
    panel.lineWidth = 1.2 * scale
    panel.stroke()

    let (caption, amount) = compactLabelText(rect: rect, label: label, value: value, scale: scale)
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: caption.font,
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.78 * alpha)
    ]
    let valueParagraph = NSMutableParagraphStyle()
    valueParagraph.alignment = .right
    let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: amount.font,
        .foregroundColor: color.withAlphaComponent(alpha),
        .paragraphStyle: valueParagraph
    ]
    label.draw(in: caption.frame, withAttributes: labelAttrs)
    value.draw(in: amount.frame, withAttributes: valueAttrs)
}

private func resetDateText(_ date: Date?) -> String {
    guard let date else { return "--/--/-- --:--" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy/MM/dd HH:mm"
    return formatter.string(from: date)
}

private func resetTimeText(_ date: Date?) -> String {
    guard let date else { return "--:--" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func drawResetBadge(rect: NSRect, weeklyResetAt: Date?, fiveHourResetAt: Date?, scale: CGFloat, alpha: CGFloat = 1.0, fiveText: String, weeklyUnknown: Bool) {
    let panel = NSBezierPath(roundedRect: rect, xRadius: 11 * scale, yRadius: 11 * scale)
    NSColor(calibratedWhite: 0.02, alpha: 0.48 * alpha).setFill()
    panel.fill()
    NSColor(calibratedRed: 0.63, green: 0.88, blue: 1.0, alpha: 0.28 * alpha).setStroke()
    panel.lineWidth = 1.1 * scale
    panel.stroke()

    let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8.5 * scale, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.82 * alpha)
    ]
    let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.88 * alpha)
    ]
    let fiveHourAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * scale, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.96, blue: 0.82, alpha: 0.92 * alpha)
    ]

    "W".draw(in: NSRect(x: rect.minX + 9 * scale, y: rect.minY + 21 * scale, width: 14 * scale, height: 11 * scale), withAttributes: captionAttrs)
    (weeklyUnknown ? "—" : resetDateText(weeklyResetAt)).draw(in: NSRect(x: rect.minX + 23 * scale, y: rect.minY + 19 * scale, width: rect.width - 30 * scale, height: 14 * scale), withAttributes: valueAttrs)
    "5h".draw(in: NSRect(x: rect.minX + 9 * scale, y: rect.minY + 6 * scale, width: 16 * scale, height: 11 * scale), withAttributes: captionAttrs)
    fiveText.draw(in: NSRect(x: rect.minX + 27 * scale, y: rect.minY + 4 * scale, width: 110 * scale, height: 15 * scale), withAttributes: fiveHourAttrs)
}

private let fixtureDate = Date(timeIntervalSince1970: 1893974400)
private func fixture(_ name: String) -> MeterSnapshot {
    var snap = MeterSnapshot(fiveHour: .limited(59, fixtureDate.addingTimeInterval(9000)), weekly: .limited(28, fixtureDate.addingTimeInterval(432000)), planType: "preview", source: .live, updatedAt: fixtureDate)
    switch name {
    case "public-pro": snap.fiveHour = .noLimit; snap.weekly = .limited(28, fixtureDate.addingTimeInterval(432000)); snap.planType = "pro"
    case "pro-no-limit": snap.fiveHour = .noLimit; snap.weekly = .limited(3, fixtureDate.addingTimeInterval(363135))
    case "unknown": snap.fiveHour = .unknown; snap.weekly = .unknown; snap.source = .unavailable
    case "cached": snap.source = .cached
    default: break
    }
    return snap
}
private func writePreview(to url: URL, size: CGFloat, name: String, side: LabelSide, adjustment: CGFloat) -> Bool {
    let anchor = PetAnchor(x: 0, y: 0, width: clamp(size, minimumPetWidth, maximumPetWidth), height: 108)
    let layout = OverlayLayout(labelSide: side, scale: meterScale(for: anchor, adjustment: adjustment))
    let view = MeterView(frame: NSRect(x: 0, y: 0, width: layout.width, height: layout.height))
    view.snapshot = fixture(name); view.layout = layout; view.sizeAdjustment = adjustment
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: url); return true } catch { return false }
}
private func printSnapshot(_ snapshot: MeterSnapshot) {
    print("Codex Pet Hunger Meter")
    print("Source: \(snapshot.source.rawValue)")
    print("Plan: \(snapshot.planType)")
    print("Outer weekly remaining: \(snapshot.weekly.text)")
    print("Inner 5h remaining: \(snapshot.fiveHour.text)")
    print("Weekly reset: \(snapshot.weekly == .unknown ? "—" : resetDateText(snapshot.weeklyResetAt))")
    print("5h reset: \(snapshot.fiveHour.resetText)")
    print("Last success: \(snapshot.source == .unavailable ? "—" : resetDateText(snapshot.updatedAt))")
    if let failure = snapshot.failure { print("Reason: \(failure)") }
}
private func printStatus(cachedOnly: Bool) -> Int32 {
    if cachedOnly {
        print("Unverified legacy diagnostic; account identity unknown; never used by UI")
        guard let value = cachedSnapshot() else { printSnapshot(.unavailable); return 1 }
        printSnapshot(value); return 0
    }
    let store = MeterStore()
    var finished = false
    store.onChange = { if store.snapshot.source != .unavailable || store.snapshot.failure != nil { finished = true } }
    store.refresh()
    let deadline = Date().addingTimeInterval(10)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    printSnapshot(store.snapshot)
    return store.snapshot.source == .unavailable ? 1 : 0
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MeterStore()
    private var window: NSWindow!
    private var meterView: MeterView!
    private var statusItem: NSStatusItem!
    private var overlayTimer: Timer?
    private var refreshTimer: Timer?
    private var lastFrame: NSRect?
    private var wasShowing = false
    private var visible = UserDefaults.standard.object(forKey: "visible") as? Bool ?? true
    private var sizeAdjustment = savedSizeAdjustment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupWindow()
        setupMenu()

        store.onChange = { [weak self] in
            self?.meterView.snapshot = self?.store.snapshot ?? .unavailable
            self?.updateMenu()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.store.refresh() }
        store.refresh()
        updateOverlay()

        overlayTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.store.expireIfNeeded()
            self?.updateOverlay()
        }
        overlayTimer?.tolerance = 0
        if let overlayTimer {
            RunLoop.main.add(overlayTimer, forMode: .common)
        }

        refreshTimer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
        refreshTimer?.tolerance = 2
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func setupWindow() {
        let initialLayout = OverlayLayout(labelSide: .right, scale: 1.0)
        meterView = MeterView(frame: NSRect(x: 0, y: 0, width: initialLayout.width, height: initialLayout.height))
        meterView.layout = initialLayout
        meterView.sizeAdjustment = sizeAdjustment
        window = NSWindow(
            contentRect: meterView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = meterView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        meterView.onFoodBadgeClick = { [weak self] in
            self?.refreshNow()
        }
        meterView.onSizeAdjustmentChange = { [weak self] adjustment in
            self?.sizeAdjustment = adjustment
            UserDefaults.standard.set(Double(adjustment), forKey: sizeAdjustmentDefaultsKey)
            self?.lastFrame = nil
            self?.updateOverlay()
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Pet Meter"
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: visible ? "Hide Hunger Meter" : "Show Hunger Meter", action: #selector(toggleVisible), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        let snap = store.snapshot
        menu.addItem(NSMenuItem(title: "Outer Weekly: \(snap.weekly.text)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Inner 5h: \(snap.fiveHour.text)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Weekly Reset: \(snap.weekly == .unknown ? "—" : resetDateText(snap.weeklyResetAt))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "5h Reset: \(snap.fiveHour.resetText)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Last Success: \(snap.source == .unavailable ? "—" : resetDateText(snap.updatedAt))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Data Source: \(snap.source.rawValue)", action: nil, keyEquivalent: ""))
        if let reason = snap.failure { menu.addItem(NSMenuItem(title: reason, action: nil, keyEquivalent: "")) }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleVisible() {
        visible.toggle()
        UserDefaults.standard.set(visible, forKey: "visible")
        updateOverlay()
        updateMenu()
    }

    @objc private func refreshNow() {
        meterView.startManualRefreshAnimation()
        store.refresh()
        updateOverlay()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateOverlay() {
        meterView.tickManualRefreshAnimation()
        guard visible, let anchor = currentPetAnchor() else {
            window.ignoresMouseEvents = true
            window.orderOut(nil)
            wasShowing = false
            lastFrame = nil
            return
        }
        let layout = overlayLayout(for: anchor, sizeAdjustment: sizeAdjustment)
        meterView.layout = layout
        meterView.sizeAdjustment = sizeAdjustment
        let frame = appKitFrame(for: anchor, layout: layout)
        if lastFrame != frame {
            window.setFrame(frame, display: true)
            lastFrame = frame
        }
        if !wasShowing {
            window.orderFrontRegardless()
            wasShowing = true
        }
        updateMousePassthrough()
    }

    private func updateMousePassthrough() {
        guard visible, window.isVisible else {
            window.ignoresMouseEvents = true
            return
        }

        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let localPoint = NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let foodHit = foodBadgeHitRect(layout: meterView.layout).contains(localPoint)
        let controlHit = meterView.isSizeControlVisible && sizeControlHoverRect(layout: meterView.layout).contains(localPoint)
        meterView.isSizeControlVisible = foodHit || controlHit || meterView.isSizeControlDragging
        window.ignoresMouseEvents = !(meterView.isSizeControlDragging || interactiveHitRect(layout: meterView.layout, includeSizeControl: meterView.isSizeControlVisible).contains(localPoint))
    }
}

// An unattached NSView in a headless process may discard needsDisplay writes.
// Record the inherited implementation's real invalidation requests without a window/server.
private final class RedrawProbeView: MeterView {
    private var requestedDisplay = false
    override var needsDisplay: Bool {
        get { requestedDisplay }
        set { requestedDisplay = newValue }
    }
}

private func selfTest() -> Int32 {
    var count = 0
    var failures = 0
    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        count += 1
        if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
    }
    func window(_ duration: Any, _ used: Any, _ reset: Double = 1795217441) -> [String: Any] { ["limit_window_seconds": duration, "used_percent": used, "reset_at": reset] }
    func parse(_ primary: Any, _ secondary: Any = NSNull(), _ plan: String = "prolite", _ source: DataSource = .live) -> MeterSnapshot {
        parseSnapshot(from: ["plan_type": plan, "rate_limit": ["primary_window": primary, "secondary_window": secondary]], source: source, updatedAt: fixtureDate)!
    }
    let weekly = window(604800, 3)
    let five = window(18000, 42)
    let pro = parse(weekly)
    check("current Pro weekly duration", pro.weekly.remaining == 97)
    check("current Pro no 5h limit", pro.fiveHour == .noLimit)
    check("casefold Pro", parse(weekly, NSNull(), "ProMax").fiveHour == .noLimit)
    check("old two windows", parse(five, weekly).fiveHour.remaining == 58)
    check("reversed windows", parse(weekly, five).weekly.remaining == 97 && parse(weekly, five).fiveHour.remaining == 58)
    check("Pro real five wins", parse(weekly, five).fiveHour != .noLimit)
    check("unknown plan null remains unknown", parse(weekly, NSNull(), "other").fiveHour == .unknown)
    check("valid partial preserved", parse(five, NSNull(), "other").fiveHour.remaining == 58)
    check("boolean rejected", parse(weekly, window(18000, true)).fiveHour == .unknown)
    check("NaN rejected", parse(weekly, window(18000, Double.nan)).fiveHour == .unknown)
    check("Infinity rejected", parse(weekly, window(18000, Double.infinity)).fiveHour == .unknown)
    check("numeric string rejected", parse(weekly, window(18000, "3")).fiveHour == .unknown)
    check("unknown duration blocks inference", parse(weekly, window(100, 3)).fiveHour == .unknown)
    check("duplicate conflict unknown", parse(weekly, window(604800, 9)).weekly == .unknown)
    check("legacy never no limit", parse(weekly, NSNull(), "prolite", .cached).fiveHour == .unknown)
    check("unrelated main response rejected", parseSnapshot(from: ["code_review_rate_limit": ["primary_window": weekly]], source: .live) == nil)
    if case .failure(.http) = decodeResponse(data: Data("{}".utf8), status: 401, error: nil, now: fixtureDate) { check("HTTP errors", true) } else { check("HTTP errors", false) }
    if case .failure(.transport) = decodeResponse(data: nil, status: 200, error: NSError(domain: "test", code: 1), now: fixtureDate) { check("transport errors", true) } else { check("transport errors", false) }
    if case .failure(.invalid) = decodeResponse(data: Data("{}".utf8), status: 200, error: nil, now: fixtureDate) { check("invalid HTTP200", true) } else { check("invalid HTTP200", false) }
    let event = "prefix websocket event: { \"rate_limits\": {\"primary\":{\"window_minutes\":10080,\"used_percent\":3,\"resets_at\":1795217441}}, \"type\" : \"codex.rate_limits\" } tail"
    check("legacy whitespace key order minutes", legacyEvent(event, at: fixtureDate)?.weekly.remaining == 97)
    var now = fixtureDate
    var identity = "A"
    var completions: [(Result<MeterSnapshot, UsageFailure>) -> Void] = []
    let store = MeterStore(clock: { now }, auth: { Credentials(token: "synthetic", identity: identity) }, request: { _, callback in completions.append(callback) })
    store.refresh(); store.refresh(); store.refresh()
    check("singleflight coalesces", completions.count == 1)
    completions[0](.success(pro))
    check("coalesced one followup", completions.count == 2)
    completions[1](.failure(.transport))
    check("same account cached", store.snapshot.source == .cached && store.snapshot.fiveHour == .noLimit)
    now = fixtureDate.addingTimeInterval(301); store.refresh(); completions[2](.failure(.http))
    check("cache TTL expires", store.snapshot.source == .unavailable && store.snapshot.weekly == .unknown)
    now = fixtureDate
    store.refresh(); let old = completions[3]
    identity = "B"; store.refresh()
    check("account change clears", store.snapshot.source == .unavailable)
    old(.success(pro))
    check("old account response ignored", store.snapshot.source == .unavailable)
    let reset = MeterSnapshot(fiveHour: .limited(3, fixtureDate.addingTimeInterval(10)), weekly: .limited(20, fixtureDate.addingTimeInterval(100)), planType: "plus", source: .live, updatedAt: fixtureDate)
    completions[4](.success(reset)); now = fixtureDate.addingTimeInterval(20)
    store.refresh(); completions[5](.failure(.http))
    check("passed reset affected period unknown", store.snapshot.fiveHour == .unknown && store.snapshot.weekly.remaining == 80)
    var boundaryNow = fixtureDate
    var boundaryCallbacks: [(Result<MeterSnapshot, UsageFailure>) -> Void] = []
    let boundaryStore = MeterStore(clock: { boundaryNow }, auth: { Credentials(token: "fixture", identity: "boundary") }, request: { _, callback in boundaryCallbacks.append(callback) })
    boundaryStore.refresh(); boundaryCallbacks[0](.success(pro))
    boundaryNow = fixtureDate.addingTimeInterval(299)
    boundaryStore.refresh(); boundaryCallbacks[1](.failure(.transport))
    check("boundary cached at299", boundaryStore.snapshot.source == .cached)
    boundaryNow = fixtureDate.addingTimeInterval(301)
    boundaryStore.refresh() // Deliberately leave this request incomplete.
    check("TTL expires while request pending", boundaryStore.snapshot.source == .unavailable && boundaryStore.snapshot.weekly == .unknown && boundaryStore.snapshot.fiveHour == .unknown)
    var expirationChanges = 0
    boundaryStore.onChange = { expirationChanges += 1 }
    boundaryStore.expireIfNeeded(); boundaryStore.expireIfNeeded()
    check("expiration publishes once", expirationChanges == 1)
    var resetNow = fixtureDate
    var resetCallbacks: [(Result<MeterSnapshot, UsageFailure>) -> Void] = []
    let resetStore = MeterStore(clock: { resetNow }, auth: { Credentials(token: "fixture", identity: "reset") }, request: { _, callback in resetCallbacks.append(callback) })
    resetStore.refresh(); resetCallbacks[0](.success(reset))
    resetNow = fixtureDate.addingTimeInterval(9)
    resetStore.refresh(); resetCallbacks[1](.failure(.transport))
    resetNow = fixtureDate.addingTimeInterval(11)
    resetStore.refresh() // The reset crosses while this request is incomplete.
    check("reset expires while request pending", resetStore.snapshot.fiveHour == .unknown && resetStore.snapshot.weekly.remaining == 80)
    let root: [String: Any] = ["electron-avatar-overlay-open": true, "electron-avatar-overlay-bounds": ["x": -400, "y": -200]]
    let anchor = parsePetAnchor(root)!
    check("current nominal112 inferred default113x122", anchor.x == -400 && anchor.y == -200 && anchor.width == 113 && anchor.height == 122)
    let legacy: [String: Any] = ["electron-avatar-overlay-open": true, "electron-avatar-overlay-bounds": ["x": 100, "y": 200, "mascot": ["left": 10, "top": 20, "width": 99, "height": 108]]]
    check("legacy anchor sum explicit size", parsePetAnchor(legacy)?.x == 110 && parsePetAnchor(legacy)?.height == 108)
    var atoms = root; atoms["avatar-overlay-mascot-width-px"] = 224
    check("atom width", parsePetAnchor(["electron-persisted-atom-state": atoms])?.height == 243)
    let screens = [ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875), id: "1"), ScreenGeometry(frame: CGRect(x: -1000, y: 900, width: 1000, height: 800), visible: CGRect(x: -1000, y: 900, width: 1000, height: 780), id: "2")]
    let layout = overlayLayout(for: anchor, sizeAdjustment: 1, screens: screens)
    let frame = appKitFrame(for: anchor, layout: layout, screens: screens)
    check("above screen primary Y conversion", abs(frame.minY + layout.ringCenter.y - (900-anchor.y-anchor.height/2)) < 0.001)
    check("negative screen selected", targetScreen(for: anchor, screens: screens)?.id == "2")
    let right = PetAnchor(x: -120, y: -200, width: 112, height: 122)
    check("target visibleFrame label side", overlayLayout(for: right, sizeAdjustment: 1, screens: screens).labelSide == .left)
    let relocated: [String: Any] = ["electron-avatar-overlay-open": true, "electron-avatar-overlay-bounds": ["x": 10, "y": 20, "displayId": 2, "displayBounds": ["x": 0, "y": 0, "width": 1000, "height": 800]]]
    check("display origin relocation", parsePetAnchor(relocated, screens: screens)?.x == -990 && parsePetAnchor(relocated, screens: screens)?.y == -780)
    let sigA = StateFileSignature([.modificationDate: fixtureDate.addingTimeInterval(0.1), .size: 123, .systemFileNumber: 9])
    let sigB = StateFileSignature([.modificationDate: fixtureDate.addingTimeInterval(0.2), .size: 123, .systemFileNumber: 9])
    check("subsecond same-size cache invalidation", sigA != sigB)
    var savedRoot = root
    savedRoot["electron-avatar-overlay-bounds"] = ["x": 0, "y": 0, "anchor": ["x": 15, "y": 25, "width": 99, "height": 108]]
    check("saved anchor preferred", parsePetAnchor(savedRoot)?.x == 15 && parsePetAnchor(savedRoot)?.width == 99)
    var badWidth = root; badWidth["avatar-overlay-mascot-width-px"] = true
    check("malformed width uses standard default113", parsePetAnchor(badWidth)?.width == 113)
    var capsuleFits = true
    for width in [80.0, 99.0, 224.0] {
        for adjustment in [0.85, 1.2] {
            for side in [LabelSide.left, .right] {
                let a = PetAnchor(x: 0, y: 0, width: width, height: 122)
                let l = OverlayLayout(labelSide: side, scale: meterScale(for: a, adjustment: adjustment))
                capsuleFits = capsuleFits && l.cachedBadgeRect.minY > l.resetBadgeRect.maxY && l.cachedBadgeRect.maxY < l.height && l.cachedBadgeRect.minY > l.ringCenter.y + l.ringDiameter * 0.43
            }
        }
    }
    check("cached capsule reserved lane fits all sizes", capsuleFits)
    check("unknown displays emdash", MeterSnapshot.unavailable.fiveHour.text == "—")
    check("desktop canonical width96", desktopPetWidth(in: "[desktop]\navatar-overlay-mascot-width-px = 96\n") == 96)
    check("desktop quoted key and comments", desktopPetWidth(in: "[desktop] # comment\n'avatar-overlay-mascot-width-px' = 223.6 # comment\n") == 224)
    check("desktop doublequoted key", desktopPetWidth(in: "[\"desktop\"]\n\"avatar-overlay-mascot-width-px\" = 96") == 96)
    check("desktop minimum clamp", desktopPetWidth(in: "[desktop]\navatar-overlay-mascot-width-px = -1") == 80)
    check("desktop maximum clamp", desktopPetWidth(in: "[desktop]\navatar-overlay-mascot-width-px = 999") == 224)
    for bad in ["true", "false", "\"96\"", "'96'", "nan", "inf", "1e999", "96broken"] {
        check("desktop rejects \(bad)", desktopPetWidth(in: "[desktop]\navatar-overlay-mascot-width-px = " + bad) == nil)
    }
    let tripleBasic = "\"\"\""
    let fakeBasic = "note = " + tripleBasic + "\n[desktop]\navatar-overlay-mascot-width-px = 224\n" + tripleBasic + "\n[desktop]\navatar-overlay-mascot-width-px = 96"
    check("multiline basic fake section ignored", desktopPetWidth(in: fakeBasic) == 96)
    let fakeLiteral = "[desktop]\nnote = '''\navatar-overlay-mascot-width-px = 224\n'''\navatar-overlay-mascot-width-px = 96"
    check("multiline literal fake key ignored", desktopPetWidth(in: fakeLiteral) == 96)
    check("other table does not supply width", desktopPetWidth(in: "[other]\navatar-overlay-mascot-width-px = 224") == nil)
    var ownerRoot = root
    ownerRoot["electron-renderer-content-owner"] = "synthetic-owner"
    ownerRoot["electron-owner-atoms:synthetic-owner"] = ["avatar-overlay-mascot-width-px": 160]
    check("owner overrides desktop config", parsePetAnchor(ownerRoot, configWidth: 96)?.width == 160)
    ownerRoot["electron-owner-atoms:synthetic-owner"] = ["avatar-overlay-mascot-width-px": false]
    check("malformed owner falls back config", parsePetAnchor(ownerRoot, configWidth: 96)?.width == 96)
    ownerRoot["electron-owner-atoms:other-owner"] = ["avatar-overlay-mascot-width-px": 224]
    check("other owner never applies", parsePetAnchor(ownerRoot, configWidth: 96)?.width == 96)
    check("current config computes height", parsePetAnchor(root, configWidth: 96)?.height == 104)
    check("legacy explicit size kept with config", parsePetAnchor(legacy, configWidth: 224)?.width == 99)
    let syntheticState = URL(fileURLWithPath: "/synthetic/state.json")
    let syntheticConfig = URL(fileURLWithPath: "/synthetic/config.toml")
    let fixedStateData = try! JSONSerialization.data(withJSONObject: root)
    var configGeneration = 1
    var configAttributesAvailable = true
    var configReadable = true
    var configText = "[desktop]\navatar-overlay-mascot-width-px = 96"
    var stateReads = 0, configReads = 0
    let sizeCache = AnchorCache(stateURL: syntheticState, settingsURL: syntheticConfig, signatureAt: { url in
        if url == syntheticConfig && !configAttributesAvailable { return nil }
        return StateFileSignature([.modificationDate: fixtureDate.addingTimeInterval(url == syntheticState ? 0 : Double(configGeneration) / 10), .size: 123, .systemFileNumber: url == syntheticState ? 1 : 2])
    }, read: { url in
        if url == syntheticState { stateReads += 1; return fixedStateData }
        configReads += 1; return configReadable ? Data(configText.utf8) : nil
    }, screens: { [] })
    check("two input cache initial96", sizeCache.anchor()?.width == 96)
    configAttributesAvailable = false
    check("missing config attributes retain96", sizeCache.anchor()?.width == 96)
    configAttributesAvailable = true
    configText = "[desktop]\navatar-overlay-mascot-width-px = 224"; configGeneration += 1
    check("config-only resize224", sizeCache.anchor()?.width == 224)
    configText = "[desktop]\navatar-overlay-mascot-width-px = "; configGeneration += 1
    check("partial config retains last size", sizeCache.anchor()?.width == 224)
    configText = "note = " + tripleBasic + "\n[desktop]\navatar-overlay-mascot-width-px = 80"; configGeneration += 1
    check("truncated multiline retains last size", sizeCache.anchor()?.width == 224)
    configText = "[desktop]\n"; configGeneration += 1
    check("config reset nominal112 physical113", sizeCache.anchor()?.width == 113)
    _ = sizeCache.anchor()
    check("config changes do not reread global JSON", stateReads == 1 && configReads == 5)
    configText = "[desktop]\navatar-overlay-mascot-width-px = 96"; configGeneration += 1
    check("read recovery setup96", sizeCache.anchor()?.width == 96)
    configText = "[desktop]\navatar-overlay-mascot-width-px = 224"; configGeneration += 1
    configReadable = false
    check("failed config read retains96", sizeCache.anchor()?.width == 96)
    configReadable = true
    check("same signature read recovery224", sizeCache.anchor()?.width == 224)
    configText = "[desktop]\navatar-overlay-mascot-width-px = 96"; configGeneration += 1
    check("partial recovery setup96", sizeCache.anchor()?.width == 96)
    configText = "[desktop]\navatar-overlay-mascot-width-px = "; configGeneration += 1
    check("invalid partial config retains96", sizeCache.anchor()?.width == 96)
    configText = "[desktop]\navatar-overlay-mascot-width-px = 224"
    check("same signature parse recovery224", sizeCache.anchor()?.width == 224)
    check("inferred default dimensions113x122", currentPetDimensions(nominalWidth: 112) == CGSize(width: 113, height: 122))
    check("explicit dimensions80x87", currentPetDimensions(nominalWidth: 80) == CGSize(width: 80, height: 87))
    check("explicit dimensions96x104", currentPetDimensions(nominalWidth: 96) == CGSize(width: 96, height: 104))
    check("explicit dimensions224x243", currentPetDimensions(nominalWidth: 224) == CGSize(width: 224, height: 243))
    let nativeScreen = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 2560, height: 1600), visible: CGRect(x: 0, y: 0, width: 2560, height: 1570), id: "fixture")
    let compactNative = nativePetLayout(displayWidth: 2560, displayHeight: 1570, expanded: false)
    let expandedNative = nativePetLayout(displayWidth: 2560, displayHeight: 1570, expanded: true)
    check("compact native padding source reference", compactNative.left == -692 && compactNative.top == -1511 && compactNative.width == 1132 && compactNative.height == 3109)
    check("expanded native padding source reference", expandedNative.left == -696 && expandedNative.top == -1511 && expandedNative.width == 1138 && expandedNative.height == 3109)
    let nativeReferenceAnchor = PetAnchor(x: 0, y: 0, width: 80, height: 87)
    let nativeWindow = NativePetWindow(pid: 7, layer: 3, frame: CGRect(x: -536, y: -300, width: 1138, height: 3109))
    let referenceCenter = nativePetCenter(windows: [nativeWindow], pids: [7], screens: [nativeScreen], anchor: nativeReferenceAnchor)
    check("synthetic expanded native center", referenceCenter?.x == 200 && referenceCenter?.y == 1254.5)
    let compactWindow = NativePetWindow(pid: 7, layer: 3, frame: CGRect(x: -532, y: -300, width: 1132, height: 3109))
    let compactCenter = nativePetCenter(windows: [compactWindow], pids: [7], screens: [nativeScreen], anchor: nativeReferenceAnchor)
    check("synthetic compact native center", compactCenter?.x == 200 && compactCenter?.y == 1254.5)
    let oddReference = PetAnchor(x: 0, y: 0, width: 99, height: 108)
    let oddCenter = nativePetCenter(windows: [nativeWindow], pids: [7], screens: [nativeScreen], anchor: oddReference)
    check("native odd width JS half parity", oddCenter?.x == 199.5 && oddCenter?.y == 1265)
    check("native other owner rejected", nativePetCenter(windows: [nativeWindow], pids: [8], screens: [nativeScreen], anchor: nativeReferenceAnchor) == nil)
    var wrongLayer = nativeWindow; wrongLayer.layer = 0
    check("native normal window layer rejected", nativePetCenter(windows: [wrongLayer], pids: [7], screens: [nativeScreen], anchor: nativeReferenceAnchor) == nil)
    var wrongSize = nativeWindow; wrongSize.frame.size.width += 20
    check("native unexpected frame rejected", nativePetCenter(windows: [wrongSize], pids: [7], screens: [nativeScreen], anchor: nativeReferenceAnchor) == nil)
    check("native ambiguous windows rejected", nativePetCenter(windows: [nativeWindow, nativeWindow], pids: [7], screens: [nativeScreen], anchor: nativeReferenceAnchor) == nil)
    check("native multiple screens falls back", nativePetCenter(windows: [nativeWindow], pids: [7], screens: [nativeScreen, nativeScreen], anchor: nativeReferenceAnchor) == nil)
    let nativeTracker = PetAnchorTracker()
    let nativeAdopted = nativeTracker.resolve(nativeReferenceAnchor, nativeCenter: referenceCenter)!
    check("native center overrides stale saved anchor", nativeAdopted.x == 160 && nativeAdopted.y == 1211)
    let nativeFallback = nativeTracker.resolve(nativeReferenceAnchor)!
    check("native last center survives temporary fallback", nativeFallback.x == nativeAdopted.x && nativeFallback.y == nativeAdopted.y)
    let defaultWindow = NativePetWindow(pid: 7, layer: 3, frame: CGRect(x: -479, y: -347, width: 1138, height: 3109))
    let defaultAnchor = PetAnchor(x: 200, y: 1164, width: 113, height: 122)
    let defaultCenter = nativePetCenter(windows: [defaultWindow], pids: [7], screens: [nativeScreen], anchor: defaultAnchor)
    check("synthetic odd width rounded halves57x61", jsRound(defaultAnchor.width / 2) == 57 && jsRound(defaultAnchor.height / 2) == 61)
    check("synthetic translated native center", defaultCenter?.x == 256.5 && defaultCenter?.y == 1225)
    let defaultTracker = PetAnchorTracker()
    let defaultResolved = defaultTracker.resolve(defaultAnchor, nativeCenter: defaultCenter)
    check("synthetic translated anchor", defaultResolved?.x == 200 && defaultResolved?.y == 1164)
    let hotTracker = PetAnchorTracker()
    let hotStart = PetAnchor(x: 100, y: 200, width: 96, height: 104)
    _ = hotTracker.resolve(hotStart)
    let hotLarge = hotTracker.resolve(PetAnchor(x: 100, y: 200, width: 224, height: 243))!
    check("hot resize preserves rounded center", hotLarge.x + floor(hotLarge.width / 2 + 0.5) == 148 && hotLarge.y + floor(hotLarge.height / 2 + 0.5) == 252)
    let hotUnchanged = hotTracker.resolve(PetAnchor(x: 100, y: 200, width: 224, height: 243))!
    check("hot unchanged saved position keeps live anchor", hotUnchanged.x == hotLarge.x && hotUnchanged.y == hotLarge.y)
    let hotReset = hotTracker.resolve(PetAnchor(x: 100, y: 200, width: 113, height: 122))!
    check("hot reset preserves rounded center", hotReset.x + 57 == 148 && hotReset.y + 61 == 252)
    let hotMoved = hotTracker.resolve(PetAnchor(x: 150, y: 250, width: 112, height: 122))!
    check("real saved move replaces inferred anchor", hotMoved.x == 150 && hotMoved.y == 250)
    _ = hotTracker.resolve(nil)
    check("closed pet resets tracking history", hotTracker.resolve(hotStart)?.x == 100)
    check("No Limit reset is not applicable", Period.noLimit.resetText == "---")
    let publicPreview = fixture("public-pro")
    check("public synthetic pro fixture", publicPreview.fiveHour == .noLimit && publicPreview.weeklyRemaining == 72 && publicPreview.fiveHour.resetText == "---" && publicPreview.updatedAt == fixtureDate)
    var labelFits = true, labelCentered = true, labelLarger = true
    for width in [80.0, 99.0, 224.0] {
        for adjustment in [0.85, 1.2] {
            for side in [LabelSide.left, .right] {
                let a = PetAnchor(x: 0, y: 0, width: width, height: 122)
                let l = OverlayLayout(labelSide: side, scale: meterScale(for: a, adjustment: adjustment))
                let (caption, amount) = compactLabelText(rect: l.fiveHourLabelRect, label: "5h", value: "No Limit", scale: l.scale)
                labelFits = labelFits && amount.measuredSize.width <= amount.frame.width && caption.measuredSize.width <= caption.frame.width && amount.frame.height <= l.fiveHourLabelRect.height && caption.frame.maxX < amount.frame.minX
                labelCentered = labelCentered && abs(amount.frame.midY - l.fiveHourLabelRect.midY) < 0.001 && abs(caption.frame.midY - l.fiveHourLabelRect.midY) < 0.001
                labelLarger = labelLarger && abs(amount.font.pointSize - 14.5 * l.scale) < 0.001
            }
        }
    }
    check("No Limit measured text fits all layouts", labelFits)
    check("No Limit and5h measured vertical centers", labelCentered)
    check("No Limit larger font retained all layouts", labelLarger)
    let redrawView = RedrawProbeView(frame: NSRect(x: 0, y: 0, width: 310, height: 302))
    redrawView.needsDisplay = false
    redrawView.layout = OverlayLayout(labelSide: .right, scale: 1)
    check("unchanged layout does not redraw", !redrawView.needsDisplay)
    redrawView.sizeAdjustment = defaultSizeAdjustment
    check("unchanged size does not redraw", !redrawView.needsDisplay)
    redrawView.layout = OverlayLayout(labelSide: .left, scale: 1)
    check("changed layout redraws", redrawView.needsDisplay)
    redrawView.needsDisplay = false
    redrawView.sizeAdjustment = 1.1
    check("changed size redraws", redrawView.needsDisplay)
    redrawView.needsDisplay = false
    redrawView.tickManualRefreshAnimation()
    check("idle animation tick does not redraw", !redrawView.needsDisplay)
    var animationNow = fixtureDate
    redrawView.animationClock = { animationNow }
    redrawView.startManualRefreshAnimation()
    check("manual animation starts redraw", redrawView.needsDisplay)
    redrawView.needsDisplay = false
    animationNow = fixtureDate.addingTimeInterval(0.5)
    redrawView.tickManualRefreshAnimation()
    check("manual animation tick redraws", redrawView.needsDisplay)
    redrawView.needsDisplay = false
    animationNow = fixtureDate.addingTimeInterval(1)
    redrawView.tickManualRefreshAnimation()
    check("manual animation final frame redraws", redrawView.needsDisplay)
    redrawView.needsDisplay = false
    redrawView.tickManualRefreshAnimation()
    check("completed animation stops redraw", !redrawView.needsDisplay)
    print("Self-test: \(count-failures)/\(count) passed")
    return failures == 0 ? 0 : 1
}

let args = CommandLine.arguments
func option(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i+1 else { return nil }; return args[i+1] }
if args.contains("--self-test") { exit(selfTest()) }
if args.contains("--anchor-status") {
    _ = NSApplication.shared
    if let anchor = currentPetAnchor() { let screens = screenGeometries()
        print("Geometry source: \(anchorCache.geometrySource)")
        if screens.isEmpty { print("Pet open; anchor x=\(anchor.x) y=\(anchor.y) width=\(anchor.width) height=\(anchor.height)"); print("Screen geometry unavailable in this process; layout not verified"); exit(0) }
        let layout = overlayLayout(for: anchor, sizeAdjustment: 1, screens: screens)
        let frame = appKitFrame(for: anchor, layout: layout, screens: screens)
        print("Pet open; anchor x=\(anchor.x) y=\(anchor.y) width=\(anchor.width) height=\(anchor.height)")
        print("Screens=\(screens.count) target=\(targetScreen(for: anchor, screens: screens).map { NSStringFromRect($0.frame) } ?? "unknown") side=\(layout.labelSide) overlay=\(frame)"); exit(0) }
    print("Pet anchor unavailable or overlay closed"); exit(1)
}
if args.contains("--status") { exit(printStatus(cachedOnly: args.contains("--cached-only"))) }
if let path = option("--preview") {
    let size = Double(option("--size") ?? "180") ?? 180
    let adjustment = Double(option("--adjustment") ?? "1") ?? 1
    guard size.isFinite, adjustment.isFinite else { exit(1) }
    exit(writePreview(to: URL(fileURLWithPath: path), size: size, name: option("--preview-fixture") ?? "normal", side: option("--side") == "left" ? .left : .right, adjustment: adjustment) ? 0 : 1)
}
let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
