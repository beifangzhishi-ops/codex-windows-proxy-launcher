# Windows Codex Desktop + Clash 代理启动器

这是一个独立的 Windows 工具项目，用于启动 Microsoft Store 版 Codex Desktop、注入 Clash 网络代理，并在启动前确保 AOI 的 shared app-server 已经可用。

默认链路现在是：

```text
Codex Desktop -> 127.0.0.1:45789  AOI compatibility proxy
                              -> 127.0.0.1:45790  real codex app-server

Codex Desktop -> Clash/system proxy -> Internet / Remote Control
```

本地 shared app-server 流量通过 `NO_PROXY=localhost,127.0.0.1,::1` 绕过 Clash；外网流量继续走系统代理。

## 文件

- `Start-Codex-Proxy.cmd`：双击入口。
- `Start-Codex-Proxy.ps1`：主脚本。
- `Codex-代理使用说明.md`：操作步骤和结果解释。

## Shared app-server 启动逻辑

默认 `SharedAppUrl` 为 `ws://127.0.0.1:45789`。

启动器会先检查 `http://127.0.0.1:45789/readyz`：

1. 如果已经就绪，直接把 `CODEX_APP_SERVER_WS_URL=ws://127.0.0.1:45789` 注入到本次 Desktop 启动环境，并同步写入当前用户环境变量。
2. 如果未就绪，启动器会寻找 `codex2larkAOI` 本地仓库，并调用其中的 `scripts/shared-stack.ps1 -Action start -NoGui`。
3. AOI shared stack 会启动：
   - `45789`：兼容代理，过滤 Desktop 注入的 malformed `mcp_servers.codex_app` runtime override。
   - `45790`：真实 Codex app-server。
4. 如果 45789 最终仍未就绪，启动器会直接失败，不会静默回退到 Desktop 私有 app-server。

AOI 仓库位置通过 `AOI_REPO_PATH` 保存。启动器会优先读取：

- 参数 `-AoiRepoPath`
- 当前进程环境变量 `AOI_REPO_PATH`
- 当前用户环境变量 `AOI_REPO_PATH`
- 启动器同级目录和若干常见 Git 仓库目录

AOI 自身成功启动 shared stack 后也会持久记录 `AOI_REPO_PATH`，因此正常情况下只需初始化一次。

## Clash 代理

脚本自动读取 Windows 当前用户的系统代理；未检测到显式代理时，回退到 `127.0.0.1:7890`。

系统代理注册表字段按可选值读取，可兼容未配置 PAC、分协议配置和仅 SOCKS 配置。

启动 Desktop 前会设置：

```text
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY=localhost,127.0.0.1,::1
CODEX_APP_SERVER_WS_URL=ws://127.0.0.1:45789
```

## Codex Desktop 启动

脚本从 AppxManifest 读取 `Executable` 和 `EntryPoint`，不会写死 Store 包版本号或安装目录。默认查找包名 `OpenAI.Codex`，也可通过 `-PackageName` 传入其他包名。

如果检测到现有 `ChatGPT.exe`，启动器不会强杀进程，而是退出并要求先正常关闭 Desktop，避免中断正在执行的任务。

双击入口固定使用 Windows CRLF 换行，并在显示中文前切换到 UTF-8 代码页，自动寻找常见的 PowerShell 7 安装位置；找不到时回退到系统自带的 Windows PowerShell 5.1。

## 检查

Desktop 已运行时可执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -CheckOnly
```

生成的 `Codex-代理连接报告.txt` 会同时显示：

- shared app-server 是否就绪；
- `CODEX_APP_SERVER_WS_URL(User)`；
- 是否观察到 Codex 进程连接 45789；
- 是否观察到 Codex 进程连接 Clash 代理端口；
- 当前 Codex/ChatGPT TCP 连接。

## 逃生参数

`-SkipSharedApp` 只用于故障排查。使用后启动器不会强制启动或连接 AOI shared app-server，可能重新进入 Desktop 私有 app-server 与 AOI 分裂的状态，因此不建议日常使用。

## 重要说明

OpenAI 官方环境变量文档没有把 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 列为 Codex 的稳定公开环境变量。因此 Clash 注入仍属于本机兼容性方案；是否覆盖 Remote Control WebSocket，需要结合生成的 TCP 连接报告判断。
