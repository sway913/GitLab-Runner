# Linux GUI GitLab Runner + NBot 自启动

此目录提供两套 Linux amd64 的开机自启动配置，均使用用户级 `systemd --user` 管理生命周期（对应各自的 Windows 版脚本）：

- **GitLab Runner**：GUI/Shell Executor 的 CI Runner。
- **NBot**：桌面 Session 下常驻运行的 nbot 客户端。

两套都不使用独立的 `.service` 模板文件——真正的 unit 由各自的 `setup-*.sh` 脚本按本机路径**动态生成**到 `~/.config/systemd/user/`，避免模板与脚本内容漂移。

## 文件

GitLab Runner：

- `gitlab-runner-linux-amd64`：Linux amd64 Runner 二进制；不进入仓库，部署时放入本目录。
- `setup-gitlab-gui-runner.sh`：一次性/幂等配置入口（生成 unit 并 enable/start）。
- `start-gitlab-runner.sh`：由 setup 动态生成，不进入仓库；负责日志、清理和退出码透传。
- `config.toml.example`：不含凭据的 Linux 配置示例。

NBot：

- `nbot`：nbot 二进制；不进入仓库，部署时放入本目录。
- `setup-nbot.sh`：配置文件驱动的自启动配置入口（生成 launcher + unit 并 enable/start）。
- `start-nbot.sh`：由 `setup-nbot.sh` 生成的启动包装脚本，含 device_id/mid 凭据，权限 700。
- `setup-nbot.conf.example`：不含凭据的 NBot 配置示例。

公共：

- `logs/`：两套脚本的运行日志（权限 700，仅当前用户可读）。

## 前置条件

1. Linux amd64 主机。
2. 当前用户已登录图形桌面；GUI 相关能力需要 X11 或 Wayland 的真实用户 Session。
3. 当前用户有可用的 `systemd --user` 会话，且以该用户本人（非 sudo/root）执行 setup 脚本。

---

## GitLab Runner

### 配置

先准备 Linux 专用配置，不要把 token 写入脚本：

```bash
cp config.toml.example /path/to/runner/config.toml
chmod 600 /path/to/runner/config.toml
```

`config.toml` 应包含在 GitLab 注册 Linux Runner 后得到的独立身份、tags 和 token。不要复用 Windows Runner 的 ID、token 或名称，也不要复用 `shell = "pwsh"`（Linux 应用 `bash` 或省略）。

### 安装/启用

```bash
cd /path/to/linux
chmod +x setup-gitlab-gui-runner.sh gitlab-runner-linux-amd64
./setup-gitlab-gui-runner.sh \
  --runner-root "$PWD" \
  --config "$PWD/config.toml" \
  --require "git"
```

> `--gui-user` 默认当前用户；必须由该用户本人运行以配置其 `systemd --user` 服务，不要用 sudo/root。

脚本默认：以当前非 root 用户配置 `systemd --user`；登录后延迟 60 秒启动；异常退出后 60 秒自动重启；清理超过 14 天的 `logs/runner-*.log`；用 `systemd-inhibit` 阻止 CI 运行时自动睡眠；尝试停止/禁用同机已有的 system 级 `gitlab-runner.service`。

常用变体：

```bash
./setup-gitlab-gui-runner.sh --no-apply               # 只生成文件，不 enable/start
./setup-gitlab-gui-runner.sh --keep-system-service --no-linger
sudo loginctl enable-linger "$USER"                   # 脚本无法自动启用 lingering 时手动执行
```

### 服务管理

```bash
systemctl --user status gitlab-runner-gui.service
systemctl --user restart gitlab-runner-gui.service
systemctl --user disable --now gitlab-runner-gui.service
journalctl --user -u gitlab-runner-gui.service -f
tail -f "$(ls -t logs/runner-*.log | head -1)"
```

### 卸载

```bash
systemctl --user disable --now gitlab-runner-gui.service
rm -f "$HOME/.config/systemd/user/gitlab-runner-gui.service"
systemctl --user daemon-reload
```

---

## NBot

配置由脚本同目录的 `setup-nbot.conf` 驱动，跨机器部署时**只改配置、不改脚本**。

### 配置

```bash
cp setup-nbot.conf.example setup-nbot.conf
chmod 600 setup-nbot.conf
# 编辑 setup-nbot.conf，填入本机 device_id / mid
```

配置项（`key=value`，`#` 为注释）：`nbot_root`、`nbot_bin`（相对路径相对于配置文件目录）、`device_id`（32 位十六进制）、`mid`（URL-safe base64）、`start_delay_seconds`、`log_retention_days`、`service_name`、`enable_linger`、`gui_user`。脚本不 `source` 该文件，仅按白名单解析，无注入风险。

### 安装/启用

```bash
chmod +x setup-nbot.sh
./setup-nbot.sh
```

命令行参数可临时覆盖配置（`--device-id`、`--mid`、`--config`、`--start-delay`、`--no-apply`、`--no-linger` 等，见 `./setup-nbot.sh --help`）。优先级：内置默认 < 配置文件 < 命令行。

脚本会：校验凭据格式 → 生成 `start-nbot.sh`（权限 700，含凭据）→ 生成并 enable/start `systemd --user` unit（登录后延迟启动、异常自动重启）→ 可选启用 lingering。凭据不会被完整打印到终端。

> 注意：nbot 自身的输出可能包含完整 mid/token，日志文件因此仅当前用户可读（`logs/` 目录与 `nbot-*.log` 均为 700/600）。

### 服务管理

```bash
systemctl --user status nbot.service
systemctl --user restart nbot.service
systemctl --user disable --now nbot.service
journalctl --user -u nbot.service -f
tail -f "$(ls -t logs/nbot-*.log | head -1)"
```

### 卸载

```bash
systemctl --user disable --now nbot.service
rm -f "$HOME/.config/systemd/user/nbot.service" start-nbot.sh
systemctl --user daemon-reload
```

### 换机器部署

复制 `setup-nbot.sh`、`nbot`、`setup-nbot.conf.example` 到新机器，`cp setup-nbot.conf.example setup-nbot.conf` 并编辑，再执行 `./setup-nbot.sh` 即可。

---

## GUI 环境排查

两套服务都必须由实际登录桌面的用户运行。启动日志会记录以下变量，可据此排查：

```text
DISPLAY
WAYLAND_DISPLAY
XDG_RUNTIME_DIR
DBUS_SESSION_BUS_ADDRESS
```

不要改成 root system service，否则通常无法访问桌面、D-Bus 或 Wayland Socket。若测试不需要真实桌面，可改用 Xvfb（与本目录的真实交互式 GUI Session 模式不同）。

卸载 unit 不会删除配置、日志或二进制，确认不再需要后再手动处理。
