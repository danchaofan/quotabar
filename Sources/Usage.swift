import Foundation
import SQLite3

enum UsageParsing {
    static func codexRecord(_ row: [String: Any], source: String) -> TokenEvent? {
        let payload = Values.dictionary(row["payload"]), usage = Values.dictionary(payload["usage"])
        guard row["type"] as? String == "token_usage_record", let date = Values.date(row["timestamp"]), !usage.isEmpty else { return nil }
        let response = payload["response_id"] as? String
        let identity = response ?? "\(payload["thread_id"] ?? ""):\(row["ordinal"] ?? row["timestamp"] ?? "")"
        return TokenEvent(id: "codex:" + identity, vendor: .codex, source: source, date: date, input: Values.integer(usage["input_tokens"]), output: Values.integer(usage["output_tokens"]), cacheRead: Values.integer(usage["cached_input_tokens"]), cacheWrite: Values.integer(usage["cache_write_input_tokens"]))
    }
    static func kimiRecord(_ row: [String: Any], session: String, line: Int) -> TokenEvent? {
        guard row["type"] as? String == "usage.record", let date = Values.date(row["time"]) else { return nil }
        let usage = Values.dictionary(row["usage"]); guard !usage.isEmpty else { return nil }
        let read = Values.integer(usage["inputCacheRead"]), write = Values.integer(usage["inputCacheCreation"])
        let agent = row["agentId"] as? String ?? "main"
        return TokenEvent(id: "kimi:\(session):\(agent):\(line)", vendor: .kimi, source: "Kimi 桌面 / CLI", date: date, input: Values.integer(usage["inputOther"]) + read + write, output: Values.integer(usage["output"]), cacheRead: read, cacheWrite: write)
    }
    static func piRecord(_ row: [String: Any], provider: String, model: String) -> TokenEvent? {
        let type = row["type"] as? String ?? ""
        let message = Values.dictionary(row["message"])
        let isMessage = type == "message" && message["role"] as? String == "assistant"
        guard isMessage || ["usage", "compaction", "branch_summary"].contains(type) else { return nil }
        let actualProvider = (message["provider"] as? String ?? row["provider"] as? String ?? provider).lowercased()
        let actualModel = (message["model"] as? String ?? row["model"] as? String ?? model).lowercased()
        guard actualModel.contains("glm") || actualProvider.contains("zai") || actualProvider.contains("bigmodel") || actualProvider.contains("zhipu") else { return nil }
        let usage = Values.dictionary(isMessage ? message["usage"] : row["usage"])
        guard !usage.isEmpty, let date = Values.date(row["timestamp"] ?? message["timestamp"]), let id = row["id"] as? String else { return nil }
        let read = Values.integer(usage["cacheRead"]), write = Values.integer(usage["cacheWrite"])
        return TokenEvent(id: "pi:" + id, vendor: .glm, source: "pi + GLM", date: date, input: Values.integer(usage["input"]) + read + write, output: Values.integer(usage["output"]), cacheRead: read, cacheWrite: write)
    }
    static func aggregate(_ events: [TokenEvent], zone: TimeZone = .current, cutoff: Date) -> [DailyUsage] {
        var seen = Set<String>(), grouped: [String: DailyUsage] = [:]
        for event in events where event.date >= cutoff && event.date <= Date().addingTimeInterval(300) && event.total > 0 {
            guard seen.insert(event.id).inserted else { continue }
            let day = Values.day(event.date, zone: zone), key = day + ":" + event.vendor.rawValue + ":" + event.source
            if grouped[key] == nil { grouped[key] = DailyUsage(day: day, vendor: event.vendor, source: event.source, totals: TokenTotals()) }
            grouped[key]?.totals.add(event)
        }
        return grouped.values.sorted { $0.id < $1.id }
    }
}

final class UsageScanner {
    private struct Memo { let size: Int; let modified: Date; let events: [TokenEvent] }
    private var memo: [String: Memo] = [:]
    private let queue = DispatchQueue(label: "com.local.QuotaBar.usage", qos: .utility)
    func scan() async -> UsageSnapshot {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.blockingScan()) } }
    }
    private func files(_ root: URL, suffix: String) -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return iterator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(suffix) }.sorted { $0.path < $1.path }
    }
    private func readLines(_ file: URL, _ receive: ([String: Any], Int) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }; defer { try? handle.close() }
        var buffer = Data(), lineNumber = 0
        func consume(_ line: Data) {
            lineNumber += 1
            // Large prompt/tool lines are never decoded or retained.
            guard line.count < 4_000_000, let row = try? Values.json(line) else { return }
            receive(row, lineNumber)
        }
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) { let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline); consume(line) }
            if buffer.count > 16_000_000 { return } // A corrupt or unsupported log is not an unbounded allocation.
        }
        if !buffer.isEmpty { consume(buffer) }
    }
    private func logEvents(_ file: URL, kind: Vendor, cutoff: Date) -> [TokenEvent] {
        let path = file.resolvingSymlinksInPath().path
        guard let meta = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = meta.fileSize, let modified = meta.contentModificationDate else { return [] }
        if let old = memo[path], old.size == size, old.modified == modified { return old.events.filter { $0.date >= cutoff } }
        var events: [TokenEvent] = [], legacy: [TokenEvent] = []
        var firstCanonicalDate: Date?
        var source = "Codex 桌面 / CLI", session = file.deletingPathExtension().lastPathComponent
        var previousInput: Int64 = 0, previousOutput: Int64 = 0, previousRead: Int64 = 0, previousWrite: Int64 = 0
        var hasParent = false, sawLegacy = false, provider = "", model = ""
        if kind == .kimi { session = file.pathComponents.first(where: { $0.hasPrefix("session_") }) ?? session }
        readLines(file) { row, line in
            let type = row["type"] as? String ?? "", payload = Values.dictionary(row["payload"])
            if kind == .codex {
                if type == "session_meta" {
                    session = payload["id"] as? String ?? session
                    hasParent = payload["parent_thread_id"] != nil
                    let origin = (payload["originator"] as? String ?? "").lowercased()
                    if origin.contains("desktop") { source = "Codex 桌面" }
                    else if payload["source"] as? String == "cli" { source = "Codex CLI" }
                    if let s = payload["source"] as? [String: Any], s["subagent"] != nil { source = "Codex 子代理" }
                }
                if let event = UsageParsing.codexRecord(row, source: source) {
                    if firstCanonicalDate == nil { firstCanonicalDate = event.date }
                    if event.date >= cutoff { events.append(event) }
                }
                if type == "event_msg", payload["type"] as? String == "token_count", let date = Values.date(row["timestamp"]) {
                    let usage = Values.dictionary(Values.dictionary(payload["info"])["total_token_usage"])
                    guard !usage.isEmpty else { return }
                    let input = Values.integer(usage["input_tokens"]), output = Values.integer(usage["output_tokens"]), read = Values.integer(usage["cached_input_tokens"]), write = Values.integer(usage["cache_write_input_tokens"])
                    defer { previousInput = input; previousOutput = output; previousRead = read; previousWrite = write; sawLegacy = true }
                    if !sawLegacy && hasParent { return }
                    let event = TokenEvent(id: "codex-legacy:\(session):\(input):\(output):\(date.timeIntervalSince1970)", vendor: .codex, source: source, date: date, input: input >= previousInput ? input - previousInput : input, output: output >= previousOutput ? output - previousOutput : output, cacheRead: read >= previousRead ? read - previousRead : read, cacheWrite: write >= previousWrite ? write - previousWrite : write)
                    if event.date >= cutoff { legacy.append(event) }
                }
            } else if kind == .kimi {
                if let event = UsageParsing.kimiRecord(row, session: session, line: line), event.date >= cutoff { events.append(event) }
            } else {
                if type == "model_change" { provider = row["provider"] as? String ?? provider; model = row["modelId"] as? String ?? model }
                if let event = UsageParsing.piRecord(row, provider: provider, model: model), event.date >= cutoff { events.append(event) }
            }
        }
        // The newer per-response records and the legacy cumulative counters describe the same requests.
        if kind == .codex {
            if let first = firstCanonicalDate { events = legacy.filter { $0.date < first } + events }
            else { events = legacy }
        }
        memo[path] = Memo(size: size, modified: modified, events: events)
        return events
    }
    private func zcodeEvents(cutoff: Date) throws -> [TokenEvent] {
        let file = LocalPaths.zcode.appendingPathComponent("cli/db/db.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database = database { sqlite3_close(database) }; throw QuotaError.message("ZCode 用量数据库暂不可读")
        }
        defer { sqlite3_close(database) }; sqlite3_busy_timeout(database, 1000)
        // Only numeric accounting fields are selected; no conversation content is read.
        let sql = "SELECT id,provider_id,model_id,COALESCE(completed_at,started_at),input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens FROM model_usage WHERE COALESCE(completed_at,started_at)>=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw QuotaError.message("此版本 ZCode 尚未提供支持的用量表") }
        defer { sqlite3_finalize(statement) }; sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970 * 1000))
        var events: [TokenEvent] = []
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let provider = text(1).lowercased(), model = text(2).lowercased()
            if provider.contains("bigmodel") || provider.contains("zai") || provider.contains("zhipu") || model.contains("glm") {
                events.append(TokenEvent(id: "zcode:" + text(0), vendor: .glm, source: "ZCode", date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000), input: max(0, sqlite3_column_int64(statement, 4)), output: max(0, sqlite3_column_int64(statement, 5)), cacheRead: max(0, sqlite3_column_int64(statement, 6)), cacheWrite: max(0, sqlite3_column_int64(statement, 7))))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw QuotaError.message("ZCode 数据库正忙，稍后重试") }
        return events
    }
    private func blockingScan() -> UsageSnapshot {
        let cutoff = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -29, to: Date())!)
        var events: [TokenEvent] = [], health: [SourceHealth] = [], currentFiles = Set<String>()
        let sources: [(String, Vendor, String, URL, String)] = [
            ("codex", .codex, "Codex 桌面 / CLI", LocalPaths.codex.appendingPathComponent("sessions"), ".jsonl"),
            ("kimi", .kimi, "Kimi 桌面 / CLI", LocalPaths.kimi.appendingPathComponent("sessions"), "wire.jsonl"),
            ("pi", .glm, "pi + GLM", LocalPaths.pi.appendingPathComponent("sessions"), ".jsonl")
        ]
        for (id, vendor, title, root, suffix) in sources {
            var found = files(root, suffix: suffix)
            if vendor == .codex { found += files(LocalPaths.codex.appendingPathComponent("archived_sessions"), suffix: suffix) }
            var count = 0
            for file in found {
                currentFiles.insert(file.resolvingSymlinksInPath().path)
                let values = logEvents(file, kind: vendor, cutoff: cutoff); events += values; count += values.count
            }
            let exists = FileManager.default.fileExists(atPath: root.path)
            health.append(SourceHealth(id: id, vendor: vendor, title: title, available: exists, records: count, note: !exists ? "未发现本机会话目录" : count == 0 ? "目录已连接，最近 30 天暂无可计量记录" : "已连接 · 最近 30 天 \(count) 条用量记录"))
        }
        memo = memo.filter { currentFiles.contains($0.key) }
        let database = LocalPaths.zcode.appendingPathComponent("cli/db/db.sqlite")
        if FileManager.default.fileExists(atPath: database.path) {
            do { let values = try zcodeEvents(cutoff: cutoff); events += values; health.append(SourceHealth(id: "zcode", vendor: .glm, title: "ZCode", available: true, records: values.count, note: "只读连接 · 最近 30 天 \(values.count) 条用量记录")) }
            catch { health.append(SourceHealth(id: "zcode", vendor: .glm, title: "ZCode", available: false, records: 0, note: error.localizedDescription)) }
        } else { health.append(SourceHealth(id: "zcode", vendor: .glm, title: "ZCode", available: false, records: 0, note: "未发现支持的 ZCode 用量数据库")) }
        return UsageSnapshot(scannedAt: Date(), days: UsageParsing.aggregate(events, cutoff: cutoff), sources: health, timeZone: TimeZone.current.identifier)
    }
}
