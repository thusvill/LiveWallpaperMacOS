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

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface DisplayObjc : NSObject

@property(nonatomic) int daemon;
@property(nonatomic) CGDirectDisplayID screen;
@property(nonatomic, strong) NSString *uuid;
@property(nonatomic, strong) NSString *videoPath;
@property(nonatomic, strong) NSString *framePath;

- (instancetype)initWithDaemon:(int)daemon
                        screen:(CGDirectDisplayID)screen
                          uuid:(NSString *)uuid
                     videoPath:(NSString *)videoPath
                     framePath:(NSString *)framePath;

- (NSString*)getDisplayName;
- (NSString*)getResolution;

@end
