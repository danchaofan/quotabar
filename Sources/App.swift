import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var reopenObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "额度看板")
            button.image?.isTemplate = true; button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient; popover.animates = true
        popover.contentSize = NSSize(width: 410, height: 660)
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model, openSettings: { [weak self] in self?.showSettings() }))
        model.menuChanged = { [weak self] in self?.updateMenu() }
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.QuotaBar.show"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.showPopover() } }
        updateMenu(); model.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") { UserDefaults.standard.set(true, forKey: "hasLaunched"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() } }
    }
    private func updateMenu() {
        statusItem?.button?.title = model.menuText; statusItem?.button?.toolTip = model.menuTooltip
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let refresh = menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r"); refresh.target = self
            let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
            menu.addItem(.separator()); menu.addItem(withTitle: "退出额度看板", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); model.onOpen()
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc private func refresh() { model.refreshAll(force: true) }
    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "额度看板设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model)); window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { ManagedChildren.shared.stopAll() }
}

@main enum QuotaBarMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") { exit(SelfTests.run() ? 0 : 1) }
        if args.contains("--check") || args.contains("--usage-only") {
            Task {
                let report = await Diagnostics.check(usageOnly: args.contains("--usage-only"))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(report) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
                exit(report.errors.isEmpty ? 0 : 1)
            }
            RunLoop.main.run(); return
        }
        if let index = args.firstIndex(of: "--render"), args.count > index + 1 {
            let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
            let model = AppModel(loadCache: false)
            if let inputIndex = args.firstIndex(of: "--data"), args.count > inputIndex + 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[inputIndex + 1])) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let report = try? decoder.decode(DiagnosticReport.self, from: data) {
                    model.usage = report.usage
                    for snapshot in report.quotas { model.providers[snapshot.vendor]?.snapshot = snapshot }
                    for (vendor, error) in report.errors { if let value = Vendor(rawValue: vendor) { model.providers[value]?.error = error } }
                }
            }
            model.page = args.contains("--usage-page") ? 1 : 0
            if args.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) } else { app.appearance = NSAppearance(named: .aqua) }
            let size = args.contains("--settings-page") ? NSSize(width: 530, height: 650) : NSSize(width: 410, height: 660)
            let dark = args.contains("--dark")
            let root = args.contains("--settings-page") ? AnyView(SettingsView(model: model)) : AnyView(DashboardView(model: model))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light)); window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8)); view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fputs("无法创建界面预览\n", stderr); exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try data.write(to: URL(fileURLWithPath: args[index + 1])); exit(0) } catch { exit(1) }
        }
        let app = NSApplication.shared
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.QuotaBar").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.QuotaBar.show"), object: nil, userInfo: nil, deliverImmediately: true); return
        }
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
