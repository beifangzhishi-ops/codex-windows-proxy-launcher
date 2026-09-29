# Windows Codex Desktop + Clash 代理启动器

这是一个独立的 Windows 启动器，用于给 Microsoft Store 版 Codex Desktop 注入当前用户的代理环境，并在启动后检查相关进程是否连接到预期的 Clash 代理端口。

## 直接下载即可使用

运行时只需要把下面两个脚本放在同一目录：

- Start-Codex-Proxy.cmd
- Start-Codex-Proxy.ps1

Codex-代理使用说明.md 是随项目分发的使用说明。三个文件可以直接从 GitHub 下载到任意普通目录，不需要 git clone，也不依赖 .git、.codex 或固定仓库路径。

双击 Start-Codex-Proxy.cmd 即可启动。

## 当前启动方式

脚本默认查找 Microsoft Store 包 OpenAI.Codex，并从当前安装版本的 AppxManifest.xml 动态读取：

- PackageFamilyName
- Application Id
- Executable
- EntryPoint
- 安装目录

Codex Store 包当前的 Manifest 主程序文件名可能是 app/ChatGPT.exe；这不代表启动器选中了普通 ChatGPT。应用归属以 OpenAI.Codex 包信息和安装目录为准。

启动器不会从普通 PowerShell 进程直接运行 C:\Program Files\WindowsApps\...\ChatGPT.exe。实测表明，Invoke-CommandInDesktopPackage 创建的包上下文不会自动继承调用方自定义环境变量，因此启动链路是：

1. 主脚本创建 OpenAI.Codex 的包上下文 PowerShell。
2. 在这个已具备 Store package identity 的 PowerShell 内设置 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY、NO_PROXY。
3. 再由该包上下文 PowerShell 启动 Manifest 指定的 Codex executable。

包上下文使用 PreventBreakaway，使子进程保持 package identity。这样既保留代理环境，又避免直接从无包身份进程运行 WindowsApps 内部 exe 时出现“该进程没有程序包标识符”一类错误。

## 代理行为

脚本读取当前用户的 Windows 系统代理：

- 单一代理地址会同时用于 HTTP_PROXY、HTTPS_PROXY 和 ALL_PROXY。
- 分协议代理会分别解析 HTTP / HTTPS / SOCKS。
- 未检测到可转换的显式代理时，默认回退到 127.0.0.1:7890。
- NO_PROXY 固定为 localhost,127.0.0.1,::1。

这些环境变量只作用于本次启动进程树，不写入用户级或系统级永久环境变量。

独立启动器会清除本次进程树中的 CODEX_APP_SERVER_WS_URL，因此不会主动连接外部共享 App Server，也不会修改用户级该变量。

## PowerShell

双击入口优先使用 PowerShell 7；找不到时回退到 Windows PowerShell 5.1。Store 包上下文启动由系统自带的 Windows PowerShell / Appx 模块承载，以保证 package identity。

CMD 入口保持 ASCII 文本，并在启动 PowerShell 前切换到 UTF-8 代码页；.gitattributes 固定使用 CRLF，确保 GitHub 下载和 Windows checkout 的批处理换行一致。维护或自动测试时可传入 --no-pause。

## 验证

首次启动后脚本默认等待 12 秒，然后生成 Codex-代理连接报告.txt。报告会记录包身份、AUMID、启动方式、代理端点和当前属于 OpenAI.Codex 安装目录的 ChatGPT.exe / codex.exe TCP 连接。

只检查当前实例而不重新启动：

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -CheckOnly

TCP 连接命中代理端口只能证明相关连接经过该代理，不能单独证明某条连接就是 Remote Control WebSocket。
