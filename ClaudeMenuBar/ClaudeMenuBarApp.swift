import SwiftUI

@main
struct ClaudeMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.usageMonitor)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    let usageMonitor = UsageMonitor()

    // Live session tracking
    var isClaudeLive = false
    var processCheckTimer: Timer?
    var pulseTimer: Timer?
    var pulseAlpha: CGFloat = 1.0
    var pulseDirection: CGFloat = -1  // -1 = dimming, +1 = brightening

    // Claude brand color (coral/terracotta)
    static let claudeColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1.0)  // #D97757

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateButton(button)
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        usageMonitor.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                if let button = self?.statusItem.button {
                    self?.updateButton(button)
                }
            }
        }
        usageMonitor.startMonitoring()

        // Check for claude process every 3 seconds
        processCheckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkClaudeProcess()
        }
        checkClaudeProcess()

        // Pulse animation timer (smooth ~15fps)
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self = self, self.isClaudeLive else { return }
            self.pulseAlpha += self.pulseDirection * 0.04
            if self.pulseAlpha <= 0.3 {
                self.pulseAlpha = 0.3
                self.pulseDirection = 1
            } else if self.pulseAlpha >= 1.0 {
                self.pulseAlpha = 1.0
                self.pulseDirection = -1
            }
            if let button = self.statusItem.button {
                self.updateButton(button)
            }
        }
    }

    func checkClaudeProcess() {
        let pipe = Pipe()
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-f", "claude"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let wasLive = isClaudeLive
        isClaudeLive = task.terminationStatus == 0

        // Adjust refresh interval when live status changes
        if isClaudeLive != wasLive {
            if isClaudeLive {
                usageMonitor.refreshInterval = 60  // every 1 min when live
            } else {
                let saved = UserDefaults.standard.double(forKey: "refresh_interval")
                usageMonitor.refreshInterval = saved > 0 ? saved : 300
                pulseAlpha = 1.0  // reset pulse
            }
            DispatchQueue.main.async {
                if let button = self.statusItem.button {
                    self.updateButton(button)
                }
            }
        }
    }

    // Rebuild menu each time it opens so data is fresh
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status
        if isClaudeLive {
            let liveItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            liveItem.isEnabled = false
            liveItem.attributedTitle = NSAttributedString(
                string: "● Claude is running",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: Self.claudeColor
                ]
            )
            menu.addItem(liveItem)
        } else {
            menu.addItem(disabledItem("○ Claude is idle"))
        }

        menu.addItem(NSMenuItem.separator())

        if let usage = usageMonitor.currentUsage {
            let statusText = usage.status == "allowed" ? "✅ Allowed" : "🔴 Blocked"
            menu.addItem(headerItem(statusText))
            menu.addItem(NSMenuItem.separator())

            let active5 = usage.representativeClaim == "five_hour" ? " ◀" : ""
            menu.addItem(coloredMenuItem(
                label: "5h  ", percent: usage.fiveHourPercent, suffix: active5
            ))
            menu.addItem(disabledItem("      Reset: \(relativeTime(usage.fiveHourReset))"))

            menu.addItem(NSMenuItem.separator())

            let active7 = usage.representativeClaim == "seven_day" ? " ◀" : ""
            menu.addItem(coloredMenuItem(
                label: "7d  ", percent: usage.sevenDayPercent, suffix: active7
            ))
            menu.addItem(disabledItem("      Reset: \(relativeTime(usage.sevenDayReset))"))

            if usage.overagePercent > 0 {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(coloredMenuItem(
                    label: "Ovg ", percent: usage.overagePercent, suffix: ""
                ))
            }

            menu.addItem(NSMenuItem.separator())

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            menu.addItem(disabledItem("Updated: \(formatter.string(from: usage.fetchedAt))"))

        } else if let error = usageMonitor.error {
            menu.addItem(disabledItem("⚠️ \(error)"))
        } else {
            menu.addItem(disabledItem("Loading..."))
        }

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func updateButton(_ button: NSStatusBarButton) {
        if let usage = usageMonitor.currentUsage {
            button.image = drawFullStatusIcon(
                sessionPercent: usage.fiveHourPercent,
                weeklyPercent: usage.sevenDayPercent,
                blocked: usage.status != "allowed",
                resetDate: usage.fiveHourReset
            )
            button.title = ""
        } else {
            button.image = drawFullStatusIcon(
                sessionPercent: 0, weeklyPercent: 0,
                blocked: false, resetDate: nil
            )
            button.title = ""
        }
    }

    private func drawFullStatusIcon(sessionPercent: Int, weeklyPercent: Int, blocked: Bool, resetDate: Date?) -> NSImage {
        let circleSize: CGFloat = 18
        let barHeight = 22.0  // menu bar height
        let gap: CGFloat = 4
        let dotSize: CGFloat = 5

        // Measure percentage text
        let pctStr = sessionPercent > 0 ? "\(sessionPercent)%" : "--%"
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let pctColor = percentColor(sessionPercent)
        let pctAttr: [NSAttributedString.Key: Any] = [.font: pctFont, .foregroundColor: pctColor]
        let pctSize = (pctStr as NSString).size(withAttributes: pctAttr)

        // Time bar dimensions
        let timeBarWidth = pctSize.width
        let timeBarHeight: CGFloat = 3
        let timeBarGap: CGFloat = 2

        // Content block height (pct text + gap + bar)
        let contentHeight = pctSize.height + timeBarGap + timeBarHeight
        let contentY = (barHeight - contentHeight) / 2  // vertically center the block

        // Live dot
        let showDot = isClaudeLive
        let dotGap: CGFloat = 3

        // Total width
        let totalWidth = circleSize + gap + pctSize.width + (showDot ? dotGap + dotSize : 0) + 2

        let image = NSImage(size: NSSize(width: totalWidth, height: barHeight), flipped: true) { _ in
            let ctx = NSGraphicsContext.current!.cgContext

            // --- Draw circle icon (centered vertically) ---
            let circleY = (barHeight - circleSize) / 2
            ctx.saveGState()
            ctx.translateBy(x: 0, y: circleY)
            self.drawCircleIcon(ctx: ctx, size: circleSize, sessionPercent: sessionPercent, weeklyPercent: weeklyPercent, blocked: blocked)
            ctx.restoreGState()

            // --- Percentage text ---
            let pctX = circleSize + gap
            let pctY = contentY
            (pctStr as NSString).draw(at: NSPoint(x: pctX, y: pctY), withAttributes: pctAttr)

            // --- Time remaining bar ---
            if let resetDate = resetDate {
                let barY = pctY + pctSize.height + timeBarGap
                let barX = pctX

                // Background track
                let trackRect = NSRect(x: barX, y: barY, width: timeBarWidth, height: timeBarHeight)
                NSColor.tertiaryLabelColor.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: 1.5, yRadius: 1.5).fill()

                // Fill based on time remaining (5h = 18000s total)
                let remaining = max(0, resetDate.timeIntervalSince(Date()))
                let totalWindow: TimeInterval = 5 * 3600
                let timePct = min(1.0, max(0, remaining / totalWindow))
                let fillWidth = timeBarWidth * timePct

                if fillWidth > 0 {
                    let fillRect = NSRect(x: barX, y: barY, width: fillWidth, height: timeBarHeight)
                    NSColor.systemGreen.setFill()
                    NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }

            // --- Live dot (vertically centered to whole item) ---
            if showDot {
                let dotX = circleSize + gap + pctSize.width + dotGap
                let dotY = (barHeight - dotSize) / 2
                Self.claudeColor.withAlphaComponent(self.pulseAlpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)).fill()
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawCircleIcon(ctx: CGContext, size: CGFloat, sessionPercent: Int, weeklyPercent: Int, blocked: Bool) {
        let center = CGPoint(x: size / 2, y: size / 2)
        let outerRadius: CGFloat = size / 2 - 1
        let ringWidth: CGFloat = 2.5

        // Background ring
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(ringWidth)
        ctx.addArc(center: center, radius: outerRadius - ringWidth / 2,
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Session arc (note: flipped coord, so -π/2 is top)
        if sessionPercent > 0 {
            let sessionColor = blocked ? NSColor.systemRed : self.percentColor(sessionPercent)
            ctx.setStrokeColor(sessionColor.cgColor)
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            let startAngle: CGFloat = -.pi / 2
            let sweep = CGFloat(min(sessionPercent, 100)) / 100.0 * .pi * 2
            let endAngle = startAngle + sweep
            ctx.addArc(center: center, radius: outerRadius - ringWidth / 2,
                       startAngle: startAngle, endAngle: endAngle, clockwise: false)
            ctx.strokePath()
        }

        // Inner circle
        let innerRadius: CGFloat = size / 2 - ringWidth - 2
        if innerRadius > 1 {
            ctx.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.3).cgColor)
            ctx.fillEllipse(in: CGRect(
                x: center.x - innerRadius, y: center.y - innerRadius,
                width: innerRadius * 2, height: innerRadius * 2
            ))

            if weeklyPercent > 0 {
                ctx.saveGState()
                ctx.addEllipse(in: CGRect(
                    x: center.x - innerRadius, y: center.y - innerRadius,
                    width: innerRadius * 2, height: innerRadius * 2
                ))
                ctx.clip()

                // Fill from bottom up in flipped coords (top = y:0)
                let fillHeight = innerRadius * 2 * CGFloat(min(weeklyPercent, 100)) / 100.0
                let weeklyColor = blocked ? NSColor.systemRed : self.percentColor(weeklyPercent)
                ctx.setFillColor(weeklyColor.cgColor)
                ctx.fill(CGRect(
                    x: center.x - innerRadius,
                    y: center.y + innerRadius - fillHeight,
                    width: innerRadius * 2,
                    height: fillHeight
                ))
                ctx.restoreGState()
            }
        }
    }

    private func percentColor(_ percent: Int) -> NSColor {
        if percent >= 85 { return .systemRed }
        if percent >= 70 { return .systemOrange }
        if percent >= 55 { return .systemYellow }
        return .systemGreen
    }


    private func shortResetTime(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff <= 0 { return "now" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    // MARK: - Helpers

    private func barString(percent: Int) -> String {
        let clamped = min(max(percent, 0), 100)
        let filled = clamped / 5
        let empty = 20 - filled
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    private func coloredMenuItem(label: String, percent: Int, suffix: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false

        let color = percentColor(percent)
        let bar = barString(percent: percent)
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: label, attributes: [.font: mono]))
        attr.append(NSAttributedString(string: bar, attributes: [.font: mono, .foregroundColor: color]))
        attr.append(NSAttributedString(string: " \(percent)%", attributes: [.font: bold, .foregroundColor: color]))
        if !suffix.isEmpty {
            attr.append(NSAttributedString(string: suffix, attributes: [.font: mono, .foregroundColor: NSColor.systemBlue]))
        }

        item.attributedTitle = attr
        return item
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
        )
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    // MARK: - Actions

    @objc func refresh() {
        usageMonitor.fetchUsage()
    }

    @objc func openSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView().environmentObject(usageMonitor)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Claude Menu Bar Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 280))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
