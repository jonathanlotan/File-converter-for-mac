<div align="center">

<img src="docs/images/icon.png" width="112" alt="">

# Swivel

**拖动文件，按一下键，放到转盘上。**<br>
在 Mac 上转换、裁剪、压缩、查看和分享文件，无需上传到任何地方。

[![下载 Mac 版](https://img.shields.io/badge/Download_for_Mac-Swivel.dmg-0071e3?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/jonathanlotan/Swivel/releases/latest/download/Swivel.dmg)

```bash
brew install --cask jonathanlotan/tap/swivel
```

[![最新版本](https://img.shields.io/github/v/release/jonathanlotan/Swivel?color=1d1d1f&label=release)](https://github.com/jonathanlotan/Swivel/releases/latest)
[![macOS 13 或更高版本](https://img.shields.io/badge/macOS-13%2B-1d1d1f?logo=apple&logoColor=white)](#faq)
[![Apple 芯片](https://img.shields.io/badge/Apple%20silicon-arm64-1d1d1f)](#faq)
[![完全离线](https://img.shields.io/badge/network-none-2ea44f)](#private-by-design)
[![MIT 许可证](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)
[![测试](https://github.com/jonathanlotan/Swivel/actions/workflows/ci.yml/badge.svg)](https://github.com/jonathanlotan/Swivel/actions/workflows/ci.yml)

[English](README.md) · 简体中文

<sub>Swivel 的界面只有英文，文中的菜单和按钮名称均保留英文原文。</sub>

### [▶ 在浏览器里试试转盘](https://jonathanlotan.github.io/Swivel/)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-demo.dark.gif">
  <img src="docs/images/wheel-demo.light.gif" width="460" alt="动画：拖动一张照片时，转盘打开并列出格式；滚动切换到 Actions，再切换到 Tools；放到 Crop › Square 上，会在原图旁边保存一份正方形副本。">
</picture>

</div>

<a id="why-swivel"></a>
## 为什么选 Swivel

- **免费开源**。MIT 许可证。没有试用期，不用注册账号，没有 App 内购买。
- **无需授权**。转盘不需要辅助功能或输入监控权限（[原理](#how-it-works)）。
- **从不联网**。没有任何网络代码，一旦链接进网络 API，测试就会失败。
- **小巧、原生**。用 Swift 和 Apple 自家的框架编写，已签名并通过 Apple 公证。
- **支持快捷指令**。提供 Convert File（转换文件）操作，另有现成的 Convert to JPEG、Compress（压缩）和 Convert to PDF，在聚焦搜索里也能用。
- **还有命令行**。与 App 是同一个引擎，比如 `swivel convert --to image.jpeg *.heic`，随 App 一起安装。

<a id="one-gesture-three-rings"></a>
## 一个手势，三个圆环

在任何地方开始拖动文件，访达里或桌面上都行，然后**按一下**某个键。转盘会在指针处打开。放到某个扇区上就执行它，放在中间则取消。带 › 的扇区，停留片刻会展开第二圈。

<table>
  <tr>
    <th align="center"><kbd>⇧</kbd> Shift：<b>Convert（转换）</b></th>
    <th align="center"><kbd>⌘</kbd> Command：<b>Tools（工具）</b></th>
    <th align="center"><kbd>⌃</kbd> Control：<b>Actions（操作）</b></th>
  </tr>
  <tr>
    <td>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-convert.dark.png">
        <img src="docs/images/wheel-convert.light.png" alt="一张 HEIC 照片的 Convert 圆环，指向 JPEG，中间显示 IMG_2041.jpg">
      </picture>
    </td>
    <td>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-tools.dark.png">
        <img src="docs/images/wheel-tools.light.png" alt="Tools 圆环，Crop 已展开，指向 Square">
      </picture>
    </td>
    <td>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-actions.dark.png">
        <img src="docs/images/wheel-actions.light.png" alt="Actions 圆环，Share 已展开，指向 Mail">
      </picture>
    </td>
  </tr>
  <tr>
    <td valign="top">这些文件能转成的格式：图片、视频、音频、文档和 PDF。不常用的格式在 More（更多）里。</td>
    <td valign="top">调整大小、裁剪、旋转、压到指定大小、压缩、移除背景或元数据、识别文字、合并或拆分 PDF、制作压缩包。</td>
    <td valign="top">分享（AirDrop、邮件、信息、备忘录、照片或任意 App）、查看元数据、放到悬浮暂存架上、拷贝、移动、拷贝路径、在终端中打开。</td>
  </tr>
</table>

- **滚动**可以切换圆环。向上滚动切到下一个，顺序是 Actions、Tools、Convert。直接按另一个键也行。
- **结果保存在原文件旁边**，命名方式和访达一致：`IMG_2041.jpg`、`IMG_2041 2.jpg`、`IMG_2041 (square).heic`。不会覆盖任何文件，原文件也不会被改动。
- **用哪个键由你决定**，在 Settings（设置）里修改。开始拖动时已经按住的键不算数，所以普通的拖动不受影响。

<a id="crop-and-metadata"></a>
## 裁剪和元数据

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/crop-editor.dark.png">
  <img src="docs/images/crop-editor.light.png" width="760" alt="裁剪编辑器：一张横向照片，裁剪比例为 4:3，带有 Aspect 菜单、宽度和高度输入框，以及 Reset、Skip、Cancel 和 Crop & Next 按钮">
</picture>

**Crop（裁剪）** 可以直接在转盘上选 Square（正方形）、4:3、3:2、16:9、3:4、2:3 和 9:16，从画面中间裁切。**Custom…（自定义…）** 会打开上图的编辑器：拖动控制点、选一个比例，或者输入精确尺寸，裁剪结果会缩放到这个尺寸。选了多张照片时会逐张处理，并沿用同一比例。

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/metadata.dark.png">
        <img src="docs/images/metadata.light.png" alt="一张照片的元数据窗口：相机、镜头、曝光、拍摄日期和位置坐标，以及 Remove Metadata 和 Copy All 按钮">
      </picture>
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings.dark.png">
        <img src="docs/images/settings.light.png" alt="General 设置页：每个圆环由哪个键打开、菜单栏图标、登录时启动，以及使用的终端 App">
      </picture>
    </td>
  </tr>
  <tr>
    <td valign="top"><b>Metadata（元数据）</b> 显示文件自身记录的信息：照片的相机、镜头、曝光和位置；音视频的音轨和编解码器；PDF 的页数和作者。<b>Remove Metadata（移除元数据）</b> 会为照片、视频或 PDF 另存一份干净的副本。</td>
    <td valign="top"><b>Settings</b>：每个圆环用的键、图片和视频质量、常用格式、登录时启动，以及是否显示菜单栏图标。</td>
  </tr>
</table>

<a id="what-it-handles"></a>
## 支持哪些文件

<details>
<summary><b>图片</b>：JPEG、PNG、HEIC、AVIF、TIFF、GIF、PDF 等</summary>

- 可写入：JPEG、PNG、HEIC、AVIF、TIFF、GIF、PDF、BMP、JPEG 2000、ICNS、ICO、PSD、TGA。
- 还可读取：WebP、EXR 和 SVG。JPEG XL 和相机 RAW 借助 macOS 应该也能打开，但没有测试过。
- GIF 动图可以转成 MP4 或 MOV。
- 工具：调整大小、裁剪、旋转和翻转、压到 1、5、8 或 25 MB 以内、压缩、移除背景（macOS 14 或更高版本）、移除元数据、识别文字、合并成一个 PDF。
- Fit to Size（压到指定大小）先降低画质，再缩小像素尺寸；如果结果会小到或糊到没法用，就宁可不保存。
- 照片方向保持正确，元数据默认保留，除非你关掉这个选项。
</details>

<details>
<summary><b>视频和音频</b>：MP4、MOV、ProRes、GIF、M4A、WAV、FLAC…</summary>

- 视频：MP4（H.264 或 HEVC）、MOV、MOV（ProRes）、M4V、GIF，或者一帧静态画面。
- 视频中的声音：M4A、WAV、AIFF 或 FLAC。
- 音频：M4A（AAC 或无损）、WAV、AIFF、FLAC、AAC、CAF。24 位的仍保持 24 位。
- 视频工具：压缩、缩放到 4K、1080p、720p 或 540p（只提供比原片小的尺寸）、移除音频、移除元数据（位置、日期、相机和标题，无需重新编码）。
- 音频工具：压缩成更小的 AAC 文件（仅对无损音频和码率高于所选值的音频提供）。
</details>

<details>
<summary><b>文档和 PDF</b>：Word、RTF、HTML、文本、PDF</summary>

- 纯文本、RTF、HTML、Word（.docx 和 .doc）与 OpenDocument 之间互转，也都能转成 PDF。
- PDF 转文本，或逐页转成 PNG、JPEG、HEIC 或 TIFF 图片。
- 合并、拆分和压缩 PDF，移除其元数据（标题、作者、关键词），识别扫描件中的文字。
</details>

<details>
<summary><b>压缩包</b>：ZIP、TAR.GZ、TAR.XZ、7Z、Apple Archive</summary>

- 把任意文件或文件夹打包、解压压缩包，或在格式之间转换。
- 解压时绝不会写到它自己的文件夹之外。
</details>

需要第三方编码器的格式（写入 WebP 或 JPEG XL、MP3、Ogg、WebM、MKV）不在支持范围内。

**其他入口**：把文件拖到菜单栏图标上，从它的菜单里选 **Convert Files…（转换文件…）**，在访达里用 **服务（Services）› Convert with Swivel…** 或快速操作，或者用 **打开方式（Open With）**。

- **快捷指令**：**Convert File** 操作接收文件和一种转换（JPEG、Resize › 1920 px、Crop › Square…）并返回结果，因此文件夹自动化或快速操作不用转盘也能转换。**Convert to JPEG**、**Compress** 和 **Convert to PDF** 是现成的，在聚焦搜索里也能用：“Compress with Swivel”。

<a id="the-command-line"></a>
### 命令行

App 自带 `swivel`，就是去掉转盘的同一个引擎。用 Homebrew 安装时它会被放进 `PATH`；否则它位于 `Swivel.app/Contents/Helpers/swivel`。

```bash
swivel list IMG_2041.heic                  # 这个文件能转成什么
swivel convert --to image.jpeg *.heic      # 结果保存在各自的原文件旁边
swivel formats                             # 列出所有转换，以及这台 Mac 能否执行
```

<a id="private-by-design"></a>
## 隐私优先

所有处理都在你的 Mac 上完成，使用 Apple 自家的框架（ImageIO、AVFoundation、AudioToolbox、PDFKit、Vision）和 macOS 自带的工具（`textutil`、`ditto`、`tar`、`aa`）。没有网络代码，没有账号，没有遥测；有测试专门检查没有链接任何网络 API。元数据窗口里的位置只显示为坐标，不显示地图，因为地图需要联网。详见[隐私政策](https://jonathanlotan.github.io/Swivel/privacy.html)。

<a id="how-it-works"></a>
## 工作原理

- **不需要权限也能察觉拖动**。任何 App 都可以监听其他 App 中的鼠标按下事件，并读取拖拽粘贴板的变更计数和数据类型（但读不到内容）。Swivel 在鼠标按下时进入待命状态，按住期间每秒检查 60 次，只有拖拽粘贴板发生了变化、且其中是文件 URL 时，才认定这是一次文件拖动。这时按一下对应圆环的键，就会打开转盘：一个不会激活自身的面板（non-activating panel），由它接收拖放。监听其他 App 中的按键需要辅助功能或输入监控权限，而读取当前按下了哪些修饰键则不需要。
- **不覆盖，不留半成品**。每个结果先写入临时文件夹，再用 `renamex_np(…, RENAME_EXCL)` 移到目标位置；目标已存在时它会直接失败而不是替换文件，于是文件名顺延为 `IMG_2041 2.jpg`。任务取消或失败时不会留下任何东西。
- **压缩包只解到自己的文件夹里**。任何会落到该文件夹之外的条目，解压时都会被拒绝。
- **离线，有测试把关**。测试会对构建出的 App、快速操作和 CLI 运行 `nm -u`，只要出现 `URLSession`、CFNetwork、socket 或 `getaddrinfo` 就会失败。快速操作没有网络 entitlement。
- **这些图片就是 App 本身**。本页图片由一个测试（`make readme-images`）用 App 自己的视图渲染而成，所以不会和实际发布的版本脱节。

<a id="faq"></a>
## 常见问题

<details>
<summary><b>为什么不能写入 WebP、MP3、WebM 或 MKV？</b></summary>

macOS 没有这些格式的编码器，而 Swivel 只使用 macOS 自带的东西。WebP 可以读取。要写入这些格式，就得捆绑 libwebp、LAME 或 ffmpeg，它们各有各的许可证和体积；以后也许会作为可选的附加组件提供。
</details>

<details>
<summary><b>支持哪些 Mac 和 macOS 版本？</b></summary>

搭载 Apple 芯片、运行 macOS 13 Ventura 或更高版本的 Mac。在 macOS 26 上测试过，每次改动时转换引擎的测试也会在 macOS 15 上运行。欢迎在 [Issues](https://github.com/jonathanlotan/Swivel/issues) 里反馈其他版本上的情况。
</details>

<details>
<summary><b>怎么更新？</b></summary>

Swivel 从不检查更新，因为那需要联网。可以运行 `brew upgrade --cask swivel`，或者在本仓库订阅新版本发布（**Watch › Custom › Releases**）。
</details>

<details>
<summary><b>和 Tangerine 有什么不同？</b></summary>

Shift 拖拽这个想法来自 Leap Studio 的 [Tangerine](https://tangerineformac.com)，那是一款付费 App，格式和工具更多。如果你想要一款有商业支持的转换工具，推荐购买它。Swivel 是对这个想法的独立开源实现，依据的是 Tangerine 公开的介绍，没有使用它的任何代码或素材。
</details>

<details>
<summary><b>怎么卸载？</b></summary>

从菜单栏退出，然后把 Swivel.app 移到废纸篓（或者运行 `brew uninstall --cask swivel`）。它的设置保存在 `~/Library/Preferences/io.github.jonathanlotan.Swivel.plist`。
</details>

<a id="building"></a>
## 构建

需要 Xcode 26 或更高版本（构建和测试用的是 Xcode 27.1），以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
make run
```

| 命令 | 作用 |
|---|---|
| `make run` | 构建并打开 App（它常驻在菜单栏） |
| `make test` | 运行全部测试：转换引擎 65 个，App 104 个 |
| `make app` | 生成 Xcode 项目并构建 App |
| `make core-test` | 只运行转换引擎的测试 |
| `make cli` | 构建 `swivel` 命令并输出它的路径 |
| `make readme-images` | 用 App 自己的视图渲染本页图片 |
| `make release` | 签名、公证并打包 `Swivel.dmg`（[说明](docs/dev/releasing.md)） |
| `make clean` | 删除构建产物 |

构建产物放在 `~/Library/Caches/Converter`，而不是项目文件夹里，因为 iCloud 云盘的文件属性会破坏代码签名。本地构建使用 ad hoc 签名，只能在你自己的 Mac 上运行。

<a id="project-layout"></a>
## 项目结构

- `Packages/ConverterCore`：转换引擎，一个不含 UI 代码的 Swift 包，另外还有 `swivel` 命令及其测试。
- `Converter/App`：用 SwiftUI 和 AppKit 编写的菜单栏 App，包括转盘、菜单、任务队列、设置、裁剪编辑器、元数据窗口、欢迎窗口和文件操作。
- `Converter/QuickAction`：访达快速操作扩展。
- `Converter/AppTests`：App 的测试，包括渲染本页图片的渲染器。
- `docs/`：[浏览器试用页](docs/index.html)；[`docs/dev`](docs/dev) 里是开发[计划](docs/dev/plan.md)、[验证报告](docs/dev/verification.md)，以及针对 macOS 26 和 27 的[设计笔记](docs/dev/design.md)。

<a id="contributing"></a>
## 参与贡献

欢迎提交 bug 报告、格式需求和 pull request，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

<a id="credits"></a>
## 致谢

作者 Jonathan Lotan，开发中得到了 [Claude Code](https://claude.com/claude-code) 的帮助。Shift 拖拽手势的灵感来自 [Tangerine](https://tangerineformac.com)。

如果 Swivel 让你少跑了一趟在线转换网站，点个 ⭐ 能帮更多人发现它。
