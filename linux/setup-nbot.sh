#!/usr/bin/env bash
#
# NBot 开机自启动配置脚本（Linux, systemd --user）
#
# 使用方式（跨机器部署）：
#   1. 把本脚本、nbot 二进制、setup-nbot.conf.example 一起复制到目标机器
#   2. cp setup-nbot.conf.example setup-nbot.conf && chmod 600 setup-nbot.conf
#   3. 编辑 setup-nbot.conf，填入本机 device_id / mid 等
#   4. ./setup-nbot.sh
#
# 本脚本会：
#   1. 读取脚本同目录的 setup-nbot.conf（可用 --config 指定其他路径）
#   2. 校验 device_id / mid 格式，避免注入畸形数据
#   3. 生成带日志的启动器 start-nbot.sh（设 device_id、执行 ./nbot start --mid=...）
#   4. 生成并启用 systemd --user 服务（登录桌面后延迟启动、异常自动重启）
#   5. 可选启用 lingering
#
# 本脚本不会：
#   - 下载或安装 NBot / 任何软件
#   - 把完整的 device_id / mid 打印到终端或日志
#
# GUI 启动链路：
#     Linux 启动 -> 用户登录桌面 -> systemd --user (graphical-session.target)
#       -> 延迟 N 秒 -> start-nbot.sh -> nbot start --mid=...

set -euo pipefail

# ---------------------------------------------------------------------------
# 内置默认值（优先级：默认值 < 配置文件 < 命令行参数）
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

CONFIG_FILE=""                      # 默认 $SCRIPT_DIR/setup-nbot.conf
GUI_USER_NAME="${USER:-$(id -un)}"

# 可由配置文件设置的值
CFG_NBOT_ROOT=""
CFG_NBOT_BIN=""
CFG_DEVICE_ID=""
CFG_MID=""
CFG_START_DELAY_SECONDS=""
CFG_LOG_RETENTION_DAYS=""
CFG_SERVICE_NAME=""
CFG_GUI_USER=""
CFG_ENABLE_LINGER=""

# 命令行覆盖值（为空表示未指定）
OPT_NBOT_ROOT=""
OPT_NBOT_BIN=""
OPT_DEVICE_ID=""
OPT_MID=""
OPT_START_DELAY_SECONDS=""
OPT_LOG_RETENTION_DAYS=""
OPT_SERVICE_NAME=""
OPT_GUI_USER=""
OPT_ENABLE_LINGER=""
OPT_APPLY=""

usage() {
    cat <<'EOF'
用法: setup-nbot.sh [选项]

常规用法（推荐）：
  cp setup-nbot.conf.example setup-nbot.conf
  chmod 600 setup-nbot.conf
  # 编辑 setup-nbot.conf 填入本机 device_id / mid
  ./setup-nbot.sh

选项（命令行值会覆盖配置文件）:
  --config PATH        配置文件路径（默认：脚本同目录/setup-nbot.conf）
  --nbot-root DIR      NBot 目录（覆盖配置 nbot_root）
  --nbot-bin PATH      nbot 可执行文件（覆盖配置 nbot_bin）
  --device-id ID       覆盖配置 device_id
  --mid MID            覆盖配置 mid
  --gui-user NAME      运行 NBot 的用户，必须是当前用户（覆盖配置 gui_user）
  --start-delay N      登录后延迟启动秒数（覆盖 start_delay_seconds，范围 0-3600）
  --log-retention N    NBot 日志保留天数（覆盖 log_retention_days）
  --service-name NAME  systemd --user 服务名（覆盖 service_name）
  --no-linger          不启用 loginctl enable-linger
  --no-apply           只生成启动脚本和 unit，不 enable/start
  -h, --help           显示帮助

说明:
  - 本脚本以“当前登录用户”身份配置 systemd --user 服务，请勿使用 sudo/root 运行。
  - device_id 与 mid 属于凭据，脚本不会将其完整打印到终端或日志。
  - 配置文件是跨机器部署的主入口；换机器只需改配置，不必改脚本。
EOF
}

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

step() { printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '\033[33m警告：%s\033[0m\n' "$1" >&2; }
die()  { echo "错误：$1" >&2; exit "${2:-2}"; }

# 打印凭据时仅显示前缀，避免泄露
mask() {
    local v="$1"
    if (( ${#v} <= 6 )); then
        printf '***'
    else
        printf '%s...(%d 字符)' "${v:0:6}" "${#v}"
    fi
}

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------

need_value() {
    if (( $# < 2 )); then
        echo "错误：$1 需要一个参数" >&2
        usage >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)        need_value "$@"; CONFIG_FILE="$2"; shift 2 ;;
        --nbot-root)     need_value "$@"; OPT_NBOT_ROOT="$2"; shift 2 ;;
        --nbot-bin)      need_value "$@"; OPT_NBOT_BIN="$2"; shift 2 ;;
        --device-id)     need_value "$@"; OPT_DEVICE_ID="$2"; shift 2 ;;
        --mid)           need_value "$@"; OPT_MID="$2"; shift 2 ;;
        --gui-user)      need_value "$@"; OPT_GUI_USER="$2"; shift 2 ;;
        --start-delay)   need_value "$@"; OPT_START_DELAY_SECONDS="$2"; shift 2 ;;
        --log-retention) need_value "$@"; OPT_LOG_RETENTION_DAYS="$2"; shift 2 ;;
        --service-name)  need_value "$@"; OPT_SERVICE_NAME="$2"; shift 2 ;;
        --no-linger)     OPT_ENABLE_LINGER=0; shift ;;
        --no-apply)      OPT_APPLY=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="$SCRIPT_DIR/setup-nbot.conf"

# ---------------------------------------------------------------------------
# 加载配置文件（严格 key=value，不使用 source/eval）
# ---------------------------------------------------------------------------

CONFIG_DIR=""

load_config() {
    local file="$1"
    local line key value trimmed lineno=0
    CONFIG_DIR="$(cd -- "$(dirname -- "$file")" &>/dev/null && pwd || echo "$SCRIPT_DIR")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        # 去掉首尾空白
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        # 跳过空行和注释
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if [[ "$trimmed" != *=* ]]; then
            die "配置文件第 $lineno 行缺少 '='：$trimmed"
        fi
        key="${trimmed%%=*}"
        value="${trimmed#*=}"
        # 去掉 key 尾部空白、value 首部空白
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        case "$key" in
            nbot_root)           CFG_NBOT_ROOT="$value" ;;
            nbot_bin)            CFG_NBOT_BIN="$value" ;;
            device_id)           CFG_DEVICE_ID="$value" ;;
            mid)                 CFG_MID="$value" ;;
            start_delay_seconds) CFG_START_DELAY_SECONDS="$value" ;;
            log_retention_days)  CFG_LOG_RETENTION_DAYS="$value" ;;
            service_name)        CFG_SERVICE_NAME="$value" ;;
            gui_user)            CFG_GUI_USER="$value" ;;
            enable_linger)       CFG_ENABLE_LINGER="$value" ;;
            *) die "配置文件第 $lineno 行含未知配置项：$key" ;;
        esac
    done <"$file"
}

if [[ -n "$OPT_DEVICE_ID" && -n "$OPT_MID" ]]; then
    # device_id 和 mid 均由命令行提供时，允许没有配置文件（便于临时调试）
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE"
        info_config_source="$CONFIG_FILE（命令行覆盖凭据）"
    else
        CONFIG_DIR="$SCRIPT_DIR"
        info_config_source="命令行参数（无配置文件）"
    fi
else
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "错误：配置文件不存在：$CONFIG_FILE" >&2
        echo "请先执行：cp setup-nbot.conf.example setup-nbot.conf && chmod 600 setup-nbot.conf" >&2
        echo "然后编辑 setup-nbot.conf 填入本机 device_id / mid。" >&2
        echo "或用 --device-id/--mid 直接指定，用 --config 指定其他配置文件。" >&2
        exit 2
    fi
    load_config "$CONFIG_FILE"
    info_config_source="$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# 合并优先级：命令行 > 配置文件 > 默认值
# ---------------------------------------------------------------------------

pick() {
    # pick <opt> <cfg> <default>
    if [[ -n "$1" ]]; then printf '%s' "$1"
    elif [[ -n "$2" ]]; then printf '%s' "$2"
    else printf '%s' "$3"; fi
}

NBOT_ROOT="$(pick "$OPT_NBOT_ROOT" "$CFG_NBOT_ROOT" ".")"
NBOT_BIN="$(pick "$OPT_NBOT_BIN" "$CFG_NBOT_BIN" "")"
DEVICE_ID="$(pick "$OPT_DEVICE_ID" "$CFG_DEVICE_ID" "")"
MID="$(pick "$OPT_MID" "$CFG_MID" "")"
START_DELAY_SECONDS="$(pick "$OPT_START_DELAY_SECONDS" "$CFG_START_DELAY_SECONDS" "60")"
LOG_RETENTION_DAYS="$(pick "$OPT_LOG_RETENTION_DAYS" "$CFG_LOG_RETENTION_DAYS" "14")"
SERVICE_NAME="$(pick "$OPT_SERVICE_NAME" "$CFG_SERVICE_NAME" "nbot")"
GUI_USER_NAME="$(pick "$OPT_GUI_USER" "$CFG_GUI_USER" "$GUI_USER_NAME")"
ENABLE_LINGER="$(pick "$OPT_ENABLE_LINGER" "$CFG_ENABLE_LINGER" "1")"
APPLY="$(pick "$OPT_APPLY" "" "1")"

# 相对路径以配置文件所在目录为基准
[[ -z "$CONFIG_DIR" ]] && CONFIG_DIR="$SCRIPT_DIR"
if [[ "$NBOT_ROOT" != /* ]]; then
    NBOT_ROOT="$CONFIG_DIR/$NBOT_ROOT"
fi

# ---------------------------------------------------------------------------
# 参数格式校验
# ---------------------------------------------------------------------------

if ! [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    die "service_name 不是有效的 systemd 服务名：$SERVICE_NAME"
fi
if ! [[ "$START_DELAY_SECONDS" =~ ^[0-9]+$ ]] || (( START_DELAY_SECONDS > 3600 )); then
    die "start_delay_seconds 需为 0-3600 的整数：$START_DELAY_SECONDS"
fi
if ! [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( LOG_RETENTION_DAYS < 1 )); then
    die "log_retention_days 需为 >=1 的整数：$LOG_RETENTION_DAYS"
fi
if ! [[ "$ENABLE_LINGER" =~ ^[01]$ ]]; then
    die "enable_linger 只能为 0 或 1：$ENABLE_LINGER"
fi
if ! [[ "$APPLY" =~ ^[01]$ ]]; then
    die "apply 内部值异常：$APPLY"
fi

if [[ ! -d "$NBOT_ROOT" ]]; then
    die "NBot 根目录不存在：$NBOT_ROOT"
fi
NBOT_ROOT="$(cd -- "$NBOT_ROOT" && pwd)"

# nbot_bin 默认取 <nbot_root>/nbot；相对路径以 nbot_root 为基准
[[ -z "$NBOT_BIN" ]] && NBOT_BIN="$NBOT_ROOT/nbot"
if [[ "$NBOT_BIN" != /* ]]; then
    NBOT_BIN="$NBOT_ROOT/$NBOT_BIN"
fi

LOG_DIR="$NBOT_ROOT/logs"
LAUNCHER="$NBOT_ROOT/start-nbot.sh"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$USER_UNIT_DIR/${SERVICE_NAME}.service"

# 生成含凭据的文件，限制默认权限
umask 077

# ---------------------------------------------------------------------------
# 0. 基础环境
# ---------------------------------------------------------------------------

if [[ "$(uname -s)" != "Linux" ]]; then
    die "本脚本仅支持 Linux。" 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
    warn "检测到以 root 运行。NBot 应以真实桌面用户身份运行。"
    warn "请改用普通登录用户执行本脚本。"
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    die "未找到 systemctl，本脚本依赖 systemd --user。"
fi

if ! id "$GUI_USER_NAME" &>/dev/null; then
    die "找不到用户 $GUI_USER_NAME" 1
fi

if [[ "$GUI_USER_NAME" != "$(id -un)" ]]; then
    echo "错误：NBot 需由 $GUI_USER_NAME 本人运行本脚本，以配置其 systemd --user 服务。" >&2
    echo "请以该用户登录桌面后重新执行，或去掉 gui_user 设置。" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 定位并检查 NBot 二进制
# ---------------------------------------------------------------------------

step "定位 NBot 二进制"

if [[ ! -f "$NBOT_BIN" ]]; then
    die "nbot 不存在：$NBOT_BIN（可用配置 nbot_bin 或 --nbot-bin 指定）"
fi

if [[ ! -x "$NBOT_BIN" ]]; then
    info "为 $NBOT_BIN 添加执行权限"
    chmod +x "$NBOT_BIN"
fi

info "NBot 二进制：$NBOT_BIN"

# ---------------------------------------------------------------------------
# 2. 校验凭据
# ---------------------------------------------------------------------------

step "校验 NBot 凭据"

info "配置来源：$info_config_source"

if [[ -z "$DEVICE_ID" ]]; then
    die "未设置 device_id（在配置文件中填写 device_id，或用 --device-id 指定）。"
fi
if [[ -z "$MID" ]]; then
    die "未设置 mid（在配置文件中填写 mid，或用 --mid 指定）。"
fi
if ! [[ "$DEVICE_ID" =~ ^[0-9a-fA-F]{32}$ ]]; then
    die "device_id 格式非法（应为 32 位十六进制字符串）。"
fi
if ! [[ "$MID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "mid 格式非法（应为 URL-safe base64 字符集 A-Za-z0-9_-）。"
fi

info "device_id：$(mask "$DEVICE_ID")"
info "mid：$(mask "$MID")"

# ---------------------------------------------------------------------------
# 3. 日志目录
# ---------------------------------------------------------------------------

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# 4. 生成日志包装启动脚本
# ---------------------------------------------------------------------------

step "生成 NBot 启动脚本"

# 以 shell 字面量形式写入生成脚本，支持路径中的空格并避免重新解释特殊字符。
shell_quote() {
    printf '%q' "$1"
}

NBOT_BIN_LITERAL="$(shell_quote "$NBOT_BIN")"
NBOT_ROOT_LITERAL="$(shell_quote "$NBOT_ROOT")"
LOG_DIR_LITERAL="$(shell_quote "$LOG_DIR")"
DEVICE_ID_LITERAL="$(shell_quote "$DEVICE_ID")"
MID_LITERAL="$(shell_quote "$MID")"

cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
# 由 setup-nbot.sh 生成，请勿手动编辑。
# 本文件包含 device_id 与 mid 凭据，权限应为 700。
set -uo pipefail

# NBot 自身的输出可能包含完整 mid/token，日志必须仅当前用户可读。
umask 077

NBOT_BIN=$NBOT_BIN_LITERAL
NBOT_ROOT=$NBOT_ROOT_LITERAL
LOG_DIR=$LOG_DIR_LITERAL
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS
DEVICE_ID=$DEVICE_ID_LITERAL
MID=$MID_LITERAL

mkdir -p "\$LOG_DIR"
chmod 700 "\$LOG_DIR" 2>/dev/null || true

# 清理过期日志
find "\$LOG_DIR" -type f -name 'nbot-*.log' \\
    -mtime +"\$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

LOG_FILE="\$LOG_DIR/nbot-\$(date +%Y%m%d-%H%M%S).log"
exec >>"\$LOG_FILE" 2>&1

log() { printf '[%s] %s\n' "\$(date '+%Y-%m-%d %H:%M:%S.%3N')" "\$1"; }

# 仅显示凭据前缀，避免写入完整值
mask() {
    local v="\$1"
    if (( \${#v} <= 6 )); then printf '***'; else printf '%s...(%d)' "\${v:0:6}" "\${#v}"; fi
}

log "============================================================"
log "NBot starting"
log "============================================================"
log "Host        : \$(hostname)"
log "User        : \$(id -un)"
log "ProcessId   : \$\$"
log "NBotBin     : \$NBOT_BIN"
log "WorkingDir  : \$NBOT_ROOT"
log "DeviceId    : \$(mask "\$DEVICE_ID")"
log "Mid         : \$(mask "\$MID")"
log "DISPLAY     : \${DISPLAY:-<unset>}"
log "WAYLAND     : \${WAYLAND_DISPLAY:-<unset>}"
log "XDG_RUNTIME : \${XDG_RUNTIME_DIR:-<unset>}"
log "DBUS        : \${DBUS_SESSION_BUS_ADDRESS:-<unset>}"
log "PATH        : \$PATH"

if [[ ! -x "\$NBOT_BIN" ]]; then
    log "ERROR: nbot 不可执行：\$NBOT_BIN"
    exit 10
fi

export device_id="\$DEVICE_ID"
cd "\$NBOT_ROOT"
log "Starting nbot start --mid=***"

"\$NBOT_BIN" start "--mid=\$MID" 2>&1 \\
    | while IFS= read -r line; do log "\$line"; done

exit_code=\${PIPESTATUS[0]}
log "nbot exited. ExitCode=\$exit_code"
exit "\$exit_code"
EOF

chmod 700 "$LAUNCHER"
info "启动脚本：$LAUNCHER（权限 700，含凭据）"

# ---------------------------------------------------------------------------
# 5. 生成 systemd --user unit
# ---------------------------------------------------------------------------

step "生成 systemd --user 服务"

mkdir -p "$USER_UNIT_DIR"

systemd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value// /\\x20}"
    value="${value//$'\t'/\\x09}"
    value="${value//$'\n'/\\x0a}"
    printf '%s' "$value"
}

NBOT_ROOT_UNIT="$(systemd_quote "$NBOT_ROOT")"
LAUNCHER_UNIT="$(systemd_quote "$LAUNCHER")"

cat >"$UNIT_FILE" <<EOF
[Unit]
Description=NBot (login delay ${START_DELAY_SECONDS}s, user desktop session)
After=graphical-session.target
PartOf=graphical-session.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$NBOT_ROOT_UNIT
ExecStartPre=/bin/sleep $START_DELAY_SECONDS
ExecStart=$LAUNCHER_UNIT
Restart=always
RestartSec=60
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF

chmod 644 "$UNIT_FILE"
info "systemd unit：$UNIT_FILE"
info "登录后延迟：$START_DELAY_SECONDS 秒"

# ---------------------------------------------------------------------------
# 6. lingering（登录后可靠拉起）
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
# 7. 应用配置
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
# 8. 最终状态
# ---------------------------------------------------------------------------

cat <<EOF

============================================================
 NBot 开机自启动配置完成
============================================================

用户       : $(id -un)
配置       : $CONFIG_FILE
NBot       : $NBOT_BIN
Launcher   : $LAUNCHER
Logs       : $LOG_DIR
Unit       : $UNIT_FILE
Service    : ${SERVICE_NAME}.service
延迟       : ${START_DELAY_SECONDS} 秒

启动链路：
  Linux 开机
      ↓
  $(id -un) 登录桌面
      ↓
  systemd --user (graphical-session.target)
      ↓
  等待 ${START_DELAY_SECONDS} 秒
      ↓
  start-nbot.sh
      ↓
  nbot start --mid=***

常用命令：
  查看状态：  systemctl --user status ${SERVICE_NAME}.service
  实时日志：  journalctl --user -u ${SERVICE_NAME}.service -f
  文件日志：  tail -f "\$(ls -t $LOG_DIR/nbot-*.log | head -1)"
  重启服务：  systemctl --user restart ${SERVICE_NAME}.service
  停用服务：  systemctl --user disable --now ${SERVICE_NAME}.service

卸载：
  systemctl --user disable --now ${SERVICE_NAME}.service
  rm -f "$UNIT_FILE" "$LAUNCHER"
  systemctl --user daemon-reload

换机器部署：
  复制 setup-nbot.sh、nbot、setup-nbot.conf.example 到新机器，
  cp setup-nbot.conf.example setup-nbot.conf 并编辑，再执行 ./setup-nbot.sh。

注意：
  NBot 服务需要真实登录的桌面 Session（本机检测到 DISPLAY）。
  start-nbot.sh 含 device_id/mid 凭据，权限为 700，请勿改为组/其他可读。
EOF
