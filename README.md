# Windows Codex Desktop + Clash 代理启动器

这是一个独立的 Windows 工具项目，用于启动 Microsoft Store 版 Codex Desktop 并检查代理连接。脚本自动读取 Windows 当前用户的系统代理；未检测到显式代理时，回退到 `127.0.0.1:7890`。

## 文件

- `Start-Codex-Proxy.cmd`：双击入口。
- `Start-Codex-Proxy.ps1`：主脚本。
- `Codex-代理使用说明.md`：操作步骤和结果解释。

脚本从 AppxManifest 读取 `Executable` 和 `EntryPoint`，不会写死 Store 包版本号或安装目录。默认查找包名 `OpenAI.Codex`，也可通过 `-PackageName` 传入其他包名。脚本只使用自身目录定位同目录文件，移动整个项目目录不会改变路径逻辑。

系统代理注册表字段按可选值读取，可兼容未配置 PAC、因而不存在 `AutoConfigURL` 的 Windows 环境；分协议配置和仅 SOCKS 配置也能识别。

双击入口固定使用 Windows CRLF 换行，并在显示中文前切换到 UTF-8 代码页，自动寻找常见的 PowerShell 7 安装位置；找不到时回退到系统自带的 Windows PowerShell 5.1。维护时可传入 `--no-pause` 进行非交互测试。

## 重要说明

OpenAI 官方环境变量文档没有把 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 列为 Codex 的稳定公开环境变量。因此，本脚本属于本机兼容性排查方案；是否覆盖 Remote Control WebSocket，需要根据脚本生成的 TCP 连接报告判断。
