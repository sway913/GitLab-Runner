[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot "setup-nbot.conf"),
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-NBotConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "NBot 配置文件不存在：$Path`n请复制 setup-nbot.conf.example 为 setup-nbot.conf，填入重新签发的凭据。"
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
        if ($separator -lt 1) { throw "配置文件第 $lineNumber 行缺少 '='。" }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($allowed -notcontains $key) { throw "配置文件第 $lineNumber 行含未知配置项：$key" }
        if ($result.ContainsKey($key)) { throw "配置文件第 $lineNumber 行重复定义：$key" }
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
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Set-PrivateFileAcl {
    param([string]$Path, [Security.Principal.SecurityIdentifier]$UserSid)
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(
        @($UserSid, [Security.AccessControl.FileSystemRights]::ReadAndExecute),
        @([Security.Principal.SecurityIdentifier]::new("S-1-5-18"), [Security.AccessControl.FileSystemRights]::FullControl),
        @([Security.Principal.SecurityIdentifier]::new("S-1-5-32-544"), [Security.AccessControl.FileSystemRights]::FullControl)
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $entry[0], $entry[1], [Security.AccessControl.AccessControlType]::Allow
        ))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Add-DirectoryReadExecuteAcl {
    param([string]$Path, [Security.Principal.SecurityIdentifier]$UserSid)
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $UserSid,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-PrivateDirectoryAcl {
    param([string]$Path, [Security.Principal.SecurityIdentifier]$UserSid)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    foreach ($entry in @(
        @($UserSid, [Security.AccessControl.FileSystemRights]::Modify),
        @([Security.Principal.SecurityIdentifier]::new("S-1-5-18"), [Security.AccessControl.FileSystemRights]::FullControl),
        @([Security.Principal.SecurityIdentifier]::new("S-1-5-32-544"), [Security.AccessControl.FileSystemRights]::FullControl)
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $entry[0], $entry[1], $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        ))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Quote-TaskArgument {
    param([string]$Value)
    if ($Value.Contains('"')) { throw "计划任务参数不能包含双引号：$Value" }
    return '"' + $Value + '"'
}

function Get-PowerShellExecutable {
    # 固定使用机器级 Windows PowerShell，避免把 setup 用户私有的 pwsh 路径写入任务。
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Test-InteractiveUserSession {
    param([string]$UserName)
    try {
        return ((& quser.exe 2>$null | Out-String) -match "(?im)^\s*>?\s*$([regex]::Escape($UserName))\s+")
    }
    catch { return $false }
}

function Get-ProcessUsingExecutable {
    param([string]$ExecutablePath)
    $fullPath = [IO.Path]::GetFullPath($ExecutablePath)
    return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -and [string]::Equals(
            [IO.Path]::GetFullPath($_.ExecutablePath),
            $fullPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
}

if (-not $WhatIfPreference -and -not (Test-IsAdministrator)) {
    throw "请使用管理员 PowerShell 运行；仅预检时可使用 -WhatIf。"
}

$ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
$config = Import-NBotConfig -Path $ConfigFile
$configDirectory = Split-Path -Parent $ConfigFile
$deviceId = Get-RequiredConfigValue -Config $config -Name "device_id"
$mid = Get-RequiredConfigValue -Config $config -Name "mid"
if ($deviceId -notmatch '^[0-9a-fA-F]{32}$') { throw "device_id 格式非法，应为 32 位十六进制字符串。" }
if ($mid -notmatch '^[A-Za-z0-9_-]+$') { throw "mid 格式非法，应只包含 URL-safe base64 字符。" }

$GuiUserName = if ($config.ContainsKey("gui_user") -and $config["gui_user"]) { $config["gui_user"] } else { $env:USERNAME }
$localUser = Get-LocalUser -Name $GuiUserName -ErrorAction Stop
if (-not $localUser.Enabled) { throw "Windows 用户已禁用：$GuiUserName" }
$GuiUser = "$env:COMPUTERNAME\$GuiUserName"

$rootValue = if ($config.ContainsKey("nbot_root") -and $config["nbot_root"]) { $config["nbot_root"] } else { "." }
$NBotRoot = Resolve-ConfiguredPath -Value $rootValue -BaseDirectory $configDirectory
$binValue = if ($config.ContainsKey("nbot_bin") -and $config["nbot_bin"]) { $config["nbot_bin"] } else { ".\nbot.exe" }
$NBotExe = Resolve-ConfiguredPath -Value $binValue -BaseDirectory $NBotRoot
$Launcher = Join-Path $NBotRoot "start-nbot.ps1"
$LogDir = Join-Path $NBotRoot "logs"
$TaskName = if ($config.ContainsKey("task_name") -and $config["task_name"]) { $config["task_name"] } else { "NBot" }

$StartDelaySeconds = 30
if ($config.ContainsKey("start_delay_seconds") -and $config["start_delay_seconds"]) {
    if (-not [int]::TryParse($config["start_delay_seconds"], [ref]$StartDelaySeconds) -or $StartDelaySeconds -lt 0 -or $StartDelaySeconds -gt 3600) {
        throw "start_delay_seconds 必须是 0-3600 的整数。"
    }
}
$LogRetentionDays = 14
if ($config.ContainsKey("log_retention_days") -and $config["log_retention_days"]) {
    if (-not [int]::TryParse($config["log_retention_days"], [ref]$LogRetentionDays) -or $LogRetentionDays -lt 1 -or $LogRetentionDays -gt 3650) {
        throw "log_retention_days 必须是 1-3650 的整数。"
    }
}
if ($TaskName -match '[\\/:*?"<>|]') { throw "task_name 含 Windows 计划任务不允许的字符。" }
if (-not (Test-Path -LiteralPath $NBotExe -PathType Leaf)) { throw "nbot.exe 不存在：$NBotExe" }
if (-not (Test-Path -LiteralPath $Launcher -PathType Leaf)) { throw "启动脚本不存在：$Launcher" }

Write-Host "NBot 配置检查通过" -ForegroundColor Green
Write-Host "  用户：$GuiUser"
Write-Host "  程序：$NBotExe"
Write-Host "  配置：$ConfigFile"
Write-Host "  任务：$TaskName"

if (-not (Test-Path -LiteralPath $LogDir) -and $PSCmdlet.ShouldProcess($LogDir, "创建日志目录")) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
if ($PSCmdlet.ShouldProcess($ConfigFile, "收紧 NBot 配置与日志 ACL")) {
    Add-DirectoryReadExecuteAcl -Path $NBotRoot -UserSid $localUser.SID
    Set-PrivateFileAcl -Path $NBotExe -UserSid $localUser.SID
    Set-PrivateFileAcl -Path $ConfigFile -UserSid $localUser.SID
    Set-PrivateFileAcl -Path $Launcher -UserSid $localUser.SID
    Set-PrivateDirectoryAcl -Path $LogDir -UserSid $localUser.SID
}

$PowerShellExe = Get-PowerShellExecutable
$actionArguments = @(
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden", "-File", (Quote-TaskArgument $Launcher),
    "-ConfigFile", (Quote-TaskArgument $ConfigFile)
) -join " "
$Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $actionArguments -WorkingDirectory $NBotRoot
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $GuiUser
if ($StartDelaySeconds -gt 0) { $Trigger.Delay = "PT${StartDelaySeconds}S" }
$Principal = New-ScheduledTaskPrincipal -UserId $GuiUser -LogonType Interactive -RunLevel Limited
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$oldTaskXml = $null
$oldTaskWasRunning = $false
if ($existingTask) {
    $oldTaskXml = Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $oldTaskWasRunning = $existingTask.State -eq "Running"
}

$taskInstalled = $false
if ($PSCmdlet.ShouldProcess($TaskName, "原子替换 NBot 计划任务并在失败时恢复旧状态")) {
    $oldTaskRemoved = $false
    $newTaskRegistered = $false
    try {
        if ($existingTask) {
            # 从停止旧任务开始就视为需要回滚，确保部分失败也会重建原任务。
            $oldTaskRemoved = $true
            if ($existingTask.State -eq "Running") {
                Stop-ScheduledTask -TaskName $TaskName
                $deadline = (Get-Date).AddSeconds(15)
                do {
                    Start-Sleep -Milliseconds 500
                    $taskState = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                } while ($taskState -and $taskState.State -eq "Running" -and (Get-Date) -lt $deadline)
                if ($taskState -and $taskState.State -eq "Running") {
                    throw "旧 NBot 任务在 15 秒内未停止。"
                }
            }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        }

        $leftoverNBot = @(Get-ProcessUsingExecutable -ExecutablePath $NBotExe)
        if ($leftoverNBot.Count -gt 0) {
            throw "检测到仍在运行的目标 NBot 进程（PID: $($leftoverNBot.ProcessId -join ', ')）。"
        }

        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
            -Principal $Principal -Settings $Settings `
            -Description "NBot interactive desktop process" -Force | Out-Null
        $newTaskRegistered = $true

        $readBack = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ($readBack.Principal.LogonType -ne "Interactive") {
            throw "计划任务回读失败：LogonType 不是 Interactive。"
        }
        if (-not [string]::Equals($readBack.Actions[0].Execute, $PowerShellExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "计划任务回读失败：启动程序与预期不一致。"
        }
        $taskInstalled = $true
        Write-Host "计划任务已注册：$($readBack.TaskName)，状态：$($readBack.State)" -ForegroundColor Green
    }
    catch {
        $failureMessage = $_.Exception.Message
        $rollbackError = $null
        try {
            $currentTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($newTaskRegistered -or ($oldTaskRemoved -and $currentTask)) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            }
            if ($oldTaskRemoved -and $oldTaskXml) {
                Register-ScheduledTask -TaskName $TaskName -Xml $oldTaskXml -Force -ErrorAction Stop | Out-Null
                $runningTarget = @(Get-ProcessUsingExecutable -ExecutablePath $NBotExe)
                if ($oldTaskWasRunning -and $runningTarget.Count -eq 0) {
                    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                }
            }
        }
        catch {
            $rollbackError = $_.Exception.Message
        }

        if ($rollbackError) {
            throw "NBot 任务更新失败：$failureMessage 回滚不完整：$rollbackError"
        }
        else {
            throw "NBot 任务更新失败：$failureMessage 旧状态已恢复。"
        }
    }
}

if ($StartNow -and $taskInstalled) {
    if (Test-InteractiveUserSession -UserName $GuiUserName) {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "已请求立即启动 NBot。"
    }
    else {
        Write-Warning "$GuiUser 当前没有可识别的交互式会话，未立即启动；下次登录时会自动启动。"
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf 预检完成：未修改 ACL、计划任务或进程。" -ForegroundColor Yellow
}
