import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

enum CacheStore {
    static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: LocalPaths.support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, name: String) {
        do {
            try FileManager.default.createDirectory(at: LocalPaths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = LocalPaths.support.appendingPathComponent(name)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A read-only disk must not interrupt live values. */ }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var providers = Dictionary(uniqueKeysWithValues: Vendor.allCases.map { ($0, ProviderState(vendor: $0)) })
    @Published var usage: UsageSnapshot?
    @Published var scanning = false
    @Published var page = 0
    @Published var selectedDay = Values.day(Date())
    @Published var connectionMessage = ""
    @Published var refreshMinutes: Int { didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var menuMetric: String { didSet { UserDefaults.standard.set(menuMetric, forKey: "menuMetric"); menuChanged?() } }
    @Published var notifications: Bool { didSet { UserDefaults.standard.set(notifications, forKey: "notifications") } }
    var menuChanged: (() -> Void)?
    private let client = ProviderClient(), scanner = UsageScanner()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastDay = Values.day(Date())
    init(loadCache: Bool = true) {
        let interval = UserDefaults.standard.integer(forKey: "refreshMinutes")
        refreshMinutes = [1, 5, 10, 15].contains(interval) ? interval : 5
        menuMetric = UserDefaults.standard.string(forKey: "menuMetric") ?? "icon"
        notifications = UserDefaults.standard.bool(forKey: "notifications")
        if loadCache {
            if let cached = CacheStore.read("quotas.json", as: [QuotaSnapshot].self) {
                for snapshot in cached { providers[snapshot.vendor]?.snapshot = snapshot; providers[snapshot.vendor]?.error = "正在更新上次记录" }
            }
            usage = CacheStore.read("daily-usage.json", as: UsageSnapshot.self)
        }
    }
    var refreshing: Bool { providers.values.contains { $0.loading } }
    func start() {
        refreshAll(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshAll(force: true) } }
    }
    private func tick() {
        let day = Values.day(Date())
        if day != lastDay { if selectedDay == lastDay { selectedDay = day }; lastDay = day }
        for vendor in Vendor.allCases {
            let state = providers[vendor]!
            let resetElapsed = state.error == nil && state.snapshot.map { snapshot in snapshot.quotas.contains { quota in quota.resetsAt.map { $0 <= Date() && $0 > snapshot.fetchedAt } ?? false } } ?? false
            if state.nextAttempt <= Date() || resetElapsed { refresh(vendor) }
        }
        scanUsage(); menuChanged?()
    }
    func onOpen() {
        for vendor in Vendor.allCases {
            if providers[vendor]?.snapshot.map({ Date().timeIntervalSince($0.fetchedAt) > 60 }) ?? true { refresh(vendor) }
        }
        scanUsage()
    }
    func refreshAll(force: Bool) {
        for vendor in Vendor.allCases { if force || (providers[vendor]?.nextAttempt ?? .distantPast) <= Date() { refresh(vendor) } }
        scanUsage()
    }
    private func refresh(_ vendor: Vendor) {
        guard providers[vendor]?.loading == false else { return }
        providers[vendor]?.loading = true
        Task {
            do {
                let snapshot = try await client.fetch(vendor)
                providers[vendor]?.snapshot = snapshot; providers[vendor]?.error = nil; providers[vendor]?.failures = 0
                providers[vendor]?.nextAttempt = Date().addingTimeInterval(Double(refreshMinutes) * 60)
                notifyIfNeeded(snapshot)
            } catch {
                providers[vendor]?.error = error.localizedDescription; providers[vendor]?.failures += 1
                let factor = pow(2, Double(min(3, (providers[vendor]?.failures ?? 1) - 1)))
                providers[vendor]?.nextAttempt = Date().addingTimeInterval(min(1800, Double(refreshMinutes) * 60 * factor))
            }
            providers[vendor]?.loading = false
            CacheStore.save(Vendor.allCases.compactMap { providers[$0]?.snapshot }, name: "quotas.json")
            menuChanged?()
        }
    }
    func scanUsage() {
        guard !scanning else { return }; scanning = true
        Task {
            usage = await scanner.scan(); scanning = false
            if let usage = usage { CacheStore.save(usage, name: "daily-usage.json") }
        }
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { notifications = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] accepted, _ in
            Task { @MainActor [weak self] in
                self?.notifications = accepted
                if !accepted { self?.connectionMessage = "请在系统设置 → 通知中允许「额度看板」提醒" }
            }
        }
    }
    private func notifyIfNeeded(_ snapshot: QuotaSnapshot) {
        guard notifications else { return }
        var marks = UserDefaults.standard.dictionary(forKey: "notificationMarks") as? [String: Bool] ?? [:]
        if marks.count > 200 { marks = [:] }
        for quota in snapshot.quotas {
            let cycle = quota.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "window"
            for threshold in [20, 10] {
                let key = quota.id + ":" + cycle + ":" + String(threshold)
                if quota.remainingPercent > Double(threshold) { marks[key] = nil; continue }
                guard marks[key] != true else { continue }
                // If already below 10%, send one notification rather than both thresholds.
                if threshold == 20 && quota.remainingPercent <= 10 { marks[key] = true; continue }
                marks[key] = true
                let content = UNMutableNotificationContent()
                content.title = "\(snapshot.vendor.shortName)额度不足"
                content.body = "\(quota.title)剩余 \(Values.percentText(quota.remainingPercent))"
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            }
        }
        UserDefaults.standard.set(marks, forKey: "notificationMarks")
    }
    func saveManualKey(_ key: String) {
        do { try Secrets.saveGLM(key); connectionMessage = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已移除手动密钥，将使用 ZCode 本机配置" : "密钥已保存到 macOS 钥匙串"; refresh(.glm) }
        catch { connectionMessage = error.localizedDescription }
    }
    func exportUsage() {
        guard let usage = usage else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "每日-token-用量.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "日期,服务,来源,输入token（含缓存）,输出token,缓存读取（输入子集）,缓存写入（输入子集）,总token,请求记录数\n"
        for row in usage.days {
            let t = row.totals
            csv += "\(row.day),\(row.vendor.name),\(row.source),\(t.input),\(t.output),\(t.cacheRead),\(t.cacheWrite),\(t.total),\(t.requests)\n"
        }
        do { try ("\u{FEFF}" + csv).write(to: url, atomically: true, encoding: .utf8) }
        catch { connectionMessage = "导出失败，请选择可写入的位置" }
    }
    var menuText: String {
        guard menuMetric != "icon" else { return "" }
        for vendor in Vendor.allCases {
            if let state = providers[vendor], let quota = state.snapshot?.quotas.first(where: { $0.id == menuMetric }) {
                return state.stale || state.error != nil ? " —" : " " + Values.percentText(quota.remainingPercent)
            }
        }
        return " —"
    }
    var menuTooltip: String {
        Vendor.allCases.map { vendor in
            let state = providers[vendor]!
            if let snapshot = state.snapshot {
                return vendor.shortName + " · " + snapshot.quotas.map { $0.title + " " + Values.percentText($0.remainingPercent) }.joined(separator: " / ") + (state.stale || state.error != nil ? "（待更新）" : "")
            }
            return vendor.shortName + " · " + (state.loading ? "查询中" : "待连接")
        }.joined(separator: "\n")
    }
}
