import Foundation

struct DiagnosticReport: Codable {
    let checkedAt: Date
    let quotas: [QuotaSnapshot]
    let errors: [String: String]
    let usage: UsageSnapshot?
}

enum Diagnostics {
    static func check(usageOnly: Bool) async -> DiagnosticReport {
        let client = ProviderClient(), scanner = UsageScanner()
        async let usage = scanner.scan()
        var quotas: [QuotaSnapshot] = [], errors: [String: String] = [:]
        if !usageOnly {
            await withTaskGroup(of: (Vendor, QuotaSnapshot?, String?).self) { group in
                for vendor in Vendor.allCases {
                    group.addTask {
                        do { return (vendor, try await client.fetch(vendor), nil) }
                        catch { return (vendor, nil, error.localizedDescription) }
                    }
                }
                for await (vendor, snapshot, error) in group { if let snapshot = snapshot { quotas.append(snapshot) }; if let error = error { errors[vendor.rawValue] = error } }
            }
        }
        return await DiagnosticReport(checkedAt: Date(), quotas: quotas.sorted { $0.vendor.rawValue < $1.vendor.rawValue }, errors: errors, usage: usage)
    }
}

enum SelfTests {
    static func run() -> Bool {
        var count = 0, failures: [String] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) { count += 1; if !condition() { failures.append(name) } }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        // Synthetic fixtures only. Never paste real account responses into tests.
        let glm: [String: Any] = ["code": 200, "success": true, "data": ["limits": [
            ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 10000, "currentValue": 7655, "remaining": 2345, "percentage": 76, "nextResetTime": 1700000000123] as [String: Any],
            ["type": "TIME_LIMIT", "unit": 6, "number": 1, "percentage": 99] as [String: Any],
            ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 2000, "remaining": 2000, "percentage": 0] as [String: Any]
        ]]]
        do {
            let result = try QuotaParser.glm(glm)
            check("GLM selects 5h by unit, not array order", result.quotas[0].id == "glm.5h" && result.quotas[0].remainingPercent == 100)
            check("GLM uses precise remaining, not rounded percentage", abs(result.quotas[1].remainingPercent - 23.45) < 0.00001)
            check("GLM missing reset stays unknown", result.quotas[0].resetsAt == nil)
            check("GLM millisecond reset", abs(result.quotas[1].resetsAt!.timeIntervalSince1970 - 1700000000.123) < 0.001)
        } catch { failures.append("GLM parser unexpectedly rejected valid data") }
        check("GLM business failure with HTTP 200 is rejected", rejects { _ = try QuotaParser.glm(["code": 401, "success": false]) })
        check("GLM missing weekly quota rejected", rejects { _ = try QuotaParser.glm(["code": 200, "data": ["limits": [[String: Any]]()]]) })
        let codex: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 12, "windowDurationMins": 300], "secondary": ["usedPercent": 35, "windowDurationMins": 10080, "resetsAt": 1700000000]]]]
        do { let result = try QuotaParser.codex(codex); check("Codex locates weekly window even in secondary", result.quotas[0].remainingPercent == 65) }
        catch { failures.append("Codex parser unexpectedly rejected valid data") }
        check("Codex unavailable is not zero", rejects { _ = try QuotaParser.codex([:]) })
        let kimi: [String: Any] = ["code": 0, "data": ["kind": "ok", "quota": ["usages": ["limit5h": ["usedRatio": 0], "monthTotal": ["usedRatio": 0.2345], "monthCode": ["usedRatio": 0.91]]]] as [String: Any]]
        do { let result = try QuotaParser.kimi(kimi); check("Kimi monthly uses shared monthTotal", abs(result.quotas[1].remainingPercent - 76.55) < 0.00001); check("Kimi monthly pools are not added", result.quotas.count == 2) }
        catch { failures.append("Kimi parser unexpectedly rejected valid data") }
        check("Kimi in-band error rejected", rejects { _ = try QuotaParser.kimi(["code": 0, "data": ["kind": "error"]]) })
        check("Invalid percentages rejected", rejects { _ = try Values.percent(-1) })
        check("Booleans are not numeric quotas", Values.number(true) == nil)
        let progressFixture: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 8, "windowDurationMins": 10080]]]
        do {
            let quota = try QuotaParser.codex(progressFixture).quotas[0]
            check("Remaining 92% renders 8% used progress", quota.remainingPercent == 92 && abs(quota.usedFraction - 0.08) < 0.000001)
        } catch { failures.append("Used progress regression fixture rejected") }
        check("Unused quota renders empty progress", Quota(id: "test", title: "", remainingPercent: 100).usedFraction == 0)
        check("Depleted quota renders full progress", Quota(id: "test", title: "", remainingPercent: 0).usedFraction == 1)
        let date = Date(timeIntervalSince1970: 1704196800)
        let raw: [String: Any] = ["type": "token_usage_record", "timestamp": "2024-01-02T12:00:00Z", "payload": ["response_id": "test-response", "usage": ["input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 100, "reasoning_output_tokens": 60]] as [String: Any]]
        if let record = UsageParsing.codexRecord(raw, source: "Codex 桌面") {
            check("Codex cached and reasoning are subsets", record.total == 1100 && record.cacheRead == 800)
            let rows = UsageParsing.aggregate([record, record], zone: TimeZone(secondsFromGMT: 8 * 3600)!, cutoff: date.addingTimeInterval(-3600))
            check("Duplicate Codex responses counted once", rows.first?.totals.total == 1100 && rows.first?.totals.requests == 1)
        } else { failures.append("Codex token record unexpectedly absent") }
        let kimiRecord: [String: Any] = ["type": "usage.record", "time": date.timeIntervalSince1970 * 1000, "agentId": "main", "usage": ["inputOther": 10, "inputCacheRead": 80, "inputCacheCreation": 10, "output": 20]]
        check("Kimi adds cache to inputOther exactly once", UsageParsing.kimiRecord(kimiRecord, session: "s", line: 1)?.total == 120)
        check("Kimi mirrored loop event excluded", UsageParsing.kimiRecord(["type": "context.append_loop_event", "time": date.timeIntervalSince1970 * 1000, "usage": ["output": 100]], session: "s", line: 2) == nil)
        let pi: [String: Any] = ["id": "pi-1", "type": "message", "timestamp": "2024-01-02T12:00:00Z", "message": ["role": "assistant", "provider": "zai", "model": "glm-5", "usage": ["input": 10, "output": 20, "cacheRead": 80, "cacheWrite": 10, "reasoning": 5]] as [String: Any]]
        check("Pi excludes cache and reasoning double count", UsageParsing.piRecord(pi, provider: "", model: "")?.total == 120)
        check("Pi other providers filtered", UsageParsing.piRecord(["id": "p", "type": "usage", "provider": "other", "model": "other", "usage": ["input": 2]], provider: "", model: "") == nil)
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        check("Day grouping respects local midnight", Values.day(Values.date("2024-01-02T16:00:01Z")!, zone: zone) == "2024-01-03")
        // Reproduce Finder's minimal PATH with a synthetic npm-style CLI/runtime.
        do {
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-runtime-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let runtime = fixture.appendingPathComponent("bin")
            let cli = fixture.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            let node = runtime.appendingPathComponent("node")
            try Data("#!/bin/sh\nprintf 'fixture-node\\n'\n".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
            let environment = LocalPaths.cliEnvironment(for: cli, inheriting: ["PATH": "/usr/bin:/bin", "QUOTABAR_FIXTURE": "retained"])
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node"]
            process.environment = environment; process.standardOutput = output
            process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            let result = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            check("Finder PATH resolves the selected CLI's Node runtime", process.terminationStatus == 0 && result == "fixture-node\n")
            check("CLI environment preserves inherited settings", environment["QUOTABAR_FIXTURE"] == "retained")
        } catch { failures.append("Finder runtime fixture failed") }
        check("CLI exit 127 reports missing runtime", CodexRPC.failureMessage(initialized: false, exitCode: 127).contains("Node.js"))
        check("Quota timeout does not imply expired login", !CodexRPC.failureMessage(initialized: true, exitCode: nil).contains("登录"))
        if failures.isEmpty { print("PASS: \(count) accounting, quota and deduplication checks") }
        else { for failure in failures { print("FAIL: " + failure) } }
        return failures.isEmpty
    }
}
