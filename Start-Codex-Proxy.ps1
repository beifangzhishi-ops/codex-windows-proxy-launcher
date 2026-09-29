[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [ValidateRange(1, 120)]
    [int]$WaitSeconds = 12,
    [string]$FallbackProxy = '127.0.0.1:7890',
    [string]$PackageName = 'OpenAI.Codex'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Remove-Item Env:CODEX_APP_SERVER_WS_URL -ErrorAction SilentlyContinue

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===') -ForegroundColor Cyan
}

function ConvertTo-ProxyUri {
    param(
        [AllowNull()]
        [string]$Value,
        [string]$DefaultScheme = 'http'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $cleanValue = $Value.Trim()
    if ($cleanValue -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return $cleanValue
    }

    return ($DefaultScheme + '://' + $cleanValue)
}

function Hide-ProxyCredential {
    param([string]$ProxyUri)

    try {
        $uri = [Uri]$ProxyUri
        if ([string]::IsNullOrWhiteSpace($uri.UserInfo)) {
            return $ProxyUri
        }

        return ('{0}://***@{1}:{2}' -f $uri.Scheme, $uri.Host, $uri.Port)
    }
    catch {
        return $ProxyUri
    }
}

function Get-OptionalPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-WindowsSystemProxy {
    $registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $settings = Get-ItemProperty -LiteralPath $registryPath
    $proxyEnabled = ([int](Get-OptionalPropertyValue -InputObject $settings -Name 'ProxyEnable') -eq 1)
    $proxyServer = [string](Get-OptionalPropertyValue -InputObject $settings -Name 'ProxyServer')
    $autoConfigUrl = [string](Get-OptionalPropertyValue -InputObject $settings -Name 'AutoConfigURL')

    if (-not $proxyEnabled -or [string]::IsNullOrWhiteSpace($proxyServer)) {
        return @{
            Found = $false
            Source = if ([string]::IsNullOrWhiteSpace($autoConfigUrl)) {
                '未检测到已启用的显式 Windows 系统代理'
            }
            else {
                '仅检测到 PAC，无法可靠转换为固定代理：' + $autoConfigUrl
            }
            Http = $null
            Https = $null
            All = $null
        }
    }

    $proxyServer = $proxyServer.Trim()
    if ($proxyServer -notmatch '=') {
        $singleProxy = ConvertTo-ProxyUri -Value $proxyServer
        return @{
            Found = $true
            Source = 'Windows 当前用户系统代理'
            Http = $singleProxy
            Https = $singleProxy
            All = $singleProxy
        }
    }

    $proxyMap = @{}
    foreach ($entry in ($proxyServer -split ';')) {
        if ($entry -match '^\s*([^=]+)=(.+?)\s*$') {
            $proxyMap[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
        }
    }

    $httpValue = $proxyMap['http']
    $httpsValue = $proxyMap['https']
    $socksValue = $proxyMap['socks']

    if ([string]::IsNullOrWhiteSpace($httpValue)) {
        $httpValue = $httpsValue
    }
    if ([string]::IsNullOrWhiteSpace($httpsValue)) {
        $httpsValue = $httpValue
    }

    if ([string]::IsNullOrWhiteSpace($httpValue) -and [string]::IsNullOrWhiteSpace($socksValue)) {
        return @{
            Found = $false
            Source = '系统代理格式无法转换：' + $proxyServer
            Http = $null
            Https = $null
            All = $null
        }
    }

    $httpProxy = ConvertTo-ProxyUri -Value $httpValue
    $httpsProxy = ConvertTo-ProxyUri -Value $httpsValue
    $allProxy = if ([string]::IsNullOrWhiteSpace($socksValue)) {
        $httpsProxy
    }
    else {
        ConvertTo-ProxyUri -Value $socksValue -DefaultScheme 'socks5'
    }

    return @{
        Found = $true
        Source = 'Windows 当前用户分协议系统代理'
        Http = $httpProxy
        Https = $httpsProxy
        All = $allProxy
    }
}

function Get-CodexPackageInfo {
    param([string]$Name)

    $package = Get-AppxPackage -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $package) {
        throw ('未找到 Microsoft Store 包：' + $Name)
    }

    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $applications = @($manifest.Package.Applications.Application)
    if ($applications.Count -eq 0) {
        throw 'AppxManifest.xml 中没有 Application 入口。'
    }

    $application = $applications |
        Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$_.Executable)) -and (
                ([string]$_.Id -eq 'App') -or
                ([string]$_.Executable -match '(?i)(chatgpt|codex)')
            )
        } |
        Select-Object -First 1

    if ($null -eq $application) {
        $application = $applications |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Executable) } |
            Select-Object -First 1
    }
    if ($null -eq $application) {
        throw 'AppxManifest.xml 中没有可执行的 Application 入口。'
    }

    $appId = [string]$application.Id
    $relativeExecutable = [string]$application.Executable
    $packageFamilyName = [string]$package.PackageFamilyName

    if ([string]::IsNullOrWhiteSpace($appId)) {
        throw 'AppxManifest Application 缺少 Id。'
    }
    if ([string]::IsNullOrWhiteSpace($relativeExecutable)) {
        throw 'AppxManifest Application 缺少 Executable。'
    }
    if ([string]::IsNullOrWhiteSpace($packageFamilyName)) {
        throw '无法读取 Codex 包的 PackageFamilyName。'
    }

    $executablePath = Join-Path $package.InstallLocation $relativeExecutable
    if (-not (Test-Path -LiteralPath $executablePath)) {
        throw ('AppxManifest 指定的可执行文件不存在：' + $executablePath)
    }

    return @{
        Package = $package
        Application = $application
        PackageFamilyName = $packageFamilyName
        AppId = $appId
        Aumid = ($packageFamilyName + '!' + $appId)
        InstallLocation = [string]$package.InstallLocation
        RelativeExecutable = $relativeExecutable
        ExecutablePath = $executablePath
    }
}

function Test-ProcessBelongsToCodexPackage {
    param(
        [object]$Process,
        [hashtable]$PackageInfo
    )

    try {
        $processPath = [string]$Process.Path
        if ([string]::IsNullOrWhiteSpace($processPath)) {
            return $false
        }

        $installRoot = $PackageInfo.InstallLocation.TrimEnd('\') + '\'
        return $processPath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-CodexProcesses {
    param([hashtable]$PackageInfo)

    return @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue |
        Where-Object {
            Test-ProcessBelongsToCodexPackage -Process $_ -PackageInfo $PackageInfo
        })
}

function Get-CodexConnections {
    param([hashtable]$PackageInfo)

    $processes = @(Get-CodexProcesses -PackageInfo $PackageInfo)
    if ($processes.Count -eq 0) {
        return @()
    }

    $processIds = @($processes | Select-Object -ExpandProperty Id)
    return @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in $processIds } |
        Sort-Object OwningProcess, RemoteAddress, RemotePort)
}

function Test-IsExpectedProxyConnection {
    param(
        [string]$RemoteAddress,
        [int]$RemotePort,
        [Uri]$ExpectedProxy
    )

    if ($RemotePort -ne $ExpectedProxy.Port) {
        return $false
    }

    $expectedHost = $ExpectedProxy.Host.ToLowerInvariant()
    $actualHost = $RemoteAddress.ToLowerInvariant()
    if ($expectedHost -eq $actualHost) {
        return $true
    }

    $loopbackNames = @('localhost', '127.0.0.1', '::1', '0:0:0:0:0:0:0:1', '::ffff:127.0.0.1')
    return (($expectedHost -in $loopbackNames) -and ($actualHost -in $loopbackNames))
}

function Start-CodexWithPackageIdentity {
    param(
        [hashtable]$PackageInfo,
        [hashtable]$Proxy
    )

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        throw ('未找到用于 Appx 包上下文启动的 Windows PowerShell：' + $windowsPowerShell)
    }

    $launchErrorPath = Join-Path $PSScriptRoot 'Codex-启动错误.txt'
    Remove-Item -LiteralPath $launchErrorPath -Force -ErrorAction SilentlyContinue

    $packageFamilyName = $PackageInfo.PackageFamilyName.Replace("'", "''")
    $appId = $PackageInfo.AppId.Replace("'", "''")
    $executablePath = $PackageInfo.ExecutablePath.Replace("'", "''")
    $errorPath = $launchErrorPath.Replace("'", "''")
    $httpProxy = ([string]$Proxy.Http).Replace("'", "''")
    $httpsProxy = ([string]$Proxy.Https).Replace("'", "''")
    $allProxy = ([string]$Proxy.All).Replace("'", "''")
    $noProxy = 'localhost,127.0.0.1,::1'

    $innerCommand = @'
$ErrorActionPreference = 'Stop'
try {
    $env:HTTP_PROXY = '__HTTP_PROXY__'
    $env:HTTPS_PROXY = '__HTTPS_PROXY__'
    $env:ALL_PROXY = '__ALL_PROXY__'
    $env:NO_PROXY = '__NO_PROXY__'
    Remove-Item Env:CODEX_APP_SERVER_WS_URL -ErrorAction SilentlyContinue
    & '__EXECUTABLE__'
}
catch {
    ($_ | Out-String) | Set-Content -LiteralPath '__ERROR_PATH__' -Encoding UTF8
    exit 1
}
'@
    $innerCommand = $innerCommand.Replace('__HTTP_PROXY__', $httpProxy)
    $innerCommand = $innerCommand.Replace('__HTTPS_PROXY__', $httpsProxy)
    $innerCommand = $innerCommand.Replace('__ALL_PROXY__', $allProxy)
    $innerCommand = $innerCommand.Replace('__NO_PROXY__', $noProxy)
    $innerCommand = $innerCommand.Replace('__EXECUTABLE__', $executablePath)
    $innerCommand = $innerCommand.Replace('__ERROR_PATH__', $errorPath)
    $innerEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerCommand))
    $innerArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $innerEncodedCommand

    $packageLaunchCommand = @'
$ErrorActionPreference = 'Stop'
try {
    Import-Module Appx -ErrorAction Stop
    Invoke-CommandInDesktopPackage -PackageFamilyName '__PACKAGE_FAMILY__' -AppId '__APP_ID__' -Command '__WINDOWS_POWERSHELL__' -Args '__INNER_ARGS__' -PreventBreakaway
}
catch {
    ($_ | Out-String) | Set-Content -LiteralPath '__ERROR_PATH__' -Encoding UTF8
    exit 1
}
'@
    $packageLaunchCommand = $packageLaunchCommand.Replace('__PACKAGE_FAMILY__', $packageFamilyName)
    $packageLaunchCommand = $packageLaunchCommand.Replace('__APP_ID__', $appId)
    $packageLaunchCommand = $packageLaunchCommand.Replace('__WINDOWS_POWERSHELL__', $windowsPowerShell.Replace("'", "''"))
    $packageLaunchCommand = $packageLaunchCommand.Replace('__INNER_ARGS__', $innerArgs.Replace("'", "''"))
    $packageLaunchCommand = $packageLaunchCommand.Replace('__ERROR_PATH__', $errorPath)

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($packageLaunchCommand))
    $launcher = Start-Process -FilePath $windowsPowerShell -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) -WindowStyle Hidden -PassThru

    Start-Sleep -Milliseconds 800
    if (Test-Path -LiteralPath $launchErrorPath) {
        $details = (Get-Content -LiteralPath $launchErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            throw 'Codex 包上下文启动失败；错误日志为空。'
        }
        throw ('Codex 包上下文启动失败：' + $details)
    }

    if ($launcher.HasExited -and $launcher.ExitCode -ne 0) {
        $details = if (Test-Path -LiteralPath $launchErrorPath) {
            (Get-Content -LiteralPath $launchErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
        }
        else {
            ''
        }

        if ([string]::IsNullOrWhiteSpace($details)) {
            throw ('Codex 包上下文启动失败，启动器退出代码：' + $launcher.ExitCode)
        }
        throw ('Codex 包上下文启动失败：' + $details)
    }

    return $launcher
}

function Save-ConnectionReport {
    param(
        [string]$ReportPath,
        [hashtable]$Proxy,
        [hashtable]$PackageInfo,
        [object[]]$Connections,
        [Uri]$ExpectedProxy,
        [bool]$ProxyHit
    )

    $reportLines = @(
        'Codex 代理连接检查报告',
        ('检查时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')),
        ('代理来源：' + $Proxy.Source),
        ('HTTP_PROXY：' + (Hide-ProxyCredential $Proxy.Http)),
        ('HTTPS_PROXY：' + (Hide-ProxyCredential $Proxy.Https)),
        ('ALL_PROXY：' + (Hide-ProxyCredential $Proxy.All)),
        ('包名：' + [string]$PackageInfo.Package.Name),
        ('包版本：' + [string]$PackageInfo.Package.Version),
        ('PackageFamilyName：' + $PackageInfo.PackageFamilyName),
        ('AppId：' + $PackageInfo.AppId),
        ('AUMID：' + $PackageInfo.Aumid),
        ('Manifest Executable：' + $PackageInfo.RelativeExecutable),
        ('EntryPoint：' + [string]$PackageInfo.Application.EntryPoint),
        ('实际路径：' + $PackageInfo.ExecutablePath),
        '启动方式：Invoke-CommandInDesktopPackage -> 包上下文 PowerShell -> Manifest executable',
        ('预期代理端点：' + $ExpectedProxy.Host + ':' + $ExpectedProxy.Port),
        ('发现代理连接：' + $(if ($ProxyHit) { '是' } else { '否' })),
        '',
        '当前 OpenAI.Codex 包内 ChatGPT.exe / codex.exe 的已建立 TCP 连接：'
    )

    if ($Connections.Count -eq 0) {
        $reportLines += '未发现已建立连接。'
    }
    else {
        foreach ($connection in $Connections) {
            $processName = try {
                (Get-Process -Id $connection.OwningProcess -ErrorAction Stop).ProcessName
            }
            catch {
                '进程已退出'
            }

            $reportLines += ('PID={0} 进程={1} 本地={2}:{3} 远端={4}:{5}' -f
                $connection.OwningProcess,
                $processName,
                $connection.LocalAddress,
                $connection.LocalPort,
                $connection.RemoteAddress,
                $connection.RemotePort)
        }
    }

    $reportLines += @(
        '',
        '判断说明：',
        '“发现代理连接：是”表示至少一个属于 OpenAI.Codex Store 包的相关进程连接到了预期的 Clash 代理端口。',
        'Codex Store 包当前 Manifest 的主程序文件名可能是 ChatGPT.exe；判断应用归属时以包安装目录为准，不只看进程名。',
        'TCP 连接表无法读取加密 WebSocket 的业务内容，因此不能仅凭某一条连接断言其一定是 Remote Control。',
        '如果 Remote Control 尚未建立连接，可在功能处于连接状态时再次使用 -CheckOnly 检查。'
    )

    Set-Content -LiteralPath $ReportPath -Value $reportLines -Encoding UTF8
}

try {
    Write-Section '检查 Windows 系统代理'
    $proxy = Get-WindowsSystemProxy
    if (-not $proxy.Found) {
        $fallbackUri = ConvertTo-ProxyUri -Value $FallbackProxy
        Write-Warning ($proxy.Source + '；回退到 ' + $fallbackUri)
        $proxy = @{
            Found = $true
            Source = '回退代理'
            Http = $fallbackUri
            Https = $fallbackUri
            All = $fallbackUri
        }
    }

    Write-Host ('来源：' + $proxy.Source)
    Write-Host ('HTTP ：' + (Hide-ProxyCredential $proxy.Http))
    Write-Host ('HTTPS：' + (Hide-ProxyCredential $proxy.Https))
    Write-Host ('ALL  ：' + (Hide-ProxyCredential $proxy.All))

    $expectedProxyText = [string]$proxy.Https
    if ([string]::IsNullOrWhiteSpace($expectedProxyText)) {
        $expectedProxyText = [string]$proxy.Http
    }
    if ([string]::IsNullOrWhiteSpace($expectedProxyText)) {
        $expectedProxyText = [string]$proxy.All
    }
    $expectedProxy = [Uri]$expectedProxyText
    if ($expectedProxy.Port -le 0) {
        throw ('代理地址没有有效端口：' + $expectedProxyText)
    }

    Write-Section '读取 Microsoft Store Codex 包'
    $packageInfo = Get-CodexPackageInfo -Name $PackageName
    Write-Host ('包名      ：' + [string]$packageInfo.Package.Name)
    Write-Host ('版本      ：' + [string]$packageInfo.Package.Version)
    Write-Host ('PFN       ：' + $packageInfo.PackageFamilyName)
    Write-Host ('AppId     ：' + $packageInfo.AppId)
    Write-Host ('AUMID     ：' + $packageInfo.Aumid)
    Write-Host ('Executable：' + $packageInfo.RelativeExecutable)
    Write-Host ('EntryPoint：' + [string]$packageInfo.Application.EntryPoint)
    Write-Host ('实际路径  ：' + $packageInfo.ExecutablePath)

    if (-not $CheckOnly) {
        $runningCodex = @(Get-CodexProcesses -PackageInfo $packageInfo)
        if ($runningCodex.Count -gt 0) {
            Write-Section '检测到已有 Codex 实例'
            Write-Warning '请先从 Codex 菜单完全退出应用，并等待其 OpenAI.Codex 包内进程全部结束，然后重新双击启动脚本。'
            Write-Warning '脚本不会自动结束现有 Codex 进程，以免中断未保存工作。'
            exit 20
        }

        Write-Section '检查 Clash 代理端口'
        $proxyReachable = Test-NetConnection -ComputerName $expectedProxy.Host -Port $expectedProxy.Port -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $proxyReachable) {
            throw ('无法连接代理端口 ' + $expectedProxy.Host + ':' + $expectedProxy.Port + '。请确认 Clash 已启动且对应端口正在监听。')
        }
        Write-Host '代理端口可以连接。' -ForegroundColor Green

        Write-Section '设置本次启动进程树的代理环境'
        $env:HTTP_PROXY = $proxy.Http
        $env:HTTPS_PROXY = $proxy.Https
        $env:ALL_PROXY = $proxy.All
        $env:NO_PROXY = 'localhost,127.0.0.1,::1'
        Write-Host ('HTTP_PROXY =' + (Hide-ProxyCredential $env:HTTP_PROXY))
        Write-Host ('HTTPS_PROXY=' + (Hide-ProxyCredential $env:HTTPS_PROXY))
        Write-Host ('ALL_PROXY  =' + (Hide-ProxyCredential $env:ALL_PROXY))
        Write-Host ('NO_PROXY   =' + $env:NO_PROXY)

        Write-Section '通过 Store 包上下文启动 Codex'
        $launchProcess = Start-CodexWithPackageIdentity -PackageInfo $packageInfo -Proxy $proxy
        Write-Host ('包上下文启动器 PID：' + $launchProcess.Id) -ForegroundColor Green
        Write-Host ('等待 ' + $WaitSeconds + ' 秒，让界面、app-server 和网络连接完成初始化。')
        Start-Sleep -Seconds $WaitSeconds

        $startedCodex = @(Get-CodexProcesses -PackageInfo $packageInfo)
        if ($startedCodex.Count -eq 0) {
            throw ('已提交 Store 包上下文启动，但等待 ' + $WaitSeconds + ' 秒后仍未检测到 OpenAI.Codex 进程。')
        }
        Write-Host ('已检测到 ' + $startedCodex.Count + ' 个属于 OpenAI.Codex 包的相关进程。') -ForegroundColor Green
    }

    Write-Section '检查 Codex 代理连接'
    $connections = @(Get-CodexConnections -PackageInfo $packageInfo)
    $proxyConnections = @($connections | Where-Object {
        Test-IsExpectedProxyConnection -RemoteAddress $_.RemoteAddress -RemotePort $_.RemotePort -ExpectedProxy $expectedProxy
    })
    $proxyHit = ($proxyConnections.Count -gt 0)

    $reportPath = Join-Path $PSScriptRoot 'Codex-代理连接报告.txt'
    Save-ConnectionReport -ReportPath $reportPath -Proxy $proxy -PackageInfo $packageInfo -Connections $connections -ExpectedProxy $expectedProxy -ProxyHit $proxyHit

    if ($proxyHit) {
        Write-Host ('已确认：发现 ' + $proxyConnections.Count + ' 条 Codex 到 Clash 代理端口的连接。') -ForegroundColor Green
    }
    else {
        Write-Warning '暂未发现 Codex 到预期代理端口的连接。如果 Remote Control 尚未建立连接，请启用后再使用 -CheckOnly 检查。'
    }
    Write-Host ('报告：' + $reportPath)
    Write-Host ''
    Write-Host '检查命令：' -ForegroundColor Cyan
    Write-Host ('pwsh -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -CheckOnly')
}
catch {
    Write-Host ''
    Write-Host ('失败：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
