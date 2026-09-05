[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [ValidateRange(1, 120)]
    [int]$WaitSeconds = 12,
    [string]$FallbackProxy = '127.0.0.1:7890',
    [string]$PackageName = 'OpenAI.Codex',
    [string]$SharedAppUrl = 'ws://127.0.0.1:45789',
    [string]$AoiRepoPath = '',
    [switch]$SkipSharedApp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

    $clean = $Value.Trim()
    if ($clean -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return $clean
    }

    return ($DefaultScheme + '://' + $clean)
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
        $source = '未检测到已启用的显式系统代理'
        if (-not [string]::IsNullOrWhiteSpace($autoConfigUrl)) {
            $source = '仅检测到 PAC，无法可靠转换为固定代理：' + $autoConfigUrl
        }
        return @{
            Found = $false
            Source = $source
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

    if ([string]::IsNullOrWhiteSpace($httpValue)) { $httpValue = $httpsValue }
    if ([string]::IsNullOrWhiteSpace($httpsValue)) { $httpsValue = $httpValue }

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
    if ([string]::IsNullOrWhiteSpace($socksValue)) {
        $allProxy = $httpsProxy
    }
    else {
        $allProxy = ConvertTo-ProxyUri -Value $socksValue -DefaultScheme 'socks5'
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
            ([string]$_.Executable -match '(?i)(chatgpt|codex)') -or
            ([string]$_.Id -match '(?i)(chatgpt|codex|app)')
        } |
        Select-Object -First 1

    if ($null -eq $application) {
        $application = $applications | Select-Object -First 1
    }

    $relativeExecutable = [string]$application.Executable
    if ([string]::IsNullOrWhiteSpace($relativeExecutable)) {
        throw 'AppxManifest 的 Application 入口没有 Executable 属性。'
    }

    $executablePath = Join-Path $package.InstallLocation $relativeExecutable
    if (-not (Test-Path -LiteralPath $executablePath)) {
        throw ('AppxManifest 指定的可执行文件不存在：' + $executablePath)
    }

    return @{
        Package = $package
        Application = $application
        ExecutablePath = $executablePath
    }
}

function Get-CodexProcesses {
    return @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue)
}

function Get-CodexConnections {
    $processes = @(Get-CodexProcesses)
    if ($processes.Count -eq 0) { return @() }

    $processIds = @($processes | Select-Object -ExpandProperty Id)
    return @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in $processIds } |
        Sort-Object OwningProcess, RemoteAddress, RemotePort)
}

function Test-IsExpectedConnection {
    param(
        [string]$RemoteAddress,
        [int]$RemotePort,
        [Uri]$Expected
    )

    if ($RemotePort -ne $Expected.Port) { return $false }

    $expectedHost = $Expected.Host.ToLowerInvariant()
    $actualHost = $RemoteAddress.ToLowerInvariant()
    if ($expectedHost -eq $actualHost) { return $true }

    $loopbackNames = @('localhost', '127.0.0.1', '::1', '0:0:0:0:0:0:0:1', '::ffff:127.0.0.1')
    return (($expectedHost -in $loopbackNames) -and ($actualHost -in $loopbackNames))
}

function ConvertTo-ReadyUrl {
    param([string]$WsUrl)

    $uri = [Uri]$WsUrl
    if ($uri.Scheme -ne 'ws' -and $uri.Scheme -ne 'wss') {
        throw ('共享 app-server URL 必须是 ws:// 或 wss://：' + $WsUrl)
    }

    if ($uri.Scheme -eq 'wss') { $scheme = 'https' } else { $scheme = 'http' }
    $builder = New-Object -TypeName System.UriBuilder -ArgumentList @($scheme, $uri.Host, $uri.Port, '/readyz')
    return $builder.Uri.AbsoluteUri
}

function Test-HttpReady {
    param([string]$Url)

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2 -ErrorAction Stop
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Wait-HttpReady {
    param(
        [string]$Url,
        [int]$Seconds = 30
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-HttpReady -Url $Url) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Resolve-AoiRepoPath {
    param([string]$ConfiguredPath)

    $candidates = @()
    $currentEnv = [string]$env:AOI_REPO_PATH
    $userEnv = [string][Environment]::GetEnvironmentVariable('AOI_REPO_PATH', 'User')

    foreach ($candidate in @($ConfiguredPath, $currentEnv, $userEnv)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $candidates += [string]$candidate
        }
    }

    $parent = Split-Path -Parent $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $candidates += (Join-Path $parent 'codex2larkAOI')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        foreach ($relative in @(
            'codex2larkAOI',
            'Documents\codex2larkAOI',
            'Documents\GitHub\codex2larkAOI',
            'GitHub\codex2larkAOI',
            'source\repos\codex2larkAOI',
            'Desktop\codex2larkAOI'
        )) {
            $candidates += (Join-Path $env:USERPROFILE $relative)
        }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $stackScript = Join-Path $candidate 'scripts\shared-stack.ps1'
        if (Test-Path -LiteralPath $stackScript) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Ensure-SharedApp {
    param(
        [string]$WsUrl,
        [string]$ConfiguredRepoPath
    )

    $readyUrl = ConvertTo-ReadyUrl -WsUrl $WsUrl
    $repoPath = Resolve-AoiRepoPath -ConfiguredPath $ConfiguredRepoPath

    if (Test-HttpReady -Url $readyUrl) {
        $env:CODEX_APP_SERVER_WS_URL = $WsUrl
        [Environment]::SetEnvironmentVariable('CODEX_APP_SERVER_WS_URL', $WsUrl, 'User')
        if (-not [string]::IsNullOrWhiteSpace($repoPath)) {
            $env:AOI_REPO_PATH = $repoPath
            [Environment]::SetEnvironmentVariable('AOI_REPO_PATH', $repoPath, 'User')
        }
        Write-Host ('共享 app-server 已就绪：' + $WsUrl) -ForegroundColor Green
        return
    }

    if ([string]::IsNullOrWhiteSpace($repoPath)) {
        throw ('共享 app-server 未运行，且找不到 AOI 仓库。请先设置用户环境变量 AOI_REPO_PATH 指向 codex2larkAOI 本地目录。目标：' + $WsUrl)
    }

    $stackScript = Join-Path $repoPath 'scripts\shared-stack.ps1'
    $runner = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $runner)) {
        $runner = (Get-Command powershell.exe -ErrorAction Stop).Source
    }

    Write-Section '启动 AOI shared app-server'
    Write-Host ('AOI 仓库：' + $repoPath)
    Write-Host ('目标：' + $WsUrl)

    $env:AOI_REPO_PATH = $repoPath
    [Environment]::SetEnvironmentVariable('AOI_REPO_PATH', $repoPath, 'User')

    & $runner -NoProfile -ExecutionPolicy Bypass -File $stackScript -Action start -NoGui
    $stackExitCode = $LASTEXITCODE
    if ($stackExitCode -ne 0) {
        throw ('AOI shared stack 启动失败，退出代码：' + $stackExitCode)
    }

    if (-not (Wait-HttpReady -Url $readyUrl -Seconds 35)) {
        throw ('AOI shared stack 未在预期时间内就绪：' + $readyUrl)
    }

    $env:CODEX_APP_SERVER_WS_URL = $WsUrl
    [Environment]::SetEnvironmentVariable('CODEX_APP_SERVER_WS_URL', $WsUrl, 'User')
    Write-Host ('共享 app-server 已启动：' + $WsUrl) -ForegroundColor Green
}

function Save-ConnectionReport {
    param(
        [string]$ReportPath,
        [hashtable]$Proxy,
        [hashtable]$PackageInfo,
        [object[]]$Connections,
        [Uri]$ExpectedProxy,
        [bool]$ProxyHit,
        [string]$SharedAppUrl,
        [string]$SharedAppStatus,
        [string]$SharedAppUserEnv,
        [bool]$SharedAppHit
    )

    $reportLines = @(
        'Codex 代理连接检查报告',
        ('检查时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')),
        ('代理来源：' + $Proxy.Source),
        ('HTTP_PROXY：' + (Hide-ProxyCredential $Proxy.Http)),
        ('HTTPS_PROXY：' + (Hide-ProxyCredential $Proxy.Https)),
        ('ALL_PROXY：' + (Hide-ProxyCredential $Proxy.All)),
        ('共享 App Server：' + $SharedAppUrl),
        ('共享 App Server 状态：' + $SharedAppStatus),
        ('CODEX_APP_SERVER_WS_URL(User)：' + $SharedAppUserEnv),
        ('发现 Codex/共享 App Server 连接：' + $(if ($SharedAppHit) { '是' } else { '否' })),
        ('包版本：' + [string]$PackageInfo.Package.Version),
        ('Executable：' + [string]$PackageInfo.Application.Executable),
        ('EntryPoint：' + [string]$PackageInfo.Application.EntryPoint),
        ('实际路径：' + $PackageInfo.ExecutablePath),
        ('预期 Clash 代理对端：' + $ExpectedProxy.Host + ':' + $ExpectedProxy.Port),
        ('发现 Clash 代理连接：' + $(if ($ProxyHit) { '是' } else { '否' })),
        '',
        '当前由 ChatGPT.exe 或 codex.exe 持有的已建立 TCP 连接：'
    )

    if ($Connections.Count -eq 0) {
        $reportLines += '未发现已建立连接。'
    }
    else {
        foreach ($connection in $Connections) {
            try {
                $processName = (Get-Process -Id $connection.OwningProcess -ErrorAction Stop).ProcessName
            }
            catch {
                $processName = '进程已退出'
            }

            $reportLines += ('PID={0} 进程={1} 本地={2}:{3} 对端={4}:{5}' -f
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
        '判定说明：',
        '共享 App Server 状态“就绪”表示 45789/readyz 可访问。',
        '“发现 Codex/共享 App Server 连接：是”表示至少有 Codex 相关进程连到共享 App Server 端口。',
        '“发现 Clash 代理连接：是”表示至少有一个 Codex 相关进程连接到了预期的 Clash 代理端口。',
        '仅凭 TCP 表无法给单条加密连接标注“Remote Control WebSocket”。'
    )

    Set-Content -LiteralPath $ReportPath -Value $reportLines -Encoding UTF8
}

try {
    Write-Section '检测 Windows 系统代理'
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
    if ([string]::IsNullOrWhiteSpace($expectedProxyText)) { $expectedProxyText = [string]$proxy.Http }
    if ([string]::IsNullOrWhiteSpace($expectedProxyText)) { $expectedProxyText = [string]$proxy.All }
    $expectedProxy = [Uri]$expectedProxyText
    if ($expectedProxy.Port -le 0) {
        throw ('代理地址没有有效端口：' + $expectedProxyText)
    }

    Write-Section '读取 Microsoft Store Codex 入口'
    $packageInfo = Get-CodexPackageInfo -Name $PackageName
    Write-Host ('版本      ：' + [string]$packageInfo.Package.Version)
    Write-Host ('Executable：' + [string]$packageInfo.Application.Executable)
    Write-Host ('EntryPoint ：' + [string]$packageInfo.Application.EntryPoint)
    Write-Host ('实际路径   ：' + $packageInfo.ExecutablePath)

    $sharedReadyUrl = $null
    if (-not $SkipSharedApp) {
        $sharedReadyUrl = ConvertTo-ReadyUrl -WsUrl $SharedAppUrl
    }

    if (-not $CheckOnly) {
        $runningChatGpt = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
        if ($runningChatGpt.Count -gt 0) {
            Write-Section '检测到旧 Codex 实例'
            Write-Warning '请先从 Codex 菜单完全退出应用，并在任务管理器确认没有 ChatGPT.exe，然后重新双击启动脚本。'
            Write-Warning '脚本不会自动结束现有进程，以免中断未保存的任务。'
            exit 20
        }

        Write-Section '检查 Clash 代理端口'
        $proxyReachable = Test-NetConnection -ComputerName $expectedProxy.Host -Port $expectedProxy.Port -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $proxyReachable) {
            throw ('无法连接代理端口 ' + $expectedProxy.Host + ':' + $expectedProxy.Port + '。请确认 Clash 已启动且对应端口正在监听。')
        }
        Write-Host '代理端口可连接。' -ForegroundColor Green

        if (-not $SkipSharedApp) {
            Ensure-SharedApp -WsUrl $SharedAppUrl -ConfiguredRepoPath $AoiRepoPath
        }
        else {
            Write-Warning '已使用 -SkipSharedApp：本次启动不会强制连接 AOI shared app-server。'
        }

        Write-Section '设置本次启动环境'
        $env:HTTP_PROXY = $proxy.Http
        $env:HTTPS_PROXY = $proxy.Https
        $env:ALL_PROXY = $proxy.All
        $env:NO_PROXY = 'localhost,127.0.0.1,::1'
        if (-not $SkipSharedApp) {
            $env:CODEX_APP_SERVER_WS_URL = $SharedAppUrl
        }

        Write-Host ('HTTP_PROXY =' + (Hide-ProxyCredential $env:HTTP_PROXY))
        Write-Host ('HTTPS_PROXY=' + (Hide-ProxyCredential $env:HTTPS_PROXY))
        Write-Host ('ALL_PROXY  =' + (Hide-ProxyCredential $env:ALL_PROXY))
        Write-Host ('NO_PROXY   =' + $env:NO_PROXY)
        if (-not $SkipSharedApp) {
            Write-Host ('CODEX_APP_SERVER_WS_URL=' + $env:CODEX_APP_SERVER_WS_URL)
        }

        Write-Section '启动 Codex'
        $launchProcess = Start-Process -FilePath $packageInfo.ExecutablePath -PassThru
        Write-Host ('已提交启动，初始 PID：' + $launchProcess.Id) -ForegroundColor Green
        Write-Host ('等待 ' + $WaitSeconds + ' 秒，让界面、shared app-server 和网络连接完成初始化……')
        Start-Sleep -Seconds $WaitSeconds
    }

    Write-Section '检查 Codex 网络连接'
    $connections = @(Get-CodexConnections)
    $proxyConnections = @($connections | Where-Object {
        Test-IsExpectedConnection -RemoteAddress $_.RemoteAddress -RemotePort $_.RemotePort -Expected $expectedProxy
    })
    $proxyHit = ($proxyConnections.Count -gt 0)

    $sharedAppStatus = '跳过'
    $sharedAppHit = $false
    if (-not $SkipSharedApp) {
        if (Test-HttpReady -Url $sharedReadyUrl) { $sharedAppStatus = '就绪' } else { $sharedAppStatus = '未就绪' }
        $sharedUri = [Uri]$SharedAppUrl
        $sharedConnections = @($connections | Where-Object {
            Test-IsExpectedConnection -RemoteAddress $_.RemoteAddress -RemotePort $_.RemotePort -Expected $sharedUri
        })
        $sharedAppHit = ($sharedConnections.Count -gt 0)
    }

    $sharedAppUserEnv = [string][Environment]::GetEnvironmentVariable('CODEX_APP_SERVER_WS_URL', 'User')
    $reportPath = Join-Path $PSScriptRoot 'Codex-代理连接报告.txt'
    Save-ConnectionReport -ReportPath $reportPath -Proxy $proxy -PackageInfo $packageInfo -Connections $connections -ExpectedProxy $expectedProxy -ProxyHit $proxyHit -SharedAppUrl $SharedAppUrl -SharedAppStatus $sharedAppStatus -SharedAppUserEnv $sharedAppUserEnv -SharedAppHit $sharedAppHit

    if ($proxyHit) {
        Write-Host ('已确认：发现 ' + $proxyConnections.Count + ' 条 Codex 到 Clash 代理端口的连接。') -ForegroundColor Green
    }
    else {
        Write-Warning '暂未发现 Codex 到预期 Clash 代理端口的连接。若 Remote Control 尚未建立，请启用后使用 -CheckOnly 再检查。'
    }

    if (-not $SkipSharedApp) {
        if ($sharedAppStatus -eq '就绪') {
            Write-Host ('共享 App Server：' + $SharedAppUrl + ' 已就绪。') -ForegroundColor Green
        }
        else {
            Write-Warning ('共享 App Server 未就绪：' + $SharedAppUrl)
        }

        if ($sharedAppHit) {
            Write-Host '已发现 Codex 进程连接到共享 App Server。' -ForegroundColor Green
        }
        elseif (-not $CheckOnly) {
            Write-Warning '暂未在 TCP 表中看到 Codex -> shared app-server 连接；请在 Desktop 完成初始化后用 -CheckOnly 复查。'
        }
    }

    Write-Host ('报告：' + $reportPath)
    Write-Host ''
    Write-Host '复查命令：' -ForegroundColor Cyan
    Write-Host ('pwsh -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -CheckOnly')
}
catch {
    Write-Host ''
    Write-Host ('失败：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
