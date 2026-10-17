import AppKit
import SwiftUI
import ServiceManagement

extension Vendor {
    var color: Color { switch self { case .codex: return Color(red: 0.13, green: 0.62, blue: 0.48); case .glm: return Color(red: 0.28, green: 0.46, blue: 0.91); case .kimi: return Color(red: 0.57, green: 0.38, blue: 0.84) } }
}

struct Monogram: View {
    let vendor: Vendor
    var body: some View {
        Text(vendor.initials).font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(vendor.color).frame(width: 24, height: 24)
            .background(vendor.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .semibold)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("额度看板").font(.system(size: 17, weight: .semibold))
                    Text("你的 AI 用量，一眼可见").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                if model.refreshing || model.scanning { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18) }
                Button { model.refreshAll(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新额度和本机用量")
                Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("设置")
            }
            Picker("页面", selection: $model.page) { Text("剩余额度").tag(0); Text("每日用量").tag(1) }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                if model.page == 0 {
                    VStack(spacing: 10) { ForEach(Vendor.allCases) { vendor in ProviderCard(state: model.providers[vendor]!) } }
                } else { UsageView(model: model) }
            }.scrollIndicators(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Circle().fill(Color.accentColor.opacity(0.75)).frame(width: 5, height: 5)
                Text(model.page == 0 ? "额度每 \(model.refreshMinutes) 分钟更新" : "本机用量每分钟更新").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 11)) }.buttonStyle(.borderless).help("退出额度看板")
            }
        }.padding(18).frame(width: 410, height: 660).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProviderCard: View {
    let state: ProviderState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Monogram(vendor: state.vendor)
                Text(state.vendor.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(state.loading ? "更新中" : state.error != nil ? "待更新" : state.stale ? "已过期" : "已连接")
                    .font(.system(size: 10)).foregroundColor(state.error != nil || state.stale ? .orange : .secondary)
            }
            if let snapshot = state.snapshot {
                ForEach(snapshot.quotas) { quota in QuotaRow(quota: quota, color: state.vendor.color, muted: state.error != nil || state.stale) }
                HStack(spacing: 4) {
                    if state.error != nil { Image(systemName: "exclamationmark.circle") }
                    Text(state.error ?? "更新于 \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }.font(.system(size: 9)).foregroundColor(state.error == nil ? .secondary : .orange).lineLimit(2)
            } else {
                Text(state.error ?? "正在读取本机账号额度…").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.05)))
    }
}

struct QuotaRow: View {
    let quota: Quota
    let color: Color
    let muted: Bool
    var tint: Color { muted ? .gray : quota.remainingPercent <= 10 ? .red : quota.remainingPercent <= 20 ? .orange : color }
    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.title).font(.system(size: 11))
                Spacer()
                Text("剩余").font(.system(size: 9)).foregroundColor(.secondary)
                Text(Values.percentText(quota.remainingPercent)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    Capsule().fill(tint).frame(width: max(0, geo.size.width * quota.usedFraction))
                }
            }.frame(height: 5)
                .accessibilityLabel("\(quota.title)已用 \(Values.percentText(quota.usedPercent))，剩余 \(Values.percentText(quota.remainingPercent))")
                .help("进度条显示已用额度：\(Values.percentText(quota.usedPercent))")
            HStack(alignment: .firstTextBaseline) {
                TimelineView(.periodic(from: .now, by: 30)) { context in Text(resetText(now: context.date)).lineLimit(1) }
                Spacer(minLength: 4)
                if let remaining = quota.remaining, let total = quota.total {
                    Text("\(Int(remaining).formatted(.number)) / \(Int(total).formatted(.number)) \(quota.unit ?? "")").lineLimit(1).minimumScaleFactor(0.8)
                }
            }.font(.system(size: 9)).foregroundColor(.secondary)
                .help(quota.resetsAt.map { "重置时间：" + $0.formatted(date: .complete, time: .standard) } ?? "服务未返回重置时间")
        }
    }
    private func resetText(now: Date) -> String {
        guard let date = quota.resetsAt else { return "恢复时间待服务提供" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "窗口已结束，等待查询确认" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "\(minutes) 分钟后重置" }
        if minutes < 1440 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置"
    }
}

struct UsageView: View {
    @ObservedObject var model: AppModel
    private var snapshot: UsageSnapshot? { model.usage }
    private var total: TokenTotals { snapshot?.totals(day: model.selectedDay) ?? TokenTotals() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { changeDay(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).disabled(model.selectedDay <= dayOffset(-29))
                Spacer()
                Text(model.selectedDay == Values.day(Date()) ? "今天 · \(model.selectedDay)" : model.selectedDay).font(.system(size: 11, weight: .medium))
                Spacer()
                Button { changeDay(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).disabled(model.selectedDay >= Values.day(Date()))
            }.padding(.top, 2)
            if snapshot == nil {
                ProgressView("正在索引本机用量记录…").frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Values.compact(total.total)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("tokens").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                        Text("\(total.requests) 条请求记录").font(.system(size: 9)).foregroundColor(.secondary)
                    }.help("本机记录总计：\(total.total.formatted(.number)) tokens")
                    HStack {
                        smallStat("输入（含缓存）", total.input)
                        Spacer(); smallStat("输出", total.output)
                        Spacer(); smallStat("缓存读取", total.cacheRead)
                    }
                }.padding(13).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                sevenDayChart
                VStack(spacing: 9) {
                    ForEach(Vendor.allCases) { vendor in
                        UsageVendorRow(vendor: vendor, rows: snapshot?.days.filter { $0.day == model.selectedDay && $0.vendor == vendor } ?? [], health: snapshot?.sources.filter { $0.vendor == vendor } ?? [])
                    }
                }
                Text("统计本机最近 30 天保存的请求记录。输入已包含缓存，推理属于输出，不重复相加。普通 ChatGPT 聊天、其他设备及已删除记录不在覆盖范围内。")
                    .font(.system(size: 9)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("按 \(snapshot?.timeZone ?? TimeZone.current.identifier) 分日").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Button { model.exportUsage() } label: { Text("导出 CSV").foregroundColor(.accentColor) }.buttonStyle(.borderless).font(.system(size: 10))
                }
            }
        }
    }
    private func smallStat(_ title: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 9)).foregroundColor(.secondary); Text(Values.compact(count)).font(.system(size: 12, weight: .medium)).monospacedDigit() }
            .help(count.formatted(.number) + " tokens")
    }
    private func dayOffset(_ n: Int) -> String { Values.day(Calendar.current.date(byAdding: .day, value: n, to: Date())!) }
    private func changeDay(_ n: Int) {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        if let date = f.date(from: model.selectedDay), let next = Calendar.current.date(byAdding: .day, value: n, to: date) { model.selectedDay = Values.day(next) }
    }
    private var sevenDayChart: some View {
        let dates = (-6...0).map(dayOffset)
        let maximum = max(1, dates.map { snapshot?.totals(day: $0).total ?? 0 }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("最近 7 天").font(.system(size: 10, weight: .medium)); Spacer()
                ForEach(Vendor.allCases) { vendor in HStack(spacing: 3) { Circle().fill(vendor.color).frame(width: 5, height: 5); Text(vendor.shortName).font(.system(size: 8)).foregroundColor(.secondary) } }
            }
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(dates, id: \.self) { day in
                    Button { model.selectedDay = day } label: {
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            VStack(spacing: 1) {
                                ForEach(Vendor.allCases.reversed()) { vendor in
                                    let amount = snapshot?.totals(day: day, vendor: vendor).total ?? 0
                                    if amount > 0 { RoundedRectangle(cornerRadius: 2).fill(vendor.color.opacity(model.selectedDay == day ? 1 : 0.65)).frame(height: max(1, Double(amount) / Double(maximum) * 45)) }
                                }
                            }.frame(maxWidth: .infinity, minHeight: 2, alignment: .bottom).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 2))
                            Text(String(day.suffix(5))).font(.system(size: 8)).foregroundColor(model.selectedDay == day ? .primary : .secondary)
                        }.frame(height: 65)
                    }.buttonStyle(.plain).help(day + " · " + Values.compact(snapshot?.totals(day: day).total ?? 0) + " tokens")
                }
            }
        }
    }
}

struct UsageVendorRow: View {
    let vendor: Vendor
    let rows: [DailyUsage]
    let health: [SourceHealth]
    private var total: TokenTotals { rows.reduce(into: TokenTotals()) { $0.add($1.totals) } }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in HStack { Text(row.source); Spacer(); Text(row.totals.total.formatted(.number)).monospacedDigit() } }
                if rows.isEmpty { Text(health.contains { $0.available } ? "当天暂无本机用量记录" : "尚未连接可计量的本机记录").foregroundColor(.secondary) }
                ForEach(health.filter { !$0.available || $0.records == 0 }) { item in Text(item.title + "：" + item.note).foregroundColor(.secondary) }
                HStack { Text("缓存写入（输入子集）"); Spacer(); Text(Values.compact(total.cacheWrite)) }
            }.font(.system(size: 9)).padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Monogram(vendor: vendor)
                Text(vendor.shortName).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(total.total > 0 ? Values.compact(total.total) : health.contains { $0.available } ? "暂无记录" : "未连接").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }.padding(8).background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var startup = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section("常规") {
                Picker("额度刷新间隔", selection: $model.refreshMinutes) { ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) 分钟").tag($0) } }
                Picker("菜单栏显示", selection: $model.menuMetric) {
                    Text("仅图标").tag("icon"); Text("Codex 周额度").tag("codex.week")
                    Text("智谱 5 小时额度").tag("glm.5h"); Text("智谱周额度").tag("glm.week")
                    Text("Kimi 5 小时额度").tag("kimi.5h"); Text("Kimi 月额度").tag("kimi.month")
                }
                Toggle("开机启动", isOn: Binding(get: { startup }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        startup = SMAppService.mainApp.status == .enabled
                        if SMAppService.mainApp.status == .requiresApproval { model.connectionMessage = "请在系统设置 → 通用 → 登录项中允许额度看板开机启动" }
                    }
                    catch { model.connectionMessage = "开机启动设置未完成，请将应用放入「应用程序」后重试"; startup = SMAppService.mainApp.status == .enabled }
                }))
                Toggle("低额度提醒（20% 和 10%）", isOn: Binding(get: { model.notifications }, set: { model.setNotifications($0) }))
            }
            Section("账号连接") {
                Text("自动使用本机 Codex、ZCode 和 Kimi Code 的已有登录。查询不发送模型请求。").font(.system(size: 11)).foregroundColor(.secondary)
                SecureField("智谱 Coding Plan API Key（可选）", text: $key)
                HStack {
                    Button { model.saveManualKey(key); key = "" } label: { Text("保存到钥匙串").foregroundColor(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { model.saveManualKey(""); key = "" } label: { Text("恢复自动读取").foregroundColor(.primary) }
                }
                DisclosureGroup("CLI 命令位置") {
                    executableRow("Codex", name: "codex"); executableRow("Kimi", name: "kimi")
                }
            }
            Section("用量来源") {
                ForEach(model.usage?.sources ?? []) { source in
                    HStack(alignment: .top) {
                        Image(systemName: source.available ? "checkmark.circle.fill" : "minus.circle").foregroundColor(source.available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(source.title).font(.system(size: 11, weight: .medium)); Text(source.note).font(.system(size: 10)).foregroundColor(.secondary) }
                    }
                }
                Text("只读扫描本机记录，仅保存数值汇总，不保存对话正文。缓存 token 属于输入，推理 token 属于输出。普通 ChatGPT 聊天不提供精确 token 记录。").font(.system(size: 10)).foregroundColor(.secondary)
            }
            if !model.connectionMessage.isEmpty { Text(model.connectionMessage).font(.system(size: 11)).foregroundColor(.secondary) }
            HStack { Text("额度看板 1.0.1 · macOS 原生客户端").font(.system(size: 10)).foregroundColor(.secondary); Spacer(); Button { model.refreshAll(force: true) } label: { Text("立即刷新").foregroundColor(.primary) } }
        }.formStyle(.grouped).frame(width: 530, height: 650)
    }
    private func executableRow(_ title: String, name: String) -> some View {
        HStack {
            Text(title).frame(width: 55, alignment: .leading)
            Text(LocalPaths.executable(name)?.path ?? "未找到").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            Spacer()
            Button {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: name + "Executable"); model.objectWillChange.send(); model.refreshAll(force: true) }
            } label: { Text("选择…").foregroundColor(.primary) }
        }.font(.system(size: 10))
    }
}
