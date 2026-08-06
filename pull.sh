#!/usr/bin/env bash
# pull.sh — her_fly 唯一启动入口（镜像内）
# 职责：探测存储源 → 拉取引导脚本 scripts/ → 分发运行位 → 调用 state-restore.sh 恢复业务数据 → 交接 entrypoint
# 说明：业务数据恢复逻辑在 S3 的 state-restore.sh（可随时修改，重启即生效，无需改本文件/重建镜像）。
set -Eeuo pipefail

log() { printf '[pull] %s\n' "$*"; }
die() { printf '[pull] FATAL: %s\n' "$*" >&2; exit 1; }

# ── 1. 存储凭据 env 映射（与旧 entrypoint 一致；CC 注入 CELLAR_* 或 S3_*）──
export S3_ENDPOINT="${S3_ENDPOINT:-${CELLAR_ADDON_HOST:-}}"
export S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-${CELLAR_ADDON_KEY_ID:-}}"
export S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-${CELLAR_ADDON_KEY_SECRET:-}}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_PREFIX="${S3_PREFIX:-hermes-prod}"

[[ -n "$S3_ENDPOINT" ]] || die "缺少 S3_ENDPOINT（或 CELLAR_ADDON_HOST）"
[[ -n "$S3_ACCESS_KEY_ID" ]] || die "缺少 S3_ACCESS_KEY_ID"
[[ -n "$S3_SECRET_ACCESS_KEY" ]] || die "缺少 S3_SECRET_ACCESS_KEY"

case "$S3_ENDPOINT" in
  http://*|https://*) ;;
  *) export S3_ENDPOINT="https://${S3_ENDPOINT}" ;;
esac

export RCLONE_CONFIG_BACKUP_TYPE=s3
export RCLONE_CONFIG_BACKUP_PROVIDER=Other
export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_BACKUP_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_BACKUP_REGION="$S3_REGION"
export RCLONE_CONFIG_BACKUP_FORCE_PATH_STYLE=true
export RCLONE_CONFIG_BACKUP_ACL=private

RCLONE="${RCLONE:-/usr/local/bin/rclone}"
export RCLONE
STATE_SRC="backup:${S3_BUCKET}/${S3_PREFIX}/state"
R2_STATE_SRC="r2:${R2_S3_BUCKET:-$S3_BUCKET}/${R2_S3_PREFIX:-$S3_PREFIX}/state"

# ── 2. 探测 S3；真空/不可用则切 R2（R2 凭据由 CC 注入 RCLONE_CONFIG_R2_*）──
SOURCE=""
if "$RCLONE" lsf "$STATE_SRC/scripts" --max-depth 1 >/dev/null 2>&1; then
  SOURCE="$STATE_SRC"
  log "存储源: S3"
elif "$RCLONE" lsf "$R2_STATE_SRC/scripts" --max-depth 1 >/dev/null 2>&1; then
  SOURCE="$R2_STATE_SRC"
  log "S3 不可用/真空 → 切换存储源: R2"
fi

if [[ -z "$SOURCE" ]]; then
  log "S3 与 R2 均不可用 → 镜像兜底启动（等待存储恢复，平台重启后自动重试）"
  exec /usr/local/bin/entrypoint.fallback.sh
fi
export HERMES_PULL_SOURCE="${HERMES_PULL_SOURCE:-$( [[ "$SOURCE" == "$R2_STATE_SRC" ]] && echo R2 || echo S3 )}"
export HERMES_STATE_SRC="$SOURCE"

# ── 3. 拉取引导 scripts（仅运行必需；业务数据由 state-restore.sh 恢复）──
mkdir -p /opt/data/scripts
"$RCLONE" copy "$SOURCE/scripts" /opt/data/scripts \
  --transfers 8 --checkers 16 --retries 5 --low-level-retries 10 --s3-acl= \
  || log "scripts 拉取未完全成功（继续启动）"

# ── 4. 分发到运行位（无则保留镜像兜底文件）──
install_file() { # $1 S3侧相对路径(scripts/) $2 目标 $3 是否可执行
  if [[ -f "/opt/data/scripts/$1" ]]; then
    cp -f "/opt/data/scripts/$1" "$2"
    [[ "${3:-}" == "x" ]] && chmod 0755 "$2"
    log "分发 $1 → $2"
  else
    log "缺失 $1（使用镜像兜底）"
  fi
}
install_file entrypoint.sh         /usr/local/bin/entrypoint.sh         x
install_file state-sync.sh         /usr/local/bin/state-sync.sh         x
install_file r2-sync.sh            /usr/local/bin/r2-sync.sh            x
install_file bootstrap-packages.sh /usr/local/bin/bootstrap-packages.sh x
install_file state-restore.sh      /usr/local/bin/state-restore.sh      x
install_file health.py             /usr/local/bin/health.py             ""

# ── 5. 业务数据恢复（S3 脚本；改 S3 上的 state-restore.sh 即改恢复策略，重启生效）──
if [[ -x /usr/local/bin/state-restore.sh ]]; then
  log "执行 state-restore.sh（业务数据恢复，含 config/.env/skills/memories/cron/plugins…）"
  /usr/local/bin/state-restore.sh || log "业务数据恢复未完全成功（继续启动）"
else
  log "缺失 state-restore.sh（跳过业务数据恢复）"
fi

# ── 6. 配置分发 → /etc（config 由 state-restore 拉到位；无则保留镜像兜底）──
[[ -f /opt/data/config/litestream.yml ]]   && { cp -f /opt/data/config/litestream.yml /etc/litestream.yml; log "分发 litestream.yml"; }
[[ -f /opt/data/config/supervisord.conf ]] && { cp -f /opt/data/config/supervisord.conf /etc/supervisor/supervisord.conf; log "分发 supervisord.conf"; }
[[ -f /opt/data/config/lazy-requirements.txt ]] && log "lazy-requirements.txt 就位"

# ── 7. 交接 entrypoint ──
[[ -x /usr/local/bin/entrypoint.sh ]] || die "缺少 entrypoint.sh（S3/R2 均无 scripts 内容）"
log "交接 /usr/local/bin/entrypoint.sh"
exec /usr/local/bin/entrypoint.sh