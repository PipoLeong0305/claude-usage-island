import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI

let defaults = UserDefaults.standard
let commandCodeAuth = NSString(string: "~/.commandcode/auth.json").expandingTildeInPath
let codexAuth = NSString(string: "~/.codex/auth.json").expandingTildeInPath

// Settings: claudeDirs = Claude Code config dirs, one per line; commandCode / allScreens toggles.
func registerDefaults() {
    defaults.register(defaults: [
        "claudeDirs": "~/.claude",
        "commandCode": FileManager.default.fileExists(atPath: commandCodeAuth),
        "codex": FileManager.default.fileExists(atPath: codexAuth),
        "allScreens": true,
    ])
}

typealias Account = (name: String, fetch: () async throws -> Usage)

// Cards shown in the island, left to right.
func accounts() -> [Account] {
    let dirs = (defaults.string(forKey: "claudeDirs") ?? "").split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    var list: [Account] = dirs.map { dir in
        ((dir as NSString).lastPathComponent.trimmingCharacters(in: ["."]), {
            guard FileManager.default.fileExists(atPath: NSString(string: dir).expandingTildeInPath) else { throw Err(description: "目录不存在：\(dir)") }
            return try await fetchUsage(dir)
        })
    }
    if defaults.bool(forKey: "commandCode") { list.append(("command code", fetchCommandCode)) }
    if defaults.bool(forKey: "codex") { list.append(("codex", fetchCodex)) }
    return list
}

// ~/.claude uses the plain keychain item; other config dirs add a sha256(path) prefix.
func keychainService(_ dir: String) -> String {
    let path = NSString(string: dir).expandingTildeInPath
    if path == NSString(string: "~/.claude").expandingTildeInPath { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-" + hash.prefix(8)
}

struct Limit: Codable { let utilization: Double; let resets_at: String? }
struct Usage: Codable { let five_hour: Limit; let seven_day: Limit }
struct Err: Error, CustomStringConvertible { let description: String }

// Only the claude CLI renews the keychain token (~8h life), and an expired token gets a 429 rather than a 401,
// so check expiresAt first instead of misreporting it as rate limiting.
func token(_ dir: String) throws -> String {
    let service = keychainService(dir)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    struct Creds: Decodable { struct O: Decodable { let accessToken: String; let expiresAt: Double? }; let claudeAiOauth: O }
    guard let c = try? JSONDecoder().decode(Creds.self, from: data) else { throw Err(description: "Keychain 里找不到 Claude Code 登录信息") }
    if let exp = c.claudeAiOauth.expiresAt, exp / 1000 < Date().timeIntervalSince1970 {
        let cmd = service == "Claude Code-credentials" ? "claude" : "CLAUDE_CONFIG_DIR=\(dir) claude"
        throw Err(description: "token 过期，运行一次 \(cmd)")
    }
    return c.claudeAiOauth.accessToken
}

func fetchUsage(_ dir: String) async throws -> Usage {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(try token(dir))", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw Err(description: "token 过期，打开一次 Claude Code") }
    if code == 429 { throw Err(description: "请求太频繁，稍后自动重试") }
    guard code == 200 else { throw Err(description: "HTTP \(code)") }
    return try JSONDecoder().decode(Usage.self, from: data)
}

// Command Code limits are dollar amounts (used/cap); converted to % so they render like Claude's.
func fetchCommandCode() async throws -> Usage {
    struct Auth: Decodable { let apiKey: String }
    struct W: Decodable { let used: Double; let cap: Double; let resetAt: Double }
    struct R: Decodable { struct L: Decodable { let fiveHour: W; let weekly: W }; let windowLimits: L }
    guard let data = FileManager.default.contents(atPath: commandCodeAuth),
          let auth = try? JSONDecoder().decode(Auth.self, from: data)
    else { throw Err(description: "未登录，运行 commandcode login") }
    var req = URLRequest(url: URL(string: "https://api.commandcode.ai/alpha/billing/credits")!)
    req.setValue("Bearer \(auth.apiKey)", forHTTPHeaderField: "Authorization")
    let (body, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw Err(description: "登录过期，运行 commandcode login") }
    guard code == 200 else { throw Err(description: "HTTP \(code)") }
    let l = try JSONDecoder().decode(R.self, from: body).windowLimits
    func limit(_ w: W) -> Limit {
        Limit(utilization: w.cap > 0 ? w.used / w.cap * 100 : 0,
              resets_at: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: w.resetAt / 1000)))
    }
    return Usage(five_hour: limit(l.fiveHour), seven_day: limit(l.weekly))
}

// Codex (ChatGPT login): the CLI keeps the access token fresh, so a 401 means it needs a run.
func fetchCodex() async throws -> Usage {
    struct Auth: Decodable { struct T: Decodable { let access_token: String; let account_id: String? }; let tokens: T }
    struct W: Decodable { let used_percent: Double; let reset_at: Double }
    struct R: Decodable { struct L: Decodable { let primary_window: W; let secondary_window: W }; let rate_limit: L }
    guard let data = FileManager.default.contents(atPath: codexAuth),
          let auth = try? JSONDecoder().decode(Auth.self, from: data)
    else { throw Err(description: "未登录，运行 codex login") }
    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    req.setValue("Bearer \(auth.tokens.access_token)", forHTTPHeaderField: "Authorization")
    if let id = auth.tokens.account_id { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
    let (body, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw Err(description: "token 过期，运行一次 codex") }
    guard code == 200 else { throw Err(description: "HTTP \(code)") }
    let l = try JSONDecoder().decode(R.self, from: body).rate_limit
    func limit(_ w: W) -> Limit {
        Limit(utilization: w.used_percent, resets_at: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: w.reset_at)))
    }
    return Usage(five_hour: limit(l.primary_window), seven_day: limit(l.secondary_window))
}

// "2026-09-27T21:49:59.542997+00:00" → "2h13m"; ISO8601DateFormatter chokes on 6-digit fractions, so drop them.
func resetText(_ s: String?) -> String {
    guard let s, let d = ISO8601DateFormatter().date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    else { return "" }
    let t = max(0, Int(d.timeIntervalSinceNow))
    let (days, h, m) = (t / 86400, t % 86400 / 3600, t % 3600 / 60)
    return days > 0 ? "\(days)d \(h)h" : "\(h)h \(m)m"
}

@MainActor final class Model: ObservableObject {
    // last good result per account survives restarts, so a 429 on launch doesn't leave a card empty
    @Published var usage: [String: Usage] = (defaults.data(forKey: "cache").flatMap { try? JSONDecoder().decode([String: Usage].self, from: $0) }) ?? [:]
    @Published var error: [String: String] = [:]
    @Published var names: [String] = accounts().map(\.name)
    @Published var expanded: Int? // index of the screen whose island is open
    @Published var loading = false
    private var last = Date.distantPast

    func refresh(force: Bool = false) async {
        guard !loading, force || Date().timeIntervalSince(last) > 60 else { return }
        last = Date()
        loading = true
        defer { loading = false }
        let list = accounts()
        names = list.map(\.name)
        // all accounts in parallel; plain Tasks because withTaskGroup segfaults under -O with Swift 6.4
        let tasks = list.map { a in (a.name, Task { try await a.fetch() }) }
        for (name, t) in tasks {
            switch await t.result {
            case .success(let u): usage[name] = u; error[name] = nil
            case .failure(let e): error[name] = "\(e)"
            }
        }
        defaults.set(try? JSONEncoder().encode(usage), forKey: "cache")
    }
}

let cardWidth: CGFloat = 200

struct IslandView: View {
    @ObservedObject var m: Model
    let notch: CGSize
    let index: Int
    var open: Bool { m.expanded == index }

    var body: some View {
        VStack(spacing: 0) {
            if open {
                HStack {
                    Spacer()
                    Button { Task { await m.refresh(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                            .rotationEffect(.degrees(m.loading ? 360 : 0))
                            .animation(m.loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: m.loading)
                    }
                    .buttonStyle(.plain)
                    .disabled(m.loading)
                    Button { (NSApp.delegate as? Delegate)?.openSettings() } label: {
                        Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: notch.height + 4)
                HStack(spacing: 10) {
                    ForEach(m.names, id: \.self) { card($0) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .foregroundStyle(.white)
        .padding([.horizontal, .bottom], open ? 12 : 0)
        .frame(width: open ? nil : notch.width, height: open ? nil : notch.height, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: open ? 28 : 10, bottomTrailingRadius: open ? 28 : 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: open)
        .environment(\.colorScheme, .dark)
    }

    func card(_ dir: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let peak = m.usage[dir].map { max($0.five_hour.utilization, $0.seven_day.utilization) }
            HStack(spacing: 6) {
                logo(dir).frame(width: 14, height: 14)
                Text(dir).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if let peak {
                    Text("\(Int(peak))%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(m.error[dir] == nil ? level(peak) : .orange)
                }
            }
            if let u = m.usage[dir] {
                HStack(spacing: 0) {
                    gauge("5 小时", u.five_hour).frame(maxWidth: .infinity)
                    gauge("每周", u.seven_day).frame(maxWidth: .infinity)
                }
            } else {
                Text(m.error[dir] ?? "加载中…").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92)
            }
            if let e = m.error[dir], m.usage[dir] != nil {
                Text(e).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: cardWidth)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // Logos are drawn (no image assets in a single-file build): Claude's spark, OpenAI's blossom, an SF Symbol for Command Code.
    @ViewBuilder func logo(_ name: String) -> some View {
        if name.hasPrefix("command") {
            Image(systemName: "command").resizable().scaledToFit().foregroundStyle(.white)
        } else if name == "codex" {
            // OpenAI-style blossom: six interlocking loops
            ZStack {
                ForEach(0..<6) { i in
                    Capsule().stroke(.white, lineWidth: 1.3).frame(width: 5, height: 9).offset(y: -3.2).rotationEffect(.degrees(Double(i) * 60))
                }
            }
        } else {
            ZStack {
                ForEach(0..<8) { i in
                    Capsule().fill(Color.claude).frame(width: 2.4, height: 6.5).offset(y: -3.5).rotationEffect(.degrees(Double(i) * 45))
                }
            }
        }
    }

    func gauge(_ title: String, _ l: Limit) -> some View {
        let v = min(l.utilization, 100) / 100
        let color = level(l.utilization)
        return VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 5)
                Circle().trim(from: 0, to: v)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(l.utilization))%").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 54, height: 54)
            Text(title).font(.system(size: 11, weight: .medium))
            Label(resetText(l.resets_at), systemImage: "arrow.clockwise")
                .font(.system(size: 9)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
    }
}

extension Color { static let claude = Color(red: 0.85, green: 0.47, blue: 0.34) } // #D97757

// green < 50, yellow < 80, orange < 95, red above
func level(_ pct: Double) -> Color {
    pct < 50 ? .green : pct < 80 ? .yellow : pct < 95 ? .orange : .red
}

// not @State: it's a macro in this SDK, and plain swiftc (no Xcode) lacks the macro plugin
final class LoginItem: ObservableObject { @Published var status = SMAppService.mainApp.status }

struct SettingsView: View {
    @AppStorage("claudeDirs") var claudeDirs = "~/.claude"
    @AppStorage("commandCode") var commandCode = false
    @AppStorage("codex") var codex = false
    @AppStorage("allScreens") var allScreens = true
    @StateObject var login = LoginItem()

    var body: some View {
        Form {
            Section {
                TextEditor(text: $claudeDirs).font(.system(.body, design: .monospaced)).frame(height: 64)
            } header: {
                Text("Claude Code 配置目录（每行一个）")
            } footer: {
                Text("默认 ~/.claude；用 CLAUDE_CONFIG_DIR 登录的其他账号填对应目录").foregroundStyle(.secondary)
            }
            Toggle("显示 Command Code", isOn: $commandCode)
            Toggle("显示 Codex", isOn: $codex)
            Toggle("在所有显示器上显示", isOn: $allScreens)
            Toggle("开机自启", isOn: Binding(get: { login.status == .enabled }, set: { on in
                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                login.status = SMAppService.mainApp.status
            }))
            if login.status == .requiresApproval { Text("请到 系统设置 › 通用 › 登录项 中允许").foregroundStyle(.orange) }
            HStack {
                Text("关闭窗口后生效").foregroundStyle(.secondary)
                Spacer()
                Button("退出 Claude Usage Island") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 410) // grouped Form scrolls, so it has no intrinsic height
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let m = Model()
    var slots: [(panel: NSPanel, trigger: CGRect)] = []
    var settings: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildPanels()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.buildPanels() }
        }
        // ponytail: 10Hz mouse polling, no permissions needed; switch to a tracking area if CPU ever shows up
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { self.trackMouse() }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [m] _ in
            MainActor.assumeIsolated { _ = Task { await m.refresh(force: true) } }
        }
        Task { await m.refresh(force: true) }
    }

    // Double-clicking the app again opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    // One island per screen (or just the notch screen), rebuilt when screens or settings change.
    func buildPanels() {
        slots.forEach { $0.panel.close() }
        m.expanded = nil
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let screens = defaults.bool(forKey: "allScreens") ? NSScreen.screens : [notched]
        let size = CGSize(width: (cardWidth + 10) * CGFloat(max(accounts().count, 1)) + 40, height: 220)
        slots = screens.enumerated().map { i, s in
            let f = s.frame
            // no notch: a pill the height of the menu bar in its center
            var notch = CGSize(width: 200, height: max(f.maxY - s.visibleFrame.maxY, 24))
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 {
                notch = CGSize(width: f.width - l.width - r.width, height: s.safeAreaInsets.top)
            }
            let panel = NSPanel(contentRect: CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true // clicks pass through until the island is open
            panel.contentView = NSHostingView(rootView: IslandView(m: m, notch: notch, index: i))
            panel.orderFrontRegardless()
            return (panel, CGRect(x: f.midX - notch.width / 2, y: f.maxY - notch.height, width: notch.width, height: notch.height + 2))
        }
    }

    func trackMouse() {
        let p = NSEvent.mouseLocation
        let hit = slots.indices.first { (m.expanded == $0 ? slots[$0].panel.frame : slots[$0].trigger).contains(p) }
        guard hit != m.expanded else { return }
        if let e = m.expanded { slots[e].panel.ignoresMouseEvents = true }
        m.expanded = hit
        if let hit {
            slots[hit].panel.ignoresMouseEvents = false // so the gear button is clickable
            Task { await m.refresh() }
        }
    }

    func openSettings() {
        if settings == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Claude Usage Island"
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.buildPanels()
                    Task { await self.m.refresh(force: true) }
                }
            }
            settings = w
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
        settings?.orderFrontRegardless() // activate() is cooperative since macOS 14 and may leave it behind
    }
}

@main @MainActor enum Island {
    static let delegate = Delegate()
    static func main() {
        registerDefaults()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
