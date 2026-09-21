#!/usr/bin/env bash
#
# Linux GUI CI - GitLab Runner systemd --user 配置脚本（检查型，不负责安装软件）
#
# 适用场景：
#   - Linux GUI 自动化测试机
#   - GitLab Runner 使用 Shell Executor
#   - git / gitlab-runner / 项目所需命令均已预先安装
#   - Runner 需要运行在真实登录用户的桌面 Session 中（X11 / Wayland）
#
# 本脚本不会：
#   - 下载或安装 GitLab Runner
#   - 下载或安装 Git / Node / pnpm / Python 等软件
#   - 注册新的 GitLab Runner
#   - 修改 PATH
#   - 复制或生成任何 Runner token
#
# 本脚本会：
#   1. 检查是否为 Linux、当前用户与 systemd --user 可用性
#   2. 检查 gitlab-runner 二进制 / config.toml
#   3. 检查指定命令是否可执行；缺失时仅提示并终止，不自动处理
#   4. 创建日志目录
#   5. 生成带日志的 Runner 启动脚本
#   6. 检查并处理旧的 gitlab-runner system 级服务
#   7. 生成并启用 systemd --user 服务（graphical-session 之后启动）
#   8. Runner 异常退出后由 systemd 自动重启
#   9. 可选启用 lingering，使服务在登录后可靠拉起
#  10. 可选启用睡眠抑制，适合 GUI CI
#
# GUI Runner 正确启动链路：
#     Linux 启动
#       -> GUI 用户登录桌面
#       -> systemd --user (graphical-session.target)
#       -> start-gitlab-runner.sh
#       -> gitlab-runner run
#       -> Shell Executor
#       -> GUI 测试

set -euo pipefail

# ---------------------------------------------------------------------------
# 默认参数（可用命令行覆盖，见 --help）
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RUNNER_ROOT="$SCRIPT_DIR"
GUI_USER_NAME="${USER:-$(id -un)}"
RUNNER_BIN=""                       # 默认自动探测，见下方
CONFIG_FILE=""                      # 默认 $RUNNER_ROOT/config.toml
START_DELAY_SECONDS=60
LOG_RETENTION_DAYS=14
REQUIRED_COMMANDS=("git")
DISABLE_EXISTING_SYSTEM_SERVICE=1   # 1=停止并禁用 system 级 gitlab-runner
ENABLE_LINGER=1                     # 1=开启 loginctl enable-linger
INHIBIT_SLEEP=1                     # 1=用 systemd-inhibit 抑制睡眠
SERVICE_NAME="gitlab-runner-gui"
APPLY=1                             # 0=只生成文件，不 enable/start

usage() {
    cat <<'EOF'
用法: setup-gitlab-gui-runner.sh [选项]

选项:
  --gui-user NAME          GUI 测试用户，必须是当前执行脚本的用户（默认：当前用户）
  --runner-root DIR        Runner 根目录（默认：脚本所在目录）
  --runner-bin PATH        gitlab-runner 可执行文件（默认：自动探测）
  --config PATH            config.toml 路径（默认：<runner-root>/config.toml）
  --start-delay N          登录后延迟启动秒数（默认：60）
  --log-retention N        Runner 日志保留天数（默认：14）
  --require "a b c"        除 gitlab-runner 外还需检查的命令（空格分隔）
  --service-name NAME      systemd --user 服务名（默认：gitlab-runner-gui）
  --keep-system-service    不停止/禁用已有的 system 级 gitlab-runner
  --no-linger              不启用 loginctl enable-linger
  --no-inhibit-sleep       不使用 systemd-inhibit 抑制睡眠
  --no-apply               只生成启动脚本和 unit，不 enable/start
  -h, --help               显示帮助

说明:
  - 本脚本以“当前登录用户”身份配置 systemd --user 服务，请勿使用 sudo/root 运行。
  - 处理 system 级旧服务需要 sudo，脚本会在需要时单独调用 sudo。
  - 不会下载、安装软件，也不会注册 Runner 或写入 token。
EOF
}

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gui-user)      GUI_USER_NAME="$2"; shift 2 ;;
        --runner-root)   RUNNER_ROOT="$2"; shift 2 ;;
        --runner-bin)    RUNNER_BIN="$2"; shift 2 ;;
        --config)        CONFIG_FILE="$2"; shift 2 ;;
        --start-delay)   START_DELAY_SECONDS="$2"; shift 2 ;;
        --log-retention) LOG_RETENTION_DAYS="$2"; shift 2 ;;
        --require)       read -r -a REQUIRED_COMMANDS <<<"$2"; shift 2 ;;
        --service-name)  SERVICE_NAME="$2"; shift 2 ;;
        --keep-system-service) DISABLE_EXISTING_SYSTEM_SERVICE=0; shift ;;
        --no-linger)     ENABLE_LINGER=0; shift ;;
        --no-inhibit-sleep) INHIBIT_SLEEP=0; shift ;;
        --no-apply)      APPLY=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

RUNNER_ROOT="$(cd -- "$RUNNER_ROOT" &>/dev/null && pwd || echo "$RUNNER_ROOT")"
[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="$RUNNER_ROOT/config.toml"

LOG_DIR="$RUNNER_ROOT/logs"
LAUNCHER="$RUNNER_ROOT/start-gitlab-runner.sh"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$USER_UNIT_DIR/${SERVICE_NAME}.service"

# ---------------------------------------------------------------------------
# 数字参数校验
# ---------------------------------------------------------------------------

if ! [[ "$START_DELAY_SECONDS" =~ ^[0-9]+$ ]] || (( START_DELAY_SECONDS > 3600 )); then
    echo "错误：--start-delay 需为 0-3600 的整数" >&2
    exit 2
fi

if ! [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( LOG_RETENTION_DAYS < 1 )); then
    echo "错误：--log-retention 需为 >=1 的整数" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

step() { printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '\033[33m警告：%s\033[0m\n' "$1" >&2; }

stop_missing() {
    printf '\n\033[31m============================================================\033[0m\n' >&2
    printf '\033[31m 环境检查未通过，未创建/修改 systemd 服务\033[0m\n' >&2
    printf '\033[31m============================================================\033[0m\n' >&2
    printf '\n缺少以下程序或文件：\n' >&2
    local item
    for item in "$@"; do
        printf '  - %s\n' "$item" >&2
    done
    printf '\n请先准备好上述环境后重新运行本脚本。\n' >&2
    printf '脚本不会自动下载、安装软件，也不会修改 PATH。\n\n' >&2
    exit 2
}

# ---------------------------------------------------------------------------
# 0. 基础环境
# ---------------------------------------------------------------------------

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "错误：本脚本仅支持 Linux。" >&2
    exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
    warn "检测到以 root 运行。GUI Runner 应以真实桌面用户身份运行。"
    warn "请改用普通登录用户执行本脚本（处理 system 服务时会单独调用 sudo）。"
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    stop_missing "systemctl（本脚本依赖 systemd --user）"
fi

if ! id "$GUI_USER_NAME" &>/dev/null; then
    echo "错误：找不到用户 $GUI_USER_NAME" >&2
    exit 1
fi

if [[ "$GUI_USER_NAME" != "$(id -un)" ]]; then
    echo "错误：GUI Runner 需由 $GUI_USER_NAME 本人运行本脚本，以配置其 systemd --user 服务。" >&2
    echo "请以该用户登录桌面后重新执行，或去掉 --gui-user。" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 探测 Runner 二进制
# ---------------------------------------------------------------------------

step "定位 GitLab Runner 二进制"

if [[ -z "$RUNNER_BIN" ]]; then
    for candidate in \
        "$RUNNER_ROOT/gitlab-runner" \
        "$RUNNER_ROOT/gitlab-runner-linux-amd64" \
        "$(command -v gitlab-runner 2>/dev/null || true)"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            RUNNER_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$RUNNER_BIN" || ! -f "$RUNNER_BIN" ]]; then
    stop_missing "gitlab-runner 二进制（在 $RUNNER_ROOT 未找到，可用 --runner-bin 指定）"
fi

if [[ ! -x "$RUNNER_BIN" ]]; then
    info "为 $RUNNER_BIN 添加执行权限"
    chmod +x "$RUNNER_BIN"
fi

info "Runner 二进制：$RUNNER_BIN"

# ---------------------------------------------------------------------------
# 2. 日志目录
# ---------------------------------------------------------------------------

if [[ ! -d "$RUNNER_ROOT" ]]; then
    stop_missing "$RUNNER_ROOT（Runner 根目录不存在）"
fi

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# 3. 检查配置与依赖命令，只检查不安装
# ---------------------------------------------------------------------------

step "检查 Runner 配置与项目执行程序"

missing=()

if [[ ! -f "$CONFIG_FILE" ]]; then
    missing+=("$CONFIG_FILE")
else
    info "Runner Config：$CONFIG_FILE"
fi

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    [[ -z "$cmd" ]] && continue
    if src="$(command -v "$cmd" 2>/dev/null)"; then
        info "$cmd -> $src"
    else
        missing+=("命令：$cmd")
    fi
done

if (( ${#missing[@]} > 0 )); then
    stop_missing "${missing[@]}"
fi

# Runner 自身能否执行
if ! runner_version="$("$RUNNER_BIN" --version 2>&1)"; then
    stop_missing "$RUNNER_BIN 存在，但无法正常执行：$runner_version"
fi
info "gitlab-runner 可正常执行"

# config.toml 至少包含一个 runner
if ! grep -q '\[\[runners\]\]' "$CONFIG_FILE"; then
    stop_missing "$CONFIG_FILE 存在，但没有检测到 [[runners]] 配置"
fi

# GUI 测试建议 Shell Executor
if ! grep -Eq '^[[:space:]]*executor[[:space:]]*=[[:space:]]*"shell"' "$CONFIG_FILE"; then
    warn "config.toml 未检测到 executor = \"shell\"。GUI 自动化测试建议使用 Shell Executor，脚本不会自动修改。"
fi

# Linux 上不应使用 Windows 的 pwsh 作为默认 shell
if grep -Eq '^[[:space:]]*shell[[:space:]]*=[[:space:]]*"pwsh"' "$CONFIG_FILE"; then
    warn "config.toml 使用 shell = \"pwsh\"，这是 Windows 取向。Linux Shell Executor 建议改为 bash 或删除该字段。"
fi

# ---------------------------------------------------------------------------
# 4. 处理 system 级旧服务
# ---------------------------------------------------------------------------

step "检查 system 级 gitlab-runner 服务"

if systemctl list-unit-files 2>/dev/null | grep '^gitlab-runner\.service' >/dev/null; then
    if (( DISABLE_EXISTING_SYSTEM_SERVICE )); then
        warn "检测到 system 级 gitlab-runner.service，将尝试用 sudo 停止并禁用（避免与 GUI Runner 重复运行）。"
        if sudo systemctl disable --now gitlab-runner.service 2>/dev/null; then
            info "system 级 gitlab-runner.service 已停止并禁用"
        else
            warn "无法自动处理 system 级 gitlab-runner.service，请手动执行：sudo systemctl disable --now gitlab-runner.service"
        fi
    else
        warn "检测到 system 级 gitlab-runner.service，但 --keep-system-service 已指定，未修改。注意可能出现两个 Runner 进程。"
    fi
else
    info "未检测到 system 级 gitlab-runner.service"
fi

# ---------------------------------------------------------------------------
# 5. 生成日志包装启动脚本
# ---------------------------------------------------------------------------

step "生成 Runner 日志启动脚本"

cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
# 由 setup-gitlab-gui-runner.sh 生成，请勿手动编辑。
set -uo pipefail

RUNNER_BIN="$RUNNER_BIN"
CONFIG_FILE="$CONFIG_FILE"
RUNNER_ROOT="$RUNNER_ROOT"
LOG_DIR="$LOG_DIR"
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS
INHIBIT_SLEEP=$INHIBIT_SLEEP

mkdir -p "\$LOG_DIR"

# 清理过期日志
find "\$LOG_DIR" -type f -name 'runner-*.log' \\
    -mtime +"\$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

LOG_FILE="\$LOG_DIR/runner-\$(date +%Y%m%d-%H%M%S).log"
exec >>"\$LOG_FILE" 2>&1

log() { printf '[%s] %s\n' "\$(date '+%Y-%m-%d %H:%M:%S.%3N')" "\$1"; }

log "============================================================"
log "GitLab Runner GUI starting"
log "============================================================"
log "Host        : \$(hostname)"
log "User        : \$(id -un)"
log "ProcessId   : \$\$"
log "RunnerBin   : \$RUNNER_BIN"
log "ConfigFile  : \$CONFIG_FILE"
log "WorkingDir  : \$RUNNER_ROOT"
log "DISPLAY     : \${DISPLAY:-<unset>}"
log "WAYLAND     : \${WAYLAND_DISPLAY:-<unset>}"
log "XDG_RUNTIME : \${XDG_RUNTIME_DIR:-<unset>}"
log "DBUS        : \${DBUS_SESSION_BUS_ADDRESS:-<unset>}"
log "PATH        : \$PATH"
log "---------- gitlab-runner version ----------"
"\$RUNNER_BIN" --version 2>&1 | while IFS= read -r line; do log "\$line"; done

if [[ ! -x "\$RUNNER_BIN" ]]; then
    log "ERROR: gitlab-runner 不可执行：\$RUNNER_BIN"
    exit 10
fi
if [[ ! -f "\$CONFIG_FILE" ]]; then
    log "ERROR: config.toml 不存在：\$CONFIG_FILE"
    exit 11
fi

cd "\$RUNNER_ROOT"
log "Starting gitlab-runner run"

run_runner() {
    if [[ "\$INHIBIT_SLEEP" == "1" ]] && command -v systemd-inhibit &>/dev/null &&
        { [[ -n "\${DBUS_SESSION_BUS_ADDRESS:-}" ]] || [[ -S "\${XDG_RUNTIME_DIR:-}/bus" ]]; }; then
        systemd-inhibit \\
            --what=idle:sleep \\
            --why='GitLab GUI CI is running' \\
            --mode=block \\
            "\$RUNNER_BIN" run --config "\$CONFIG_FILE"
    else
        "\$RUNNER_BIN" run --config "\$CONFIG_FILE"
    fi
}

run_runner 2>&1 \\
    | while IFS= read -r line; do log "\$line"; done

exit_code=\${PIPESTATUS[0]}
log "gitlab-runner exited. ExitCode=\$exit_code"
exit "\$exit_code"
EOF

chmod +x "$LAUNCHER"
info "启动脚本：$LAUNCHER"

# ---------------------------------------------------------------------------
# 6. 生成 systemd --user unit
# ---------------------------------------------------------------------------

step "生成 systemd --user 服务"

mkdir -p "$USER_UNIT_DIR"

cat >"$UNIT_FILE" <<EOF
[Unit]
Description=GitLab Runner GUI CI (Shell Executor, interactive desktop session)
After=graphical-session.target
PartOf=graphical-session.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$RUNNER_ROOT
ExecStartPre=/bin/sleep $START_DELAY_SECONDS
ExecStart=$LAUNCHER
Restart=on-failure
RestartSec=60
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF

info "systemd unit：$UNIT_FILE"
info "登录后延迟：$START_DELAY_SECONDS 秒"

# ---------------------------------------------------------------------------
# 7. lingering（登录后可靠拉起）
# ---------------------------------------------------------------------------

if (( ENABLE_LINGER )); then
    step "启用 loginctl lingering"
    if loginctl enable-linger "$(id -un)" 2>/dev/null; then
        info "已为 $(id -un) 启用 lingering"
    else
        warn "无法启用 lingering，可手动执行：sudo loginctl enable-linger $(id -un)"
    fi
fi

# ---------------------------------------------------------------------------
# 8. 应用配置
# ---------------------------------------------------------------------------

if (( APPLY )); then
    step "启用并启动 systemd --user 服务"
    systemctl --user daemon-reload
    systemctl --user enable "${SERVICE_NAME}.service"
    systemctl --user restart "${SERVICE_NAME}.service"
    info "服务已启用并启动：${SERVICE_NAME}.service"
else
    step "已生成文件（--no-apply，未 enable/start）"
    info "手动应用：systemctl --user daemon-reload && systemctl --user enable --now ${SERVICE_NAME}.service"
fi

# ---------------------------------------------------------------------------
# 9. 最终状态
# ---------------------------------------------------------------------------

cat <<EOF

============================================================
 GitLab Runner GUI (Linux) 配置完成
============================================================

用户       : $(id -un)
Runner     : $RUNNER_BIN
Config     : $CONFIG_FILE
Launcher   : $LAUNCHER
Logs       : $LOG_DIR
Unit       : $UNIT_FILE
Service    : ${SERVICE_NAME}.service

启动链路：
  Linux 开机
      ↓
  $(id -un) 登录桌面
      ↓
  systemd --user (graphical-session.target)
      ↓
  等待 ${START_DELAY_SECONDS} 秒
      ↓
  start-gitlab-runner.sh
      ↓
  gitlab-runner run
      ↓
  Shell Executor / GUI CI

常用命令：
  查看状态：  systemctl --user status ${SERVICE_NAME}.service
  实时日志：  journalctl --user -u ${SERVICE_NAME}.service -f
  文件日志：  tail -f "\$(ls -t $LOG_DIR/runner-*.log | head -1)"
  重启服务：  systemctl --user restart ${SERVICE_NAME}.service
  停用服务：  systemctl --user disable --now ${SERVICE_NAME}.service

注意：
  GUI Runner 必须有真实登录的桌面 Session（X11/Wayland）。
  本脚本不会自动安装、下载或修复任何执行程序。
  Linux Runner 请使用独立的 Runner 注册与 tags，勿复用 Windows Runner 身份。
EOF
