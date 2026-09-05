# Codex + Clash 代理启动与验证

本项目根目录中的两个脚本必须放在同一目录；可以把整个目录移动到任意位置，不需要修改脚本中的路径。

## 第一次运行

1. 确认 Clash 已启动，并开启 Windows 系统代理。
2. 如果你希望 Desktop 使用 AOI 共享 app-server，请先单独启动 `codex2larkAOI\shared-start.cmd`。
3. 在 Codex 中保存好正在进行的工作，然后从菜单完全退出 Codex。
4. 在任务管理器中确认没有 `ChatGPT.exe`。如果仍有进程，等待几秒；脚本不会替你结束进程。
5. 双击 `Start-Codex-Proxy.cmd`。
6. 启动器会读取系统代理、从 AppxManifest 定位 Store 版 Codex，并自动选择 app-server：
   - `http://127.0.0.1:45789/readyz` 可用：本次 Desktop 连接共享 app-server。
   - 45789 未就绪：本次 Desktop 使用自己的内置 app-server。

启动器本身不会启动 AOI shared stack，也不会寻找 AOI 仓库。

## 共享 / 内置自动选择

默认共享地址：

```text
ws://127.0.0.1:45789
```

共享已运行时，本次 Desktop 启动进程树会设置：

```text
CODEX_APP_SERVER_WS_URL=ws://127.0.0.1:45789
```

共享未运行时，启动器会从本次 Desktop 启动环境移除 `CODEX_APP_SERVER_WS_URL`，让 Desktop 回到内置 app-server。

启动器不会为这个选择写入用户级或系统级永久环境变量。

如果需要强制使用内置 app-server，即使 45789 正在运行，也可以执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -SkipSharedApp
```

## Clash 代理

如果 Microsoft Store 包名不是默认的 `OpenAI.Codex`，可在 PowerShell 7 中指定包名：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -PackageName OpenAI.Codex
```

如果未检测到显式系统代理，脚本回退到 `127.0.0.1:7890`。可以指定其他回退地址：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -FallbackProxy 127.0.0.1:7890
```

本次 Desktop 启动环境会设置：

```text
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY=localhost,127.0.0.1,::1
```

`NO_PROXY` 用于确保本地 45789/45790 流量不绕进 Clash。

## 验证 Remote Control 和 shared app-server

首次启动后，脚本等待 12 秒并检查一次连接。Remote Control WebSocket 可能尚未建立，因此建议在 Desktop 启动后执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -CheckOnly
```

检查结果会同时显示在窗口中，并保存到 `Codex-代理连接报告.txt`。

报告重点看：

- `共享 App Server 状态`
- `本次选择模式`
- 是否观察到 Codex 连接 45789
- 是否观察到 Codex 连接 Clash 代理端口

## 如何解释结果

- `本次选择模式：共享 app-server`：启动时 45789 已就绪，Desktop 应走共享。
- `本次选择模式：内置 app-server`：启动时共享未就绪，Desktop 使用内置 app-server。
- `已确认：发现 N 条 Codex 到 Clash 代理端口的连接`：至少一个 `ChatGPT.exe` 或 `codex.exe` 的 TCP 连接到达了预期 Clash 端口。
- `暂未发现`：可能是 Remote Control 尚未连接，也可能是相关组件没有采用这些代理变量。可在 Remote Control 明确处于连接状态时再次运行 `-CheckOnly`。
- TCP 连接表无法读取加密 WebSocket 的业务内容，因此不能仅凭某一条连接断言其一定是 Remote Control。

## 脚本不会做什么

- 不启动 AOI shared stack。
- 不修改 Windows 注册表。
- 不写入用户级或系统级永久环境变量。
- 不自动结束现有 Codex 进程。
- 不写死 Store 包版本号或安装目录。
