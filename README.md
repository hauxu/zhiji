# 之计

两个人的手帐风计划应用，Android + Windows，自带同步服务端。

## 功能

- 计划：日/周视图、重复、提醒、排序；清单：备注、附件、共享编辑
- 习惯：打卡月历、热力图；日子：日记、心情月历、倒数本
- 情侣：配对、加密同步、留言板；多设备：设备管理
- 其他：通知、外观、AI 识别（默认关闭，在「我的 → AI 助手」填 Key）

## 下载

<https://www.huaxu.xin/zhiji/>

Android 7.0+；Windows 10/11 便携版解压即用，安装版装到用户目录。应用内「检查更新」可升级。

## 构建

需要 Flutter 3.47（Dart 3.13+）、Android SDK 36 + JDK 17；Windows 另需 VS2022 的 C++ 桌面负载。

```sh
flutter build apk --release \
  --dart-define=ZHIZI_SYNC_HOST=your.server.com --dart-define=ZHIZI_SYNC_PORT=8443 \
  --dart-define=ZHIZI_SYNC_APPKEY=<GD_APP_KEY> --dart-define=ZHIZI_SYNC_CERT=<证书 SHA-256 指纹>
```

四个参数依次是服务器地址、端口（默认 8443）、应用密钥（同服务端 `GD_APP_KEY`）、证书 SHA-256 指纹（小写去冒号）。不填时云同步、情侣配对、检查更新不可用。

证书指纹：`openssl x509 -in sync.crt -noout -fingerprint -sha256`。Windows 构建用 `flutter build windows --release`，产物在 `build/windows/x64/runner/Release/`，缺运行库先跑 `windows/install_judging.bat`。服务端部署见 [server/README.md](server/README.md)。

## 隐私

- 加密上传：日记、计划、清单、习惯、倒数日、纪念日、留言、评价
- 明文：邮箱、昵称、头像、配对公钥、设备名、纪念日日期
- 日记图片、清单附件只在本机；恢复码丢了日记解不开，可用本机数据重建备份

## 许可

客户端 GPL-3.0（[LICENSE](LICENSE)），服务端 AGPL-3.0（[server/LICENSE](server/LICENSE)）。第三方组件见应用内「开源许可」。