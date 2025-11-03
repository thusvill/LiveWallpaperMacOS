cmake_minimum_required(VERSION 3.15)
project(wallpaperdeamon LANGUAGES CXX OBJCXX)

set(SOURCES
    deamon.mm
)

add_executable(wallpaperdeamon ${SOURCES})

target_link_libraries(wallpaperdeamon
    "-framework Cocoa"
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework UniformTypeIdentifiers"
     "-framework QuartzCore"
)

target_compile_options(wallpaperdeamon PRIVATE
    -fobjc-arc
)