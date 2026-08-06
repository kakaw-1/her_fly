# her_fly — Hermes Agent × Clever Cloud 部署镜像

将 [Hermes Agent](https://hermes-agent.nousresearch.com) 部署到 Clever Cloud 的自愈式镜像。
**仓库仅 2 个运行时文件**（Dockerfile + pull.sh）+ 本说明；其余运行时文件全部存 S3，容器启动时由 pull.sh 拉取，**改配置不受重启影响**。

## 架构

```
                    ┌─────────────────────────────────────────────┐
                    │              Clever Cloud 容器               │
                    │                                             │
  Dockerfile ──────▶│  pull.sh（唯一入口，镜像内）                  │
                    │   ① 探测 S3 state/scripts                    │
                    │   ② S3 真空 → 切 R2 拉取                      │
                    │   ③ 双源全挂 → 镜像兜底（8080 存活）           │
                    │   ④ 分发 scripts→/usr/local/bin、config→/etc │
                    │   ⑤ exec entrypoint.sh                       │
                    │ entrypoint.sh                                │
                    │   ⑥ health(8080) → 懒加载包重建 → DB 恢复     │
                    │   ⑦ quick_check → supervisord                │
                    │ supervisord: gateway / dashboard /           │
                    │   state-sync(5min→S3) / litestream(1s→S3)    │
                    └─────────────────────────────────────────────┘
                                   │
                 S3 (Cellar) 主存储 │ R2 (Cloudflare) 每日镜像
                 state/ + litestream/ ── r2-sync cron 00:00 UTC ──▶ state/ + litestream/
```

## 仓库内容

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 基于 `nousresearch/hermes-agent:v2026.8.3`；内置 rclone v1.75、litestream 0.5.14、supervisor、cloudflared；内嵌最小兜底配置 |
| `pull.sh` | 唯一启动入口：探测存储源 → 拉取 scripts/config/.env → 分发 → 交接 entrypoint |

## 启动链路

1. **pull.sh**：`lsf` 探测 S3 `state/scripts` → 可用则[拉取完整 `/opt/data` 状态](从 S3 `state/` 到 `/opt/data/`，含 scripts/config/.env/skills/memories/cron/plugins 等；排除 lazy-packages/bin)；S3 真空/不可用切 R2；双源全挂则镜像兜底（8080 存活等待恢复）
2. **分发**：`scripts/*` → `/usr/local/bin/`；`config/litestream.yml`、`config/supervisord.conf` → `/etc/`；`.env` → `/opt/data/.env`（密钥自愈）
3. **entrypoint.sh**：bootstrap health(8080) → 懒加载包重建（按 `config/lazy-requirements.txt` 从 PyPI，幂等）→ DB 恢复（S3 源走 litestream restore←S3；R2 源走临时 file:// 配置 restore←R2）→ SQLite quick_check → 交接 supervisord
4. **supervisord**：gateway / dashboard / state-sync / litestream / health.py(8080)

## 部署（Clever Cloud）

1. 新建应用，构建方式选 **Dockerfile**，镜像源指向本仓库
2. 注入环境变量：

| 变量 | 说明 |
|---|---|
| `TUNNEL_TOKEN` | Cloudflare 隧道 token（必填） |
| `S3_ENDPOINT` / `CELLAR_ADDON_HOST` | Cellar S3 地址（必填） |
| `S3_ACCESS_KEY_ID` / `CELLAR_ADDON_KEY_ID` | 访问密钥（必填） |
| `S3_SECRET_ACCESS_KEY` / `CELLAR_ADDON_KEY_SECRET` | 访问密钥（必填） |
| `S3_BUCKET` | 存储桶（默认 `my-hermes-data`） |
| `S3_PREFIX` | 前缀（默认 `hermes-prod`） |
| `RCLONE_CONFIG_R2_*` | R2 兜底凭据（endpoint/access key/secret/region） |
| `R2_S3_BUCKET` / `R2_S3_PREFIX` | R2 镜像 bucket/prefix |

3. 端口：CC 暴露 **8080**（health.py 监听）
4. 保存触发部署；首次启动约 5–8 分钟（含 459MB 懒加载包下载），之后重启约 30s–1min

## 存储布局（S3）

```
my-hermes-data/hermes-prod/
├── state/                # /opt/data 镜像（state-sync 每 5min）
│   ├── scripts/          # entrypoint / state-sync / r2-sync / bootstrap-packages / health.py
│   ├── config/           # litestream.yml / supervisord.conf / lazy-requirements.txt
│   ├── .env              # 密钥备份（启动拉取自愈）
│   └── …业务数据（lazy-packages/ 已排除，不备份）
└── litestream/           # state.db / kanban.db WAL（litestream 实时复制）
```

## 灾备

- **S3（Cellar）主存储**：state-sync 每 5min + litestream 实时（1s 粒度）
- **R2（Cloudflare）纯镜像**：每日 00:00 UTC cron 删除式镜像 `state/` + `litestream/`，失败告警投飞书
- **懒加载包**（~459MB）不备份：启动时按清单从 PyPI 重建
- **兜底链**：S3 → R2 → 镜像内嵌最小配置，三级降级

## 运维

- **改配置**：改 S3 `state/config` 或 `state/scripts` → 重启容器生效；或在容器内改 `/opt/data/scripts|config` → state-sync 5min 自动推 S3
- **改密钥**：改容器内 `/opt/data/.env` → 自动备份 → 重启自愈
- **检查启动日志**：`[pull] 存储源: S3` → 分发日志 → `[entrypoint] Starting Supervisor`
- **R2 镜像状态**：`rclone size r2:<bucket>/<prefix>/state`
