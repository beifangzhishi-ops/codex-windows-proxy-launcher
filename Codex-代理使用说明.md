# Codex + Clash 代理启动与验证

本项目根目录中的两个脚本必须放在同一目录；可以把整个目录移动到任意位置，不需要修改脚本中的路径。

## 第一次运行

1. 确认 Clash 已启动，并开启 Windows 系统代理。
2. 在 Codex 中保存好正在进行的工作，然后从菜单完全退出 Codex。
3. 在任务管理器中确认没有 `ChatGPT.exe`。如果仍有进程，等待几秒；脚本不会替你结束进程。
4. 双击 `Start-Codex-Proxy.cmd`。
5. 脚本会自动读取系统代理、从 AppxManifest 定位 Store 版 Codex、设置本次进程树的代理环境，然后启动 Codex。

如果 Microsoft Store 包名不是默认的 `OpenAI.Codex`，可在 PowerShell 7 中指定包名：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -PackageName OpenAI.Codex
```

如果未检测到显式系统代理，脚本回退到 `127.0.0.1:7890`。可以在 PowerShell 7 中用下列命令指定其他回退地址：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -FallbackProxy 127.0.0.1:7890
```

## 验证 Remote Control 连接

首次启动后，脚本等待 12 秒并检查一次连接。Remote Control WebSocket 可能尚未建立，因此建议：

1. 在 Codex 中开启或触发 Remote Control，保持其处于连接状态。
2. 在脚本所在目录打开 PowerShell 7。
3. 执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -CheckOnly
```

检查结果会同时显示在窗口中，并保存到 `Codex-代理连接报告.txt`。

## 如何解释结果

- `已确认：发现 N 条 Codex 到 Clash 代理端口的连接`：至少一个 `ChatGPT.exe` 或 `codex.exe` 的 TCP 连接到达了预期的 Clash 端口，说明该连接经过代理。
- `暂未发现`：可能是 Remote Control 尚未连接，也可能是相关组件没有采用这些代理变量。请在 Remote Control 明确处于连接状态时再运行一次 `-CheckOnly`。
- TCP 连接表无法读取加密 WebSocket 的业务内容，因此不能仅凭某一条连接断言其一定是 Remote Control。要进一步确认，可以把连接报告发回给 Codex，并结合 Clash 的连接记录核对目标域名。

## 脚本不会做什么

- 不修改 Windows 注册表。
- 不写入用户级或系统级永久环境变量。
- 不自动结束现有 Codex 进程。
- 不写死 Store 包版本号或安装目录。
