# MacGacha — Apple Silicon 上的 HoYoverse 游戏通用启动器

[![English](https://img.shields.io/badge/English-555555?style=for-the-badge)](../README.md)
[![Русский](https://img.shields.io/badge/%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-555555?style=for-the-badge)](README.ru.md)
[![Українська](https://img.shields.io/badge/%D0%A3%D0%BA%D1%80%D0%B0%D1%97%D0%BD%D1%81%D1%8C%D0%BA%D0%B0-555555?style=for-the-badge)](README.uk.md)
[![Deutsch](https://img.shields.io/badge/Deutsch-555555?style=for-the-badge)](README.de.md)
[![Français](https://img.shields.io/badge/Fran%C3%A7ais-555555?style=for-the-badge)](README.fr.md)
[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-0078D4?style=for-the-badge)](README.zh-CN.md)
[![日本語](https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-555555?style=for-the-badge)](README.ja.md)

> ✨ **[MacGacha 0.2.0](https://github.com/deruta74/MacGacha/releases/tag/v0.2.0) 已发布**，这是首个不带 beta 标记的版本：支持 14 种语言、HoYoPlay 风格的背景和活动、《原神》帧率解锁、《崩坏：星穹铁道》120 FPS、搭配空间音频的环绕声，以及游戏模式。已经在使用 0.1.x？MacGacha 会自行更新。发现问题？欢迎[反馈](#feedback)。

面向 Apple Silicon 的原生 macOS 启动器，支持 **《原神》**、**《崩坏：星穹铁道》** 和 **《绝区零》**。它从 HoYoverse 官方服务器安装、更新和校验游戏，管理 Wine / DXMT / D3DMetal 运行环境，并可一键启动各款游戏。

- 系统要求：配备 Apple Silicon 的 Mac、Rosetta 2（MacGacha 会提示安装），以及 macOS 27 或更新版本。

本仓库的代码和文档可能使用大型语言模型（LLM）和 AI 代理辅助编写或修改。软件依照 [GPL-3.0 许可证](../LICENSE)按“原样”提供，不附带任何担保。

## 安装

1. 从 [Releases](https://github.com/deruta74/MacGacha/releases) 下载 `MacGacha-<version>.dmg`，打开后将 **MacGacha** 拖入**应用程序**。
2. 打开 MacGacha。应用尚未获得 Apple 签名或公证，因此 macOS 会提示无法验证开发者。点击**完成**。
3. 打开**系统设置 → 隐私与安全性**，向下滚动至有关 MacGacha 的提示，点击**仍要打开**，然后确认。

如果没有**仍要打开**按钮，或 macOS 仍然拒绝打开应用，请在“终端”中移除下载隔离标记，然后重新打开 MacGacha：

```bash
xattr -dr com.apple.quarantine /Applications/MacGacha.app
```

此命令只修改 MacGacha 本身，不会更改系统设置。首次启动时，macOS 需要检查应用，因此可能耗时较长。

后续版本通过 MacGacha 菜单中的**检查更新…**获取，因此上述操作只需执行一次。

## 截图

![启动器，显示当前的《原神》背景、版本亮点和活动](../assets/screenshots/launcher.jpg)

| 游戏设置 | 帧率解锁警告 |
|---|---|
| ![《原神》设置中的帧率解锁和环绕声选项](../assets/screenshots/game-settings.jpg) | ![首次启用《原神》帧率解锁前的警告，带有倒计时](../assets/screenshots/fps-warning.jpg) |

| 安装 | 下载中 |
|---|---|
| ![安装窗口中的位置、语音包和磁盘空间估算](../assets/screenshots/install.jpg) | ![正在下载，可暂停](../assets/screenshots/progress.jpg) |

| 一键配置 | 中国大陆 |
|---|---|
| ![配置窗口列出游戏所需的运行环境及其大小](../assets/screenshots/setup.jpg) | ![中国大陆区域，界面语言为简体中文](../assets/screenshots/region-cn.jpg) |

<p align="center"><img src="../assets/screenshots/settings.jpg" width="360" alt="语言、区域、更新和游戏模式设置"></p>

## 开发路线图

**已完成**

- **一键开始游戏。** 点击“开始游戏”后，启动器会准备 Wine 前缀和兼容性绕过方案，启动游戏，然后最小化到程序坞。游戏关闭后，启动器会重新显示，并还原此前隐藏的游戏文件。三款游戏均已在 D3DMetal 和 DXMT 下通过验收。
- **游戏安装。** 通过 HoYoverse 官方分发系统安装、更新、校验和修复游戏，管理语音包、使用已有安装以及卸载游戏。暂停和继续下载在应用重启后仍然有效。下载前和下载过程中都会检查可用空间。如果 macOS 仍占用部分空间（Time Machine 快照、缓存），启动器会说明原因，而不只是提示“空间不足”。游戏菜单中的**检查更新**会立即查找新版本。
- **下载引擎。** 支持断点续传、文件校验以及可在崩溃后恢复的日志。只有哈希匹配的文件才会进入游戏文件夹。文件并行下载和组装，速度接近 2.5 Gbit/s 链路的满速。下载和完整校验会显示剩余时间，耗时较长的步骤会显示已运行时间。
- **启动器。** 在一个窗口中管理三款游戏，使用 HoYoPlay 的背景，并保留其原始顺序。每次打开 MacGacha 都会显示下一张背景，也可通过顶部圆点切换。动态背景由 MacGacha 自带的视频播放器播放，内存占用比网页视图低约三分之一。每张背景对应的版本亮点和 HoYoPlay 当前活动都会在浏览器中打开。
- **《原神》帧率解锁（可选）。** 《原神》游戏设置中提供开关，默认关闭，目标帧率为 120 FPS，也可自定义至最高 360 FPS。MacGacha 会向游戏加载一个小型辅助模块，仅提高帧率上限，采用 [genshin-fps-unlock](https://github.com/34736384/genshin-fps-unlock) 的方法。我们自行进行可复现构建（[发布页](https://github.com/deruta74/MacGacha/releases/tag/genshin-fps-unlock-2)）。首次开启时会提示封号风险。已在国际服《原神》7.1 中测试：连续在线游玩 3.5 小时，维持 120 FPS。
- **《崩坏：星穹铁道》120 FPS。** 国际服和中国大陆服的游戏设置中均有开关，每次启动前将游戏自身保存的帧率设置为 120。全新安装后，请先在游戏中更改任意一项图形设置，让游戏保存设置，然后重新启动游戏。
- **环绕声。** 《原神》和《绝区零》可通过 D3DMetal 输出环绕声，并混音为空间音频，供 AirPods 及其他受支持的耳机使用。六声道及以上的扬声器保留自身的声道布局。默认关闭，每款游戏可单独开启。
- **游戏模式。** macOS 为游戏开启游戏模式，启动器本身不启用。每款游戏以拥有独立名称和图标的应用运行，便于 macOS 识别。已在 D3DMetal 和 DXMT 下确认有效。可在设置中关闭。
- **各游戏独立设置：** 图形后端、帧率限制（关闭、30、60、90 或 120）、显示器、Retina 模式、《绝区零》的 DirectX 12，以及兼容性绕过开关。
- **运行环境。** Wine、DXMT 和 D3DMetal 下载后并存，因此更新不会破坏可用的旧版本。D3DMetal 仅在接受 Apple 条款后安装，也可从现有 Game Porting Toolkit 导入。默认 DXMT 构建使用 CrossOver 的 Wine，CPU 资源消耗约为上一版的 1/2.5。
- **一键配置。** 游戏需要运行环境时，“设置运行环境…”会根据该游戏的设置准确列出所需组件，并一次安装完成。仅当其中包含 D3DMetal 时，才会要求接受 Apple 条款。仍可在运行环境面板中手动选择版本。
- **兼容性组件。** 可在运行环境窗口中安装和移除 jadeite 及 Steam 启动器兼容替身（shim）。该替身由我们使用 Valve 的 Proton 源代码自行进行可复现构建（[发布页](https://github.com/deruta74/MacGacha/releases/tag/steam-shim-proton-10.0-4)）。
- **语言。** 界面支持英语、简体中文、繁体中文、日语、韩语、俄语、乌克兰语、德语、法语、西班牙语、葡萄牙语、印度尼西亚语、泰语和越南语。默认遵循 Mac 的语言优先顺序，也可在设置中自行选择。游戏新闻和美术内容使用界面语言（乌克兰语使用英语，因为 HoYoPlay 不提供乌克兰语）。更改语言会重启 MacGacha，正在进行的下载会自动继续。
- **自动更新**（Sparkle）。MacGacha 菜单中提供**检查更新…**，设置中提供开关。下载更新前会征求同意，且仅在没有游戏、恢复或安装任务运行时安装。更新窗口会显示版本变更。
- **恢复。** 如果启动器在游戏运行时崩溃或退出，重新启动后会再次找到游戏，并在游戏退出后恢复所有状态。在游戏运行期间退出启动器前，会先要求确认。
- **隐私。** 游戏使用各自独立的 Wine 前缀，不链接到桌面、文稿或其他个人文件夹。会话日志保留在你的 Mac 上，可在设置中关闭。用于提交问题的诊断包会移除路径和令牌。

**已手动验证（macOS 27.0.1）**

三款游戏均可通过社区提供的反作弊绕过方案启动和游玩，均无需修改 `/etc/hosts` 或使用管理员权限。测试设备为配备 M5 Pro（48 GB）的 14 英寸 MacBook Pro 和基础款 M5（16 GB）。《绝区零》在两台设备上使用相同的图形预设。

| 游戏 | 默认后端 | M5 Pro，48 GB | M5，16 GB |
|---|---|---|---|
| 崩坏：星穹铁道 4.6 | D3DMetal，限制 60 FPS | 极高画质下 60 FPS。CPU 占用约为 DXMT 的一半，GPU 耗时约 6.5 ms，DXMT 约为 9 ms。 | 尚未测量。 |
| 绝区零 | D3DMetal，DirectX 12 | 高画质下 120 FPS，战斗中的低点仍高于 115。光线追踪设为低时为 70–90 FPS。 | 高画质战斗中为 70–110 FPS，取决于屏幕上的敌人和特效数量。光线追踪设为低时为 50–60 FPS。 |
| 原神 7.1 | D3DMetal，限制 60 FPS | 极高画质、1800×1169、渲染精度 1.2 时稳定 60 FPS，帧时间平稳。解锁帧率后为 120 FPS。 | 1512×982、渲染精度 1.2 时为 60 FPS。 |

DXMT 适用于所有游戏，并作为开源替代方案保留。60 FPS 限制可改善《崩坏：星穹铁道》和《原神》的帧时间不均问题，可按游戏单独调整。

**进行中**

- **中国大陆版本（测试版）。** 设置中的区域切换可显示《原神》《崩坏：星穹铁道》和《绝区零》，并使用各自独立的安装、前缀及设置。《绝区零》可从 miHoYo 服务器安装，并借助我们的 [Wine crypt32 修复](https://github.com/deruta74/MacGacha/releases/tag/crypt32-fix-wine-11.20-1)运行至登录界面之后。《原神》和《崩坏：星穹铁道》仍需进行实际游戏测试，所有中国大陆版本均未测试账号登录。欢迎拥有中国大陆服账号的用户参与测试。
- **《崩坏：星穹铁道》游戏内热更新后的重启**，尚未测试。

**下一步**

1. **Wine 11.21 运行环境**，内置 crypt32 修复，届时将不再需要我们的独立修复组件。
2. **预下载。** 在新版本发布前下载更新内容。
3. **空间音频头部跟踪。** 在空间音频播放时跟随耳机的运动。

<a id="feedback"></a>

## 反馈

发现错误或有新想法？请[提交 issue](https://github.com/deruta74/MacGacha/issues)，说明操作步骤、实际结果、Mac 型号、macOS 版本、游戏及其图形后端。如果遇到安装或启动问题，请附上诊断包：侧边栏中的**诊断** → **导出诊断包…**。诊断包会移除路径和令牌。

## 安全吗？

请自行承担使用风险。为了让游戏在 Wine 下运行，MacGacha 使用社区提供的反作弊绕过方案（jadeite、Steam 启动器替身）。这可能违反 HoYoverse 的服务条款；即使可能性较低，也存在封号风险。如果有所顾虑，请先使用新建的免费账号测试。

默认情况下，MacGacha 仅从 HoYoverse 官方服务器下载游戏，并校验每个文件。它不修改游戏进程，从不编辑 `/etc/hosts`，也不会索取密码。各款游戏在独立的 Wine 前缀中运行，无法访问桌面或文稿。会修改游戏进程的可选功能，例如《原神》帧率解锁，**默认关闭**。首次开启前，MacGacha 会提示额外的封号风险。

## 免责声明

MacGacha 是非官方社区项目，与 HoYoverse（COGNOSPHERE）或 Apple Inc. 没有关联，也未获得其认可或支持。所有游戏名称和商标均属于各自的所有者。

- 使用第三方启动器可能违反 HoYoverse 的服务条款。请自行承担使用风险。
- 在 Wine 下，游戏的反作弊机制会阻止游戏启动。为此，MacGacha 使用社区绕过方案：《崩坏：星穹铁道》使用 [jadeite](https://codeberg.org/mkrsym1/jadeite)，并在游戏运行时通过本地代理屏蔽一个游戏服务器；《原神》和《绝区零》使用 Steam 启动器替身。这些方案可能违反服务条款并导致账号被封禁。默认情况下，MacGacha 不修改游戏进程。部分可选功能会修改进程，例如《原神》帧率解锁；它们默认关闭，启用前 MacGacha 会提示封号风险。
- 软件按“原样”提供。作者不对账号封禁、数据丢失或其他任何损害负责。
- D3DMetal 和 Game Porting Toolkit 的版权归 Apple Inc. 所有，并依据 Apple 的条款授权。启动器会在下载组件前要求接受这些条款。

## 相关项目

- [DXMT](https://github.com/3Shain/dxmt)：基于 Metal 的 Direct3D 11 转译层，是 MacGacha 的两个图形后端之一。
- [jadeite](https://codeberg.org/mkrsym1/jadeite)：MacGacha 为《崩坏：星穹铁道》使用的反作弊绕过方案。
- [genshin-fps-unlock](https://github.com/34736384/genshin-fps-unlock)：帧率解锁工具，MacGacha 的《原神》帧率解锁采用其方法。

## 特别感谢

- [Wine](https://www.winehq.org) 项目，以及 CodeWeavers 提供的 CrossOver 开源 Wine。
- 3Shain 开发的 DXMT 和 yaagl，MacGacha 的启动方案以其研究为基础。
- dbc-hbin 提供的 Wine 11.20 + D3DMetal 构建。
- mkrsym1 开发的 jadeite。
- 34736384 开发的 [genshin-fps-unlock](https://github.com/34736384/genshin-fps-unlock)，我们的《原神》帧率解锁采用其方法。
- Valve 开发的 Proton，我们的 Steam 启动器替身源于其代码。
- an-anime-team，其问题跟踪记录帮助定位了中国大陆版本的崩溃问题（[AAGL #572](https://github.com/an-anime-team/an-anime-game-launcher/issues/572)）；以及 Michael Nelson 向 Wine 上游提交的修复（[MR 11824](https://gitlab.winehq.org/wine/wine/-/merge_requests/11824)）。
- Apple 提供的 D3DMetal 和 Game Porting Toolkit。

## 许可证

Copyright (C) 2026 deruta74。MacGacha 是依照 [GNU General Public License v3.0](../LICENSE) 发布的自由软件，并根据 GPL 第 7(b) 节附加一项条款（参见 [NOTICE](../NOTICE)）：每份转交（分发）的副本，以及所有基于 MacGacha 分发的作品，都必须在源代码和“关于”界面中保留原始项目链接 https://github.com/deruta74/MacGacha 。不对外分发的私人修改不受此要求影响。任何分发的版本，无论是否修改或收费，都必须继续采用 GPL-3.0，并提供源代码。

启动器在运行时下载的组件（Wine、DXMT、D3DMetal、jadeite、Steam 替身、环绕声模块和《原神》帧率辅助模块），以及游戏本身，均遵循各自的许可证和条款。
