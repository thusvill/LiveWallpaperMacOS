/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#import "DisplayObjc.h"
#include "DisplayManager.h"

@implementation DisplayObjc

- (instancetype)initWithDaemon:(int)daemon
                        screen:(CGDirectDisplayID)screen
                          uuid:(NSString *)uuid
                     videoPath:(NSString *)videoPath
                     framePath:(NSString *)framePath
{
    self = [super init];
    if (self) {
        _daemon = daemon;
        _screen = screen;
        _uuid = uuid;
        _videoPath = videoPath;
        _framePath = framePath;
    }
    return self;
}

- (NSString*)getDisplayName{
    return displayNameForDisplayID(_screen);
}
- (NSString*)getResolution{
    
    size_t width = CGDisplayPixelsWide(_screen);
    size_t height = CGDisplayPixelsHigh(_screen);
    
    NSString * resolution = [NSString stringWithFormat:@"%zuX%zu", width, height];
    return resolution;
}

@end
