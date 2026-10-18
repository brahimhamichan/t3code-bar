import SwiftUI
import AppKit
import Charts

/// Config lives in ~/.config/t3code-bar/: `devices.json` lists T3 Code servers (default: this Mac only),
/// and each device needs a read-only token at `<id>.token`. See README.
let configDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/t3code-bar")

/// `ssh: nil` is this Mac; remote servers are reached through an SSH port-forward.
let devices: [Device] = (try? JSONDecoder().decode([Device].self, from: Data(contentsOf: configDir.appending(path: "devices.json"))))
    ?? [Device(id: "local", name: "This Mac", ssh: nil)]

// MARK: - T3 usage-limit snapshot (subscribeServerConfig)

struct Window: Decodable { let id: String; let kind: String; let label: String; let usedPercent: Double; let resetsAt: Date? }
struct Credits: Decodable { let availableCount: Int }
struct Limits: Decodable { let checkedAt: Date; let windows: [Window]; let resetCredits: Credits? }
struct Provider: Decodable { let instanceId: String; let displayName: String?; let driver: String; let usageLimits: Limits? }
struct SourceAccount: Decodable { let id: String; let driver: String; let email: String?; let usageLimits: Limits }
struct Source: Decodable { let label: String; let accounts: [SourceAccount] }
struct Snapshot: Decodable { let providers: [Provider]; let sources: [Source]? }

struct Account: Identifiable { let id: String; let name: String; let limits: Limits }
struct Agent: Identifiable {
    let id: String; let name: String; let icon: String; let tint: Color; var accounts: [Account]
    /// Window labels in first-seen order, e.g. Session, Weekly, Monthly.
    var rows: [String] { accounts.flatMap { $0.limits.windows.map(\.label) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    func bars(_ label: String) -> [(Account, Window)] { accounts.compactMap { a in a.limits.windows.first { $0.label == label }.map { (a, $0) } } }
    func left(_ label: String) -> Int { let b = bars(label); return b.isEmpty ? 0 : Int((b.map { 100 - $0.1.usedPercent }.reduce(0, +) / Double(b.count)).rounded()) }
    /// Menubar value: weekly if reported, otherwise the longest window.
    var headline: Int? {
        let w = accounts.flatMap(\.limits.windows)
        guard let pick = w.first(where: { $0.kind == "weekly" }) ?? w.first(where: { $0.kind == "monthly" }) ?? w.last else { return nil }
        return left(pick.label)
    }
}

/// Brand marks and colors from t3code's Icons.tsx.
let brands: [String: (name: String, icon: String, tint: Color)] = [
    "codex": ("Codex", "openai", Color(white: 0.62)),
    "claudeAgent": ("Claude", "claude", Color(red: 0.85, green: 0.47, blue: 0.34)),
    "grok": ("Grok", "grok", Color(white: 0.62)),
]

/// t3code dark theme tokens (apps/web/src/index.css).
enum T3 {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.04)   // neutral-950
    static let card = Color.white.opacity(0.03)
    static let border = Color.white.opacity(0.06)
    static let foreground = Color(red: 0.96, green: 0.96, blue: 0.96)   // neutral-100
    static let muted = Color(red: 0.49, green: 0.49, blue: 0.49)        // neutral-500 + white
    static let secondary = Color.white.opacity(0.04)
}

func icon(_ name: String, size: CGFloat) -> NSImage {
    guard let url = Bundle.main.url(forResource: name, withExtension: "svg"), let img = NSImage(contentsOf: url)
    else { return NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)! }
    img.size = NSSize(width: size, height: size); img.isTemplate = true
    return img
}

// MARK: - Usage (server.getUsageSummary buckets)

struct Totals: Decodable { let uncachedInputTokens, cachedInputTokens, cacheCreationTokens, outputTokens: Double }
struct Bucket: Decodable { let day: String; let provider: String; let model: String; let totals: Totals; let costUsd: Double; let cacheSavingsUsd: Double?; let sessions: Int }
struct UsageResult: Decodable { let buckets: [Bucket] }

enum Tab: String, CaseIterable { case cost = "Cost", tokens = "Tokens", limits = "Limits" }
enum Range: Int, CaseIterable {
    case day = 1, week = 7, month = 30, quarter = 90
    var label: String { self == .day ? "24h" : "\(rawValue)d" }
}

/// Usage providers → display name + icon + tint, matching T3's Usage page.
let usageBrands: [String: (name: String, icon: String, tint: Color)] = [
    "codex": ("Codex", "openai", Color(white: 0.85)),
    "claude": ("Claude Code", "claude", Color(red: 0.85, green: 0.47, blue: 0.34)),
    "grok": ("Grok Build", "grok", Color(white: 0.55)),
    "opencode": ("OpenCode", "", Color(red: 0.35, green: 0.62, blue: 0.85)),
]
func usageBrand(_ p: String) -> (name: String, icon: String, tint: Color) { usageBrands[p] ?? (p.capitalized, "", T3.muted) }

extension Bucket {
    var tokens: Double { totals.uncachedInputTokens + totals.cachedInputTokens + totals.cacheCreationTokens + totals.outputTokens }
    func value(_ tab: Tab) -> Double { tab == .cost ? costUsd : tokens }
}

func compact(_ v: Double) -> String {
    switch v { case 1e9...: String(format: "%.1fB", v / 1e9); case 1e6...: String(format: "%.0fM", v / 1e6); case 1e3...: String(format: "%.1fK", v / 1e3); default: String(format: "%.0f", v) }
}
func money(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }

// MARK: - T3 Code server client (same WebSocket RPC the T3 app uses)

struct Device: Sendable, Decodable { let id: String; let name: String; let ssh: String? }

let decoder: JSONDecoder = {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .custom { d in
        let s = try d.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? .distantPast
    }
    return dec
}()

/// Tunnel ssh processes, killed when the app exits.
nonisolated(unsafe) var tunnelPIDs: [Int32] = []
let tunnelCleanup: Void = { atexit { tunnelPIDs.forEach { kill($0, SIGTERM) } } }()

/// Keeps one `ssh -N -L` per remote device alive and returns the local port.
actor Tunnels {
    static let shared = Tunnels()
    private var open: [String: (Process, Int)] = [:]

    func port(for d: Device) async throws -> Int {
        guard let host = d.ssh else {
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".t3/userdata/server-runtime.json")
            return try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: url)).port
        }
        _ = tunnelCleanup
        if let (p, port) = open[d.id], p.isRunning { return port }
        let remote = try JSONDecoder().decode(Runtime.self, from: Data(shell("ssh -o ConnectTimeout=5 -o BatchMode=yes \(host) cat .t3/userdata/server-runtime.json").utf8)).port
        let local = 37_700 + (devices.firstIndex { $0.id == d.id } ?? 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-L", "\(local):127.0.0.1:\(remote)", host]
        try p.run()
        open[d.id] = (p, local)
        tunnelPIDs.append(p.processIdentifier)
        try await Task.sleep(for: .seconds(2))
        return local
    }

    private struct Runtime: Decodable { let port: Int }
    private func shell(_ cmd: String) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", cmd]
        let out = Pipe(); p.standardOutput = out; try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct T3Client {
    let device: Device
    init(_ d: Device) { device = d }

    /// Opens an authenticated /ws socket: bearer token → one-time wsTicket.
    private func connect() async throws -> URLSessionWebSocketTask {
        let port = try await Tunnels.shared.port(for: device)
        let token = try String(contentsOf: configDir.appending(path: "\(device.id).token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/auth/websocket-ticket")!)
        req.httpMethod = "POST"; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ticket = try JSONDecoder().decode([String: String].self, from: try await URLSession.shared.data(for: req).0)["ticket"] ?? ""
        var c = URLComponents(string: "ws://127.0.0.1:\(port)/ws")!
        c.queryItems = [.init(name: "orchestrationProtocol", value: "2"), .init(name: "wsTicket", value: ticket)]
        let ws = URLSession.shared.webSocketTask(with: c.url!)
        ws.maximumMessageSize = 64 << 20
        ws.resume()
        return ws
    }

    private func send(_ ws: URLSessionWebSocketTask, _ tag: String, _ payload: [String: Any]) async throws {
        let msg: [String: Any] = ["_tag": "Request", "id": "1", "tag": tag, "payload": payload, "headers": []]
        try await ws.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)))
    }

    private func next(_ ws: URLSessionWebSocketTask) async throws -> [String: Any] {
        guard case .string(let text) = try await ws.receive() else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// `subscribeServerConfig` snapshot (+ usage-limit sources), then disconnects.
    /// Closing the socket is the only way to unblock a pending `receive()`, so deadlines cancel it.
    func serverConfig() async throws -> Snapshot {
        let ws = try await connect(); defer { ws.cancel() }
        try await send(ws, "subscribeServerConfig", ["usageLimitSources": true])
        Task { try await Task.sleep(for: .seconds(15)); ws.cancel() }
        var providers: Any?, sources: Any = [Any]()
        while let m = try? await next(ws) {
            if m["_tag"] as? String == "Ping" { try? await ws.send(.string(#"{"_tag":"Pong"}"#)) }
            for v in m["values"] as? [[String: Any]] ?? [] {
                if v["type"] as? String == "snapshot" {
                    providers = (v["config"] as? [String: Any])?["providers"]
                    Task { try await Task.sleep(for: .seconds(2.5)); ws.cancel() }  // give sources a moment to arrive
                }
                if v["type"] as? String == "usageLimitSourcesUpdated" { sources = (v["payload"] as? [String: Any])?["sources"] ?? [] }
            }
            if providers != nil, (sources as? [Any])?.isEmpty == false { break }
        }
        guard let providers else { throw URLError(.timedOut) }
        return try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: ["providers": providers, "sources": sources]))
    }

    /// `server.getUsageSummary` buckets for a day range.
    func usage(since: String, until: String) async throws -> UsageResult {
        let ws = try await connect(); defer { ws.cancel() }
        try await send(ws, "server.getUsageSummary", ["sinceDay": since, "untilDay": until, "timeZone": TimeZone.current.identifier])
        Task { try await Task.sleep(for: .seconds(60)); ws.cancel() }
        while true {
            let m = try await next(ws)
            guard m["_tag"] as? String == "Exit", let exit = m["exit"] as? [String: Any], let value = exit["value"] else { continue }
            return try decoder.decode(UsageResult.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }
}

// MARK: - Store

@MainActor final class Store: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var errors: [String] = []
    @Published var updated: Date?
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }

    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .limits {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab"); if tab != .limits { loadUsage() } }
    }
    @Published var range: Range = .month { didSet { usage = nil; loadUsage() } }
    @Published var usage: [Bucket]?
    @Published var usageLoading = false

    /// Sums buckets from every device for the selected range (each device scans its own agent logs).
    func loadUsage() {
        guard !usageLoading || usage == nil else { return }
        usageLoading = true
        let range = range
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let until = f.string(from: .now), since = f.string(from: Calendar.current.date(byAdding: .day, value: -(range.rawValue - 1) - (range == .day ? 1 : 0), to: .now)!)
        Task {
            let all = await withTaskGroup(of: [Bucket].self) { group in
                for d in devices { group.addTask { (try? await T3Client(d).usage(since: since, until: until))?.buckets ?? [] } }
                return await group.reduce(into: []) { $0 += $1 }
            }
            guard range == self.range else { return }
            usage = all; usageLoading = false
        }
    }

    func toggle(_ id: String) { if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) } }

    func refresh() {
        Task {
            let results = await withTaskGroup(of: (String, Snapshot?).self) { group in
                for d in devices { group.addTask { (d.name, await Self.fetch(d)) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            apply(results)
        }
    }

    nonisolated static func fetch(_ d: Device) async -> Snapshot? { try? await T3Client(d).serverConfig() }

    private func apply(_ results: [(String, Snapshot?)]) {
        // The same account can be signed in on several devices: keep the freshest reading per (driver, name).
        var accounts: [String: (driver: String, account: Account)] = [:]
        func add(_ driver: String, _ name: String, _ limits: Limits) {
            // Drop per-model windows like "Weekly · Fable".
            let windows = limits.windows.filter { !$0.label.contains("·") }
            guard !windows.isEmpty else { return }
            let key = "\(driver)/\(name)"
            if let old = accounts[key], old.account.limits.checkedAt >= limits.checkedAt { return }
            accounts[key] = (driver, Account(id: key, name: name, limits: Limits(checkedAt: limits.checkedAt, windows: windows, resetCredits: limits.resetCredits)))
        }
        for (_, snap) in results {
            for p in snap?.providers ?? [] { if let l = p.usageLimits { add(p.driver, p.displayName ?? p.instanceId, l) } }
            for s in snap?.sources ?? [] { for a in s.accounts { add(a.driver, a.email ?? a.id, a.usageLimits) } }
        }
        var byDriver: [String: Agent] = [:]
        for (driver, acc) in accounts.values.sorted(by: { $0.account.name < $1.account.name }) {
            let b = brands[driver] ?? (driver.capitalized, "", T3.muted)
            byDriver[driver, default: Agent(id: driver, name: b.name, icon: b.icon, tint: b.tint, accounts: [])].accounts.append(acc)
        }
        let order = ["codex", "claudeAgent", "grok"]
        agents = byDriver.values.sorted { (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name) }
        errors = results.filter { $0.1 == nil }.map { "Can't reach T3 Code on \($0.0)" }
        updated = .now
    }
}

// MARK: - Popover UI

func countdown(_ d: Date?) -> String? {
    guard let d else { return nil }
    let m = max(0, Int(d.timeIntervalSinceNow / 60))
    return m >= 1440 ? "\(m / 1440)d \(m % 1440 / 60)h" : m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

struct Chip: LabelStyle {
    func makeBody(configuration c: Configuration) -> some View {
        HStack(spacing: 3) { c.icon.imageScale(.small); c.title }
            .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct Bar: View {
    let name: String; let window: Window; let credits: Int?; let tint: Color
    var left: Double { 100 - window.usedPercent }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12))
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.55)).frame(width: g.size.width * left / 100)
                HStack(spacing: 6) {
                    Text("\(name)  \(Int(left.rounded()))%").fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if let c = countdown(window.resetsAt) { Label(c, systemImage: "arrow.clockwise").labelStyle(Chip()) }
                    if let credits { Label("\(credits)", systemImage: "ticket").labelStyle(Chip()) }
                }.font(.system(size: 11)).foregroundStyle(T3.foreground).padding(.horizontal, 8)
            }
        }.frame(height: 24)
    }
}

struct AgentSection: View {
    let agent: Agent; let hidden: Bool; let toggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: toggle) { Image(systemName: hidden ? "eye.slash" : "eye").frame(width: 16) }
                    .buttonStyle(.plain).foregroundStyle(T3.muted).help(hidden ? "Show in menubar" : "Hide from menubar")
                Image(nsImage: icon(agent.icon, size: 14)).foregroundStyle(agent.tint)
                Text(agent.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(T3.foreground)
            }
            if !hidden {
                ForEach(agent.rows, id: \.self) { row in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row).font(.system(size: 12, weight: .medium)).foregroundStyle(T3.foreground)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(agent.left(row))%").font(.system(size: 22, weight: .medium))
                                Text("left").font(.system(size: 11)).foregroundStyle(T3.muted)
                            }.foregroundStyle(T3.foreground)
                        }.frame(width: 84, alignment: .leading)
                        VStack(spacing: 4) {
                            ForEach(agent.bars(row), id: \.0.id) { acc, w in
                                Bar(name: acc.name, window: w, credits: acc.limits.resetCredits?.availableCount, tint: agent.tint)
                            }
                        }
                    }
                    .padding(12)
                    .background(T3.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(T3.border))
                }
            }
        }.opacity(hidden ? 0.6 : 1)
    }
}

struct Popover: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Segmented(options: Tab.allCases, label: \.rawValue, selection: $store.tab)
                Spacer()
                if store.tab != .limits { Segmented(options: Range.allCases, label: \.label, selection: $store.range) }
            }
            Scroll {
                VStack(alignment: .leading, spacing: 16) {
                    if store.tab == .limits {
                        ForEach(store.errors, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(T3.muted) }
                        ForEach(store.agents) { a in AgentSection(agent: a, hidden: store.hidden.contains(a.id)) { store.toggle(a.id) } }
                    } else if let usage = store.usage {
                        UsageView(buckets: usage, tab: store.tab)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
            }
            HStack(spacing: 8) {
                if let u = store.updated { Text("Updated \(u.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(T3.muted) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(T3Button())
                Button("Refresh") { store.refresh(); if store.tab != .limits { store.usage = nil; store.loadUsage() } }.buttonStyle(T3Button())
            }
        }
        .padding(16).frame(width: 520).background(T3.background).environment(\.colorScheme, .dark)
    }
}

/// Scrolls past 620pt; plain stack in `--snapshot` mode since ImageRenderer can't draw ScrollView content.
var snapshotMode = false
var snapshotHoverDay: Date?
struct Scroll<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        if snapshotMode { content } else { ScrollView { content }.scrollIndicators(.never).frame(maxHeight: 620).fixedSize(horizontal: false, vertical: true) }
    }
}

/// T3's pill tab group (Cost | Tokens | Limits, Past 24h | 7 days …).
struct Segmented<T: Hashable>: View {
    let options: [T]; let label: (T) -> String; @Binding var selection: T
    init(options: [T], label: KeyPath<T, String>, selection: Binding<T>) { self.options = options; self.label = { $0[keyPath: label] }; _selection = selection }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Text(label(o)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(o == selection ? T3.foreground : T3.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(o == selection ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle()).onTapGesture { selection = o }
            }
        }.padding(2).background(T3.secondary, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(T3.border))
    }
}

let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

struct UsageView: View {
    let buckets: [Bucket]; let tab: Tab
    @State private var hoverDay: Date? = snapshotHoverDay
    func fmt(_ v: Double) -> String { tab == .cost ? money(v) : compact(v) }
    func sum(_ b: [Bucket], _ f: (Bucket) -> Double) -> Double { b.reduce(0) { $0 + f($1) } }

    var body: some View {
        let total = sum(buckets) { $0.value(tab) }
        let providers = Dictionary(grouping: buckets, by: \.provider).sorted { sum($0.value) { $0.value(tab) } > sum($1.value) { $0.value(tab) } }
        let models = Dictionary(grouping: buckets.filter { !$0.model.hasPrefix("<") }, by: \.model)
            .map { (model: $0.key, provider: $0.value[0].provider, cost: sum($0.value, \.costUsd), tokens: sum($0.value, \.tokens)) }
            .sorted { tab == .cost ? $0.cost > $1.cost : $0.tokens > $1.tokens }
        let daily = Dictionary(grouping: buckets) { "\($0.provider)|\($0.day)" }
            .map { (id: $0.key, provider: $0.value[0].provider, day: dayFormat.date(from: $0.value[0].day) ?? .now, value: sum($0.value) { $0.value(tab) }) }
            .sorted { $0.day < $1.day }

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fmt(total)).font(.system(size: 30, weight: .semibold)).foregroundStyle(T3.foreground)
                Text("\(sum(buckets) { Double($0.sessions) }.formatted()) sessions\(tab == .cost ? " · API estimate" : "")").font(.system(size: 11)).foregroundStyle(T3.muted)
            }

            VStack(spacing: 10) {
                ForEach(providers, id: \.key) { p, b in
                    let brand = usageBrand(p), v = sum(b) { $0.value(tab) }
                    HStack(alignment: .firstTextBaseline) {
                        Circle().fill(brand.tint).frame(width: 6, height: 6)
                        if !brand.icon.isEmpty { Image(nsImage: icon(brand.icon, size: 12)).foregroundStyle(brand.tint) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(brand.name).font(.system(size: 12, weight: .medium)).foregroundStyle(T3.foreground)
                            Text("\(total > 0 ? String(format: "%.1f", v / total * 100) : "0")% of \(tab == .cost ? "cost" : "tokens") · \(tab == .cost ? compact(sum(b, \.tokens)) + " tokens" : money(sum(b, \.costUsd)))")
                                .font(.system(size: 10)).foregroundStyle(T3.muted)
                        }
                        Spacer()
                        Text(fmt(v)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(T3.foreground)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(tab == .cost ? "Daily cost" : "Daily processed tokens").font(.system(size: 12, weight: .medium)).foregroundStyle(T3.foreground)
                Chart(daily, id: \.id) {
                    AreaMark(x: .value("Day", $0.day, unit: .day), y: .value("Value", $0.value), stacking: .unstacked)
                        .foregroundStyle(by: .value("Provider", usageBrand($0.provider).name)).opacity(0.15).interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", $0.day, unit: .day), y: .value("Value", $0.value))
                        .foregroundStyle(by: .value("Provider", usageBrand($0.provider).name)).interpolationMethod(.catmullRom)
                    if let hoverDay, Calendar.current.isDate($0.day, inSameDayAs: hoverDay) {
                        PointMark(x: .value("Day", $0.day, unit: .day), y: .value("Value", $0.value))
                            .foregroundStyle(by: .value("Provider", usageBrand($0.provider).name)).symbolSize(30)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            guard case .active(let pt) = phase, let plot = proxy.plotFrame,
                                  let d: Date = proxy.value(atX: pt.x - geo[plot].origin.x) else { hoverDay = nil; return }
                            hoverDay = Calendar.current.startOfDay(for: d.addingTimeInterval(43_200))
                        }
                        if let hoverDay, let plot = proxy.plotFrame, let x = proxy.position(forX: hoverDay) {
                            let rows = daily.filter { Calendar.current.isDate($0.day, inSameDayAs: hoverDay) }.sorted { $0.value > $1.value }
                            let px = geo[plot].origin.x + x
                            Rectangle().fill(T3.muted.opacity(0.5)).frame(width: 1, height: geo[plot].height).position(x: px, y: geo[plot].midY)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hoverDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).foregroundStyle(T3.muted)
                                ForEach(rows, id: \.provider) { r in
                                    HStack(spacing: 6) {
                                        Circle().fill(usageBrand(r.provider).tint).frame(width: 6, height: 6)
                                        Text(usageBrand(r.provider).name); Spacer(minLength: 12); Text(fmt(r.value)).monospacedDigit()
                                    }.foregroundStyle(T3.foreground)
                                }
                                if rows.count > 1 { HStack { Text("Total"); Spacer(); Text(fmt(rows.reduce(0) { $0 + $1.value })).monospacedDigit() }.foregroundStyle(T3.foreground).fontWeight(.medium) }
                            }
                            .font(.system(size: 10)).padding(8).frame(width: 170)
                            .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(T3.border))
                            .position(x: px > geo.size.width / 2 ? px - 95 : px + 95, y: geo[plot].minY + 50)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: providers.map { usageBrand($0.key).name }, range: providers.map { usageBrand($0.key).tint })
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 9)) } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in AxisGridLine().foregroundStyle(T3.border); AxisValueLabel { Text(fmt(v.as(Double.self) ?? 0)).font(.system(size: 9)).foregroundStyle(T3.muted) } } }
                .frame(height: 140)
            }

            HStack(alignment: .top) {
                stat("Processed", compact(sum(buckets, \.tokens)))
                stat("Cached input", compact(sum(buckets) { $0.totals.cachedInputTokens }))
                stat("Uncached input", compact(sum(buckets) { $0.totals.uncachedInputTokens }))
                stat("Output", compact(sum(buckets) { $0.totals.outputTokens }))
                stat("Cache savings", money(sum(buckets) { $0.cacheSavingsUsd ?? 0 }))
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("Model"); Spacer(); Text("Cost").frame(width: 80, alignment: .trailing); Text("Share").frame(width: 50, alignment: .trailing); Text("Tokens").frame(width: 56, alignment: .trailing) }
                    .font(.system(size: 10)).foregroundStyle(T3.muted).padding(.bottom, 6)
                ForEach(Array(models.prefix(10).enumerated()), id: \.offset) { i, m in
                    let brand = usageBrand(m.provider), share = total > 0 ? (tab == .cost ? m.cost : m.tokens) / total : 0
                    Divider().overlay(T3.border)
                    HStack {
                        Text("\(i + 1)").foregroundStyle(T3.muted).frame(width: 14, alignment: .leading)
                        if !brand.icon.isEmpty { Image(nsImage: icon(brand.icon, size: 11)).foregroundStyle(brand.tint) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.model).foregroundStyle(T3.foreground).lineLimit(1)
                            Capsule().fill(brand.tint).frame(width: max(8, 140 * share), height: 2)
                        }
                        Spacer()
                        Text(money(m.cost)).frame(width: 80, alignment: .trailing).foregroundStyle(T3.foreground)
                        Text(String(format: "%.1f%%", share * 100)).frame(width: 50, alignment: .trailing).foregroundStyle(T3.muted)
                        Text(compact(m.tokens)).frame(width: 56, alignment: .trailing).foregroundStyle(T3.muted)
                    }.font(.system(size: 11)).monospacedDigit().padding(.vertical, 7)
                }
            }
        }
    }

    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(T3.muted)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(T3.foreground)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct T3Button: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.system(size: 12, weight: .medium)).foregroundStyle(T3.foreground)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(T3.secondary.opacity(c.isPressed ? 2 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T3.border))
    }
}

// MARK: - Menubar

/// Icons + percentages rendered into one template image (MenuBarExtra labels only take one image/text).
func menubarImage(_ agents: [Agent]) -> NSImage {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
    let parts: [(NSImage, String)] = agents.compactMap { a in a.headline.map { (icon(a.icon, size: 14), "\($0)%") } }
    if parts.isEmpty { return icon("claude", size: 14) }
    let width = parts.reduce(0) { $0 + 18 + ($1.1 as NSString).size(withAttributes: attrs).width + 8 } - 8
    let img = NSImage(size: NSSize(width: ceil(width), height: 16), flipped: false) { _ in
        var x: CGFloat = 0
        for (ic, text) in parts {
            ic.draw(in: NSRect(x: x, y: 1, width: 14, height: 14)); x += 18
            (text as NSString).draw(at: NSPoint(x: x, y: 1), withAttributes: attrs)
            x += (text as NSString).size(withAttributes: attrs).width + 8
        }
        return true
    }
    img.isTemplate = true
    return img
}

@main struct T3codeBar: App {
    @StateObject private var store = Store()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {
        // `--snapshot <dir>` writes popover.png + menubar.png and exits (for screenshots).
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot") else { return }
        snapshotMode = true
        let dir = CommandLine.arguments[i + 1], store = Store()
        if CommandLine.arguments.count > i + 2, let t = Tab(rawValue: CommandLine.arguments[i + 2]) { store.tab = t }
        if CommandLine.arguments.count > i + 3 { snapshotHoverDay = dayFormat.date(from: CommandLine.arguments[i + 3]) }
        store.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            let r = ImageRenderer(content: Popover(store: store)); r.scale = 2
            try? NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/popover.png"))
            let m = menubarImage(store.agents.filter { !store.hidden.contains($0.id) })
            try? NSBitmapImageRep(data: m.tiffRepresentation!)!.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/menubar.png"))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Popover(store: store)
        } label: {
            Image(nsImage: menubarImage(store.agents.filter { !store.hidden.contains($0.id) }))
                .onAppear { store.refresh() }.onReceive(timer) { _ in store.refresh() }
        }.menuBarExtraStyle(.window)
    }
}
