# Windows Codex Desktop + Clash 代理启动器

这是一个独立的 Windows 工具项目，用于启动 Microsoft Store 版 Codex Desktop、注入 Clash 网络代理，并在启动时自动选择共享或内置 app-server。

## 分工

`Start-Codex-Proxy.cmd` 只负责 Desktop 启动和网络代理，不负责启动 AOI shared stack。

默认 `SharedAppUrl` 为 `ws://127.0.0.1:45789`，启动器会检查 `http://127.0.0.1:45789/readyz`：

- 如果 45789 已就绪：本次 Desktop 启动环境注入 `CODEX_APP_SERVER_WS_URL=ws://127.0.0.1:45789`，Desktop 使用共享 app-server。
- 如果 45789 未就绪：本次 Desktop 启动环境移除 `CODEX_APP_SERVER_WS_URL`，Desktop 使用自己的内置 app-server。
- 启动器不会寻找 AOI 仓库，不会调用 `shared-start.cmd` / `shared-stack.ps1`，也不会写入 `AOI_REPO_PATH`。

共享 app-server 由 `codex2larkAOI\shared-start.cmd` 单独负责启动：

```text
Desktop / AOI -> 127.0.0.1:45789  compatibility proxy
                                  -> 127.0.0.1:45790  real codex app-server
```

因此两套职责保持独立：

```text
codex-windows-proxy-launcher
= Desktop + Clash + 自动选择共享/内置

codex2larkAOI\shared-start.cmd
= 启动 45789 + 45790 共享栈
```

## Clash 代理

脚本自动读取 Windows 当前用户的系统代理；未检测到显式代理时，回退到 `127.0.0.1:7890`。

启动 Desktop 前会设置：

```text
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY=localhost,127.0.0.1,::1
```

本地 shared app-server 流量通过 `NO_PROXY` 绕过 Clash；外网流量继续走系统代理。

如果共享 45789 已就绪，还会仅对本次 Desktop 启动进程树设置：

```text
CODEX_APP_SERVER_WS_URL=ws://127.0.0.1:45789
```

如果共享未就绪，则本次 Desktop 启动环境不设置该变量。

启动器不会为了选择模式去修改用户级 `CODEX_APP_SERVER_WS_URL`；报告中仍会显示当前 User 值，方便排查旧环境变量。

## Codex Desktop 启动

脚本从 AppxManifest 读取 `Executable` 和 `EntryPoint`，不会写死 Store 包版本号或安装目录。默认查找包名 `OpenAI.Codex`，也可通过 `-PackageName` 指定其他包名。

如果检测到现有 `ChatGPT.exe`，启动器不会强杀进程，而是退出并要求先正常关闭 Desktop，避免中断正在执行的任务。

双击入口固定使用 Windows CRLF 换行，并在显示中文前切换到 UTF-8 代码页，自动寻找常见的 PowerShell 7 安装位置；找不到时回退到系统自带的 Windows PowerShell 5.1。

## 检查

Desktop 已运行时可执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -CheckOnly
```

生成的 `Codex-代理连接报告.txt` 会显示：

- 共享 app-server 是否就绪；
- 当前自动选择的是“共享 app-server”还是“内置 app-server”；
- `CODEX_APP_SERVER_WS_URL(User)` 当前值；
- 是否观察到 Codex 进程连接 45789；
- 是否观察到 Codex 进程连接 Clash 代理端口；
- 当前 Codex/ChatGPT TCP 连接。

## 强制内置模式

故障排查时可以使用：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -SkipSharedApp
```

即使 45789 已经就绪，本次也会强制使用 Desktop 内置 app-server。

## 重要说明

OpenAI 官方环境变量文档没有把 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 列为 Codex 的稳定公开环境变量。因此 Clash 注入仍属于本机兼容性方案；是否覆盖 Remote Control WebSocket，需要结合生成的 TCP 连接报告判断。
