import AppKit
import SwiftUI
import ServiceManagement

private enum Palette {
    static let accent = adaptive(light: (0.25, 0.39, 0.85), dark: (0.48, 0.61, 1.0))
    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.065)
}

private struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line))
            .shadow(color: .black.opacity(0.025), radius: 5, x: 0, y: 2)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 8))
                .background(Color.primary.opacity(hovered ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.35).help(help).accessibilityLabel(help).onHover { hovered = $0 }
    }
}

extension Vendor {
    var color: Color {
        switch self {
        case .codex: return Palette.adaptive(light: (0.10, 0.57, 0.43), dark: (0.28, 0.78, 0.62))
        case .glm: return Palette.adaptive(light: (0.27, 0.45, 0.88), dark: (0.47, 0.64, 1.0))
        case .kimi: return Palette.adaptive(light: (0.57, 0.37, 0.80), dark: (0.73, 0.55, 0.96))
        }
    }
    var detail: String { switch self { case .codex: return "ChatGPT · Codex"; case .glm: return "ZCode · GLM"; case .kimi: return "Kimi Coding Plan" } }
}

struct Monogram: View {
    let vendor: Vendor
    var body: some View {
        Text(vendor.initials).font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(vendor.color).frame(width: 30, height: 30)
            .background(vendor.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(vendor.color.opacity(0.10)))
    }
}

private struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("额度看板").font(.system(size: 16, weight: .semibold))
                Text("QuotaBar").font(.system(size: 10, weight: .medium)).tracking(0.7).foregroundColor(.secondary)
            }
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Brand(); Spacer()
                if model.refreshing || model.scanning { ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 16) }
                IconButton(symbol: "arrow.clockwise", help: "刷新额度和本机用量") { model.refreshAll(force: true) }
                IconButton(symbol: "gearshape", help: "设置", action: openSettings)
            }
            HStack(spacing: 4) {
                pageTab("剩余额度", symbol: "gauge.medium", page: 0)
                pageTab("每日用量", symbol: "chart.bar", page: 1)
            }.padding(4).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            ScrollView(.vertical, showsIndicators: false) {
                if model.page == 0 {
                    VStack(spacing: 10) {
                        HStack {
                            Text("订阅额度").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                            Spacer()
                            Text("数字为剩余 · 进度为已用").font(.system(size: 9)).foregroundColor(.secondary)
                        }.padding(.horizontal, 2).padding(.bottom, 2)
                        ForEach(Vendor.allCases) { vendor in
                            if let state = model.providers[vendor] { ProviderCard(state: state) }
                        }
                    }.padding(.bottom, 4)
                } else { UsageView(model: model).padding(.bottom, 4) }
            }.scrollIndicators(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 5) {
                Circle().fill(model.refreshing || model.scanning ? Color.orange : Color.green.opacity(0.8)).frame(width: 5, height: 5)
                Text(model.refreshing || model.scanning ? "正在更新…" : model.page == 0 ? "每 \(model.refreshMinutes) 分钟自动更新" : "本机用量每分钟更新").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text("QuotaBar").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary.opacity(0.65))
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 20, height: 20) }.buttonStyle(.plain).help("退出额度看板")
            }.padding(.top, 9).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }.padding(18).frame(width: 424, height: 720).background(Palette.canvas).tint(Palette.accent)
    }
    private func pageTab(_ title: String, symbol: String, page: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.16)) { model.page = page } } label: {
            HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 11)); Text(title).font(.system(size: 11, weight: .semibold)) }
                .foregroundColor(model.page == page ? .primary : .secondary)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(model.page == page ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(model.page == page ? 0.06 : 0), radius: 2, y: 1)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
    }
}

struct ProviderCard: View {
    let state: ProviderState
    private var warning: Bool { state.error != nil || state.stale }
    private var status: String { state.loading ? "更新中" : state.error != nil ? "待更新" : state.stale ? "已过期" : "已连接" }
    private var subtitle: String {
        guard let snapshot = state.snapshot else { return state.vendor.detail }
        return "更新于 " + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Monogram(vendor: state.vendor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.vendor.name).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(warning ? Color.orange : state.vendor.color).frame(width: 4, height: 4)
                    Text(status).font(.system(size: 9, weight: .medium))
                }.foregroundColor(warning ? .orange : .secondary).padding(.horizontal, 7).padding(.vertical, 4)
                    .background((warning ? Color.orange : state.vendor.color).opacity(0.07), in: Capsule())
            }
            if let snapshot = state.snapshot {
                VStack(spacing: 7) {
                    ForEach(Array(snapshot.quotas.enumerated()), id: \.element.id) { index, quota in
                        if index > 0 { Rectangle().fill(Palette.line).frame(height: 1) }
                        QuotaRow(quota: quota, color: state.vendor.color, muted: warning)
                    }
                }
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.system(size: 9)).foregroundColor(.orange).lineLimit(2)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: state.error == nil ? "ellipsis.circle" : "exclamationmark.circle")
                    Text(state.error ?? "正在读取本机账号额度…").fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundColor(.secondary).padding(.vertical, 10)
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).modifier(Panel())
    }
}

struct QuotaRow: View {
    let quota: Quota
    let color: Color
    let muted: Bool
    var tint: Color { muted ? .gray : quota.remainingPercent <= 10 ? .red : quota.remainingPercent <= 20 ? .orange : color }
    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(quota.title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("剩余").font(.system(size: 9)).foregroundColor(.secondary)
                Text(Values.percentText(quota.remainingPercent)).font(.system(size: 21, weight: .semibold, design: .rounded)).tracking(-0.6).monospacedDigit().foregroundColor(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.10))
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.72), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * quota.usedFraction))
                }
            }.frame(height: 5)
                .accessibilityLabel("\(quota.title)已用 \(Values.percentText(quota.usedPercent))，剩余 \(Values.percentText(quota.remainingPercent))")
                .help("进度条显示已用额度：\(Values.percentText(quota.usedPercent))")
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 30)) { context in Text(resetText(now: context.date)).lineLimit(1).minimumScaleFactor(0.8) }
                Spacer(minLength: 2)
                if let remaining = quota.remaining, let total = quota.total {
                    Text("\(Int(remaining).formatted(.number)) / \(Int(total).formatted(.number)) \(quota.unit ?? "")").lineLimit(1).minimumScaleFactor(0.8)
                } else { Text("已用 \(Values.percentText(quota.usedPercent))").monospacedDigit() }
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
    @State private var showScope = false
    private var snapshot: UsageSnapshot? { model.usage }
    private var total: TokenTotals { snapshot?.totals(day: model.selectedDay) ?? TokenTotals() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconButton(symbol: "chevron.left", help: "前一天") { changeDay(-1) }.disabled(model.selectedDay <= dayOffset(-29))
                Spacer()
                Text(model.selectedDay == Values.day(Date()) ? "今天 · \(model.selectedDay)" : model.selectedDay).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Spacer()
                IconButton(symbol: "chevron.right", help: "后一天") { changeDay(1) }.disabled(model.selectedDay >= Values.day(Date()))
            }
            if snapshot == nil {
                ProgressView("正在索引本机用量记录…").frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Label("当日 Token 消耗", systemImage: "sparkle").font(.system(size: 10, weight: .medium)); Spacer(); Text("\(total.requests) 条请求").font(.system(size: 9)) }.foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Values.compact(total.total)).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1).monospacedDigit()
                        Text("tokens").font(.system(size: 11)).foregroundColor(.secondary)
                    }.help("本机记录总计：\(total.total.formatted(.number)) tokens")
                    Rectangle().fill(Palette.accent.opacity(0.12)).frame(height: 1)
                    HStack(spacing: 0) {
                        smallStat("输入（含缓存）", total.input)
                        smallStat("输出", total.output)
                        smallStat("缓存读取", total.cacheRead)
                    }
                }.padding(13).background(LinearGradient(colors: [Palette.accent.opacity(0.09), Palette.accent.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.13)))
                sevenDayChart
                VStack(spacing: 8) {
                    HStack { Text("按服务查看").font(.system(size: 10, weight: .medium)); Spacer(); Text("展开查看来源").font(.system(size: 9)) }.foregroundColor(.secondary).padding(.horizontal, 2)
                    ForEach(Vendor.allCases) { vendor in
                        UsageVendorRow(vendor: vendor, rows: snapshot?.days.filter { $0.day == model.selectedDay && $0.vendor == vendor } ?? [], health: snapshot?.sources.filter { $0.vendor == vendor } ?? [])
                    }
                }
                HStack {
                    Button { showScope.toggle() } label: {
                        Label("本机记录 · 最近 30 天", systemImage: "info.circle").font(.system(size: 9)).foregroundColor(.secondary)
                    }.buttonStyle(.plain).help("查看统计范围和分日时区")
                        .popover(isPresented: $showScope) { scopeDetails }
                    Spacer()
                    Button { model.exportUsage() } label: {
                        Label("导出 CSV", systemImage: "square.and.arrow.up").font(.system(size: 10)).foregroundColor(Palette.accent)
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 2)

            }
        }
    }
    private var scopeDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("统计范围").font(.system(size: 12, weight: .semibold))
            Text("仅统计本机最近 30 天保存的请求记录。输入包含缓存，输出包含推理，不重复相加。普通 ChatGPT 聊天、其他设备及已删除记录不在覆盖范围内。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("分日时区：" + (snapshot?.timeZone ?? TimeZone.current.identifier)).font(.system(size: 10)).foregroundColor(.secondary)
        }.padding(16).frame(width: 280)
    }
    private func smallStat(_ title: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 9)).foregroundColor(.secondary); Text(Values.compact(count)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading).help(count.formatted(.number) + " tokens")
    }
    private func dayOffset(_ n: Int) -> String { Values.day(Calendar.current.date(byAdding: .day, value: n, to: Date())!) }
    private func changeDay(_ n: Int) {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        if let date = f.date(from: model.selectedDay), let next = Calendar.current.date(byAdding: .day, value: n, to: date) { model.selectedDay = Values.day(next) }
    }
    private var sevenDayChart: some View { SevenDayChart(snapshot: snapshot, selectedDay: $model.selectedDay) }
}

private struct SevenDayChart: View {
    let snapshot: UsageSnapshot?
    @Binding var selectedDay: String
    private var dates: [String] { (-6...0).map { Values.day(Calendar.current.date(byAdding: .day, value: $0, to: Date())!) } }
    private var maximum: Int64 { max(1, dates.map { snapshot?.totals(day: $0).total ?? 0 }.max() ?? 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("最近 7 天").font(.system(size: 10, weight: .semibold)); Spacer()
                ForEach(Vendor.allCases) { vendor in HStack(spacing: 3) { Circle().fill(vendor.color).frame(width: 5, height: 5); Text(vendor.shortName).font(.system(size: 8)).foregroundColor(.secondary) } }
            }
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(dates, id: \.self) { day in
                    UsageDayBar(day: day, snapshot: snapshot, maximum: maximum, selected: selectedDay == day) { selectedDay = day }
                }
            }
        }.padding(13).modifier(Panel())
    }
}

private struct UsageDayBar: View {
    let day: String
    let snapshot: UsageSnapshot?
    let maximum: Int64
    let selected: Bool
    let action: () -> Void
    private var total: Int64 { snapshot?.totals(day: day).total ?? 0 }
    private var hint: String { day + " · " + Values.compact(total) + " tokens" }
    private var spoken: String { day + "，" + String(total) + " tokens" }
    var body: some View {
        Button(action: action) { column }
            .buttonStyle(.plain).help(hint).accessibilityLabel(spoken)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var column: some View {
        VStack(spacing: 6) {
            bars.frame(height: 44)
            Text(String(day.suffix(5)))
                .font(.system(size: 8, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? Palette.accent : Color.secondary)
            Capsule().fill(selected ? Palette.accent : Color.clear).frame(width: 12, height: 2)
        }.frame(maxWidth: .infinity).contentShape(Rectangle())
    }
    private var bars: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.025))
            VStack(spacing: 1) {
                ForEach(Vendor.allCases.reversed()) { vendor in segment(vendor) }
            }.clipShape(RoundedRectangle(cornerRadius: 4)).padding(.horizontal, 5)
        }
    }
    @ViewBuilder private func segment(_ vendor: Vendor) -> some View {
        let amount = snapshot?.totals(day: day, vendor: vendor).total ?? 0
        let height = max(1.0, Double(amount) / Double(maximum) * 40.0)
        if amount > 0 {
            Rectangle().fill(vendor.color.opacity(selected ? 1 : 0.55)).frame(height: height)
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
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in HStack { Text(row.source); Spacer(); Text(row.totals.total.formatted(.number)).monospacedDigit() } }
                if rows.isEmpty { Text(health.contains { $0.available } ? "当天暂无本机用量记录" : "尚未连接可计量的本机记录").foregroundColor(.secondary) }
                ForEach(health.filter { !$0.available || $0.records == 0 }) { item in Text(item.title + "：" + item.note).foregroundColor(.secondary) }
                HStack { Text("缓存写入（输入子集）"); Spacer(); Text(Values.compact(total.cacheWrite)) }.foregroundColor(.secondary)
            }.font(.system(size: 10)).padding(.top, 10).padding(.leading, 3)
        } label: {
            HStack(spacing: 9) {
                Monogram(vendor: vendor)
                Text(vendor.shortName).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(total.total > 0 ? Values.compact(total.total) : health.contains { $0.available } ? "暂无记录" : "未连接").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }.padding(8).modifier(Panel()).tint(vendor.color)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var startup = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(spacing: 0) {
            HStack { Brand(); Spacer(); Text("偏好设置").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary) }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
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
            HStack { Text("额度看板 1.0.2 · macOS 原生客户端").font(.system(size: 10)).foregroundColor(.secondary); Spacer(); Button { model.refreshAll(force: true) } label: { Text("立即刷新").foregroundColor(.primary) } }
            }.formStyle(.grouped)
        }.frame(width: 530, height: 690).background(Palette.canvas).tint(Palette.accent)
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
