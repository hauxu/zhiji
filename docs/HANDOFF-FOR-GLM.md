# 之计 · 交接说明（给接手改代码的 AI）

这份文档写给下一个接手这个仓库的模型/开发者。目标：读完就能在这个工作目录里安全地改代码、跑测试、发版，不踩我们已经踩过的坑。

- 仓库根目录：`F:\workspace\zcode\goalday`
- 当前分支：`main`，HEAD 提交 `ea39909`
- 版本：`5.16.28+136`（`pubspec.yaml` / `windows/setup.iss` / `lib/sync/sync_service.dart` 的 `clientVersion` 三处必须一致）
- 工作区状态：干净，无未提交改动

---

## 1. 项目是什么

Flutter 应用（Android + Windows 桌面），一套情侣共用的小手帐：计划、清单、习惯、日记、倒数本、留言板。

- 客户端：Flutter 3.47 / Dart 3.13，状态用 Provider（`AppStore` / `SyncService` / `UiPrefs` / `ThemeStore`），Material 3
- 服务端：`server/server.py`，纯 Python 标准库，单进程 + JSON 文件
- 加密：日记用恢复码派生密钥（PBKDF2，salt `zhiji-journal-v1`，10 万次）；情侣数据用 X25519 协商的共享密钥；身份用 Ed25519 签名公钥，TOFU 固定

### 目录

```
lib/
  main.dart            主题、根组件、毛玻璃判定
  app.dart             宽屏 NavigationRail / 窄屏导航的壳
  data/store.dart      任务、清单、习惯、日记等本地数据
  data/models.dart     数据模型与 JSON
  sync/sync_service.dart   同步主逻辑（最大的文件，改动前先读）
  sync/api.dart            HTTP 与证书固定
  sync/notify.dart         通知（id 分配、去重）
  sync/reminders.dart      闹钟排程
  sync/updater.dart        应用内更新（含断点续传）
  crypto/journal_crypto.dart  AES-GCM、PBKDF2、X25519、Ed25519
  pages/               各页面
  widgets/             共用组件
  desktop/             Windows 托盘、窗口桥接
  ui_prefs.dart        界面偏好（含毛玻璃浓度）
server/
  server.py            同步服务端（鉴权、房间、快照、更新分发）
  README.md            部署步骤与环境变量
windows/
  setup.iss            Inno Setup 安装脚本
  runner/flutter_window.cpp   原生窗口（材质、自绘边框、托盘、进度）
  readme-win.txt       便携版说明（会被打进包里）
tools/
  package_windows.ps1  打 Windows 便携包 + 安装包
docs/                  README 用的图与交付文档
.github/              CI、Issue/PR 模板、dependabot
```

---

## 2. 环境与构建

```powershell
$env:JAVA_HOME   = 'D:\dev\jdk-17.0.20.1+1'
$env:ANDROID_HOME= 'D:\dev\android-sdk'
$env:PUB_CACHE   = 'D:\dev\pub-cache'
$env:PATH        = 'D:\dev\flutter\bin;' + $env:PATH
```

| 用途 | 命令 |
|---|---|
| 静态检查 | `flutter analyze`（必须 0 issue） |
| 单元/组件测试 | `flutter test --no-pub`（当前 115 个，必须全过） |
| 打 Android 包 | `powershell -File build_local.ps1 apk`（内含四个 `--dart-define`，该文件不入库） |
| 打 Windows | `flutter build windows --release` |
| 打便携包 + 安装包 | `powershell -File tools/package_windows.ps1 -AppKey <GD_APP_KEY> -SyncHost <IP> -CertSha256 <指纹>` |

构建参数（不填只能离线用）：

```
ZHIZI_SYNC_HOST / ZHIZI_SYNC_PORT / ZHIZI_SYNC_APPKEY / ZHIZI_SYNC_CERT
```

本地联调用的自签证书种子和测试账号在 `.localtest/`，已被 `.gitignore` 排除，不要提交。

---

## 3. 最近这一轮改了什么（5.16.23 → 5.16.28）

### 3.1 安全修复（最重要，别回退）

| 位置 | 改了什么 |
|---|---|
| `lib/sync/sync_service.dart` `_upgradeToX25519Key` | 协商出的共享密钥升为主密钥；旧密钥放候选位只用于解历史。**之前主密钥一直是绑定码派生的，服务端能算出来** |
| 同文件 `_applySyncResult` 验签段 | 对方公钥验签失败/缺签名时直接不固定、不协商；之前只提示不阻断 |
| 同文件 `_decryptSnapshot` / `_decryptOwnSnapshot` | v2 信封的 `shared` 必须是密文，明文一律按读不出来处理 |
| 同文件 `_decryptOwnSnapshot` | `coupleKeyEnc` 解不开时不标记 recovered，留给解锁后处理 |
| `_persist` | 留言/评价落盘上限与内存一致（2000 / 1200），之前只存 500 |
| `lib/widgets/update_flow.dart` | 更新包只解到 `zhiji-<版本>` 专用目录，不再递归删除同名目录 |

### 3.2 审计遗留的 30 条

界面 15 条、同步 15 条，逐条说明见 `docs/DELIVERY-5.16.28.md` 第三节。主要文件：

`lib/pages/lists_page.dart`、`history_page.dart`、`journal_page.dart`、`plan_page.dart`、`profile_page.dart`、`archived_page.dart`、`couple_page.dart`，
`lib/widgets/recovery_codes.dart`、`update_flow.dart`、`task_edit_sheet.dart`、`top_toast.dart`、`entity_dialog.dart`，
`lib/sync/sync_service.dart`、`notify.dart`、`reminders.dart`、`updater.dart`、`api.dart`、`keep_alive.dart`。

### 3.3 服务端（`server/server.py`）

- `checkUpdate`：`file` / `fileWindows` 只取 `basename`，挡住 `../`
- `listDevices`：不再把请求里的 `device` 当 current；`dropDevice` 的保护因此不能靠传参绕过
- 登录：密码 ≤1024、邮箱 ≤254，超了直接报参数错误
- `action` 必须是字符串，否则 400（之前 list 会让字典查找抛 TypeError 变 500）
- 落盘：新增 `_write_atomic()`，写完 fsync 再 replace

### 3.4 Windows 窗口（`windows/runner/flutter_window.cpp`）

- `WM_NCCALCSIZE`：客户区铺满整窗（去掉系统标题栏与边框），最大化时对齐工作区
- `WM_NCHITTEST`：顶部 38dp 判定为标题栏（可拖动、双击最大化），四边四角缩放，右侧 150dp 留给按钮
- 新通道方法：`minimize`、`toggleMaximize`、`closeWindow`、`resetFrame`
- `OnCreate` 里 `SetWindowPos(HWND_NOTOPMOST)`，避免被外部工具留成置顶
- **不要用 `window_manager` 包**：它会重置窗口样式，毛玻璃直接失效（我们试过，已回退）

Flutter 侧：`lib/desktop/windows_title_bar.dart`（自绘标题栏）、`lib/app.dart`（Windows 下包一层 Column）、`lib/desktop/windows_shell.dart`（设完材质调 `resetFrame`）。

### 3.5 文案与术语

统一为：**计划**（原「任务」）、**TA**（原「对方」）、**归档**（原「收藏」）、**日子**、**倒数本**、**云端备份**。
新增术语时请沿用这套，别再混用。

---

## 4. 测试与验收

改动后至少跑：

```powershell
flutter analyze
flutter test --no-pub
```

要跑双端联调（Android 模拟器 + Windows 本地服务器）：

- 本地服务端：`.localtest/dual/base.py`（端口 9443，**不要碰生产的 8443**）
- 配对与密钥验证脚本：`.localtest/verify_p0_key.py`，输出应包含
  `主密钥 != 绑定码派生: True` 和两端密钥一致
- 截图脚本：`.localtest/measure.ps1`（量窗口与客户区尺寸）、`.localtest/shot_final.ps1`（截窗口）、`.localtest/tour.ps1`（连拍各页）

验收标准（发版前必须满足）：

1. `flutter analyze` 0 issue
2. `flutter test` 全绿
3. 版本号三处一致
4. 双端能配对，主密钥一致且不等于绑定码派生值
5. 留言双向可解
6. Windows：`window == client` 尺寸、`topmost=False`、关闭后窗口隐藏（进托盘）

---

## 5. 发布流程

```powershell
# 1. 改版本号（三处）并写 CHANGELOG
#    pubspec.yaml / windows/setup.iss / lib/sync/sync_service.dart clientVersion

# 2. 构建
powershell -File build_local.ps1 apk
flutter build windows --release
powershell -File tools/package_windows.ps1 -AppKey <KEY> -SyncHost <IP> -CertSha256 <指纹>
& 'D:\dev\inno\ISCC.exe' windows\setup.iss

# 3. 上传（SSH 到生产服务器，密钥 ~/.ssh/moonsoft_deploy）
#    站点   /www/wwwroot/www.huaxu.xin/_site/zhiji/
#    OTA   /var/lib/goalday-sync/apk/version.json（含 file、fileWindows、sha256、notes）
```

官网首页、`version.json`、GitHub Release 三处要保持同一个版本与同一份文件。

GitHub Release 附件上传走 `uploads.github.com`，国内直连会断，需代理；断点续传可补齐 66 MB 的 APK。

---

## 6. 约定

- **提交信息**：短句、动词开头、中文，例如 `Windows：去掉系统标题栏`。不要写一长串分号。
- **注释**：说结论，不写「注意」「统一入口」，不用破折号解释。
- **UI 文案**：能删就删，别写「点击即可…」这类废话。
- **不要改这些**（改了会破坏升级或数据兼容）：
  - `applicationId com.huaxu.judging`
  - KDF salt `zhiji-journal-v1`
  - 存储键 `goalday-m3:app-v2`、`gd2_*` 系列
  - Android 签名、`android/key.properties`
- **不要提交**：`build/`、`dist/`、`.localtest/`、`HANDOFF.md`、`build_local.ps1`、keystore、任何证书私钥。

---

## 7. 已知坑

| 坑 | 说明 |
|---|---|
| PowerShell 5.1 按 ANSI 读脚本 | `.ps1` 里不要放中文（文件名、字符串），否则解析报错。`tools/package_windows.ps1` 全 ASCII |
| 中文文件名 | curl 在 git-bash 下读不了中文路径，上传前先复制成 ASCII 名 |
| flutter_acrylic | 它会把 DWM 窗框扩进客户区；设完材质必须调 `resetFrame()`，否则系统标题栏和自绘标题栏叠成两层 |
| 窗口截图 | `PrintWindow` 拿不到毛玻璃，要 `CopyFromScreen`；枚举窗口时偶发拿到 160×28 的辅助窗口，按面积取最大 |
| GitHub 直连 | API 与 release 下载都要 `-x http://127.0.0.1:7897`，git 需单独配 `http.https://github.com/.proxy` |
| 单实例 | 同时跑两个实例会互相抢焦点，测试前先 `Stop-Process zhiji` |

---

## 8. 需要接着做的事

1. **CI 目前跑不了**：GitHub 账户 Actions 计费未结清，任务在 2 秒内被判失败（页面提示 account locked due to a billing issue）。`.github/workflows/build.yml` 已写好，触发暂时改成只有 `workflow_dispatch`；账单处理完后把注释掉的 `push:` / `pull_request:` 打开即可。
2. **社交预览图要手动传**：`docs/social-preview.png`（1280×640），在仓库 Settings → Social preview 上传，API 不支持。
3. **Windows 无代码签名**：SmartScreen 会提示未知发布者。
4. 可选的增强：英文 README、Android 端截图、毛玻璃浓度做成连续滑块。

---

## 9. 参考

- 改动明细：`docs/DELIVERY-5.16.28.md`
- 服务端部署：`server/README.md`
- 更新日志：`assets/CHANGELOG.md`（应用内按 `## vX.Y.Z` 解析，别改结构）
- 安全说明：`SECURITY.md`
