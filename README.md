# 之计 (judging)

两个人的手帐风计划应用，Android + Windows。

## 功能

- 计划：日/周视图、重复任务、提醒、置顶、拖动排序
- 清单：备注、附件、条目日期、共享编辑
- 习惯：打卡月历、热力图、每日提醒
- 日子：日记、心情月历、倒数本（循环、农历）
- 情侣：配对、加密同步、留言板、已读回执
- 多设备：设备管理、历史分页
- 通知：本地闹钟 + 长连接
- 外观：动态取色、中国传统色、深色模式、自定义背景

AI 识别可选：任务编辑器点 ✨，接 OpenAI 兼容接口；在「我的 → AI 助手」填 Key，默认关闭。

## 下载

- Android 7.0+：<https://www.huaxu.xin/zhiji/>
- Windows 10/11：便携版解压即用，安装版装到当前用户目录

应用内「我的 → 检查更新」可升级并查看更新日志。

## 从源码构建

准备：Flutter 3.47（Dart 3.13+）、Android SDK 36 + JDK 17；Windows 需 VS2022 的 C++ 桌面负载。

构建时用 `--dart-define` 指向同步服务器（不注入时云同步、情侣配对、检查更新不可用）：

```sh
flutter build apk --release \
  --dart-define=ZHIZI_SYNC_HOST=your.server.com \
  --dart-define=ZHIZI_SYNC_PORT=8443 \
  --dart-define=ZHIZI_SYNC_APPKEY=<服务端 GD_APP_KEY> \
  --dart-define=ZHIZI_SYNC_CERT=<服务器证书 SHA-256 指纹>
```

| 参数 | 说明 |
|---|---|
| `ZHIZI_SYNC_HOST` | 服务器地址 |
| `ZHIZI_SYNC_PORT` | HTTPS 端口，默认 8443 |
| `ZHIZI_SYNC_APPKEY` | 与服务端 `GD_APP_KEY` 一致 |
| `ZHIZI_SYNC_CERT` | 证书 SHA-256 指纹（证书锁定） |

证书指纹：`openssl x509 -in sync.crt -noout -fingerprint -sha256`，填小写、去掉冒号。`build_local.ps1.example` 是构建脚本模板，复制为 `build_local.ps1` 后填参数。

- Android：`flutter build apk --release <参数>`。发布签名写 `android/key.properties`，没有则用调试签名。
- Windows：`flutter build windows --release <参数>`。产物在 `build/windows/x64/runner/Release/`；首次运行先执行 `windows/install_judging.bat` 安装 VC++ 运行库；`windows/setup.iss` 是安装器脚本。
- 测试：`flutter test`

## 自建同步服务器

`server/` 只用 Python 标准库，提供账号、情侣房间、快照、留言评价与更新分发。部署步骤（证书、systemd、权限、备份）和环境变量见 [server/README.md](server/README.md)。

```sh
GD_APP_KEY=<随机长密钥> GD_SMTP_HOST=smtp.example.com \
GD_SMTP_USER=<发信邮箱> GD_SMTP_PASS=<授权码> \
sudo -E python3 server/server.py
```

`GD_APP_KEY` 与构建时的 `ZHIZI_SYNC_APPKEY` 相同。

## 隐私与数据

- 加密上传：日记、计划、清单、习惯、倒数日、纪念日、留言、评价正文。密钥只在设备上。
- 明文：邮箱、昵称、头像、配对公钥、设备名称、纪念日日期、倒数本名称。
- 日记图片、清单附件只在本机；分享给伴侣的日记不含图片。
- 恢复码：换机前先备份；恢复码丢了，日记解不开，可用本机数据重建备份（覆盖旧数据）。
- 服务端每个情侣房间保留最近 2000 条留言、1200 条评价，超了从最旧删。
- 绑定码每 24 小时轮换；断网时改动先存本机，联网后自动同步。

## 许可

客户端（`lib/`、`android/`、`windows/`）GPL-3.0，见 [LICENSE](LICENSE)；服务端（`server/`）AGPL-3.0，见 [server/LICENSE](server/LICENSE)。第三方组件的许可见应用内「我的 → 版本详情 → 开源许可」；`assets/` 图标和音效为本项目原创，随客户端按 GPL-3.0 发布。
