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
#pragma once

#ifndef WallpaperEngine_h
#define WallpaperEngine_h

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <list>
#include <string>
#include "DisplayManager.h"



@interface WallpaperEngine : NSObject

+ (instancetype)sharedEngine;

- (instancetype)init;

- (void) randomWallpapersLid;

- (void)startWallpaperWithPath:(NSString *)videoPath
                    onDisplays:(NSArray<NSNumber *> *)displayIDs;

- (void)applyWallpaperToDisplay:(CGDirectDisplayID)displayID
                      videoPath:(NSString *)videoPath;

- (void)killAllDaemons;

- (NSString *)thumbnailCachePath;
- (NSString *)staticWallpaperCachePath;

- (void)generateThumbnails;

- (void)clearCache;
- (void)resetUserData;

- (void)generateThumbnailsForFolder:(NSString *)folderPath
                     withCompletion:(void (^)(void))completion;

- (void)generateStaticWallpapersForFolder:(NSString *)folderPath
                           withCompletion:(void (^)(void))completion;

- (BOOL)generateStaticImageForVideoPath:(NSString *)videoPath
                             outputPath:(NSString *)outputPath;

- (void)videoQualityBadgeForURL:(NSURL *)url
                     completion:(void (^)(NSString *badge))completion;
- (NSImage *)image:(NSImage *)image withBadge:(NSString *)badge;

- (void)setupNotifications;
- (void)removeNotifications;

- (BOOL)enableAppAsLoginItem;

- (NSString *)getFolderPath;
- (void)checkFolderPath;
- (void)scanDisplays;
- (void)selectFolder:(NSString* )path;

- (NSArray *)getDisplays;

-(void)updateVolume:(double) value;
-(void)updateScaleMode:(NSInteger) mode;

-(void) terminateApplication;

-(BOOL)isFirstLaunch;

- (void)checkWallpapers;

-(void) nextWallpaper;

-(void) startPlaylist;
- (void)startWallpaperRotation;
- (void)stopWallpaperRotation;




@property(nonatomic, assign) BOOL generatingImages;
@property(nonatomic, assign) BOOL generatingThumbImages;
@property(nonatomic, strong) NSString *currentVideoPath;
@property(nonatomic, assign) std::list<pid_t> daemonPIDs;
@property(nonatomic, assign) NSMutableArray<NSString* >* wallpaperList;
@property(assign) int currentWallpaper;
@property (nonatomic, strong) NSTimer *wallpaperTimer;
typedef NS_ENUM(NSInteger, RotationType) {
    RotationTypeSequential = 1,
    RotationTypeRandom = 2
};

@property (nonatomic, assign) RotationType rotationType;
@property (nonatomic, assign) bool isrotationrunning;
@property (assign) int rotationDelay;


@end

CGImageRef CompressImageWithQuality(CGImageRef image, float qualityFactor);

#endif
