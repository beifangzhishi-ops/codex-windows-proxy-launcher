# Codex + Clash 代理启动与验证

## 文件

把下面三个文件下载到同一个普通目录即可使用：

- Start-Codex-Proxy.cmd
- Start-Codex-Proxy.ps1
- Codex-代理使用说明.md

不需要克隆 Git 仓库，也不需要 .git、.codex 或其他项目文件。

## 第一次运行

1. 确认 Microsoft Store 版 Codex 已安装。
2. 确认 Clash 已启动，并开启 Windows 系统代理。
3. 在 Codex 中保存当前工作，然后从菜单完全退出 Codex。
4. 等待几秒，确保属于 OpenAI.Codex 安装目录的相关进程已经结束。
5. 双击 Start-Codex-Proxy.cmd。

脚本会依次：

1. 读取 Windows 当前用户的系统代理；无法转换时回退到 127.0.0.1:7890。
2. 读取当前安装的 OpenAI.Codex Store 包及其 Manifest 入口。
3. 设置本次启动进程树的 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY、NO_PROXY。
4. 创建 Windows Appx 包上下文 PowerShell，在其中设置代理变量，再由它启动 Codex。
5. 等待应用初始化并检查代理 TCP 连接。

Codex Store 包的 Manifest 主程序当前可能名为 ChatGPT.exe。脚本不会仅凭这个文件名判断应用身份，而是核对它是否位于当前 OpenAI.Codex 包安装目录。

## 为什么不能直接运行 WindowsApps 里的 exe

Microsoft Store 安装的桌面应用除了可执行文件本身，还可能依赖 Windows 提供的 package identity。直接运行：

    C:\Program Files\WindowsApps\OpenAI.Codex_...\app\ChatGPT.exe

可能在部分机器上启动到一半后出现“该进程没有程序包标识符”。本启动器先通过 Invoke-CommandInDesktopPackage 创建带 OpenAI.Codex package identity 的 PowerShell，再在该上下文中设置代理并启动 Manifest executable，不使用从普通进程裸启动 WindowsApps exe 的方式。

## 自定义包名或回退代理

默认包名：

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -PackageName OpenAI.Codex

指定其他回退代理：

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -FallbackProxy 127.0.0.1:7890

## 只检查当前连接

当 Codex 已经运行，并且 Remote Control 已经建立连接时执行：

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex-Proxy.ps1 -CheckOnly

结果会显示在窗口中，并保存为 Codex-代理连接报告.txt。

## 结果解释

- “已确认：发现 N 条 Codex 到 Clash 代理端口的连接”：至少一个属于当前 OpenAI.Codex Store 包的相关进程连接到了预期的 Clash 端口。
- “暂未发现”：应用可以已经正常启动，只是当前没有相关连接命中该代理端口；可在 Remote Control 明确处于连接状态时再次运行 -CheckOnly。
- TCP 连接表不能读取加密 WebSocket 的业务内容，因此不能仅凭单条 TCP 记录断言它一定是 Remote Control。

## 启动失败

如果包上下文启动器立即失败，脚本会显示错误；必要时同目录还会生成 Codex-启动错误.txt 供排查。

脚本不会：

- 修改 Windows 注册表。
- 写入用户级或系统级永久代理环境变量。
- 自动结束正在运行的 Codex 进程。
- 写死 Store 包版本号或安装目录。
- 直接运行 WindowsApps 内部 exe。
