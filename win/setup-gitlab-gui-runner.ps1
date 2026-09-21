<#
.SYNOPSIS
  为真实 Windows 桌面会话配置 GitLab Runner Interactive 计划任务。

.DESCRIPTION
  脚本只负责检查现有 Runner、收紧权限并注册计划任务；不会下载软件、注册
  Runner 或生成 token。使用 -WhatIf 可完成无系统修改的预检。
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [string]$GuiUserName = $env:USERNAME,
    [string]$RunnerRoot = $PSScriptRoot,
    [string]$ConfigFile = "",
    [string]$TaskName = "GitLab Runner GUI",
    [ValidateRange(0, 3600)]
    [int]$StartDelaySeconds = 60,
    [ValidateRange(1, 3650)]
    [int]$LogRetentionDays = 14,
    [string[]]$RequiredCommands = @("git.exe"),
    [bool]$DisableExistingRunnerService = $true,
    [bool]$ConfigureGuiPowerSettings = $true,
    [switch]$DisableHibernate,
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-TaskArgument {
    param([string]$Value)
    if ($Value.Contains('"')) { throw "计划任务参数不能包含双引号：$Value" }
    return '"' + $Value + '"'
}

function Get-PowerShellExecutable {
    # 计划任务启动器只依赖 Windows PowerShell 5.1，固定使用机器级系统路径。
    # 不使用执行 setup 的管理员账户 PATH，避免写入其他 GUI 用户无法访问的私有 pwsh。
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Test-RunnerPwshAvailable {
    param([string]$TargetUserName)

    $machinePwsh = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
    if (Test-Path -LiteralPath $machinePwsh -PathType Leaf) {
        return $true
    }

    # 只有 setup 用户与任务用户相同时，才允许使用该用户 PATH 中的 pwsh。
    if ([string]::Equals($TargetUserName, $env:USERNAME, [StringComparison]::OrdinalIgnoreCase)) {
        return [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)
    }

    return $false
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

function Set-WritableDirectoryAcl {
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

function Invoke-NativeChecked {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$Description)
    & $FilePath @ArgumentList | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$Description 失败，ExitCode=$LASTEXITCODE"
    }
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

function Stop-AndRemoveScheduledTask {
    param([string]$Name)
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) { return }

    if ($task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $Name
        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 500
            $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        } while ($task -and $task.State -eq "Running" -and (Get-Date) -lt $deadline)
        if ($task -and $task.State -eq "Running") {
            throw "旧任务在 15 秒内未停止；为避免重复 Runner，已中止重建。"
        }
    }
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
}

if (-not $WhatIfPreference -and -not (Test-IsAdministrator)) {
    throw "请使用管理员 PowerShell 运行；仅预检时可使用 -WhatIf。"
}

$RunnerRoot = [IO.Path]::GetFullPath($RunnerRoot)
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $RunnerRoot "config.toml"
}
else {
    $ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
}
$RunnerExe = Join-Path $RunnerRoot "gitlab-runner.exe"
$Launcher = Join-Path $RunnerRoot "start-gitlab-runner.ps1"
$LogDir = Join-Path $RunnerRoot "logs"
$BuildsDir = Join-Path $RunnerRoot "builds"
$CacheDir = Join-Path $RunnerRoot "cache"

if ($TaskName -match '[\\/:*?"<>|]') { throw "TaskName 含 Windows 计划任务不允许的字符。" }
if (-not (Test-Path -LiteralPath $RunnerRoot -PathType Container)) { throw "Runner 目录不存在：$RunnerRoot" }

$localUser = Get-LocalUser -Name $GuiUserName -ErrorAction Stop
if (-not $localUser.Enabled) { throw "Windows 用户已禁用：$GuiUserName" }
$GuiUser = "$env:COMPUTERNAME\$GuiUserName"

$missing = [Collections.Generic.List[string]]::new()
foreach ($path in @($RunnerExe, $ConfigFile, $Launcher)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing.Add($path) }
}
foreach ($commandName in $RequiredCommands) {
    if ($commandName -and -not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        $missing.Add("命令：$commandName")
    }
}
if ($missing.Count -gt 0) {
    throw "环境检查未通过：`n  - $($missing -join "`n  - ")"
}

$versionText = (& $RunnerExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "gitlab-runner.exe 无法执行，ExitCode=$LASTEXITCODE" }
$configText = Get-Content -LiteralPath $ConfigFile -Raw
if ($configText -notmatch '\[\[runners\]\]') { throw "config.toml 未包含 [[runners]]。" }
if ($configText -notmatch '(?m)^\s*executor\s*=\s*"shell"\s*$') {
    Write-Warning "未检测到 executor = `"shell`"；GUI CI 应确认使用 Shell Executor。"
}
if ($configText -notmatch '(?m)^\s*shell\s*=\s*"pwsh"\s*$') {
    Write-Warning "未检测到 shell = `"pwsh`"；Windows Runner 推荐使用 PowerShell 7。"
}
elseif (-not (Test-RunnerPwshAvailable -TargetUserName $GuiUserName)) {
    throw "config.toml 指定 shell = `"pwsh`"，但目标用户无法确认使用 PowerShell 7。请安装机器级 C:\Program Files\PowerShell\7\pwsh.exe。"
}

Write-Host "GitLab Runner 预检通过" -ForegroundColor Green
Write-Host "  用户：$GuiUser"
Write-Host "  Runner：$RunnerExe"
Write-Host "  Config：$ConfigFile"
Write-Host "  Launcher：$Launcher"
Write-Host "  $($versionText -split "`r?`n" | Select-Object -First 1)"

foreach ($directory in @($LogDir, $BuildsDir, $CacheDir)) {
    if (-not (Test-Path -LiteralPath $directory) -and $PSCmdlet.ShouldProcess($directory, "创建可写目录")) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}
if ($PSCmdlet.ShouldProcess($RunnerRoot, "配置最小权限 ACL")) {
    Add-DirectoryReadExecuteAcl -Path $RunnerRoot -UserSid $localUser.SID
    Set-PrivateFileAcl -Path $RunnerExe -UserSid $localUser.SID
    Set-PrivateFileAcl -Path $ConfigFile -UserSid $localUser.SID
    Set-PrivateFileAcl -Path $Launcher -UserSid $localUser.SID
    foreach ($directory in @($LogDir, $BuildsDir, $CacheDir)) {
        Set-WritableDirectoryAcl -Path $directory -UserSid $localUser.SID
    }
}

$PowerShellExe = Get-PowerShellExecutable
$actionArguments = @(
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden", "-File", (Quote-TaskArgument $Launcher),
    "-RunnerRoot", (Quote-TaskArgument $RunnerRoot),
    "-ConfigFile", (Quote-TaskArgument $ConfigFile),
    "-LogRetentionDays", $LogRetentionDays
) -join " "
$Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $actionArguments -WorkingDirectory $RunnerRoot
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $GuiUser
if ($StartDelaySeconds -gt 0) { $Trigger.Delay = "PT${StartDelaySeconds}S" }
$Principal = New-ScheduledTaskPrincipal -UserId $GuiUser -LogonType Interactive -RunLevel Limited
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$service = Get-Service -Name "gitlab-runner" -ErrorAction SilentlyContinue
$serviceWasRunning = $false
$serviceStartMode = $null
if ($service) {
    $serviceWasRunning = $service.Status -eq "Running"
    $serviceCim = Get-CimInstance Win32_Service -Filter "Name='gitlab-runner'" -ErrorAction Stop
    $serviceStartMode = $serviceCim.StartMode
    if (-not $DisableExistingRunnerService) {
        Write-Warning "检测到 gitlab-runner Windows Service；它可能与 Interactive Runner 重复运行。"
    }
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$oldTaskXml = $null
$oldTaskWasRunning = $false
if ($existingTask) {
    $oldTaskXml = Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $oldTaskWasRunning = $existingTask.State -eq "Running"
}

if ($PSCmdlet.ShouldProcess($TaskName, "原子替换 Runner 计划任务并在失败时恢复旧状态")) {
    $serviceChanged = $false
    $oldTaskRemoved = $false
    $newTaskRegistered = $false
    try {
        if ($service -and $DisableExistingRunnerService) {
            $serviceChanged = $true
            if ($service.Status -ne "Stopped") {
                Stop-Service -Name "gitlab-runner" -Force -ErrorAction Stop
                $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
            }
            Set-Service -Name "gitlab-runner" -StartupType Disabled
        }

        if ($existingTask) {
            # 从停止旧任务开始就视为需要回滚，覆盖“删除成功但命令返回异常”等边界情况。
            $oldTaskRemoved = $true
            Stop-AndRemoveScheduledTask -Name $TaskName
        }

        $leftoverRunner = @(Get-ProcessUsingExecutable -ExecutablePath $RunnerExe)
        if ($leftoverRunner.Count -gt 0) {
            throw "检测到仍在运行的目标 Runner 进程（PID: $($leftoverRunner.ProcessId -join ', ')）。"
        }

        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
            -Principal $Principal -Settings $Settings `
            -Description "Interactive GitLab Runner for Windows GUI CI" -Force | Out-Null
        $newTaskRegistered = $true

        $readBack = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ($readBack.Principal.LogonType -ne "Interactive") {
            throw "计划任务回读失败：LogonType 不是 Interactive。"
        }
        if (-not [string]::Equals($readBack.Actions[0].Execute, $PowerShellExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "计划任务回读失败：启动程序与预期不一致。"
        }
        Write-Host "计划任务已注册：$($readBack.TaskName)，状态：$($readBack.State)" -ForegroundColor Green
    }
    catch {
        $failureMessage = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()

        try {
            $currentTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($newTaskRegistered -or ($oldTaskRemoved -and $currentTask)) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            }
            if ($oldTaskRemoved -and $oldTaskXml) {
                Register-ScheduledTask -TaskName $TaskName -Xml $oldTaskXml -Force -ErrorAction Stop | Out-Null
                $runningTarget = @(Get-ProcessUsingExecutable -ExecutablePath $RunnerExe)
                if ($oldTaskWasRunning -and $runningTarget.Count -eq 0) {
                    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                }
            }
        }
        catch {
            $rollbackErrors.Add("旧计划任务恢复失败：$($_.Exception.Message)")
        }

        if ($serviceChanged) {
            try {
                $startupType = switch ($serviceStartMode) {
                    "Auto" { "Automatic" }
                    "Manual" { "Manual" }
                    "Disabled" { "Disabled" }
                    default { "Manual" }
                }
                Set-Service -Name "gitlab-runner" -StartupType $startupType -ErrorAction Stop
                if ($serviceWasRunning) {
                    Start-Service -Name "gitlab-runner" -ErrorAction Stop
                }
            }
            catch {
                $rollbackErrors.Add("Windows Service 恢复失败：$($_.Exception.Message)")
            }
        }

        $rollbackSummary = if ($rollbackErrors.Count -eq 0) {
            "旧状态已恢复。"
        }
        else {
            "回滚不完整：$($rollbackErrors -join '；')"
        }
        throw "Runner 任务更新失败：$failureMessage $rollbackSummary"
    }
}

if ($ConfigureGuiPowerSettings) {
    & powercfg.exe /getactivescheme
    if ($LASTEXITCODE -ne 0) { Write-Warning "无法读取当前电源方案，ExitCode=$LASTEXITCODE" }
    if ($PSCmdlet.ShouldProcess("当前 Windows 电源方案", "将 AC 睡眠超时设置为 Never")) {
        Invoke-NativeChecked -FilePath "powercfg.exe" `
            -ArgumentList @("/change", "standby-timeout-ac", "0") `
            -Description "配置 AC 睡眠"
    }
    if ($DisableHibernate -and $PSCmdlet.ShouldProcess("Windows 休眠", "禁用休眠")) {
        Invoke-NativeChecked -FilePath "powercfg.exe" -ArgumentList @("/hibernate", "off") -Description "禁用休眠"
    }
}

if ($StartNow -and $PSCmdlet.ShouldProcess($TaskName, "立即启动计划任务")) {
    if (Test-InteractiveUserSession -UserName $GuiUserName) {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "已请求立即启动 Runner。"
    }
    else {
        Write-Warning "$GuiUser 当前没有可识别的交互式会话，未立即启动；下次登录时会自动启动。"
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf 预检完成：未修改 ACL、服务、计划任务或电源设置。" -ForegroundColor Yellow
}
else {
    Write-Host "配置完成。日志目录：$LogDir" -ForegroundColor Green
}
