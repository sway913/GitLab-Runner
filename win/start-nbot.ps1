[CmdletBinding()]
param(
    [string]$ConfigFile = ""
)

Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $PSScriptRoot "setup-nbot.conf"
}
$ErrorActionPreference = "Stop"

function Import-NBotConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "NBot 配置文件不存在：$Path"
    }

    $allowed = @(
        "nbot_root", "nbot_bin", "device_id", "mid", "gui_user",
        "start_delay_seconds", "log_retention_days", "task_name"
    )
    $result = @{}
    $lineNumber = 0

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }

        $separator = $line.IndexOf("=")
        if ($separator -lt 1) {
            throw "配置文件第 $lineNumber 行缺少 '='。"
        }

        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($allowed -notcontains $key) {
            throw "配置文件第 $lineNumber 行含未知配置项：$key"
        }
        if ($result.ContainsKey($key)) {
            throw "配置文件第 $lineNumber 行重复定义：$key"
        }
        $result[$key] = $value
    }

    return $result
}

function Get-RequiredConfigValue {
    param([hashtable]$Config, [string]$Name)
    if (-not $Config.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Config[$Name])) {
        throw "NBot 配置缺少必填项：$Name"
    }
    return [string]$Config[$Name]
}

function Resolve-ConfiguredPath {
    param([string]$Value, [string]$BaseDirectory)
    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

$ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
$config = Import-NBotConfig -Path $ConfigFile
$configDirectory = Split-Path -Parent $ConfigFile

$deviceId = Get-RequiredConfigValue -Config $config -Name "device_id"
$mid = Get-RequiredConfigValue -Config $config -Name "mid"
if ($deviceId -notmatch '^[0-9a-fA-F]{32}$') {
    throw "device_id 格式非法，应为 32 位十六进制字符串。"
}
if ($mid -notmatch '^[A-Za-z0-9_-]+$') {
    throw "mid 格式非法，应只包含 URL-safe base64 字符。"
}

$rootValue = if ($config.ContainsKey("nbot_root") -and $config["nbot_root"]) { $config["nbot_root"] } else { "." }
$NBotRoot = Resolve-ConfiguredPath -Value $rootValue -BaseDirectory $configDirectory
$binValue = if ($config.ContainsKey("nbot_bin") -and $config["nbot_bin"]) { $config["nbot_bin"] } else { ".\nbot.exe" }
$NBotExe = Resolve-ConfiguredPath -Value $binValue -BaseDirectory $NBotRoot

$LogRetentionDays = 14
if ($config.ContainsKey("log_retention_days") -and $config["log_retention_days"]) {
    if (-not [int]::TryParse($config["log_retention_days"], [ref]$LogRetentionDays) -or $LogRetentionDays -lt 1 -or $LogRetentionDays -gt 3650) {
        throw "log_retention_days 必须是 1-3650 的整数。"
    }
}

$LogDir = Join-Path $NBotRoot "logs"
if (-not (Test-Path -LiteralPath $NBotExe -PathType Leaf)) {
    throw "nbot.exe 不存在：$NBotExe"
}
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Get-ChildItem -LiteralPath $LogDir -File -Filter "nbot-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$LogFile = Join-Path $LogDir ("nbot-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Protect-LogLine {
    param([AllowEmptyString()][string]$Line)
    $safe = $Line.Replace($mid, "<redacted-mid>")
    $safe = $safe -replace '(?i)([?&](?:access-token|zm-token)=)[^&\s"]+', '$1<redacted>'
    return ($safe -replace '(?i)--mid=[A-Za-z0-9_-]+', '--mid=<redacted>')
}

function Write-NBotLog {
    param([AllowEmptyString()][string]$Message)
    "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), (Protect-LogLine $Message) |
        Out-File -LiteralPath $LogFile -Encoding utf8 -Append
}

try {
    $host.UI.RawUI.WindowTitle = "NBot - $env:COMPUTERNAME\$env:USERNAME"
}
catch { }

Write-NBotLog "NBot starting"
Write-NBotLog "Computer    : $env:COMPUTERNAME"
Write-NBotLog "User        : $env:USERDOMAIN\$env:USERNAME"
Write-NBotLog "ProcessId   : $PID"
Write-NBotLog "NBotExe     : $NBotExe"
Write-NBotLog "ConfigFile  : $ConfigFile"
Write-NBotLog "WorkingDir  : $NBotRoot"

$env:device_id = $deviceId
$exitCode = 100
Push-Location $NBotRoot
try {
    Write-NBotLog "Starting nbot start --mid=<redacted>"
    # nbot 将正常日志写到 stderr；Windows PowerShell 5.1 合并 stderr 后会触发 Stop。
    $ErrorActionPreference = "Continue"
    & $NBotExe start "--mid=$mid" 2>&1 |
        ForEach-Object { Write-NBotLog $_.ToString() }
    $exitCode = $LASTEXITCODE
    Write-NBotLog "nbot exited. ExitCode=$exitCode"
}
catch {
    Write-NBotLog "FATAL: $($_.Exception.Message)"
}
finally {
    Pop-Location
    Remove-Item Env:\device_id -ErrorAction SilentlyContinue
}

exit $exitCode
