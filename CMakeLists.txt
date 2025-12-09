cmake_minimum_required(VERSION 3.16)

project(LiveWallpaper LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0")
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(MACOSX_BUNDLE_ICON_FILE livewall.icns)
set(app_icon_macos "${CMAKE_SOURCE_DIR}/asset/livewall.icns")
set_source_files_properties(${app_icon_macos} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)



add_executable(LiveWallpaper MACOSX_BUNDLE ${app_icon_macos} LiveWallpaper.mm LineModule.m LineModule.h DisplayManager.h SaveSystem.h SaveSystem.mm LoadingOverlay.h LoadingOverlay.mm)



add_subdirectory(vendor/yaml-cpp)

target_link_libraries(LiveWallpaper yaml-cpp)

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
    "-framework IOKit"
    "-framework UniformTypeIdentifiers"
)

add_subdirectory(Daemon)

add_custom_command(TARGET LiveWallpaper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_CONTENT_DIR:LiveWallpaper>/MacOS"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:wallpaperdaemon>"
        "$<TARGET_BUNDLE_CONTENT_DIR:LiveWallpaper>/MacOS/"
    COMMENT "Copying wallpaperdaemon into LiveWallpaper.app bundle"
)
