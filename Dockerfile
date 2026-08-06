FROM nousresearch/hermes-agent:v2026.8.3

# ───────────── 二进制层（固定进镜像，不随 S3 变动）─────────────

# rclone v1.75（S3/R2 同步 + 启动拉取；1.60 老版对 R2 有 501 兼容 bug，勿降级）
ARG RCLONE_VERSION=1.75.0
RUN curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
      -o /tmp/rclone.zip \
      "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" \
    && python3 -c "import zipfile; zipfile.ZipFile('/tmp/rclone.zip').extractall('/tmp')" \
    && cp "/tmp/rclone-v${RCLONE_VERSION}-linux-amd64/rclone" /usr/local/bin/rclone \
    && chmod 0755 /usr/local/bin/rclone \
    && rm -rf /tmp/rclone*

# litestream（DB → S3 实时复制；单 replica 限制，配置见 S3 config/litestream.yml）
ARG LITESTREAM_VERSION=0.5.14
RUN curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
      -o /tmp/litestream.tar.gz \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-x86_64.tar.gz" \
    && tar -xzf /tmp/litestream.tar.gz -C /usr/local/bin litestream \
    && chmod 0755 /usr/local/bin/litestream \
    && /usr/local/bin/litestream version \
    && rm -f /tmp/litestream.tar.gz

# Supervisor 作为系统进程管理工具安装，不污染 Hermes 的 Python 环境
RUN apt-get -o Acquire::Retries=3 update \
    && apt-get -o Acquire::Retries=3 install -y --no-install-recommends supervisor \
    && rm -rf /var/lib/apt/lists/* \
    && test -x /usr/bin/supervisord \
    && /usr/bin/supervisord --version

# cloudflared
RUN set -eux; \
    if ! command -v cloudflared >/dev/null 2>&1; then \
        curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
          -o /usr/local/bin/cloudflared \
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"; \
        chmod 0755 /usr/local/bin/cloudflared; \
    fi; \
    CLOUDFLARED_PATH="$(command -v cloudflared)"; \
    if [ "$CLOUDFLARED_PATH" != "/usr/bin/cloudflared" ]; then \
        ln -sf "$CLOUDFLARED_PATH" /usr/bin/cloudflared; \
    fi; \
    /usr/bin/cloudflared --version
# ───────────── 最小兜底（仅当 S3 与 R2 同时不可用）─────────────
RUN mkdir -p \
    /etc/supervisor \
    /opt/data/files/incoming \
    /opt/data/files/output \
    /opt/data/files/tmp \
    /opt/data/lazy-packages \
    /tmp/hermes \
    /run/supervisor

RUN cat > /etc/supervisor/supervisord.conf <<'EOF'
[unix_http_server]
file=/run/supervisor/supervisor.sock
chmod=0700

[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisor/supervisord.pid
childlogdir=/tmp

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///run/supervisor/supervisor.sock

[program:health]
command=/opt/hermes/.venv/bin/python -c "import http.server,socketserver; socketserver.TCPServer(('0.0.0.0',8080),http.server.SimpleHTTPRequestHandler).serve_forever()"
user=root
priority=5
autostart=true
autorestart=true
startsecs=1
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

RUN cat > /usr/local/bin/entrypoint.fallback.sh <<'SH'
#!/bin/sh
# 兜底入口：S3/R2 全挂时保持 8080 存活
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
SH

RUN chmod 0755 /usr/local/bin/entrypoint.fallback.sh

# ───────────── 唯一启动入口 ─────────────
COPY --chmod=0755 pull.sh /usr/local/bin/pull.sh
ENTRYPOINT ["/usr/local/bin/pull.sh"]
