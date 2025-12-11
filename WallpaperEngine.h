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




@interface WallpaperEngine : NSObject

+ (instancetype)sharedEngine;

- (instancetype)init;

- (void)startWallpaperWithPath:(NSString *)videoPath
                    onDisplays:(NSArray<NSNumber *> *)displayIDs;

- (void)applyWallpaperToDisplay:(CGDirectDisplayID)displayID
                      videoPath:(NSString *)videoPath;

- (void)killAllDaemons;

- (NSString *)thumbnailCachePath;
- (NSString *)staticWallpaperCachePath;

- (void)clearCache;
- (void)resetUserData;

- (void)generateThumbnailsForFolder:(NSString *)folderPath
                     withCompletion:(void (^)(void))completion;

- (void)generateStaticWallpapersForFolder:(NSString *)folderPath
                           withCompletion:(void (^)(void))completion;

- (NSString *)videoQualityBadgeForURL:(NSURL *)videoURL;
- (NSImage *)image:(NSImage *)image withBadge:(NSString *)badge;

- (void)setupNotifications;
- (void)removeNotifications;

- (BOOL)enableAppAsLoginItem;

- (NSString *)getFolderPath;
- (void)checkFolderPath;

@property(nonatomic, assign) BOOL generatingImages;
@property(nonatomic, assign) BOOL generatingThumbImages;
@property(nonatomic, strong) NSString *currentVideoPath;
@property(nonatomic, assign) std::list<pid_t> daemonPIDs;

@end

CGImageRef CompressImageWithQuality(CGImageRef image, float qualityFactor);

#endif
