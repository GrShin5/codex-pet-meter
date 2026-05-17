import AppKit
import Foundation
import SQLite3

private let codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
private let globalStateURL = codexHome.appendingPathComponent(".codex-global-state.json")
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

private struct MeterSnapshot {
    var fiveHourUsed: Double
    var weeklyUsed: Double
    var fiveHourResetAt: Date?
    var weeklyResetAt: Date?
    var planType: String
    var source: DataSource
    var updatedAt: Date

    var fiveHourRemaining: Double { clamp(100.0 - fiveHourUsed, 0.0, 100.0) }
    var weeklyRemaining: Double { clamp(100.0 - weeklyUsed, 0.0, 100.0) }

    static let unavailable = MeterSnapshot(
        fiveHourUsed: 100,
        weeklyUsed: 100,
        fiveHourResetAt: nil,
        weeklyResetAt: nil,
        planType: "unknown",
        source: .unavailable,
        updatedAt: Date()
    )
}

private struct PetAnchor {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

private enum LabelSide {
    case left
    case right
}

private struct OverlayLayout {
    static let baseWidth: CGFloat = 286
    static let baseHeight: CGFloat = 240
    static let baseBottomControlSpace: CGFloat = 38
    static let baseRingDiameter: CGFloat = 210
    static let baseLabelWidth: CGFloat = 104
    static let baseLabelHeight: CGFloat = 30

    var labelSide: LabelSide
    var scale: CGFloat

    var width: CGFloat { Self.baseWidth * scale }
    var height: CGFloat { (Self.baseHeight + Self.baseBottomControlSpace) * scale }
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

private func number(_ key: String, in dict: [String: Any]) -> Double? {
    if let value = dict[key] as? Double { return value }
    if let value = dict[key] as? Int { return Double(value) }
    if let value = dict[key] as? String { return Double(value) }
    return nil
}

private func unixDate(_ key: String, in dict: [String: Any]) -> Date? {
    guard let seconds = number(key, in: dict), seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func parseSnapshot(from value: Any, source: DataSource, updatedAt: Date = Date()) -> MeterSnapshot? {
    let root = value as? [String: Any]
    let rateLimits = dictionary(at: ["rate_limit"], in: value) ?? dictionary(at: ["rate_limits"], in: value) ?? root
    guard
        let primary = rateLimits?["primary_window"] as? [String: Any] ?? rateLimits?["primary"] as? [String: Any],
        let secondary = rateLimits?["secondary_window"] as? [String: Any] ?? rateLimits?["secondary"] as? [String: Any],
        let primaryUsed = number("used_percent", in: primary),
        let secondaryUsed = number("used_percent", in: secondary)
    else {
        return nil
    }

    return MeterSnapshot(
        fiveHourUsed: clamp(primaryUsed, 0.0, 100.0),
        weeklyUsed: clamp(secondaryUsed, 0.0, 100.0),
        fiveHourResetAt: unixDate("reset_at", in: primary),
        weeklyResetAt: unixDate("reset_at", in: secondary),
        planType: root?["plan_type"] as? String ?? "unknown",
        source: source,
        updatedAt: updatedAt
    )
}

private func liveSnapshot(completion: @escaping (MeterSnapshot?) -> Void) {
    guard
        let authData = try? Data(contentsOf: authURL),
        let auth = jsonObject(from: authData) as? [String: Any],
        let tokens = auth["tokens"] as? [String: Any],
        let token = tokens["access_token"] as? String ?? tokens["id_token"] as? String,
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")
    else {
        completion(nil)
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("CodexPetHungerMeter/0.1", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 8

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    session.dataTask(with: request) { data, _, _ in
        guard let data, let value = jsonObject(from: data) else {
            completion(nil)
            return
        }
        completion(parseSnapshot(from: value, source: .live))
    }.resume()
}

private func liveSnapshotSync(timeout: TimeInterval = 10) -> MeterSnapshot? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: MeterSnapshot?
    liveSnapshot { snapshot in
        result = snapshot
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeout)
    return result
}

private func cachedSnapshot() -> MeterSnapshot? {
    guard FileManager.default.fileExists(atPath: logsURL.path) else { return nil }

    let query = """
    SELECT ts, feedback_log_body FROM logs
    WHERE target = 'codex_api::endpoint::responses_websocket'
      AND feedback_log_body LIKE '%websocket event: {"type":"codex.rate_limits"%'
    ORDER BY ts DESC, ts_nanos DESC, id DESC
    LIMIT 200;
    """

    var database: OpaquePointer?
    guard sqlite3_open_v2(logsURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if database != nil { sqlite3_close(database) }
        return nil
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
        return nil
    }
    defer { sqlite3_finalize(statement) }

    while sqlite3_step(statement) == SQLITE_ROW {
        let timestamp = sqlite3_column_int64(statement, 0)
        guard let text = sqlite3_column_text(statement, 1) else { continue }
        let body = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = body.range(of: "websocket event: {\"type\":\"codex.rate_limits\"") else { continue }
        let jsonStart = body.index(marker.upperBound, offsetBy: -"{\"type\":\"codex.rate_limits\"".count)
        guard let jsonString = firstJSONObjectString(in: body, startingAt: jsonStart) else { continue }
        guard let jsonData = jsonString.data(using: .utf8), let value = jsonObject(from: jsonData) else { continue }
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        if let snapshot = parseSnapshot(from: value, source: .cached, updatedAt: updatedAt) {
            return snapshot
        }
    }

    return nil
}

private final class MeterStore {
    private(set) var snapshot = MeterSnapshot.unavailable
    var onChange: (() -> Void)?

    func refresh() {
        liveSnapshot { [weak self] live in
            let next = live ?? cachedSnapshot() ?? .unavailable
            DispatchQueue.main.async {
                self?.snapshot = next
                self?.onChange?()
            }
        }
    }
}

private func currentPetAnchor() -> PetAnchor? {
    guard
        let data = try? Data(contentsOf: globalStateURL),
        let root = jsonObject(from: data) as? [String: Any],
        root["electron-avatar-overlay-open"] as? Bool == true,
        let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
        let mascot = bounds["mascot"] as? [String: Any],
        let overlayX = number("x", in: bounds),
        let overlayY = number("y", in: bounds),
        let mascotLeft = number("left", in: mascot),
        let mascotTop = number("top", in: mascot),
        let mascotWidth = number("width", in: mascot),
        let mascotHeight = number("height", in: mascot)
    else {
        return nil
    }

    return PetAnchor(
        x: CGFloat(overlayX + mascotLeft),
        y: CGFloat(overlayY + mascotTop),
        width: CGFloat(mascotWidth),
        height: CGFloat(mascotHeight)
    )
}

private func savedSizeAdjustment() -> CGFloat {
    let stored = UserDefaults.standard.object(forKey: sizeAdjustmentDefaultsKey) as? Double
    return clamp(CGFloat(stored ?? Double(defaultSizeAdjustment)), minimumSizeAdjustment, maximumSizeAdjustment)
}

private func meterScale(for anchor: PetAnchor, adjustment: CGFloat) -> CGFloat {
    let petWidth = clamp(anchor.width, minimumPetWidth, maximumPetWidth)
    return (petWidth / baselinePetWidth) * clamp(adjustment, minimumSizeAdjustment, maximumSizeAdjustment)
}

private func overlayLayout(for anchor: PetAnchor, sizeAdjustment: CGFloat) -> OverlayLayout {
    let desktopWidth = NSScreen.screens.map { $0.frame.maxX }.max() ?? (NSScreen.main?.frame.width ?? 1440)
    let petCenterX = anchor.x + anchor.width / 2
    let scale = meterScale(for: anchor, adjustment: sizeAdjustment)
    let width = OverlayLayout.baseWidth * scale
    let requiredRightEdge = petCenterX + width - 118 * scale
    return OverlayLayout(labelSide: requiredRightEdge > desktopWidth ? .left : .right, scale: scale)
}

private func appKitFrame(for anchor: PetAnchor, layout: OverlayLayout) -> NSRect {
    let topLeftCenterX = anchor.x + anchor.width / 2
    let topLeftCenterY = anchor.y + anchor.height / 2
    let desktopHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? (NSScreen.main?.frame.height ?? 900)
    return NSRect(
        x: topLeftCenterX - layout.ringCenterX,
        y: desktopHeight - topLeftCenterY - layout.ringCenter.y,
        width: layout.width,
        height: layout.height
    )
}

private final class MeterView: NSView {
    var snapshot = MeterSnapshot.unavailable { didSet { needsDisplay = true } }
    var layout = OverlayLayout(labelSide: .right, scale: 1.0) {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var sizeAdjustment = defaultSizeAdjustment {
        didSet { needsDisplay = true }
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
    private var manualRefreshAnimationStart: Date?
    private var isDraggingSizeControl = false
    var isSizeControlDragging: Bool { isDraggingSizeControl }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMeter(in: bounds, snapshot: snapshot, layout: layout, animation: currentManualRefreshAnimation(), showSizeControl: isSizeControlVisible || isDraggingSizeControl, sizeAdjustment: sizeAdjustment)
    }

    func startManualRefreshAnimation() {
        manualRefreshAnimationStart = Date()
        needsDisplay = true
    }

    private func currentManualRefreshAnimation() -> ManualRefreshAnimation? {
        guard let start = manualRefreshAnimationStart else { return nil }
        let elapsed = Date().timeIntervalSince(start)
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

    drawRing(center: center, radius: outerRadius, lineWidth: 13 * layout.scale, remaining: snapshot.weeklyRemaining * Double(ringProgress), colorRemaining: snapshot.weeklyRemaining, kind: .weekly, alpha: ringAlpha)
    drawRing(center: center, radius: innerRadius, lineWidth: 7 * layout.scale, remaining: snapshot.fiveHourRemaining * Double(ringProgress), colorRemaining: snapshot.fiveHourRemaining, kind: .fiveHour, alpha: ringAlpha)
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
    let weeklyColor = colorForRemaining(snapshot.weeklyRemaining, kind: .weekly)
    let fiveHourColor = colorForRemaining(snapshot.fiveHourRemaining, kind: .fiveHour)
    let weeklyAngle: CGFloat = layout.labelSide == .right ? 28 : 152
    let fiveHourAngle: CGFloat = layout.labelSide == .right ? -18 : 198

    drawConnector(from: pointOnRing(center: layout.ringCenter, radius: layout.ringDiameter * 0.43, degrees: weeklyAngle), to: layout.weeklyLabelRect, side: layout.labelSide, color: weeklyColor, scale: layout.scale, alpha: alpha)
    drawConnector(from: pointOnRing(center: layout.ringCenter, radius: layout.ringDiameter * 0.31, degrees: fiveHourAngle), to: layout.fiveHourLabelRect, side: layout.labelSide, color: fiveHourColor, scale: layout.scale, alpha: alpha)

    drawCompactLabel(rect: layout.weeklyLabelRect, label: "Weekly", value: "\(Int(round(snapshot.weeklyRemaining)))%", color: weeklyColor, scale: layout.scale, alpha: alpha)
    drawCompactLabel(rect: layout.fiveHourLabelRect, label: "5h", value: "\(Int(round(snapshot.fiveHourRemaining)))%", color: fiveHourColor, scale: layout.scale, alpha: alpha)
    drawResetBadge(rect: layout.resetBadgeRect, weeklyResetAt: snapshot.weeklyResetAt, fiveHourResetAt: snapshot.fiveHourResetAt, scale: layout.scale, alpha: alpha)
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

private func drawCompactLabel(rect: NSRect, label: String, value: String, color: NSColor, scale: CGFloat, alpha: CGFloat = 1.0) {
    let panel = NSBezierPath(roundedRect: rect, xRadius: 9 * scale, yRadius: 9 * scale)
    NSColor(calibratedWhite: 0.02, alpha: 0.58 * alpha).setFill()
    panel.fill()
    color.withAlphaComponent(0.48 * alpha).setStroke()
    panel.lineWidth = 1.2 * scale
    panel.stroke()

    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.78 * alpha)
    ]
    let valueParagraph = NSMutableParagraphStyle()
    valueParagraph.alignment = .right
    let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 18 * scale, weight: .bold),
        .foregroundColor: color.withAlphaComponent(alpha),
        .paragraphStyle: valueParagraph
    ]
    label.draw(in: NSRect(x: rect.minX + 9 * scale, y: rect.minY + 8 * scale, width: 45 * scale, height: 14 * scale), withAttributes: labelAttrs)
    value.draw(in: NSRect(x: rect.minX + 42 * scale, y: rect.minY + 4 * scale, width: rect.width - 50 * scale, height: 22 * scale), withAttributes: valueAttrs)
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

private func drawResetBadge(rect: NSRect, weeklyResetAt: Date?, fiveHourResetAt: Date?, scale: CGFloat, alpha: CGFloat = 1.0) {
    let panel = NSBezierPath(roundedRect: rect, xRadius: 11 * scale, yRadius: 11 * scale)
    NSColor(calibratedWhite: 0.02, alpha: 0.48 * alpha).setFill()
    panel.fill()
    NSColor(calibratedRed: 0.63, green: 0.88, blue: 1.0, alpha: 0.28 * alpha).setStroke()
    panel.lineWidth = 1.1 * scale
    panel.stroke()

    let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8.5 * scale, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.52 * alpha)
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
    resetDateText(weeklyResetAt).draw(in: NSRect(x: rect.minX + 23 * scale, y: rect.minY + 19 * scale, width: rect.width - 30 * scale, height: 14 * scale), withAttributes: valueAttrs)
    "5h".draw(in: NSRect(x: rect.minX + 9 * scale, y: rect.minY + 6 * scale, width: 16 * scale, height: 11 * scale), withAttributes: captionAttrs)
    resetTimeText(fiveHourResetAt).draw(in: NSRect(x: rect.minX + 27 * scale, y: rect.minY + 4 * scale, width: 48 * scale, height: 15 * scale), withAttributes: fiveHourAttrs)
}

private func writePreview(to url: URL, size: CGFloat) -> Bool {
    let previewAnchor = PetAnchor(x: 0, y: 0, width: clamp(size, minimumPetWidth, maximumPetWidth), height: 108)
    let layout = OverlayLayout(labelSide: .right, scale: meterScale(for: previewAnchor, adjustment: defaultSizeAdjustment))
    let view = MeterView(frame: NSRect(x: 0, y: 0, width: layout.width, height: layout.height))
    view.snapshot = cachedSnapshot() ?? MeterSnapshot(
        fiveHourUsed: 59,
        weeklyUsed: 28,
        fiveHourResetAt: Date().addingTimeInterval(2.5 * 60 * 60),
        weeklyResetAt: Date().addingTimeInterval(5 * 24 * 60 * 60),
        planType: "preview",
        source: .live,
        updatedAt: Date()
    )
    view.layout = layout
    view.sizeAdjustment = defaultSizeAdjustment

    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try png.write(to: url)
        return true
    } catch {
        return false
    }
}

private func printStatus(cachedOnly: Bool) -> Int32 {
    let snapshot = cachedOnly ? cachedSnapshot() : (liveSnapshotSync() ?? cachedSnapshot())
    guard let snapshot else {
        print("Codex Pet Hunger Meter")
        print("Source: Unavailable")
        print("Outer weekly remaining: unavailable")
        print("Inner 5h remaining: unavailable")
        return 1
    }

    print("Codex Pet Hunger Meter")
    print("Source: \(snapshot.source.rawValue)")
    print("Plan: \(snapshot.planType)")
    print("Outer weekly remaining: \(Int(round(snapshot.weeklyRemaining)))%")
    print("Inner 5h remaining: \(Int(round(snapshot.fiveHourRemaining)))%")
    print("Weekly reset: \(resetDateText(snapshot.weeklyResetAt))")
    print("5h reset: \(resetTimeText(snapshot.fiveHourResetAt))")
    print("Data updated: \(resetDateText(snapshot.updatedAt))")
    return 0
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
        store.refresh()
        updateOverlay()

        overlayTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
        menu.addItem(NSMenuItem(title: "Outer Weekly: \(Int(round(snap.weeklyRemaining)))%", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Inner 5h: \(Int(round(snap.fiveHourRemaining)))%", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Weekly Reset: \(resetDateText(snap.weeklyResetAt))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "5h Reset: \(resetTimeText(snap.fiveHourResetAt))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Data Updated: \(resetDateText(snap.updatedAt))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Data Source: \(snap.source.rawValue)", action: nil, keyEquivalent: ""))

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

let args = CommandLine.arguments
if args.contains("--status") {
    exit(printStatus(cachedOnly: args.contains("--cached-only")))
}

if let previewIndex = args.firstIndex(of: "--preview"), args.count > previewIndex + 1 {
    let output = URL(fileURLWithPath: args[previewIndex + 1])
    let sizeIndex = args.firstIndex(of: "--size")
    let size = sizeIndex.flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 180
    exit(writePreview(to: output, size: CGFloat(size)) ? 0 : 1)
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
