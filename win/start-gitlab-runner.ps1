[CmdletBinding()]
param(
    [string]$RunnerRoot = "",
    [string]$ConfigFile = "",
    [ValidateRange(1, 3650)]
    [int]$LogRetentionDays = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RunnerRoot)) {
    $RunnerRoot = $PSScriptRoot
}

$RunnerRoot = [IO.Path]::GetFullPath($RunnerRoot)
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $RunnerRoot "config.toml"
}
else {
    $ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
}
$RunnerExe = Join-Path $RunnerRoot "gitlab-runner.exe"
$LogDir = Join-Path $RunnerRoot "logs"

if (-not (Test-Path -LiteralPath $RunnerExe -PathType Leaf)) {
    throw "gitlab-runner.exe 不存在：$RunnerExe"
}
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "config.toml 不存在：$ConfigFile"
}
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Get-ChildItem -LiteralPath $LogDir -File -Filter "runner-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$LogFile = Join-Path $LogDir ("runner-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Protect-LogLine {
    param([AllowEmptyString()][string]$Line)
    return ($Line -replace 'glrt-[A-Za-z0-9._-]+', '<redacted-runner-token>')
}

function Write-RunnerLog {
    param([AllowEmptyString()][string]$Message)
    "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), (Protect-LogLine $Message) |
        Out-File -LiteralPath $LogFile -Encoding utf8 -Append
}

try {
    $host.UI.RawUI.WindowTitle = "GitLab Runner GUI - $env:COMPUTERNAME\$env:USERNAME"
}
catch { }

Write-RunnerLog "GitLab Runner GUI starting"
Write-RunnerLog "Computer    : $env:COMPUTERNAME"
Write-RunnerLog "User        : $env:USERDOMAIN\$env:USERNAME"
Write-RunnerLog "UserProfile : $env:USERPROFILE"
Write-RunnerLog "SessionName : $env:SESSIONNAME"
Write-RunnerLog "ProcessId   : $PID"
Write-RunnerLog "RunnerExe   : $RunnerExe"
Write-RunnerLog "ConfigFile  : $ConfigFile"
Write-RunnerLog "WorkingDir  : $RunnerRoot"

try {
    $sessionInfo = (& quser.exe 2>&1 | Out-String).Trim()
    foreach ($line in ($sessionInfo -split "`r?`n")) {
        if ($line) { Write-RunnerLog $line }
    }
}
catch {
    Write-RunnerLog "quser failed: $($_.Exception.Message)"
}

try {
    $versionInfo = (& $RunnerExe --version 2>&1 | Out-String).Trim()
    foreach ($line in ($versionInfo -split "`r?`n")) {
        if ($line) { Write-RunnerLog $line }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "gitlab-runner --version failed with ExitCode=$LASTEXITCODE"
    }
}
catch {
    Write-RunnerLog "version check failed: $($_.Exception.Message)"
}

$exitCode = 100
Push-Location $RunnerRoot
try {
    Write-RunnerLog "Starting gitlab-runner.exe run"
    if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $PSNativeCommandUseErrorActionPreference = $false
    }
    # gitlab-runner 把正常日志写到 stderr；在 Windows PowerShell 5.1 下 2>&1 会把每行 stderr
    # 变成 ErrorRecord，配合 ErrorActionPreference=Stop 会在第一行日志就终止。此处降级为 Continue。
    $ErrorActionPreference = "Continue"
    & $RunnerExe run --config $ConfigFile 2>&1 |
        ForEach-Object { Write-RunnerLog $_.ToString() }
    $exitCode = $LASTEXITCODE
    Write-RunnerLog "gitlab-runner exited. ExitCode=$exitCode"
}
catch {
    Write-RunnerLog "FATAL: $($_.Exception.Message)"
}
finally {
    Pop-Location
}

exit $exitCode
