cmake_minimum_required(VERSION 3.16)

project(LiveWallpaper LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)


add_executable(LiveWallpaper MACOSX_BUNDLE LiveWallpaper.mm LineModule.m LineModule.h)

set_source_files_properties(LiveWallpaper.mm PROPERTIES
    COMPILE_FLAGS "-std=c++17"
)

set_target_properties(LiveWallpaper PROPERTIES
    INSTALL_RPATH "@executable_path/../Frameworks"
    BUILD_WITH_INSTALL_RPATH TRUE
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_IDENTIFIER "com.biosthusvill.LiveWallpaper"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/custom-Info.plist.in"
)

target_link_libraries(LiveWallpaper
    "-framework Cocoa"
    "-framework QuartzCore"
    "-framework AVFoundation"
    "-framework Foundation"
    "-framework CoreMedia"
    "-framework AVKit"
    "-framework ApplicationServices"
    "-framework ServiceManagement"
)
