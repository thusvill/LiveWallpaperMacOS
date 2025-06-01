> [!NOTE]
> ## I'll be away for 5 months, so the repo won't update frequently.

# LiveWallpaper App for MacOS 15+

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
> Adaptive tray icon
> 
> ![Screenshot 2025-05-21 at 8 26 29 AM](https://github.com/user-attachments/assets/9afafdcc-b4d4-48ad-93fe-9341d09c53ff)
> ![Screenshot 2025-05-21 at 8 27 18 AM](https://github.com/user-attachments/assets/5574540a-a78d-4da2-a6c0-fc1c84f28fc5)



> ![Screenshot 2025-05-15 at 6 46 35 AM](https://github.com/user-attachments/assets/167b0c08-454f-4d53-9e65-8798aed6459f)

> ![Screenshot 2025-05-21 at 8 26 46 AM](https://github.com/user-attachments/assets/441ee882-727e-4470-9d28-baa96466e151)


> ![Screenshot 2025-05-15 at 6 46 25 AM](https://github.com/user-attachments/assets/4a0c9302-1892-44cc-9154-32987a0fd887)

> [NOTE] This video shows outdated  software
> 
> https://github.com/user-attachments/assets/c98441e8-de90-456b-8b6d-2a79a1bc2998

For license details, see [LICENSE](LICENSE).
