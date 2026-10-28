# 之计

两个人的手帐风计划应用，Android + Windows，自带同步服务端。

## 功能

- 计划：日/周视图、重复任务、提醒、置顶、拖动排序
- 清单：备注、附件、条目日期、共享编辑
- 习惯：打卡月历、热力图、每日提醒
- 日子：日记、心情月历、倒数本
- 情侣：配对、加密同步、留言板
- 多设备：设备管理、历史分页
- 通知：提醒走本地闹钟，留言走长连接
- 外观：取色、深色模式、自定义背景、Windows 毛玻璃

AI 识别默认关闭，在「我的 → AI 助手」填 OpenAI 兼容接口的 Key 后可用。

## 下载

<https://www.huaxu.xin/zhiji/>

Android 7.0+；Windows 10/11，便携版解压即用，安装版装到用户目录。

## 构建

需要 Flutter 3.47（Dart 3.13+）、Android SDK 36 + JDK 17；Windows 另需 VS2022 的 C++ 桌面负载。

```sh
flutter build apk --release \
  --dart-define=ZHIZI_SYNC_HOST=your.server.com \
  --dart-define=ZHIZI_SYNC_PORT=8443 \
  --dart-define=ZHIZI_SYNC_APPKEY=<服务端 GD_APP_KEY> \
  --dart-define=ZHIZI_SYNC_CERT=<证书 SHA-256 指纹>
```

不填这些参数时，云同步、情侣配对、检查更新不可用。

证书指纹：`openssl x509 -in sync.crt -noout -fingerprint -sha256`，小写、去掉冒号。构建脚本模板见 `build_local.ps1.example`。

Windows 构建：`flutter build windows --release <参数>`，产物在 `build/windows/x64/runner/Release/`。仓库不带 VC++ 运行库（`vc_redist.x64.exe`），缺运行库的机器自行下载放到 `windows/` 再跑 `install_judging.bat`。

## 服务端

`server/` 只用 Python 标准库。部署、环境变量、备份见 [server/README.md](server/README.md)。

## 隐私

- 加密上传：日记、计划、清单、习惯、倒数日、纪念日、留言、评价
- 明文：邮箱、昵称、头像、配对公钥、设备名、纪念日日期
- 日记图片、清单附件只在本机；分享的日记不含图片
- 恢复码丢了日记解不开，可用本机数据重建备份

## 许可

客户端 GPL-3.0（[LICENSE](LICENSE)），服务端 AGPL-3.0（[server/LICENSE](server/LICENSE)）。第三方组件见应用内「开源许可」。
