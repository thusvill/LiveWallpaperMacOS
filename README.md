
https://github.com/user-attachments/assets/c4eeca24-6210-4fd2-bbb8-40be39de1d40
> [!NOTE]
> ## I’ll be updating this repo from time to time with good features — Please be patient :)!

# LiveWallpaper App for MacOS 15+


![Roller](./asset/livewall.png)

This is an open-source live wallpaper applicationn for MacOS 15+

## Install using brew

Run this on terminal `brew tap thusvill/livewallpaper && brew install --cask livewallpaper`

## Guide for DMG Installation

> [!IMPORTANT]
> ## Fix “LiveWallpaper.app” is corrupted and cannot be opened. It is recommended that you move the object to the recycle bin.
> After you install the app in Application folder you have to bypass Gatekeeper for run this(I don't want to pay apple for opensource apps)
> 
> This will solve the occupation issue
> 
> `xattr -d com.apple.quarantine /Applications/LiveWallpaper.app` 

Click the OpenInFinder button and it'll open a folder, you can place wallpapers in it.

> [!NOTE]
> no dots should be contained on the file name exept the dot for extension
> 
> ## Eg-:
> 
>  - file.1920x1080.mp4 ❌ ('.'s > 1)
> 
>  - file-1920x1080.mp4 ✅ ('.'s = 1)

> [!NOTE]
> Currently support for `.mp4` and `.mov`

> https://github.com/user-attachments/assets/3d82e07d-b6b9-4a7d-b6de-5dd05dff3128



## Installation(Compile from source)
- macOS 15+
- git
- Xcode
- Cmake
  
Run this: `git clone https://github.com/thusvill/LiveWallpaperMacOS.git && cd LiveWallpaperMacOS && mkdir -p build && cd build && cmake .. && make -j$(sysctl -n hw.ncpu)`

## Gallery
> <img width="185" height="134" alt="Screenshot 2025-11-30 at 1 52 01 PM" src="https://github.com/user-attachments/assets/0c91fb29-e729-485b-8f93-7080aed68881" />
> <img width="185" height="134" alt="Screenshot 2025-11-30 at 1 51 53 PM" src="https://github.com/user-attachments/assets/7848d2fd-8cc4-4271-a4c0-2868bdf00422" />
 



> ![Screenshot 2025-05-15 at 6 46 35 AM](https://github.com/user-attachments/assets/167b0c08-454f-4d53-9e65-8798aed6459f)

> <img width="2560" height="1600" alt="Screenshot 2025-11-30 at 1 52 34 PM" src="https://github.com/user-attachments/assets/79a24ed8-cc5a-4246-87d0-9c93e04766f2" />

> <img width="2560" height="1600" alt="Screenshot 2025-11-30 at 1 54 35 PM" src="https://github.com/user-attachments/assets/10466b02-77d5-4814-9fb7-a865e62a41ba" />

 

> https://github.com/user-attachments/assets/748c7078-1f99-4182-876f-08aa59d2bc63
 

For license details, see [LICENSE](LICENSE).
