# 接手提示词（复制下面整段给下一个 coding 智能体）

---

你要接手一个叫「之计」的 Flutter 项目（情侣手帐：计划 / 清单 / 习惯 / 日记 / 倒数本 / 情侣同步）。
工作目录就是当前目录，代码在 `F:\workspace\zcode\goalday`（如果换机器，先 `git clone https://github.com/hauxu/zhiji`）。

## 第一步：先把这几份读完再动手

按顺序读，不要跳过：

1. `docs/HANDOFF-FOR-GLM.md` —— 项目结构、构建命令、约定、已知坑（**最重要**）
2. `docs/DELIVERY-5.16.28.md` —— 5.16.23→5.16.28 的安全修复与审计问题明细
3. `docs/MCP.md` —— 内置 MCP 接口（智能体接入）
4. `README.md`、`server/README.md`、`assets/CHANGELOG.md`、`.github/workflows/build.yml`
5. `lib/main.dart`（窗口/主题/毛玻璃）、`lib/desktop/windows_shell.dart`、`windows/runner/flutter_window.cpp`（原生窗口）

## 环境（Windows）

```powershell
$env:JAVA_HOME    = 'D:\dev\jdk-17.0.20.1+1'
$env:ANDROID_HOME = 'D:\dev\android-sdk'
$env:PUB_CACHE    = 'D:\dev\pub-cache'
$env:PATH         = 'D:\dev\flutter\bin;' + $env:PATH
```

| 用途 | 命令 |
|---|---|
| 静态检查 | `flutter analyze`（必须 0 issue） |
| 测试 | `flutter test --no-pub`（当前 130 条，必须全过） |
| 打 Android 包 | `powershell -File build_local.ps1 apk`（该文件不入库，用仓库里的 `build_local.ps1.example`） |
| 打 Windows | `flutter build windows --release` |
| 打包 + 安装包 | `powershell -File tools/package_windows.ps1 -AppKey <KEY> -SyncHost <IP> -CertSha256 <指纹>`；安装包用 `D:\dev\inno\ISCC.exe windows\setup.iss` |

## 硬约束（改坏了会出事）

- **不要改**：`applicationId com.huaxu.judging`、KDF salt `zhiji-journal-v1`、存储键 `goalday-m3:app-v2` / `gd2_*`、Android 签名、`android/key.properties`
- **不要提交**：`build/`、`dist/`、`.localtest/`、`HANDOFF.md`、`build_local.ps1`、任何 keystore / 证书私钥
- 版本号三处必须一致：`pubspec.yaml`、`windows/setup.iss`、`lib/sync/sync_service.dart` 的 `clientVersion`
- 提交信息：短句、中文、动词开头（参考 `git log`），不要写一长串分号
- 注释写结论，不写「注意」「统一入口」，不用破折号解释
- UI 文案能删就删，不要「点击即可…」这类废话

## 发布流程

1. 改版本号三处 + `assets/CHANGELOG.md` 加 `## vX.Y.Z`
2. `flutter analyze` + `flutter test` 全绿
3. 构建 APK / Windows 包 / 安装包
4. 上传：官网 `/www/wwwroot/www.huaxu.xin/_site/zhiji/`、服务端 `/var/lib/goalday-sync/apk/version.json`（含 file / fileWindows / sha256 / notes）
5. GitHub Release（走代理 `http://127.0.0.1:7897`，大文件要 `--retry`、`-m 1800`）

## 当前状态（5.16.33）

- 已发布：官网、OTA、GitHub Release 三处都是 5.16.33
- Windows 顶栏与正文融为一体（差 0~4 个 RGB 单位），毛玻璃默认最大档（通透）
- MCP 服务：`127.0.0.1:8787`，默认只读，写入与隐私内容单独开关
- 已知待办见 `docs/HANDOFF-FOR-GLM.md` 第 8 节

## 特别注意的坑（都踩过）

- PowerShell 5.1 按 ANSI 读 `.ps1`：脚本里不要放中文字符串
- `DwmExtendFrameIntoClientArea` 在主线程直接调**不生效**，要开后台线程（见 `extendFrame`）
- 自绘边框的拖动/缩放命中测试收不到（Flutter 视图全覆盖），拖动由 Flutter 侧发起
- 改窗口样式后窗口可能不重绘，截图前点一下窗口
- GitHub 直连不稳定，API 与 Release 上传都要走代理
- CI 目前只允许手动触发（账户 Actions 计费未结清）

先读完文档，再给我一个你打算怎么做的计划，我确认后再动手。
