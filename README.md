# claude-usage-island

把 MacBook 刘海变成灵动岛：鼠标移到刘海上，向下展开显示 Claude Code 的 **5 小时用量** 和 **每周用量**（支持多账号，也支持 [Command Code](https://commandcode.ai) CLI）。

Hover the MacBook notch to see your Claude Code 5-hour and weekly usage limits. Single Swift file, no dependencies.

## 运行

需要 macOS 14+ 和 Swift 工具链（Xcode 或 Command Line Tools）。

```sh
swiftc -parse-as-library -O Island.swift -o Island
./Island &
```

退出：`pkill -x Island`

## 数据来源

- **Claude Code**：从钥匙串读取 Claude Code 的 OAuth token（`Claude Code-credentials`，自定义 `CLAUDE_CONFIG_DIR` 的账号是 `Claude Code-credentials-<sha256(路径)前 8 位>`），请求 `https://api.anthropic.com/api/oauth/usage`。
- **Command Code**：读取 `~/.commandcode/auth.json` 的 `apiKey`，请求 `https://api.commandcode.ai/alpha/billing/credits`，按 `used / cap` 换算成百分比。

刷新：启动时、每 60 秒、每次展开时（最多 15 秒一次）。token 只发给对应的官方接口，不存储、不上传到别处。

## 配置账号

编辑 `Island.swift` 顶部的 `accounts` 列表，每项是一个名字加一个取数函数：

```swift
let accounts: [(name: String, fetch: () async throws -> Usage)] = [
    ("claude", { try await fetchUsage(keychainService("~/.claude")) }),
    ("claude2", { try await fetchUsage(keychainService("~/.claude2")) }),
    ("command code", fetchCommandCode),
]
```

改完重新编译即可。

## 说明

- 用的是非公开接口，随时可能变化。
- 没有刘海的屏幕会在菜单栏正中显示一个 200×32 的黑色胶囊作为触发区。

## License

MIT
