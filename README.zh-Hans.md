> [!NOTE]
> ## 我将把 Objective C++ 的 UI 逐步改造成 SwiftUI，但 `daemon` 不会改变。

# macOS 14+ 动态壁纸应用 LiveWallpaper

**语言：** [English](README.md) | 简体中文

![Roller](./asset/livewall.png)

这是一个面向 macOS 14+ 的开源动态壁纸应用。

## 使用 Homebrew 安装

在终端运行：`brew tap thusvill/livewallpaper && brew install --cask livewallpaper`

## 从源码编译安装

- macOS 14+
- git
- Xcode
- CMake

运行：
`git clone https://github.com/thusvill/LiveWallpaperMacOS.git && cd LiveWallpaperMacOS && mkdir -p build && cd build && cmake .. && make -j$(sysctl -n hw.ncpu)`

## DMG 安装指南

> [!IMPORTANT]
> ## 修复 “LiveWallpaper.app” 已损坏，无法打开。建议你将该对象移到废纸篓。
> 将应用安装到 Applications 文件夹后，你需要绕过 Gatekeeper 才能运行（因为我不想为开源应用给 Apple 付费）。
>
> 这也会解决占用问题：
>
> `xattr -cr /Applications/LiveWallpaper.app`
>
> 注意：必须使用**递归**删除（`-cr`）。仅执行 `xattr -d com.apple.quarantine /Applications/LiveWallpaper.app` 只会移除应用包根目录的隔离属性，应用内部仍有被隔离的文件，macOS 会继续提示应用已损坏。

点击 “OpenInFinder” 按钮会打开一个文件夹，你可以把壁纸文件放进去。

> [!NOTE]
> 文件名中不要包含多个点号（扩展名的点号除外）！
>
> ## 例如：
>
> - file.1920x1080.mp4 ❌（点号数量 > 1）
> - file-1920x1080.mp4 ✅（点号数量 = 1）

> [!NOTE]
> 目前支持 `.mp4` 和 `.mov`

> https://github.com/user-attachments/assets/3d82e07d-b6b9-4a7d-b6de-5dd05dff3128

## 图库

> ![Application](./asset/application.png)

> ## 这是静态图片，目前 LiveWallpaper 不支持锁屏播放视频。
> ![lockscreen](./asset/lockscreen.png)

> ![settings](./asset/settings.png)

> https://github.com/user-attachments/assets/36fb169e-b7cc-4489-9459-dab07c8dd2c6

> # 性能
> ![p1](./asset/preformance1.png)
> ![p2](./asset/preformance2.png)
> ![p3](./asset/preformance3.png)
> # 多显示器支持

> https://github.com/user-attachments/assets/9575873c-79e6-4eba-a7a5-9408b2cc4ed0

<!--
## 图库
> <img width="185" height="134" alt="Screenshot 2025-11-30 at 1 52 01 PM" src="https://github.com/user-attachments/assets/0c91fb29-e729-485b-8f93-7080aed68881" />
> <img width="185" height="134" alt="Screenshot 2025-11-30 at 1 51 53 PM" src="https://github.com/user-attachments/assets/7848d2fd-8cc4-4271-a4c0-2868bdf00422" />

> ![Screenshot 2025-05-15 at 6 46 35 AM](https://github.com/user-attachments/assets/167b0c08-454f-4d53-9e65-8798aed6459f)

> <img width="2560" height="1600" alt="Screenshot 2025-11-30 at 1 52 34 PM" src="https://github.com/user-attachments/assets/79a24ed8-cc5a-4246-87d0-9c93e04766f2" />

> <img width="2560" height="1600" alt="Screenshot 2025-11-30 at 1 54 35 PM" src="https://github.com/user-attachments/assets/10466b02-77d5-4814-9fb7-a865e62a41ba" />

> https://github.com/user-attachments/assets/748c7078-1f99-4182-876f-08aa59d2bc63
-->

许可协议请参见 [LICENSE](LICENSE)。
