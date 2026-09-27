# claude-usage-island

把 MacBook 刘海变成灵动岛：鼠标移到刘海上，向下展开显示 Claude Code 的 **5 小时用量** 和 **每周用量**（支持多账号，也支持 [Command Code](https://commandcode.ai) CLI）。

Hover the MacBook notch to see your Claude Code 5-hour and weekly usage limits. Single Swift file, no dependencies.

## 安装

需要 macOS 14+ 和 Swift 工具链（Xcode 或 Command Line Tools）。

```sh
./build.sh                                   # 生成 build/Claude Usage Island.app（universal，ad-hoc 签名）
cp -R "build/Claude Usage Island.app" /Applications/
open "/Applications/Claude Usage Island.app"
```

## 设置

鼠标移到刘海展开后点右上角齿轮，或再次打开 app，即可打开设置：

- **Claude Code 配置目录**：每行一个，默认 `~/.claude`；用 `CLAUDE_CONFIG_DIR` 登录的其他账号填对应目录
- **显示 Command Code**：检测到 `~/.commandcode/auth.json` 时默认开启
- **在所有显示器上显示**：每块屏幕一个灵动岛；没有刘海的屏幕在菜单栏正中放一个黑色胶囊作为触发区
- **开机自启**：通过 `SMAppService` 注册为登录项
- **退出**

设置在关闭窗口后生效。

## 数据来源

- **Claude Code**：从钥匙串读取 Claude Code 的 OAuth token（`Claude Code-credentials`，自定义 `CLAUDE_CONFIG_DIR` 的账号是 `Claude Code-credentials-<sha256(路径)前 8 位>`），请求 `https://api.anthropic.com/api/oauth/usage`。
- **Command Code**：读取 `~/.commandcode/auth.json` 的 `apiKey`，请求 `https://api.commandcode.ai/alpha/billing/credits`，按 `used / cap` 换算成百分比。

刷新：启动时、每 5 分钟、每次展开时（最多 1 分钟一次）。每个账号最后一次成功的结果会缓存，遇到限流（429）时继续显示。token 只发给对应的官方接口，不存储、不上传到别处。

## 说明

- 用的是非公开接口，随时可能变化。
- Anthropic 的用量接口限流较严，请求太频繁会返回 429，稍后会自动恢复。

## License

MIT
