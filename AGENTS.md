# Project Rules

## Product contract

- The launcher is a standalone Windows utility for Microsoft Store Codex Desktop.
- End users must be able to download only Start-Codex-Proxy.cmd, Start-Codex-Proxy.ps1, and Codex-代理使用说明.md into one ordinary directory and run the CMD file. Do not add another runtime dependency without an explicit product decision.
- The default Store package is OpenAI.Codex. Discover the installed version, PackageFamilyName, AppId, executable, and install location dynamically from Appx metadata.

## Launching

- Never launch the Codex Store executable directly from C:\Program Files\WindowsApps.
- Invoke-CommandInDesktopPackage does not inherit arbitrary caller environment variables. Use it to create a package-context Windows PowerShell process, set proxy variables inside that context, and launch the Manifest executable from there with PreventBreakaway.
- Preserve proxy variables only in the current launcher/package process tree. Do not write permanent user or machine proxy environment variables.
- Clear CODEX_APP_SERVER_WS_URL for the standalone launch process tree.
- Detect existing Codex processes by executable path under the selected OpenAI.Codex install location, not by the ChatGPT.exe process name alone.

## Maintenance

- Keep README.md aligned with the current behavior and keep this file aligned with project rules.
- Remove obsolete behavior and stale terminology when changing the project; do not leave defensive references to removed flows.
- Keep Start-Codex-Proxy.cmd ASCII-compatible and force CRLF through .gitattributes so GitHub direct-download and Windows checkout behavior stays consistent.
- Validate both PowerShell 7 entry and Windows PowerShell 5.1 fallback behavior.
- Before release, verify the direct-download scenario on a clean directory and confirm there is no fallback to a bare WindowsApps executable.
- After successful changes, inspect Git status and diff, commit, and push the remote branch.
