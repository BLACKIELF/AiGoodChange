# AiGoodChange

轻量、原生的 macOS 菜单栏应用切换工具。为常用 App 设置全局快捷键：按一下呼出，再按一次安全恢复。

## 为什么做 AiGoodChange

Mac 上的窗口一多，找应用就成了一件反复打断手头工作的事。

想看一眼另一个应用，先按 F3 展开窗口，再从一堆缩略图里辨认、点击。改用 ⌘Tab，也常常要沿着应用列表切过去。明明已经知道自己要打开哪个应用，手上还得再找一遍。临时过去查点东西，回来又要切一次。

AiGoodChange 让常用应用各有一组固定快捷键。需要哪个，按下对应组合就呼出哪个。用完再按同一组键，应用会根据唤出前的状态隐藏或恢复。常用应用的位置可以变，打开的窗口可以增加，已经设好的快捷键仍然对应那个应用。

比如写东西时需要找文件，可以按为访达设置的快捷键，呼出访达找到文件，用完再按一次收回。浏览器、聊天软件、编辑器也可以各设一组。临时查看的应用随用随叫，手头的工作不用一直被它挡着。

常用工具换了，也可以直接替换快捷键对应的 App。原来那组键保留下来，手已经记住的操作还能继续用。访达同样作为应用放进列表，快捷键由你自己设置。

F3 适合总览桌面，⌘Tab 适合在应用间切换。经常来回使用的几个应用，可以交给 AiGoodChange。先把最常用的两三个设好，从下一次打开它们开始用。

原名 QuickToggle（轻唤）。当前源码基于 `1.0.0`，已加入下列未发布更新；GitHub 历史安装包仍为旧名称与旧功能。

Windows 用户可使用 [Windows 1.0 预览版](https://github.com/BLACKIELF/AiGoodChange/releases/tag/v1.0.0-windows-preview.1)，提供 x64 与 ARM64 原生托盘程序，详见 [Windows 使用说明](windows/README.md)。下文为 macOS 版说明。

详细说明与示例图见 [`docs/使用说明.md`](docs/使用说明.md)。

## 当前源码更新

访达可作为应用添加并自行录制快捷键；点击应用图标或名称可更换 App，保留原快捷键。窗口底部可选择 AiGoodBro 的 10 套主题，随 macOS 使用深浅色。

应用列表支持搜索、筛选、键盘导航及大列表更新；设置与帮助独立滚动。可手动或每天自动检查 GitHub 正式发行版，发现更新后由用户打开发行页下载。不会自动下载或安装。

变更见 [更新日志](CHANGELOG.md)，历史版本见 [1.0 说明](docs/releases/1.0.md)，开发和合并流程见 [贡献指南](CONTRIBUTING.md)。

隔离预览读取配置副本，操作只在预览中生效：

```bash
QUICKTOGGLE_PREVIEW=1 bash build.sh
open "build/preview/AiGoodChange.app"
```

## 下载与运行

- Apple Silicon Mac，macOS 13 或更高版本。
- 历史安装包：[轻唤 1.0.0](https://github.com/BLACKIELF/AiGoodChange/releases/tag/v1.0.0) 中的 `QuickToggle-1.0.0-macOS-arm64.zip`。
- 默认构建使用 ad-hoc 签名；若本机已有开发证书则复用该证书。构建产物未经 Apple 公证，不会自动安装到 `/Applications`。首次运行若被 Gatekeeper 拦截，请在“系统设置 > 隐私与安全性”中确认打开；不放心时请直接从源码构建。

从源码构建需要 Xcode Command Line Tools：

```bash
bash build.sh
open "build/AiGoodChange.app"
```

## 特性

- 支持多个应用，每个应用独立录制快捷键，优先推荐未占用的 `⌘0–9`，也支持 `fn/🌐0–9`、`⌘⌥K`、`⌘⇧K`、`⌃⇧K`、`⌘⌥←/→`、`⌃⇧F1–F12`。添加应用时先从 `⌘1` 依次自动分配；`⌘` 数字用尽后转为 `fn/🌐` 数字（跳过已绑定、设置键和「本机已占用」项）。
- 自动扫描已安装的可视应用，放入“待添加”选择器；不会把 Helper、后台组件写进主列表，也不会自动注册快捷键。
- 旧配置中的绑定与占用记录会保留；若其他软件已不再占用某个组合，可在“占用记录”中移除对应记录。
- 「本机已占用」列表可编辑：主窗口“占用记录”中移除，点击“添加占用…”录入名称和组合，录制自检会自动避开。
- 配置导出/导入：菜单栏可把全部绑定、设置快捷键、启用状态和占用记录存成 JSON 备份，换机或重装后导入即可恢复；备份里本机未安装的应用会跳过并点名提示。
- 行尾“更多”菜单可呼出／恢复、更换应用、设置未运行时打开、查看快捷键说明或移除。
- 记住按键前的隐藏、最小化或显示状态，第二次按键尽量安全恢复。
- 一次物理按压只触发一次：长按自动重复或按键抖动不会误走第二次恢复；松开后可立即再次按下。
- 休眠、解锁或点开菜单栏后会自动重新注册快捷键；磁盘上的应用比正在运行的进程更新时会自动重启，不必再手动退出再进。
- 可选“登录时启动”，默认关闭，只用系统登录项，不新增后台进程。开机后要快捷键继续可用，打开这个开关即可。
- 新快捷键先注册再替换；发生冲突时旧快捷键继续有效。
- 设置窗口默认使用 `⌘3` 显示或隐藏，也可以直接重新录制。
- 无辅助功能权限时，Carbon 快捷键仍可激活、隐藏和重新打开窗口；精确恢复最小化窗口和主动拦截 `fn/🌐` 热键需要用户授权。
- 只使用 Swift、AppKit、Carbon、ApplicationServices 与 ServiceManagement，无第三方运行依赖、遥测或账号系统。更新检查仅访问 GitHub 发行版接口。

## 使用

首次启动会打开单页设置，之后默认按 `⌘3` 显示或隐藏：

1. 点击“添加应用…”从已安装可视应用中选择，或改从磁盘挑选 `.app`；可重复添加多个应用。
2. 在每个应用右侧分别录制快捷键。录制时会先确认应用还在，再探测该组合是否空闲（含「本机已占用」列表，该列表可在设置中自行增删）；占用则不改原键。
3. Esc 取消；Delete 或 Backspace 清除。
4. 每个应用可独立设置“未运行时自动打开”，也可单独移除。
5. 设置保存后立即生效，并通过 UserDefaults 保存在本机。

点击应用图标或名称可更换 App，保留该行原快捷键；呼出／恢复可使用快捷键、行尾“更多”菜单或菜单栏。聚焦应用行后可按空格或回车呼出／恢复。

访达：添加应用 → 搜索“访达” → 添加 → 点击该行“未设置”录制自己的快捷键。首次添加不会自动占用组合。

主题：在窗口底部选择默认、GitHub 极客、WAICY 流彩、千里江山、故宫红墙、敦煌飞天、液态键帽、紫蓝流光、蒙特雷曙霞或青花瓷。主题单独保存在本机，不包含在配置导出 JSON 中。

菜单栏包含：打开 AiGoodChange、呼出应用、启用/停用全部快捷键、辅助功能权限、导出/导入配置、状态与版本、退出。“设置与帮助”面板管理登录启动和权限，macOS 与应用快捷键参考默认收起。

## 两次按键行为

- 原本隐藏：第一次呼出；第二次重新隐藏。
- 目标已经在前台：按快捷键会直接安全隐藏，不关闭任何窗口。
- 原本全部窗口最小化：有辅助功能权限时只恢复一个窗口；第二次只重新最小化该窗口。
- 原本已显示：第一次激活；第二次安全隐藏，并尽量回到之前的前台应用。
- 刚呼出后立刻再按一次，即使系统还没把该应用标成前台，也会隐藏。
- 两次按键之间若用户已经切到别的常规应用、目标进程重启或窗口已被隐藏，这次会重新呼出，而不是吞掉按键。
- 目标应用启动或重开超时后，迟到的旧回调不会覆盖后来建立的新会话。
- 没有辅助功能权限时，只把当前空间里真正可见的窗口当成“已经出来”；最小化或在别的桌面的窗口会走系统“重新打开应用”，避免只改菜单栏、窗口却不出现。

辅助功能权限只在用户点击“授权恢复与 fn…”、菜单同名项目，或明确录制/自动分配 `fn/🌐 + 数字` 时请求。

## 快捷键规则

- 优先推荐未占用的 `⌘ + 任意数字（0–9）`；`⌘` 数字用尽后推荐 `fn/🌐 + 数字（0–9）`。Fn 通道使用 `CGEventTap` 的按下/释放事件对并拦截已绑定组合，需要辅助功能授权。
- 使用字母、方向键或 F1–F12 时，至少两个修饰键，且必须包含 Command 或 Control。
- `fn/🌐 + Q`、`fn/🌐 + 方向键` 等已知 macOS 组合不会注册。`fn/🌐 + F1–F12` 的事件会受“将 F1、F2 等键用作标准功能键”影响，本版明确不注册；该设置开启时顶部键默认发 F1–F12，关闭时通常要按 Fn 才发 F1–F12，外接键盘固件还可能改写行为。
- 若系统把单按 Globe 配置为切换输入法、显示表情与符号或开始听写，录制 `fn/🌐 + 数字` 时会警告可能不可达或同时触发系统行为。
- Carbon 独占注册负责普通组合；`fn/🌐 + 数字` 由事件 tap 监听。候选键先注册，失败时旧键保持有效。
- 每个应用必须使用不同组合；冲突项不会影响其他已注册快捷键。
- 「本机已占用」列表同样检测 Fn 组合。macOS 无法暴露所有系统动作、应用非独占快捷键或第三方键盘固件映射，因此不能检测全部冲突，Fn 组合保存时会保留风险提示。

“设置与帮助”中的 macOS 和应用快捷键内容用于参考；用户手动添加的占用记录会参与冲突检查。

## 验证

```bash
bash selfcheck.sh
```

自检默认在 `build/checks/` 执行：debug 构建、签名校验、快捷键规则、事务替换、按下/释放门控、多热键路由、旧配置迁移、状态机与异步启动代际分支、菜单与配置模型冒烟、600／760／1080 宽度的布局检查，以及五次进程内空闲 CPU/峰值 RSS 采样。诊断模式不会读取或写入用户设置，测量进程会按时自行结束，也不调用 `ps` 或结束其他进程。

## 项目结构

- `QuickToggle.swift`：全部应用逻辑与自检入口。
- `VERSION`：版本号唯一来源，`build.sh` 构建时注入。
- `build.sh`：无第三方依赖的 App Bundle 构建（默认 debug，`--release` 为优化构建）。
- `package.sh`：在 `build/package/` 做 release 构建并打出分发 zip。
- `selfcheck.sh`：构建、自检、冒烟和资源测量。
- `CHANGELOG.md`：版本更新日志。
- `Assets/QuickToggleIcon-0817v2.icns`：应用图标。
- `docs/使用说明.md`：中文详细说明。
- `docs/screenshots/`：设置页示例图。
- `docs/tweet/`：推文配图。

`build/`、`reviews/`、App 包和配置备份只留本机。`QUICKTOGGLE_BUILD_DIR` 可指定构建、自检或打包目录；自检与打包默认避开日常运行的 `build/AiGoodChange.app`。

## 隐私与许可

AiGoodChange 不上传应用列表或快捷键，不包含遥测或账号。更新检查默认每天一次，也可关闭，仅向 GitHub 请求公开发行信息；应用选择、快捷键和主题保存在本机。源码采用 [MIT License](LICENSE)，主题沿用 [AiGoodBro 上游许可](Assets/AiGoodBro-Themes-LICENSE.txt)。

为兼容既有安装，bundle ID `com.quicktoggle.app`、配置键、内部可执行文件名、备份文件名和构建环境变量保留 QuickToggle 命名。覆盖安装前先退出旧实例，沿用原有签名身份。

---

## English

AiGoodChange (formerly QuickToggle / 轻唤) is a lightweight, native macOS menu-bar utility for assigning global shortcuts to apps. Press once to reveal an app; press again to safely restore the previous state.

The source is based on `1.0.0` with unreleased updates. Existing release downloads retain the old name and do not include these changes.

### Why AiGoodChange

When your Mac has many windows open, switching can interrupt what you are doing. Mission Control gives you thumbnails to scan; ⌘Tab gives you apps to cycle through. Even when you already know which app you need, you still have to find it, then switch back after a quick check.

AiGoodChange gives your frequent apps fixed shortcuts. Press an app’s shortcut to bring it forward, then press again to hide or restore it according to its prior state. Finder can have its own shortcut too. If your preferred tool changes, replace the target app and keep the shortcut your hands already know. Start with the two or three apps you switch to most often.

### Download and run

- Apple Silicon Mac with macOS 13 or later.
- The historical download is `QuickToggle-1.0.0-macOS-arm64.zip` from [QuickToggle 1.0.0](https://github.com/BLACKIELF/AiGoodChange/releases/tag/v1.0.0).
- Builds use ad-hoc signing unless a local development certificate is available. They are not Apple-notarized. It is not installed into `/Applications` automatically. If Gatekeeper blocks the first launch, explicitly allow it in System Settings > Privacy & Security, or build from source.

Building from source requires Xcode Command Line Tools:

```bash
bash build.sh
open "build/AiGoodChange.app"
```

### Features

- Search apps or shortcuts, filter pending setup and occupied combinations, and inspect each shortcut’s registration state. Preferences and guides have a separate scrolling panel; feedback remains visible.
- Multiple app bindings with one independently recorded shortcut per app. Unused `⌘0–9` combinations remain the first choice; after the Command digits are exhausted, AiGoodChange recommends `fn/🌐0–9`. `⌘⌥K`, `⌘⇧K`, `⌃⇧K`, `⌘⌥←/→`, and `⌃⇧F1–F12` remain available.
- Scans installed visible apps into an “add app” picker. Helpers and background-only components stay out of the main list, and nothing is registered automatically.
- The local occupied-hotkey list is user-editable in Settings; the recorder keeps avoiding whatever it contains.
- Configuration export/import from the menu bar: a JSON backup carries every binding, the settings shortcut, the enabled state, and the occupied list. Import skips apps that are not installed and names them.
- The row’s More menu contains reveal/restore, app replacement, launch-if-needed, shortcut help, and removal.
- Click the app icon or name to replace its target while retaining the shortcut. Reveal/restore remains available through the shortcut, More menu, menu bar, or Space/Return on the focused row.
- Add Finder through the app picker (search “访达”), then record a shortcut yourself. Finder is initially left unassigned.
- Select any of the 10 AiGoodBro themes in the footer. Light/dark appearance follows macOS. Theme choice is stored separately from configuration exports.
- Check GitHub releases manually or once a day. Updates are never downloaded or installed automatically.
- Remembers whether the app was hidden, minimized, or visible and restores conservatively on the second press.
- One physical press triggers once: key repeat and switch bounce cannot accidentally perform the second action; releasing the keys immediately rearms the shortcut.
- Optional “Open at Login”, off by default, using the system login item only.
- Transactional hot-key replacement: a conflicting candidate never removes the working shortcut.
- The settings window defaults to `⌘3` and can be changed in place.
- Carbon shortcuts, activation, hiding, and window reopening work without Accessibility access; exact minimized-window restoration and active interception of `fn/🌐` shortcuts are opt-in.
- Native Swift, AppKit, Carbon, ApplicationServices, and ServiceManagement only—no third-party runtime dependencies, telemetry, accounts, or sync. The update checker requests public release metadata from GitHub.

### How it behaves

- Hidden app: reveal it, then hide it again.
- Frontmost app: hide it safely without closing any window.
- Fully minimized app: with Accessibility permission, restore one window and minimize only that window again.
- Visible app: activate it, then hide it on the second press and return focus to the previous app.
- A second press right after reveal still hides, even if macOS has not yet marked the app frontmost.
- If the user has already switched to another regular app, the target restarted, or it is hidden again, the next press reveals instead of being swallowed.
- A late completion from a timed-out or superseded launch cannot overwrite a newer toggle session.
- Without Accessibility permission, only on-screen windows in the current Space count as visible. Minimized windows or windows on another Space trigger a system reopen, so the menu bar does not change while the window stays hidden.

Accessibility permission is requested only after the user clicks the permission control/menu item or explicitly records or auto-assigns an `fn/🌐 + digit` shortcut.

### Shortcut rules

- Prefer an unused `⌘ + digit (0–9)`; after those are exhausted, use `fn/🌐 + digit (0–9)`. Fn shortcuts use an active `CGEventTap`, preserve key-down/key-up gating, and require Accessibility permission.
- Letters, arrow keys, and F1–F12 require at least two modifiers and must include Command or Control.
- Known macOS Fn combinations such as `fn/🌐 + Q` and Fn-arrow navigation are blocked. `fn/🌐 + F1–F12` is not registered because its delivered event depends on “Use F1, F2, etc. keys as standard function keys” and keyboard firmware.
- A configured single-press Globe action (input source, emoji, or dictation) produces an explicit overlap warning. Carbon exclusive registration and the local occupied list detect what they can, but macOS cannot expose every system, app, or keyboard-firmware conflict.

The shortcut guides are references; manually added occupied combinations participate in conflict checks.

### Verification

Run `bash selfcheck.sh` to build under `build/checks/`, verify the signature, execute shortcut/transaction/press-gating/state-machine checks, smoke-test the menu and configuration model, and take five in-process idle CPU/peak-RSS samples. Diagnostic modes do not read or modify user preferences, invoke `ps`, or terminate other processes; the measurement process exits on its own.

### Privacy and license

AiGoodChange has no telemetry and does not upload app selections or shortcuts. The optional daily update check requests public GitHub release information. Preferences remain in local UserDefaults. The bundle ID, preference keys, internal executable, backup filenames, and build environment variables retain their QuickToggle identifiers for compatibility. Source code is available under the [MIT License](LICENSE), with the [upstream AiGoodBro theme license](Assets/AiGoodBro-Themes-LICENSE.txt) included.
