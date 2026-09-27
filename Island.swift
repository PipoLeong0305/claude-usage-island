import AppKit
import CryptoKit
import SwiftUI

// Cards shown in the island, left to right.
let accounts: [(name: String, fetch: () async throws -> Usage)] = [
    ("claude", { try await fetchUsage(keychainService("~/.claude")) }),
    ("claude2", { try await fetchUsage(keychainService("~/.claude2")) }),
    ("command code", fetchCommandCode),
]

// ~/.claude uses the plain keychain item; other config dirs add a sha256(path) prefix.

func keychainService(_ dir: String) -> String {
    let path = NSString(string: dir).expandingTildeInPath
    if dir == "~/.claude" { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-" + hash.prefix(8)
}

struct Limit: Decodable { let utilization: Double; let resets_at: String? }
struct Usage: Decodable { let five_hour: Limit; let seven_day: Limit }
struct Err: Error, CustomStringConvertible { let description: String }

func token(_ service: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    struct Creds: Decodable { struct O: Decodable { let accessToken: String }; let claudeAiOauth: O }
    guard let c = try? JSONDecoder().decode(Creds.self, from: data) else { throw Err(description: "Keychain 里找不到 Claude Code 登录信息") }
    return c.claudeAiOauth.accessToken
}

func fetchUsage(_ service: String) async throws -> Usage {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(try token(service))", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw Err(description: "token 过期，打开一次 Claude Code") }
    guard code == 200 else { throw Err(description: "HTTP \(code)") }
    return try JSONDecoder().decode(Usage.self, from: data)
}

// Command Code limits are dollar amounts (used/cap); converted to % so they render like Claude's.
func fetchCommandCode() async throws -> Usage {
    struct Auth: Decodable { let apiKey: String }
    struct W: Decodable { let used: Double; let cap: Double; let resetAt: Double }
    struct R: Decodable { struct L: Decodable { let fiveHour: W; let weekly: W }; let windowLimits: L }
    guard let data = FileManager.default.contents(atPath: NSString(string: "~/.commandcode/auth.json").expandingTildeInPath),
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

// "2026-09-27T21:49:59.542997+00:00" → "2h13m"; ISO8601DateFormatter chokes on 6-digit fractions, so drop them.
func resetText(_ s: String?) -> String {
    guard let s, let d = ISO8601DateFormatter().date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    else { return "" }
    let t = max(0, Int(d.timeIntervalSinceNow))
    let (days, h, m) = (t / 86400, t % 86400 / 3600, t % 3600 / 60)
    return days > 0 ? "\(days)d \(h)h" : "\(h)h \(m)m"
}

@MainActor final class Model: ObservableObject {
    @Published var usage: [String: Usage] = [:]
    @Published var error: [String: String] = [:]
    @Published var expanded = false
    private var last = Date.distantPast

    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(last) > 15 else { return }
        last = Date()
        for a in accounts {
            do { usage[a.name] = try await a.fetch(); error[a.name] = nil } catch { self.error[a.name] = "\(error)" }
        }
    }
}

let cardWidth: CGFloat = 200

struct IslandView: View {
    @ObservedObject var m: Model
    let notch: CGSize

    var body: some View {
        VStack(spacing: 0) {
            if m.expanded {
                Spacer().frame(height: notch.height + 4)
                HStack(spacing: 10) {
                    ForEach(accounts, id: \.name) { card($0.name) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .foregroundStyle(.white)
        .padding([.horizontal, .bottom], m.expanded ? 12 : 0)
        .frame(width: m.expanded ? nil : notch.width, height: m.expanded ? nil : notch.height, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: m.expanded ? 28 : 10, bottomTrailingRadius: m.expanded ? 28 : 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: m.expanded)
        .environment(\.colorScheme, .dark)
    }

    func card(_ dir: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(m.error[dir] == nil ? Color.claude : .orange).frame(width: 6, height: 6)
                Text(dir).font(.system(size: 12, weight: .semibold))
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
                Text(e).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: cardWidth)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func gauge(_ title: String, _ l: Limit) -> some View {
        let v = min(l.utilization, 100) / 100
        let color: Color = l.utilization > 95 ? .red : l.utilization > 80 ? .orange : .claude
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

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let m = Model()
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ n: Notification) {
        let s = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let f = s.frame
        var notch = CGSize(width: 200, height: 32) // no-notch fallback
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 {
            notch = CGSize(width: f.width - l.width - r.width, height: s.safeAreaInsets.top)
        }
        let size = CGSize(width: (cardWidth + 10) * CGFloat(accounts.count) + 40, height: 220)
        panel = NSPanel(contentRect: CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true // hover is detected by polling below, so clicks always pass through
        panel.contentView = NSHostingView(rootView: IslandView(m: m, notch: notch))
        panel.orderFrontRegardless()

        let notchRect = CGRect(x: f.midX - notch.width / 2, y: f.maxY - notch.height, width: notch.width, height: notch.height + 2)
        // ponytail: 10Hz mouse polling, no permissions needed; switch to a tracking area if CPU ever shows up
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [m, panel] _ in
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                let inside = m.expanded ? panel!.frame.contains(p) : notchRect.contains(p)
                if inside != m.expanded {
                    m.expanded = inside
                    if inside { Task { await m.refresh() } }
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [m] _ in
            MainActor.assumeIsolated { _ = Task { await m.refresh(force: true) } }
        }
        Task { await m.refresh(force: true) }
    }
}

@main @MainActor enum Island {
    static let delegate = Delegate()
    static func main() {
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
