# Live Wallpaper for MacOS

This is a open-source live wallpaper applicationn for MacOS 15+

Currently it doesn't have a Good looking UI, but it gets the work done 🙂


## Befor you run the programme
Pleas make a folde on your `$HOME` directory called `Livewall` and place some video files in it.

This application currently supported for `.mp4` and `.mov` extensions.

I hope to make user able to define video paths and file formats 🙂

## Installation
You can just download the binary from releases or compile this using cmake

> [!IMPORTANT]
> You have to bypass Gatekeeper for run this(I don't want to pay apple for opensource apps)
> 
> This will solve the Damage-File popup
> 
> `xattr -d com.apple.quarantine /path/to/LiveWallpaper.app` 


These dependencies needed to compile(don't need for binary)
- macOS 12 or later (macOS 15 compatible)
- git for clone repo (or download directly)
- Xcode Command Line Tools
  Install with:
    `xcode-select --install`
- Cmake for compile

## Compilation 
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

