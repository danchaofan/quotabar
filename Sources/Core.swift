import Foundation

enum Vendor: String, Codable, CaseIterable, Identifiable {
    case codex, glm, kimi
    var id: String { rawValue }
    var name: String { switch self { case .codex: return "Codex"; case .glm: return "智谱 Coding Plan"; case .kimi: return "Kimi Code" } }
    var shortName: String { switch self { case .codex: return "Codex"; case .glm: return "智谱"; case .kimi: return "Kimi" } }
    var initials: String { switch self { case .codex: return "C"; case .glm: return "Z"; case .kimi: return "K" } }
}

struct Quota: Codable, Identifiable {
    let id: String
    let title: String
    let remainingPercent: Double
    var remaining: Double? = nil
    var total: Double? = nil
    var unit: String? = nil
    var resetsAt: Date? = nil
    var usedPercent: Double { 100 - remainingPercent }
    var usedFraction: Double { usedPercent / 100 }
}

struct QuotaSnapshot: Codable {
    let vendor: Vendor
    let quotas: [Quota]
    let fetchedAt: Date
}

struct ProviderState: Identifiable {
    let vendor: Vendor
    var snapshot: QuotaSnapshot? = nil
    var error: String? = nil
    var loading = false
    var failures = 0
    var nextAttempt = Date.distantPast
    var id: Vendor { vendor }
    var stale: Bool { snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 900 } ?? true }
}

struct TokenEvent: Codable {
    let id: String
    let vendor: Vendor
    let source: String
    let date: Date
    let input: Int64 // Includes cached input.
    let output: Int64 // Includes reasoning output when reported.
    let cacheRead: Int64
    let cacheWrite: Int64
    var total: Int64 { input + output }
}

struct TokenTotals: Codable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var requests = 0
    var total: Int64 { input + output }
    mutating func add(_ event: TokenEvent) {
        input += event.input; output += event.output
        cacheRead += event.cacheRead; cacheWrite += event.cacheWrite; requests += 1
    }
    mutating func add(_ other: TokenTotals) {
        input += other.input; output += other.output
        cacheRead += other.cacheRead; cacheWrite += other.cacheWrite; requests += other.requests
    }
}

struct SourceHealth: Codable, Identifiable {
    let id: String
    let vendor: Vendor
    let title: String
    let available: Bool
    let records: Int
    let note: String
}

struct DailyUsage: Codable, Identifiable {
    let day: String
    let vendor: Vendor
    let source: String
    var totals: TokenTotals
    var id: String { day + vendor.rawValue + source }
}

struct UsageSnapshot: Codable {
    let scannedAt: Date
    let days: [DailyUsage]
    let sources: [SourceHealth]
    let timeZone: String
    func totals(day: String, vendor: Vendor? = nil) -> TokenTotals {
        days.filter { $0.day == day && (vendor == nil || $0.vendor == vendor) }.reduce(into: TokenTotals()) { $0.add($1.totals) }
    }
}

enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}

enum Values {
    static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func integer(_ value: Any?) -> Int64 {
        guard let n = number(value), n >= 0, n < 9_000_000_000_000_000_000 else { return 0 }
        return Int64(n)
    }
    static func percent(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0, value <= 100.00001 else { throw QuotaError.message("服务返回了无效的额度数值") }
        return min(100, value)
    }
    static func json(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.message("服务返回格式无法识别") }
        return result
    }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value) { return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n) }
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]; return iso.date(from: s)
    }
    static func day(_ date: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func compact(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 10_000 { return String(format: "%.1fK", Double(count) / 1000) }
        return count.formatted(.number)
    }
    static func percentText(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.005 ? String(format: "%.0f%%", value) : String(format: "%.2f%%", value)
    }
}

import CoreFoundation

enum QuotaParser {
    static func codex(_ response: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        let root = Values.dictionary(response["result"] ?? response)
        let byID = Values.dictionary(root["rateLimitsByLimitId"])
        let limits = Values.dictionary(byID["codex"] ?? root["rateLimits"])
        let windows = [Values.dictionary(limits["primary"]), Values.dictionary(limits["secondary"])]
        guard let week = windows.first(where: { Values.number($0["windowDurationMins"]) == 10080 }), let used = Values.number(week["usedPercent"]) else { throw QuotaError.message("账号尚未返回 Codex 周额度，请检查 Codex 登录") }
        return QuotaSnapshot(vendor: .codex, quotas: [Quota(id: "codex.week", title: "周额度", remainingPercent: try Values.percent(100 - used), resetsAt: Values.date(week["resetsAt"]))], fetchedAt: now)
    }
    static func glm(_ root: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        guard Values.number(root["code"]) == 200, root["success"] as? Bool != false else { throw QuotaError.message("智谱查询失败，请检查 Coding Plan API Key 或登录") }
        let limits = Values.dictionary(root["data"])["limits"] as? [[String: Any]] ?? []
        var quotas: [Quota] = []
        for (unit, number, id, name) in [(3, 5, "glm.5h", "5 小时额度"), (6, 1, "glm.week", "周额度")] {
            guard let item = limits.first(where: { ["CREDIT_LIMIT", "TOKENS_LIMIT"].contains($0["type"] as? String ?? "") && Values.number($0["unit"]) == Double(unit) && (Values.number($0["number"]) ?? Double(number)) == Double(number) }) else { throw QuotaError.message("智谱未返回完整的 5 小时和周额度") }
            let remaining = Values.number(item["remaining"]), total = Values.number(item["usage"])
            let percent: Double
            if let r = remaining, let t = total, t > 0 { percent = r / t * 100 }
            else if let used = Values.number(item["percentage"]) { percent = 100 - used }
            else { throw QuotaError.message("智谱额度字段暂不支持") }
            quotas.append(Quota(id: id, title: name, remainingPercent: try Values.percent(percent), remaining: remaining, total: total, unit: item["type"] as? String == "CREDIT_LIMIT" ? "积分" : "额度", resetsAt: Values.date(item["nextResetTime"])))
        }
        return QuotaSnapshot(vendor: .glm, quotas: quotas, fetchedAt: now)
    }
    static func kimi(_ root: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        let data = Values.dictionary(root["data"])
        guard Values.number(root["code"]) == 0, data["kind"] as? String == "ok" else { throw QuotaError.message("Kimi 查询失败，请在 Kimi Code 中确认登录状态") }
        let usages = Values.dictionary(Values.dictionary(data["quota"])["usages"])
        var quotas: [Quota] = []
        for (key, id, title) in [("limit5h", "kimi.5h", "5 小时额度"), ("monthTotal", "kimi.month", "月额度 · 会员共享")] {
            guard let ratio = Values.number(Values.dictionary(usages[key])["usedRatio"]) else { throw QuotaError.message("Kimi 未返回完整的 5 小时和月额度，请更新 Kimi Code") }
            quotas.append(Quota(id: id, title: title, remainingPercent: try Values.percent((1 - ratio) * 100), resetsAt: Values.date(Values.dictionary(usages[key])["resetAt"])))
        }
        return QuotaSnapshot(vendor: .kimi, quotas: quotas, fetchedAt: now)
    }
}
