# 之计 5.16.28 改动交付说明

| 项 | 内容 |
|---|---|
| 交付版本 | 5.16.28+136 |
| 基线版本 | 5.16.23+131 |
| 交付日期 | 2026-10-31 |
| 代码位置 | <https://github.com/hauxu/zhiji>（`main` 分支） |
| 线上分发 | <https://www.huaxu.xin/zhiji/> + GitHub Releases |

---

## 一、版本线

这段时间一共发了五个版本，其中中间两个是在 Windows 外观上来回试的产物，已作废。

| 版本 | 状态 | 内容 |
|---|---|---|
| 5.16.23 | 保留 | 安全修复（密钥协商、验签、快照加密等） |
| 5.16.24 / 5.16.25 | **已撤回** | Windows 自绘边框的两次失败尝试，线上文件已删除 |
| 5.16.26 | 保留 | 审计遗留 30 条问题、术语统一、服务端加固、文档与 CI |
| 5.16.27 | 保留 | Windows 毛玻璃浓度三档 |
| 5.16.28 | **当前发布版** | Windows 去掉系统标题栏，自绘标题栏 + 同一层材质 |

---

## 二、安全修复（5.16.23）

审计发现两个 P0，均已修复并实测。

### P0-1 共享密钥停留在绑定码派生值

原先配对后主密钥是绑定码经 PBKDF2 派生的值，X25519 协商结果只进了备用位。绑定码由服务端生成，等于服务端持有会话密钥。

修复：验签通过后把协商结果升为主密钥，旧密钥全部移入候选位仅供解密历史。

实测（本地双端配对）：

```
绑定码 P4M7F9
电脑端主密钥 Kag1m/KPEZVlwf9n
手机端主密钥 Kag1m/KPEZVlwf9n      两端一致
绑定码派生值 nR9RHXp+BZpnAtQp
主密钥 != 绑定码派生              True
```

### P0-2 验签失败不阻断

对方公钥签名缺失或验签失败时，原代码只提示不 return，仍会固定公钥并协商密钥。已改为 fail-closed：验签不过就不固定、不协商、不改共享密钥。

### 同批其他修复

| 问题 | 处理 |
|---|---|
| v2 快照接受明文 shared，服务端可注入数据 | 只认密文，明文按读不出来处理 |
| 换机恢复时共享密钥可能丢失 | 解不开就不标记已恢复，留待解锁后处理 |
| 本地留言重启后只剩 500 条 | 落盘上限与内存一致，改 2000 / 1200 |
| 更新包解压可能删掉同名文件夹 | 只解到 `zhiji-<版本>` 专用目录 |
| 清单重名时弹层关闭、输入丢失 | 不关闭弹层，选中原文提示 |
| 恢复码进度圈可能卡住 | try/finally 保证关闭 |
| 分享临时图不清理 | 分享结束删除 |

---

## 三、审计遗留 30 条（5.16.26）

### 界面 15 条

| # | 问题 | 处理文件 |
|---|---|---|
| 1 | 清单被外部删除后快速添加无反应 | `lists_page.dart`：悬空选中回退到未分类 |
| 2 | 快速添加面板清单选项不更新 | 改为 build 时从 store 实时读取 |
| 3 | 四栏布局左列无选中高亮 | `_AllListsView` 增加 `selectedListId` |
| 4 | 历史页选中日期消失后不回退 | 回退第一个有效日期 |
| 5 | 日记图片异步复制可能串条目 | 用局部快照按 entryKey 写回 |
| 6 | 倒数日编辑控制器未释放 | 补 `dispose` |
| 7 | 恢复码进度圈可能卡死 | 根 Navigator + finally 关闭 |
| 8 | 检查更新无反馈 | 补「已是最新版本」「暂时无法检查更新」 |
| 9 | 头像选择未捕获异常 | 全流程 try/catch + mounted |
| 10 | 登录无 try/finally，按钮卡在登录中 | 补 try/catch/finally |
| 11 | 日期选择器 await 后 setState | 补 mounted 判断 |
| 12 | 清空结束时间后提醒被静默重置 | 补提示 |
| 13 | 取消归档失败无提示 | 统一 `_unarchive` + 失败 toast |
| 14 | 排序/撤销按钮点击区过小 | 均改 40×40，补 tooltip 与语义标签 |
| 15 | Windows 版本详情显示「莫奈取色」 | 改显示「固定品牌色」 |

### 同步与提醒 15 条

| # | 问题 | 处理 |
|---|---|---|
| 1 | 分页游标未取较小复合键 | 同时读留言/评价 oldest，取较小者 |
| 2 | 登出不清身份密钥 | 登出清空并持久化 |
| 3 | 推送成功未持久化 dirty | 立即 `_persist` |
| 4 | 损坏本地数据静默清空 | 备份到 `sync_corrupt/` 并打印 |
| 5 | dispose 后仍可能同步/通知 | 新增 `_disposed` 守卫 |
| 6 | 通知 id 12 位会碰撞覆盖 | 宽区间 + 32 位 FNV-1a + 近期去重 |
| 7 | 提醒签名先存后调度 | 调度成功才存，失败清签名 |
| 8 | 更新包断点续传在 200 响应下损坏 | 检测到 200 截断重写 |
| 9 | 设备接口错误被吞 | 新增 `SyncErrorKind` 与 `lastError` |
| 10 | 墓碑异常值中断整轮同步 | 类型容错 |
| 11 | 恢复身份私钥不校验公钥 | 推导比对，不一致重建 |
| 12 | 验签错误被末尾清空 | `preserveLastError` |
| 13 | KeepAlive 启动失败仍标 active | `start()` 返回 bool，失败不置位 |
| 14 | 设备 id 用时钟拼接 | 改 `Random.secure` |
| 15 | 证书指纹用 `==` 比较 | 改常量时间比较 |

---

## 四、服务端加固

| 问题 | 处理 | 实测 |
|---|---|---|
| `version.json` 可指向目录外 | 只取 basename | `../secret.apk` 返回 `update:false` |
| 设备管理可被 `device` 参数绕过当前设备保护 | current 只认服务端会话 | 传 `device=evil` 不影响 current |
| 登录参数无长度上限 | 密码 ≤1024、邮箱 ≤254 | — |
| `action` 非字符串导致 500 | 类型校验 | 返回 `unknown action` |
| 落盘无 fsync | 新增 `_write_atomic`，写入后 fsync | — |

改动集中在 `server/server.py`，+42/−29 行。

---

## 五、Windows 窗口（5.16.27 / 5.16.28）

### 根因

前两版失败的真正原因有两个：

1. **重影**：`flutter_acrylic` 设材质时会把 DWM 窗框扩进客户区，系统标题栏被重新画出来，和自绘标题栏叠成两层。
2. **白条**：插件已把标题栏设为透明（`COLOR_NONE`），但 `setTheme` 又涂了一层不透明主题色，于是顶部出现一条与内容不搭的实色带。

### 最终方案

- 原生 `WM_NCCALCSIZE` 让客户区铺满整窗，彻底去掉系统标题栏与边框
- `WM_NCHITTEST` 接管拖动（顶部 38dp）与四边四角缩放，右侧 150dp 留给按钮
- 设完材质后 `resetFrame()` 把窗框扩展清零，避免系统标题栏回来
- 顶部 38dp 由 Flutter 自绘：左边「之计」，右边最小化/最大化/关闭
- 最大化按工作区对齐；启动时 `SetWindowPos(HWND_NOTOPMOST)` 取消置顶

### 实测

```
window=1180x780  client=1180x780  原点重合（无系统边框）
topmost=False
最大化 1936x1048  zoomed=True
最小化 IsIconic=True
关闭后 visible=False（收进托盘）
```

### 配套设置

「我的 → Windows 设置 → 窗口毛玻璃」下方新增「浓度」三档：清晰 90% / 标准 62% / 通透 34%，写入 `gd2_glass_strength`。

---

## 六、文案与术语

统一后的用词：**计划**（原「任务」）、**TA**（原「对方」）、**归档**（原「收藏」）、**日子**（页面名）、**倒数本**（原情侣「纪念日」书名）、**云端备份**。

共约 60 处，含通知渠道名、提醒标题、测试用例。同步精简了 README（55 → 39 行后再扩展为带图版本）、`server/README.md`（52 → 45 行）、`assets/CHANGELOG.md`（663 → 184 行）。

---

## 七、仓库门面

| 项 | 内容 |
|---|---|
| README | 居中标题 + 图标 + 三枚 for-the-badge 徽章 + 6 帧演示动图 + 双截图 + 功能表 + 下载表 + 折叠构建说明 |
| `docs/demo.gif` | 960×634，6 帧，440 KB |
| `docs/screenshot-*.png` | 计划 / 清单 / 日子 三张实机截图 |
| `docs/social-preview.png` | 1280×640 社交预览图（需在仓库设置里手动上传） |
| `SECURITY.md` | 漏洞报告渠道与范围 |
| `.github/` | PR 模板、Issue 模板、config.yml、dependabot.yml、build.yml |
| 仓库元信息 | 简介修正为中文、话题 15 个、Discussions 开启、License 识别为 GPL-3.0 |
| 提交历史 | 22 条提交信息重写为短句（如「Windows：去掉系统标题栏」） |

> 注意：为改提交信息重写过历史并强制推送，任何本地 clone 需 `git fetch --all && git reset --hard origin/main`。

---

## 八、验证记录

| 项目 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 115 / 115 通过 |
| 双端回归（Android 模拟器 + Windows） | 10 / 10 通过 |
| 回归覆盖 | 配对密钥、留言双向、任务全流程、清单、日记加密、倒数本、设备管理、断网恢复、5 条通知 id 不重复、检查更新反馈 |
| 版本一致性 | pubspec 5.16.28+136 / setup.iss 5.16.28 / clientVersion 5.16.28 |
| 线上 OTA | 双通道 `latest: 5.16.28` |
| 官网文件 | 三个包 HTTP 200，长度一致 |
| GitHub Release | v5.16.28 四个附件均 `uploaded`，下载后 sha256 与线上一致 |

---

## 九、发布产物（5.16.28）

| 文件 | 体积 | SHA-256 |
|---|---|---|
| `zhiji-5.16.28.apk` | 66,575,789 B | `4a1e60c8c517f85cbfc766ed1d8bc70911f9880e91edb559b6693d9b749a6cf4` |
| `zhiji-v5.16.28-windows-portable.zip` | 40,106,095 B | `f742a6e1949bf39bcbf73fdc7d315a4e7a5b4187000dc3893f8cf792429441ae` |
| `zhiji-5.16.28-windows-setup.exe` | 36,250,994 B | `79a21de2cb33b93c73a74681a47e5fbe972881ef86d20db37f3a3ff75a9fa87f` |

分发渠道：GitHub Releases（`v5.16.28`）、官网 `huaxu.xin/zhiji`、服务端 OTA 接口 `/var/lib/goalday-sync/apk/version.json`。

---

## 十、已知限制与待办

| 项 | 说明 |
|---|---|
| GitHub Actions 不可用 | 账户 Actions 计费未结清，任务不启动；workflow 已改为仅手动触发，结清后打开 `push` / `pull_request` 即可 |
| Windows 无代码签名 | SmartScreen 会提示未知发布者 |
| Android 7–9 保存相册 | MediaStore 不可用，降级存到应用目录并提示 |
| Windows 便携版运行库 | 仓库不带 `vc_redist.x64.exe`，缺库需自行放置 |
| 社交预览图 | 需在仓库 Settings → Social preview 手动上传 `docs/social-preview.png` |

---

## 十一、回滚方式

- 客户端：官网与服务端 OTA 的 `version.json` 改回目标版本并把对应文件放回即可（各版本安装包与 zip 在本机 `dist/` 与服务端目录均有留存）
- 代码：`git revert` 对应提交，或切到 tag `v5.16.23` / `v5.16.26` / `v5.16.27` / `v5.16.28`
