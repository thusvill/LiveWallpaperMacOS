cmake_minimum_required(VERSION 3.16)

project(LiveWallpaper LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)


add_executable(LiveWallpaper MACOSX_BUNDLE LiveWallpaper.mm)

# Ensure Objective-C++ file is compiled with C++17
set_source_files_properties(LiveWallpaper.mm PROPERTIES
    COMPILE_FLAGS "-std=c++17"
)

set_target_properties(LiveWallpaper PROPERTIES
    INSTALL_RPATH "@executable_path/../Frameworks"
    BUILD_WITH_INSTALL_RPATH TRUE
)

# Link required frameworks and FFmpeg
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

# set(FFMPEG_ROOT "/opt/homebrew/opt/ffmpeg")
# # Copy FFmpeg .dylib files into the app bundle's Frameworks folder
# add_custom_command(TARGET LiveWallpaper POST_BUILD
#     COMMAND ${CMAKE_COMMAND} -E make_directory
#         "$<TARGET_BUNDLE_CONTENT_DIR:LiveWallpaper>/Frameworks"

#     COMMAND ${CMAKE_COMMAND} -E copy_if_different
#         ${FFMPEG_ROOT}/lib/libavformat*.dylib
#         ${FFMPEG_ROOT}/lib/libavcodec*.dylib
#         ${FFMPEG_ROOT}/lib/libavutil*.dylib
#         ${FFMPEG_ROOT}/lib/libswscale*.dylib
#         "$<TARGET_BUNDLE_CONTENT_DIR:LiveWallpaper>/Frameworks"
# )# Fix dynamic library paths to use @rpath
# add_custom_command(TARGET LiveWallpaper POST_BUILD
# COMMAND install_name_tool
#     -change ${FFMPEG_ROOT}/lib/libavformat.61.dylib
#             @executable_path/../Frameworks/libavformat.61.dylib
#     "$<TARGET_FILE:LiveWallpaper>"

# COMMAND install_name_tool
#     -change ${FFMPEG_ROOT}/lib/libavcodec.61.dylib
#             @executable_path/../Frameworks/libavcodec.61.dylib
#     "$<TARGET_FILE:LiveWallpaper>"

# COMMAND install_name_tool
#     -change ${FFMPEG_ROOT}/lib/libavutil.59.dylib
#             @executable_path/../Frameworks/libavutil.59.dylib
#     "$<TARGET_FILE:LiveWallpaper>"

# COMMAND install_name_tool
#     -change ${FFMPEG_ROOT}/lib/libswscale.8.dylib
#             @executable_path/../Frameworks/libswscale.8.dylib
#     "$<TARGET_FILE:LiveWallpaper>"
# )
# # Ad-hoc re-sign app after modification
# add_custom_command(TARGET LiveWallpaper POST_BUILD
#     COMMAND codesign --force --deep --sign - "$<TARGET_BUNDLE_DIR:LiveWallpaper>"
# )