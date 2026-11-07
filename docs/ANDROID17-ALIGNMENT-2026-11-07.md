# Android 17（API 37）对齐报告 · 2026-11-07

> **口径**：每一条都写「怎么验的」。验不了的标「未验」，不写「应该没问题」。
> 平台事实取自 Google 官方 Android 17 发布说明（2026-06 正式版）与本机实测；
> 设备是 OPPO PLJ110 / Android 17，但**本次核对时设备未连接**，所以凡涉及真机
> 观感的都归到 §4 的「待真机」，不当成已验证。
>
> 关联文档：`docs/ROADMAP-2026-11-06.md` §2.1（大屏）、§1.1（内存上限，已落地）。

---

## 结论

| 判据 | 状态 | 一句话 |
| --- | --- | --- |
| 构建链 | ✅ 已对齐 | compileSdk / targetSdk **37**，AGP 9.5.1 / Gradle 9.6.0 / KGP 2.4.21 / JDK 21 |
| 16KB 页 | ✅ 通过 | `zipalign -P 16` + 三个 `.so` 的 `p_align` 双验 |
| edge-to-edge | ✅ 已做 | `SystemUiMode.edgeToEdge` + 四处 `SafeArea` |
| 明文流量 | ✅ 双闸 | `network_security_config` + Dart 侧 `requireHttps()` |
| 权限面 | ✅ 只有一项 | `INTERNET` |
| 大屏强制自适应 | ✅ 无违规 | 不锁方向、不锁 aspect ratio、`resizeableActivity` 未关 |
| Activity 重建新默认 | ✅ 不依赖 | 全部状态在 Dart 侧，重建与否不影响数据 |
| 其余 14 项行为变更 | ✅ 0 命中 | 逐条理由见 §3 |
| **大屏布局质量** | ⚠️ **没做完** | 不坏，但横屏/平板是「单列居中 + 弹层变矮」，见 §4 |

**一句话**：装到 Android 17 手机上**不会坏**，这一版在「合规」这一层已经完成。
要上平板 / 折叠屏展开 / 桌面模式，剩下的全是体验问题（§4），不是崩溃风险。

---

## 一、构建链

| 项 | 值 | 位置 |
| --- | --- | --- |
| compileSdk / targetSdk | `37` / `37` | `android/app/build.gradle.kts` |
| minSdk | `24`（Android 7.0） | 经 `flutter.minSdkVersion`；`aapt dump badging` → `sdkVersion:'24'` |
| AGP / Gradle / KGP / JDK | `9.5.1` / `9.6.0` / `2.4.21` / `21` | `settings.gradle.kts`、`gradle-wrapper.properties`、`compileOptions` |
| Java / Kotlin 目标 | 21 / JVM 21 | `compileOptions`、`kotlin { jvmTarget }` |
| 断言 | `EXPECT_TARGET_SDK = 37` | `tool/verify_apk.py`，改回 36 会当场红 |

> 为什么不用 `flutter.compileSdkVersion`：Flutter 3.47.9 的默认值仍是 36，跟着它走
> 永远差一代。2026-11-05 起显式钉 37，升级节奏由自己掌握。
> 副产品：SDK 平台包名从 Android 17 起带 minor（`platforms;android-37.0`），
> AGP 9 按 `37 + minor 0` 解析，不需要额外配置。

**复核**：

```bash
"/c/Android/sdk/build-tools/37.0.0/aapt.exe" dump badging \
  build/app/outputs/flutter-apk/app-release.apk | head -3
# package: name='app.supermarket' versionCode='35' versionName='1.0.7'
#          compileSdkVersion='37' ... sdkVersion:'24'
python tool/verify_apk.py   # 目标 : ✓ targetSdk 37（期望 37 = Android 17）
```

---

## 二、硬性要求（不过就装不上 / 打不开）

### 2.1 16KB 页 —— 最容易被忽略的一条

Android 15 起有设备使用 16KB 内存页。`.so` 的 ELF 段如果只按 4KB 对齐，
在这类设备上**加载即失败**（`UnsatisfiedLinkError`），表现为"装得上、点开就闪退"。
Play 从 2025-11 起对新提交强制要求；本项目是 sideload 不受政策约束，
**但设备已经是 16KB 页，跑不起来就是真跑不起来**。

两道验证都过了：

```bash
zipalign -c -v -P 16 4 app-release.apk
# ... Verification successful
```

| 原生库 | LOAD 段数 | `p_align` | 判定 |
| --- | --- | --- | --- |
| `libapp.so` | 3 | `0x10000`（64KB） | ✅ |
| `libflutter.so` | 3 | `0x10000`（64KB） | ✅ |
| `libdartjni.so` | 3 | `0x4000`（16KB） | ✅ |

> 三个库都是 DEFLATE 压缩存储（`useLegacyPackaging = true`，见 `build.gradle.kts`），
> 安装时解压到 `/data`，**页对齐由安装器保证**——所以"压缩"不会破坏 16KB 对齐。
> 这一点容易被误判成风险：APK 内 `.so` 被压缩 ≠ ELF 段没对齐，两件事。

**未验**：设备是否真的运行在 16KB 页模式。连上设备后可查：

```bash
adb shell getconf PAGE_SIZE        # 16384 表示 16KB 页
```

### 2.2 edge-to-edge

targetSdk 35 起系统强制 edge-to-edge，`statusBarColor` 之类的 API 已失效。

| 层 | 做法 | 位置 |
| --- | --- | --- |
| Dart | `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` | `lib/main.dart` |
| Dart | 状态栏 / 导航栏透明 + 深色图标 | `lib/main.dart`（`SystemUiOverlayStyle`） |
| 布局 | 列表与弹层各用 `SafeArea`；弹层 `useSafeArea: true` | `quote_list_page.dart`、两个 sheet |

玻璃要透出状态栏后面的背景，这一点是**有意为之**，不是漏了 padding。

### 2.3 明文流量

| 闸门 | 管谁 | 位置 |
| --- | --- | --- |
| `network_security_config`（`cleartextTrafficPermitted="false"`） | 原生 HTTP 栈（OkHttp / WebView / Cronet） | `res/xml/network_security_config.xml` |
| `requireHttps()` | **Dart 侧** `dart:io HttpClient`（行情真正走的路径） | `lib/services/rest_client.dart` |

Android 17 起 `android:usesCleartextTraffic` 被标记弃用、未来默认拦明文。
本项目**从来没有用过这个属性**，用的是 NSC，正好是官方推荐的迁移方向——不需要动作。

> 为什么需要两道：`dart:io` 自带 BoringSSL + 裸 socket，**不经过** Android 的
> `NetworkSecurityPolicy`。只写 NSC 对行情请求是无效的，这一点在
> `network_security_config.xml` 的注释里已经钉过。

### 2.4 权限面

`AndroidManifest.xml` 里只有 `android.permission.INTERNET` 一项。

于是 Android 17 新加的隐私项（本地网络、SMS OTP、通讯录、相机、音频）**全部不适用**：

- **本地网络权限（LAN）**：targetSdk 37 起访问局域网设备要在 `NEARBY_DEVICES` 组里
  有权限。本项目连的是 `hq.sinajs.cn` / `qt.gtimg.cn` 这类公网域名，**不碰局域网**。
- **SMS OTP 延迟 3 小时**：不读短信，无 `READ_SMS`。
- **CP2 联系人字段 / 严格 SQL 校验**：不读通讯录。

### 2.5 ABI

单 `arm64-v8a`（`--target-platform android-arm64` + `jniLibs.excludes` 剔掉插件
带进来的 v7a / x86_64）。64 位是 Android 17 的既有要求，已经满足。
代价是装不进 32 位老设备与 x86 模拟器——自用场景可接受。

---

## 三、targetSdk 37 行为变更逐条判定

判定原则：**只看这个 App 真实用到的能力**。用不到的能力，写清"为什么用不到"，
而不是笼统地写"不涉及"。

| # | 变更 | 规则 | 本项目 | 依据 |
| --- | --- | --- | --- | --- |
| 1 | **大屏强制自适应** | sw ≥ 600dp 时忽略 `screenOrientation` / `setRequestedOrientation` / `resizeableActivity=false` / `min-maxAspectRatio` | ✅ 无违规声明，但布局未按大屏调 → §4 | Manifest 无 `screenOrientation`、无 `resizeableActivity`、无 aspect ratio |
| 2 | **Activity 重建默认变更** | `CONFIG_KEYBOARD` / `KEYBOARD_HIDDEN` / `NAVIGATION` / `TOUCHSCREEN` / `COLOR_MODE` / `UI_MODE(DESK)` 不再重建，改走 `onConfigurationChanged` | ✅ 不依赖重建 | 状态全在 Dart 侧（`ValueNotifier` + 本地存档），重建只影响启动路径 |
| 3 | 新增 `android:recreateOnConfigChanges` | 想恢复旧行为需显式声明 | ✅ 不需要 | 同 #2，没有"靠重建重载资源"的逻辑 |
| 4 | **证书透明度（CT）默认开启** | targetSdk 37 起 TLS 连接默认校验证书透明度 | ✅ 不命中 | `dart:io` 用自带 BoringSSL，不走 Android 的 TLS 栈与 CT 校验 |
| 5 | **ECH 默认开启** | 同上，走系统 TLS 才生效 | ✅ 不命中 | 同上 |
| 6 | **Safer Native DCL-C** | `System.load()` 加载的原生库必须只读，否则 `UnsatisfiedLinkError` | ✅ 不命中 | 只用 `System.loadLibrary` 加载打包内的 `.so`，没有动态下发 / 解压加载 |
| 7 | 无锁 `MessageQueue` | 反射其私有字段的代码会坏 | ✅ 不命中 | 全仓库无 `MessageQueue` 相关反射；Flutter 引擎不依赖私有字段 |
| 8 | 分代 GC | ART 并发标记压缩回收器引入年轻代 | ✅ 无感 | 无需适配 |
| 9 | 通知自定义视图严格尺寸限制 | 自定义 RemoteViews 超限会被裁 | ✅ 不命中 | 不发通知（无 `POST_NOTIFICATIONS`，无 NotificationChannel） |
| 10 | 后台音频加固 | 非有效生命周期状态下音频 API 静默失败 | ✅ 不命中 | 不播放音频（无 `MediaPlayer` / `AudioTrack` / `just_audio`） |
| 11 | `usesCleartextTraffic` 弃用 | 未来 SDK 默认拦明文 | ✅ 已就绪 | 用 NSC，没用该属性 → §2.3 |
| 12 | 触控板相对事件 | 指针捕获期间触控板传相对事件 | ✅ 不命中 | 无自定义 pointer capture 逻辑，全交给 Flutter 手势系统 |
| 13 | BAL 加固 / `IntentSender` 限制 | 后台启动 Activity 更受限 | ✅ 不命中 | 只有一个 Activity，不启动其他 App 的界面 |
| 14 | App Bubbles / Bubble Bar / 桌面交互式 PiP | 系统行为，长按图标即可触发 | ⚠️ 无需代码，但**极小窗布局要撑住** | §4.3 已测 240×320dp 无异常 |
| 15 | 相机 / 媒体 / VVC / CQ 录制 | — | ✅ 不命中 | 无相机、无录制 |
| 16 | 密码字段 / 实体键盘隐藏 | — | ✅ 不命中 | 唯一输入框是股票搜索，不是密码框 |

> 这张表里最容易出错的是 #4 / #5：**CT 与 ECH 都是"系统网络栈"的行为**，
> 而本项目的行情请求走 Dart 自己的 BoringSSL。看到"targetSdk 37 默认开 CT"
> 就去配证书链，是白忙。判断依据不是"我们有没有 HTTPS"，而是"谁在做 TLS"。

---

## 四、大屏自适应：唯一没做完的（ROADMAP §2.1）

### 4.1 规则

sw ≥ 600dp 的窗口上，系统**忽略**：

- `android:screenOrientation`（锁方向无效）
- `setRequestedOrientation()`（运行期锁方向也无效）
- `android:resizeableActivity="false"`（不能拒绝调整尺寸）
- `minAspectRatio` / `maxAspectRatio`（不能限制宽高比）

例外：sw < 600dp 的设备、`android:appCategory="game"` 的 App。
用户仍可用系统的宽高比设置覆盖。

### 4.2 现状（代码事实，不是推测）

| 层 | 现在怎么做 | 大屏下会怎样 |
| --- | --- | --- |
| 页面容器 | `LayoutBuilder` + `BoxConstraints(maxWidth: 560)` | 920dp 宽时左右各留 180dp，中间单列 |
| 详情弹层 | `maxWidth: 520` + `maxHeight: 屏高 × 0.86` | 居中 520 宽；横屏 419dp 高时内容只有 360dp 高，内部滚动 |
| 列表 | `ListView` 单列 | 一屏能看的卡片数由高度决定，不是宽度 |
| 图表 | 自绘，按可用宽度铺满 | 宽屏下 K 线横向拉伸，蜡烛变宽、点数不变 |

### 4.3 实测（widget test，非真机）

用 `tester.view.physicalSize` 模拟五种窗口，跑完整列表页 + 点开详情弹层：

| 窗口 | 逻辑尺寸 | 列表溢出 | 卡片数 | 弹层 | 判定 |
| --- | --- | --- | --- | --- | --- |
| 竖屏全屏 | 419×920dp | 无 | 5 | 419×920 | ✅ 基准 |
| 横屏 | 920×419dp | 无 | 4 | 920×419（内容限宽 520） | ✅ 不坏 |
| 分屏上半 | 419×433dp | 无 | 4 | 419×433 | ✅ 不坏 |
| 平板横屏 | 1280×800dp | 无 | 5 | 1280×800（内容限宽 520） | ✅ 不坏 |
| 气泡极小窗 | 240×320dp | 无 | 3 | 240×320 | ✅ 不坏 |

**结论**：`RenderFlex` 溢出 **0 次**、异常 **0 次**。极端窗口下会被挤压但不会碎。
这比"没测过"强，但**不等于好看**——见 4.4。

> 这五种窗口已经固化成回归用例 `test/big_screen_layout_test.dart`（6 条：
> 五个尺寸各一条 + 横屏打开详情弹层一条），进 `flutter test` 门禁。
> 它守的是「不溢出、卡片不超 560、弹层内容不超 520」，不守观感。

### 4.4 真机上还没做的（这是 §2.1 的剩余部分）

| 项 | 为什么没做 | 成本 |
| --- | --- | --- |
| 三窗口真机截图基线 | 本次核对时设备未连接 | S |
| 横屏双栏（左列表右详情） | 属于"想要"不是"必须"；先保证不坏 | M |
| 平板下端到端视觉走查 | 同上 | S |
| 折叠屏展开态（半折 / 全展开） | 无设备 | 未验 |

ROADMAP 的原话照抄在此，别当已完成：**「只修看起来坏的，不重做设计」**。

---

## 五、明确不做的（写下来是为了以后别再翻）

| 项 | 不做的理由 |
| --- | --- |
| AppFunctions / Android MCP | API 处于 alpha，Gemini 集成为私测；本项目无分发、无第三方调用方，收益 ≈ 0。见 ROADMAP §3.1 |
| 桌面交互式 PiP | 没有官方 Flutter 插件；要原生进 PiP + 引擎在 PiP 里 resize，成本远超收益 |
| 16KB 页之外的原生改造 | 已经对齐，没有剩余动作 |
| `recreateOnConfigChanges` | 不依赖重建，加了反而把状态丢失的风险请回来 |
| 深色模式（A02） | **注意**：一旦要做，`CONFIG_COLOR_MODE` 在 Android 17 下**不再重建 Activity**，必须靠 Flutter 的 `MediaQuery.platformBrightness` 响应式切换，不能指望重启重载主题。这条现在记下来，省得将来踩 |

---

## 六、复测命令

```bash
# 构建链与清单
aapt dump badging build/app/outputs/flutter-apk/app-release.apk | head -3
python tool/verify_apk.py

# 16KB 页（两道都要过）
zipalign -c -v -P 16 4 build/app/outputs/flutter-apk/app-release.apk | tail -2

# 代码门禁
flutter analyze
flutter test --exclude-tags preview   # 413（含本报告新加的 6 条大屏用例）
flutter test                          # 420（含 5 张 golden）
```

16KB 的 ELF 段对齐没有现成 CLI，用这段脚本：

```python
import zipfile, struct
z = zipfile.ZipFile("build/app/outputs/flutter-apk/app-release.apk")
for n in z.namelist():
    if n.startswith("lib/") and n.endswith(".so"):
        b = z.read(n)
        phoff, = struct.unpack_from("<Q", b, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", b, 0x36)
        aligns = [struct.unpack_from("<Q", b, phoff + i * phentsize + 48)[0]
                  for i in range(phnum)
                  if struct.unpack_from("<I", b, phoff + i * phentsize)[0] == 1]
        print(n, [hex(a) for a in aligns], "OK" if all(a >= 16384 for a in aligns) else "BAD")
```

真机侧（设备连上后补）：

```bash
adb shell getconf PAGE_SIZE                    # 16384 = 16KB 页
adb shell dumpsys package app.supermarket | grep -E "targetSdk|minSdk"
adb logcat -s app.supermarket                  # 刷新率投票 / ADPF 会话是否正常
```
