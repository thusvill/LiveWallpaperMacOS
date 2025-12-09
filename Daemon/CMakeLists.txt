cmake_minimum_required(VERSION 3.15)
project(wallpaperdaemon LANGUAGES CXX OBJCXX)

set(SOURCES
    daemon.mm
)

add_executable(wallpaperdaemon ${SOURCES})

target_link_libraries(wallpaperdaemon
    "-framework Cocoa"
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework UniformTypeIdentifiers"
     "-framework QuartzCore"
     "-framework IOKit"
)

target_compile_options(wallpaperdaemon PRIVATE
    -fobjc-arc
)