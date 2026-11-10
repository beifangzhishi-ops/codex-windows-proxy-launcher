Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-Codex-Proxy.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('Launcher syntax error: ' + ($parseErrors | Out-String))
}

$names = @('Get-CodexLaunchProcessRole', 'Get-CodexLaunchProcessStates')
$definitions = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
}, $true)
if ($definitions.Count -ne $names.Count) {
    throw 'Could not load the launch process classifier from the launcher.'
}
foreach ($definition in $definitions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function New-TestProcess {
    param([int]$Id, [string]$Path, [int]$WindowHandle = 0)
    return [pscustomobject]@{
        Id = $Id
        Path = $Path
        ProcessName = 'ChatGPT'
        MainWindowHandle = [intptr]$WindowHandle
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Scenario)
    if ($Expected -ne $Actual) {
        throw ('{0}: expected {1}, got {2}' -f $Scenario, $Expected, $Actual)
    }
    Write-Output ('PASS ' + $Scenario)
}

# Stub process discovery, not the classification code under test.
function Get-CodexProcesses {
    param([hashtable]$PackageInfo)
    return $script:TestProcesses
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter, [int]$OperationTimeoutSec)
    if ($script:CimFails) {
        throw 'CIM not available'
    }
    return $script:TestDetails
}

$mainExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_123\app\ChatGPT.exe'
$sandboxExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_123\app\resources\codex.exe'
$package = @{ ExecutablePath = $mainExe }
$withWindow = New-TestProcess -Id 101 -Path $mainExe -WindowHandle 1234
$withoutWindow = New-TestProcess -Id 102 -Path $mainExe
$worker = New-TestProcess -Id 103 -Path $sandboxExe

Assert-Equal 'Main' (Get-CodexLaunchProcessRole -Process $withWindow -PackageInfo $package -CommandLine $null) 'Visible main window blocks'
Assert-Equal 'Main' (Get-CodexLaunchProcessRole -Process $withoutWindow -PackageInfo $package -CommandLine ('"' + $mainExe + '"')) 'Windowless main with command line blocks'
Assert-Equal 'Background' (Get-CodexLaunchProcessRole -Process $withoutWindow -PackageInfo $package -CommandLine ('"' + $mainExe + '" --type=utility --utility-sub-type=network')) 'Electron utility does not block'
Assert-Equal 'Background' (Get-CodexLaunchProcessRole -Process $withoutWindow -PackageInfo $package -CommandLine ('"' + $mainExe + '" --type=renderer')) 'Electron renderer does not block'
Assert-Equal 'Background' (Get-CodexLaunchProcessRole -Process $worker -PackageInfo $package -CommandLine ('"' + $sandboxExe + '"')) 'Other packaged executable does not block'
Assert-Equal 'Unknown' (Get-CodexLaunchProcessRole -Process $withoutWindow -PackageInfo $package -CommandLine $null) 'Uninspectable windowless process does not block'
Assert-Equal 'Main' (Get-CodexLaunchProcessRole -Process $withWindow -PackageInfo $package -CommandLine ('"' + $mainExe + '" --type=renderer')) 'Visible window wins over helper arguments'

$script:CimFails = $false
$script:TestProcesses = @($withoutWindow, $worker)
$script:TestDetails = @([pscustomobject]@{ProcessId=102; CommandLine=('"' + $mainExe + '" --type=gpu-process')})
$states = @(Get-CodexLaunchProcessStates -PackageInfo $package)
Assert-Equal 2 $states.Count 'Both package processes are reported'
Assert-Equal 0 @($states | Where-Object Role -eq 'Main').Count 'Only sandbox and auxiliary processes permit relaunch'

$script:TestProcesses = @($withWindow, $withoutWindow)
$script:TestDetails = @([pscustomobject]@{ProcessId=102; CommandLine=('"' + $mainExe + '" --type=renderer')})
$states = @(Get-CodexLaunchProcessStates -PackageInfo $package)
Assert-Equal 1 @($states | Where-Object Role -eq 'Main').Count 'Active window still blocks alongside helpers'

$script:CimFails = $true
$script:TestProcesses = @($withoutWindow)
$states = @(Get-CodexLaunchProcessStates -PackageInfo $package)
Assert-Equal 'Unknown' $states[0].Role 'CIM denial does not turn orphan into blocker'

Write-Output 'PASS Process detection tests complete.'
