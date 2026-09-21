# Windows GUI GitLab Runner

本目录用于在真实 Windows 用户桌面会话中运行 GitLab Runner 和 NBot。两者均使用“用户登录触发 + Interactive + Limited”计划任务；不要改成 Windows Service，否则 GUI 自动化通常无法访问真实桌面。

## 文件

- `gitlab-runner.exe`、`nbot.exe`：部署时放入本目录的本机二进制，不进入仓库。
- `setup-gitlab-gui-runner.ps1`：检查 Runner 并注册 Interactive 计划任务。
- `start-gitlab-runner.ps1`：Runner 稳定启动器，负责日志、清理和退出码透传。
- `config.toml.example`：无凭据 Runner 配置样例；正式文件为 `config.toml`。
- `setup-nbot.ps1`：校验 NBot 配置、收紧 ACL 并注册计划任务。
- `start-nbot.ps1`：NBot 启动器，运行时读取受 ACL 保护的正式配置。
- `setup-nbot.conf.example`：无凭据配置样例；正式文件为 `setup-nbot.conf`。

## GitLab Runner

必须为 Windows 平台单独注册 Runner。Windows 与 Linux 不应复用同一个 Runner ID、token 或平台 tags。

先做无修改预检：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd C:\GitLab-Runner
.\setup-gitlab-gui-runner.ps1 -WhatIf
```

确认无误后，以管理员 PowerShell 应用：

```powershell
.\setup-gitlab-gui-runner.ps1
```

未指定 `-GuiUserName` 时，脚本默认使用当前 PowerShell 用户；如需为其他本机用户注册任务，再显式传入该参数。

默认行为：登录后延迟 60 秒启动；异常退出后 1 分钟重启；只允许一个任务实例；关闭当前电源方案的 AC 睡眠。脚本不会修改显示器超时，也不会默认关闭休眠。专用 CI 机器需要关闭休眠时显式使用 `-DisableHibernate`。

计划任务启动器固定使用系统自带的 Windows PowerShell 5.1，避免引用执行 setup 的管理员账户私有运行时。若 `config.toml` 使用 `shell = "pwsh"`，目标 GUI 用户还必须能使用 PowerShell 7；目标用户与 setup 用户不同时，脚本要求机器级安装位于 `C:\Program Files\PowerShell\7\pwsh.exe`。

如目标用户已经登录，可增加 `-StartNow`。脚本只有确认存在目标用户的交互式会话后才会立即启动。

## NBot

旧 DeviceId/MID 不再使用。获得重新签发的凭据后：

```powershell
Copy-Item .\setup-nbot.conf.example .\setup-nbot.conf
notepad .\setup-nbot.conf
.\setup-nbot.ps1 -WhatIf
.\setup-nbot.ps1
```

`setup-nbot.conf` 使用严格的 `key=value` 格式；脚本不会执行配置内容。`gui_user` 为可选项，留空时默认使用运行 setup 脚本的当前 Windows 用户。应用时会将配置、启动器和 NBot 日志 ACL 限制为目标 GUI 用户、SYSTEM 和本机 Administrators。

NBot 当前接口要求通过 `--mid` 启动，因此 MID 在进程运行期间仍可能被具有进程检查权限的管理员看到；它不会出现在计划任务参数、源码或普通日志中。

## 运维

```powershell
# 立即启动
Start-ScheduledTask -TaskName "GitLab Runner GUI"
Start-ScheduledTask -TaskName "NBot"

# 查看状态与最近结果
Get-ScheduledTask -TaskName "GitLab Runner GUI", "NBot"
Get-ScheduledTaskInfo -TaskName "GitLab Runner GUI"

# 查看最新日志
$log = Get-ChildItem C:\GitLab-Runner\logs\runner-*.log |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $log.FullName -Wait

# 停止并卸载任务
Stop-ScheduledTask -TaskName "GitLab Runner GUI" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "GitLab Runner GUI" -Confirm:$false
Stop-ScheduledTask -TaskName "NBot" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "NBot" -Confirm:$false
```

Runner 任务运行用户只有 `logs`、`builds` 和 `cache` 的修改权限；Runner 配置和启动器仅可读。重跑 setup 脚本是幂等操作：它会先停止并确认旧任务退出，避免留下重复进程。

更新任务时会在内存中备份旧任务 XML 和旧 Windows Service 状态；新任务注册或回读失败时，脚本会尝试恢复旧任务、原启动状态和 Service 配置。

## 常见问题

- 任务存在但 GUI 测试失败：确认目标用户实际登录，而不是只有锁屏前的失效会话。
- Runner 不接任务：确认 GitLab 远端 tags 属于 Windows Runner，且没有与 Linux 共用 Runner 身份。
- 任务持续重启：检查 `logs` 中最新日志和 `Get-ScheduledTaskInfo` 的 `LastTaskResult`。
- `-WhatIf` 不会修改 ACL、服务、任务或电源设置，可用于普通权限下的预检。
