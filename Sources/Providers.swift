import Foundation
import Security
import Darwin

final class ManagedChildren {
    static let shared = ManagedChildren()
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    func add(_ process: Process) { lock.lock(); processes[process.processIdentifier] = process; lock.unlock() }
    func remove(_ process: Process) { lock.lock(); processes[process.processIdentifier] = nil; lock.unlock() }
    func stopAll() {
        lock.lock(); let owned = Array(processes.values); processes.removeAll(); lock.unlock()
        for process in owned where process.isRunning { process.terminate() }
        let until = Date().addingTimeInterval(0.5)
        while Date() < until && owned.contains(where: { $0.isRunning }) { Thread.sleep(forTimeInterval: 0.02) }
        for process in owned where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

enum LocalPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var codex: URL { root("CODEX_HOME", ".codex") }
    static var kimi: URL { root("KIMI_CODE_HOME", ".kimi-code") }
    static var zcode: URL { home.appendingPathComponent(".zcode") }
    static var pi: URL { home.appendingPathComponent(".pi/agent") }
    static func root(_ environment: String, _ fallback: String) -> URL {
        if let path = ProcessInfo.processInfo.environment[environment], !path.isEmpty { return URL(fileURLWithPath: path) }
        return home.appendingPathComponent(fallback)
    }
    static func executable(_ name: String) -> URL? {
        let override = UserDefaults.standard.string(forKey: name + "Executable") ?? ""
        let paths = name == "codex" ? [override, home.appendingPathComponent(".local/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] : [override, kimi.appendingPathComponent("bin/kimi").path, "/opt/homebrew/bin/kimi", "/usr/local/bin/kimi"]
        return paths.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuotaBar")
    }
}

enum Secrets {
    static let service = "com.local.QuotaBar.credentials"
    static func readGLM() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "glm-coding-plan", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func saveGLM(_ value: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "glm-coding-plan"]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { SecItemDelete(key as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key; item.merge(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw QuotaError.message("无法保存到 macOS 钥匙串") }; return
        }
        guard status == errSecSuccess else { throw QuotaError.message("无法更新 macOS 钥匙串中的密钥") }
    }
    static func glmKey() throws -> String {
        if let key = readGLM(), !key.isEmpty { return key }
        let url = LocalPaths.zcode.appendingPathComponent("v2/config.json")
        if let data = try? Data(contentsOf: url), let json = try? Values.json(data) {
            let provider = Values.dictionary(Values.dictionary(json["provider"])["builtin:bigmodel-coding-plan"])
            if let key = Values.dictionary(provider["options"])["apiKey"] as? String, !key.isEmpty, !key.hasPrefix("enc:") { return key }
        }
        throw QuotaError.message("未找到智谱 Coding Plan 密钥，请在设置中连接")
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor ProviderClient {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 30
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func fetch(_ vendor: Vendor) async throws -> QuotaSnapshot {
        do {
            switch vendor {
            case .codex: return try QuotaParser.codex(await CodexRPC.readLimits())
            case .glm:
                let key = try Secrets.glmKey()
                return try QuotaParser.glm(await get("https://open.bigmodel.cn/api/monitor/usage/quota/limit", headers: ["Authorization": key]))
            case .kimi: return try await readKimi()
            }
        } catch let error as QuotaError { throw error }
        catch let error as URLError {
            if error.code == .timedOut { throw QuotaError.message("查询超时，将自动重试") }
            if error.code == .notConnectedToInternet { throw QuotaError.message("当前无网络连接，保留上次结果") }
            throw QuotaError.message("连接失败，请检查网络或本地客户端状态")
        } catch { throw QuotaError.message("查询暂不可用，请检查对应客户端登录") }
    }
    private func get(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 25) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw QuotaError.message("查询地址无效") }
        var request = URLRequest(url: target); request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw QuotaError.message("无法识别服务响应") }
        if response.statusCode == 429 { throw QuotaError.message("服务查询过于频繁，稍后自动重试") }
        if [401, 403].contains(response.statusCode) { throw QuotaError.message("认证已失效，请在对应客户端重新登录") }
        guard response.statusCode == 200, data.count < 2_000_000 else { throw QuotaError.message("服务暂时不可用") }
        return try Values.json(data)
    }
    private func instances() -> [(port: Int, pid: Int32, heartbeat: Double)] {
        let dir = LocalPaths.kimi.appendingPathComponent("server/instances")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file), let item = try? Values.json(data), let host = item["host"] as? String, ["127.0.0.1", "localhost", "::1"].contains(host), let port = Values.number(item["port"]), port > 0, port < 65536, let pid = Values.number(item["pid"]) else { return nil }
            return (Int(port), Int32(pid), Values.number(item["heartbeat_at"]) ?? 0)
        }.sorted { $0.heartbeat > $1.heartbeat }
    }
    private func serverToken() -> String? {
        (try? String(contentsOf: LocalPaths.kimi.appendingPathComponent("server.token"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func queryKimi(_ port: Int, token: String) async throws -> QuotaSnapshot {
        try QuotaParser.kimi(await get("http://127.0.0.1:\(port)/api/v1/oauth/usage", headers: ["Authorization": "Bearer " + token]))
    }
    private func readKimi() async throws -> QuotaSnapshot {
        var lastError: Error?
        if let token = serverToken(), !token.isEmpty {
            for item in instances().prefix(3) {
                guard (try? await get("http://127.0.0.1:\(item.port)/api/v1/healthz", timeout: 2)) != nil else { continue }
                do { return try await queryKimi(item.port, token: token) } catch { lastError = error }
            }
        }
        guard let binary = LocalPaths.executable("kimi") else { throw lastError ?? QuotaError.message("未找到 Kimi CLI，请打开 Kimi Code 后重试") }
        let process = Process(); process.executableURL = binary
        process.arguments = ["web", "--no-open", "--host", "127.0.0.1", "--port", "0", "--log-level", "silent"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); ManagedChildren.shared.add(process)
        defer { stopProcess(process); ManagedChildren.shared.remove(process) }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, process.isRunning {
            if let token = serverToken(), !token.isEmpty {
                if let own = instances().first(where: { $0.pid == process.processIdentifier }) {
                    if (try? await get("http://127.0.0.1:\(own.port)/api/v1/healthz", timeout: 1)) != nil { return try await queryKimi(own.port, token: token) }
                }
                // A desktop instance also accepts the official persistent token.
                for item in instances().filter({ $0.pid != process.processIdentifier }).prefix(1) {
                    if (try? await get("http://127.0.0.1:\(item.port)/api/v1/healthz", timeout: 1)) != nil { return try await queryKimi(item.port, token: token) }
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError ?? QuotaError.message("Kimi 本地服务未就绪，请在 Kimi Code 中登录后重试")
    }
}

func stopProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}

enum CodexRPC {
    static func readLimits() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try blockingRead()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func blockingRead() throws -> [String: Any] {
        guard let binary = LocalPaths.executable("codex") else { throw QuotaError.message("未找到 Codex CLI，请在设置中选择命令位置") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = binary; process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); ManagedChildren.shared.add(process)
        defer { try? input.fileHandleForWriting.close(); stopProcess(process); ManagedChildren.shared.remove(process); try? output.fileHandleForReading.close() }
        func send(_ item: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: item); data.append(10); try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "quotabar", "title": "额度看板", "version": "1.0.0"]]])
        var buffer = Data(); let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&item, 1, 200)
            if status < 0 { throw QuotaError.message("Codex 查询被中断") }
            if status == 0 { if !process.isRunning { break }; continue }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }; buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw QuotaError.message("Codex 返回数据过大") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let json = try? Values.json(line), let id = Values.number(json["id"]) else { continue }
                if json["error"] != nil { throw QuotaError.message("Codex 查询失败，请确认 CLI 已登录 ChatGPT 账号") }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2 { return json }
            }
        }
        throw QuotaError.message("Codex 查询超时，请确认 CLI 已登录")
    }
}
