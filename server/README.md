# server

之计的同步服务端，只用 Python 标准库。客户端构建见根目录 README。

## 部署

```sh
# 证书
sudo mkdir -p /opt/goalday-sync/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /opt/goalday-sync/certs/sync.key \
  -out /opt/goalday-sync/certs/sync.crt -subj "/CN=your.server.com"

# 专用账号
sudo useradd --system --no-create-home --shell /usr/sbin/nologin goalday
sudo mkdir -p /var/lib/goalday-sync/data
sudo chown -R goalday:goalday /var/lib/goalday-sync
sudo chown -R root:goalday /opt/goalday-sync/certs
sudo chmod 750 /opt/goalday-sync/certs
sudo chmod 640 /opt/goalday-sync/certs/*

# 环境变量写进 /etc/goalday-sync/env
sudo -E python3 server/server.py
```

数据在 `GD_DATA_DIR`，数据目录只能跑一个实例，systemd 示例见 `goalday-sync.service`（假定代码在 `/opt/goalday-sync`）。备份用 `ops_daily_backup.sh`，`ops_restore_drill.py` 校验备份包。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GD_APP_KEY` | 必填 | 应用密钥，与客户端 `ZHIZI_SYNC_APPKEY` 相同 |
| `GD_PORT` | `8443` | HTTPS 端口 |
| `GD_DATA_DIR` | `/var/lib/goalday-sync` | 数据目录 |
| `GD_CERT` / `GD_KEY` | `/opt/goalday-sync/certs/sync.crt` / `sync.key` | 证书与私钥 |
| `GD_APK_DIR` | `/var/lib/goalday-sync/apk` | 更新包与 version.json |
| `GD_SMTP_HOST` / `GD_SMTP_PORT` | `smtp.139.com` / `465` | 验证码发信 |
| `GD_SMTP_USER` / `GD_SMTP_PASS` | 必填 | 发信邮箱与授权码 |
| `GD_DEBUG` | 关闭 | `=1` 时验证码随响应返回，仅测试 |
| `GD_MIN_PUSH_VER` | `5.15.2` | 低于此版本不能覆盖加密备份 |
| `GD_MSG_CAP` / `GD_COMMENT_CAP` | `30` / `30` | 每 IP 每分钟留言 / 评价上限 |
| `GD_ROOM_MESSAGE_BYTES` / `GD_ROOM_COMMENT_BYTES` | `24MB` / `12MB` | 单房间历史总大小上限 |

## 许可

AGPL-3.0，全文见 [LICENSE](LICENSE)。客户端是 GPL-3.0；把改过的服务端部署成对外服务时，也要公开改过的源码。