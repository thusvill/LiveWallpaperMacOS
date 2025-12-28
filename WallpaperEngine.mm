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

#import "WallpaperEngine.h"
#include "DisplayObjc.h"
#include "SaveSystem.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <filesystem>
#import <mach/mach.h>
#include <spawn.h>
#include <unistd.h>

namespace fs = std::filesystem;

extern char **environ;

#define THUMBNAIL_QUALITY_FACTOR 0.05f
#define QUALITY_BADGE_FONT_SIZE 48.0f

static NSString *folderPath = nil;

@implementation WallpaperEngine {
@private
  dispatch_queue_t _wallpaperQueue;
  dispatch_queue_t _thumbnailQueue;
  dispatch_semaphore_t _wallpaperSemaphore;
}

+ (instancetype)sharedEngine {
  static WallpaperEngine *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _generatingImages = NO;
    _generatingThumbImages = NO;
    _currentVideoPath = nil;
    _daemonPIDs = std::list<pid_t>();

    _wallpaperQueue = dispatch_queue_create("com.livewallpaper.wallpaperQueue",
                                            DISPATCH_QUEUE_CONCURRENT);
    _thumbnailQueue = dispatch_queue_create("com.livewallpaper.thumbnailQueue",
                                            DISPATCH_QUEUE_SERIAL);

    _wallpaperSemaphore = dispatch_semaphore_create(2);
    ScanDisplays();

    [self killAllDaemons];
    usleep(2);

    displays = SaveSystem::Load();

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    for (Display display : displays) {
      CGDirectDisplayID displayID = DisplayIDFromUUID(display.uuid);
      if ([defaults boolForKey:@"random"]) {
        [self randomWallpapersLid];
      } else {
        if (!display.videoPath.empty()) {

          [self
              startWallpaperWithPath:[NSString
                                         stringWithUTF8String:display.videoPath
                                                                  .c_str()]
                          onDisplays:@[ @(displayID) ]];
        }
      }
    }
  }
  return self;
}

- (void)randomWallpapersLid {

  NSLog(@"Applying Random Wallpapers!");

  for (Display display : displays) {

    if (!display.videoPath.empty()) {
      CGDirectDisplayID displayID = DisplayIDFromUUID(display.uuid);

      [self startWallpaperWithPath:
                [self getRandomVideoFileFromFolder:[self getFolderPath]]
                        onDisplays:@[ @(displayID) ]];
    }
  }
}

- (NSString *)getRandomVideoFileFromFolder:(NSString *)folderPath {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;

  NSArray<NSString *> *allFiles =
      [fileManager contentsOfDirectoryAtPath:folderPath error:&error];

  if (error) {
    NSLog(@"Error reading directory: %@", error.localizedDescription);
    return nil;
  }

  NSMutableArray<NSString *> *videoFiles = [NSMutableArray array];

  for (NSString *fileName in allFiles) {
    NSString *fileExtension = [[fileName pathExtension] lowercaseString];

    if ([fileExtension isEqualToString:@"mp4"] ||
        [fileExtension isEqualToString:@"mov"]) {
      NSString *fullPath = [folderPath stringByAppendingPathComponent:fileName];
      [videoFiles addObject:fullPath];
    }
  }

  if (videoFiles.count == 0) {
    return nil;
  }

  NSUInteger randomIndex = arc4random_uniform((uint32_t)videoFiles.count);
  return videoFiles[randomIndex];
}

- (void)dealloc {
  [self removeNotifications];
}

- (void)setupNotifications {
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(screensDidChange:)
             name:NSApplicationDidChangeScreenParametersNotification
           object:nil];

  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_Nonnull note) {
                [self handleSpaceChange:note];
              }];

  [[NSWorkspace sharedWorkspace].notificationCenter
      addObserverForName:NSWorkspaceDidWakeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_Nonnull note) {
                [self aweakHandle:note];
              }];
}

- (void)removeNotifications {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleSpaceChange:(NSNotification *)note {
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.spaceChanged"), NULL, NULL, true);
}

- (void)aweakHandle:(NSNotification *)note {

  if ([[NSUserDefaults standardUserDefaults] floatForKey:@"random_lid"]) {
    NSLog(@"Screen Aweaked!");
    [self randomWallpapersLid];
  }
}

- (void)screensDidChange:(NSNotification *)note {
  NSLog(@"Screens changed");
}

- (NSString *)thumbnailCachePath {
  NSArray *cacheDirs = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES);
  NSString *systemCacheDir = cacheDirs.firstObject;
  NSString *bundleName =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

  if (!bundleName || bundleName.length == 0) {
    bundleName = @"LiveWallpaper";
  }

  NSString *thumbnailPath = [systemCacheDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/thumbnails",
                                                          bundleName]];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:thumbnailPath]) {
    [fm createDirectoryAtPath:thumbnailPath
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  return thumbnailPath;
}

- (NSString *)staticWallpaperCachePath {
  NSArray *cacheDirs = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES);
  NSString *systemCacheDir = cacheDirs.firstObject;
  NSString *bundleName =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

  if (!bundleName || bundleName.length == 0) {
    bundleName = @"LiveWallpaper";
  }

  NSString *wallpapersPath = [systemCacheDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/wallpapers",
                                                          bundleName]];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:wallpapersPath]) {
    [fm createDirectoryAtPath:wallpapersPath
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  return wallpapersPath;
}

- (void)clearCache {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  NSString *thumbnailPath = [self thumbnailCachePath];
  if ([fileManager fileExistsAtPath:thumbnailPath]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:thumbnailPath
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath =
            [thumbnailPath stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }

  NSString *staticPath = [self staticWallpaperCachePath];
  if ([fileManager fileExistsAtPath:staticPath]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:staticPath
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath = [staticPath stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }

  NSString *appSupportDir = [NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString *customDir =
      [appSupportDir stringByAppendingPathComponent:@"Livewall"];

  [fileManager createDirectoryAtPath:customDir
         withIntermediateDirectories:YES
                          attributes:nil
                               error:nil];

  if ([fileManager fileExistsAtPath:customDir]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:customDir
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath = [customDir stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }
}
- (void)generateThumbnails {
  if (!_generatingThumbImages) {
    [self generateThumbnailsForFolder:[self getFolderPath]
                       withCompletion:^{
                         dispatch_async(dispatch_get_main_queue(), ^{
                           [[NSNotificationCenter defaultCenter]
                               postNotificationName:@"ThumbnailsGenerated"
                                             object:nil];
                         });
                       }];
  }
}
- (void)resetUserData {
  NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
  [[NSUserDefaults standardUserDefaults]
      removePersistentDomainForName:appDomain];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)generateStaticWallpapersForFolder:(NSString *)folderPath
                           withCompletion:(void (^)(void))completion {
  if (_generatingImages) {
    if (completion)
      completion();
    return;
  }

  _generatingImages = YES;
  NSLog(@"Generating static wallpapers...");

  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *wallpaperCachePath = [self staticWallpaperCachePath];

  if (!folderPath) {
    folderPath = [self getFolderPath];
  }

  if (![fileManager fileExistsAtPath:wallpaperCachePath]) {
    [fileManager createDirectoryAtPath:wallpaperCachePath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
  }

  NSArray<NSString *> *files = [fileManager contentsOfDirectoryAtPath:folderPath
                                                                error:nil];
  if (files.count == 0) {
    NSLog(@"No files found in folder: %@", folderPath);
    _generatingImages = NO;
    if (completion)
      completion();
    return;
  }

  __block NSInteger completedCount = 0;
  NSInteger totalCount = 0;

  for (NSString *filename in files) {
    if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
        ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
      continue;
    }
    totalCount++;

    dispatch_async(_wallpaperQueue, ^{
      dispatch_semaphore_wait(self->_wallpaperSemaphore, DISPATCH_TIME_FOREVER);

      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        [asset
            loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                          completionHandler:^{
                            AVKeyValueStatus status =
                                [asset statusOfValueForKey:@"tracks" error:nil];
                            if (status != AVKeyValueStatusLoaded) {
                              NSLog(@"Failed to load tracks for %@", filename);
                              completedCount++;
                              dispatch_semaphore_signal(
                                  self->_wallpaperSemaphore);
                              return;
                            }

                            [self generateStaticImageFromAsset:asset
                                                      filename:filename
                                                 wallpaperPath:
                                                     wallpaperCachePath];

                            completedCount++;

                            if (completedCount >= totalCount) {
                              self->_generatingImages = NO;
                              if (completion) {
                                dispatch_async(dispatch_get_main_queue(),
                                               completion);
                              }
                            }

                            dispatch_semaphore_signal(
                                self->_wallpaperSemaphore);
                          }];
      }
    });
  }

  if (totalCount == 0) {
    _generatingImages = NO;
    if (completion)
      completion();
  }
}

- (void)generateStaticImageFromAsset:(AVAsset *)asset
                            filename:(NSString *)filename
                       wallpaperPath:(NSString *)wallpaperPath {
  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];

  if (videoTracks.count > 0) {
    AVAssetTrack *track = videoTracks.firstObject;
    CGSize videoSize = track.naturalSize;
    CGAffineTransform transform = track.preferredTransform;
    CGSize renderSize = CGSizeApplyAffineTransform(videoSize, transform);
    generator.maximumSize =
        CGSizeMake(fabs(renderSize.width), fabs(renderSize.height));
  }

  Float64 midpointSec = CMTimeGetSeconds(asset.duration) / 2.0;
  CMTime midpoint =
      CMTimeMakeWithSeconds(midpointSec, asset.duration.timescale);

  [generator
      generateCGImagesAsynchronouslyForTimes:@[ [NSValue
                                                 valueWithCMTime:midpoint] ]
                           completionHandler:^(
                               CMTime requestedTime, CGImageRef image,
                               CMTime actualTime,
                               AVAssetImageGeneratorResult result,
                               NSError *error) {
                             if (result == AVAssetImageGeneratorSucceeded &&
                                 image != NULL) {
                               CGImageRef retainedImage =
                                   CGImageCreateCopy(image);

                               NSString *thumbName =
                                   [[filename stringByDeletingPathExtension]
                                       stringByAppendingPathExtension:@"png"];
                               NSString *thumbPath = [wallpaperPath
                                   stringByAppendingPathComponent:thumbName];
                               NSURL *thumbURL =
                                   [NSURL fileURLWithPath:thumbPath];

                               CGImageDestinationRef dest =
                                   CGImageDestinationCreateWithURL(
                                       (__bridge CFURLRef)thumbURL,
                                       (__bridge CFStringRef)
                                           UTTypePNG.identifier,
                                       1, NULL);

                               if (dest) {
                                 CGImageDestinationAddImage(dest, retainedImage,
                                                            NULL);
                                 CGImageDestinationFinalize(dest);
                                 CFRelease(dest);
                               }

                               CGImageRelease(retainedImage);
                             }
                           }];
}

- (void)generateThumbnailsForFolder:(NSString *)folderPath
                     withCompletion:(void (^)(void))completion {

  // Use atomic operation to prevent race condition
  @synchronized(self) {
    if (_generatingThumbImages) {
      NSLog(@"Thumbnail generation already in progress, skipping...");
      if (completion)
        completion();
      return;
    }
    _generatingThumbImages = YES;
  }

  NSString *thumbnailCachePath = [self thumbnailCachePath];
  NSLog(@"Generating Thumbnails in %@ ...", thumbnailCachePath);

  NSFileManager *fileManager = [NSFileManager defaultManager];

  if (![fileManager fileExistsAtPath:thumbnailCachePath]) {
    [fileManager createDirectoryAtPath:thumbnailCachePath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
  }

  NSArray<NSString *> *files = [fileManager contentsOfDirectoryAtPath:folderPath
                                                                error:nil];
  if (files.count == 0) {
    NSLog(@"No files found in folder: %@", folderPath);
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  // Filter video files and check which need thumbnails
  NSMutableArray<NSString *> *filesToProcess = [NSMutableArray array];
  for (NSString *filename in files) {
    if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
        ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
      continue;
    }

    // Check if thumbnail already exists
    NSString *thumbName = [[filename stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"png"];
    NSString *thumbPath =
        [thumbnailCachePath stringByAppendingPathComponent:thumbName];

    BOOL isDir;
    NSLog(@"THUMB CHECK:\n  filename: %@\n  thumbPath: %@\n  exists: %d isDir: "
          @"%d",
          filename, thumbPath,
          [fileManager fileExistsAtPath:thumbPath isDirectory:&isDir], isDir);

    if (![fileManager fileExistsAtPath:thumbPath]) {
      [filesToProcess addObject:filename];
    }
  }

  if (filesToProcess.count == 0) {
    NSLog(@"All thumbnails already exist");
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  NSLog(@"Processing %lu videos for thumbnails",
        (unsigned long)filesToProcess.count);

  // Use block-scoped variable for counting
  __block NSInteger completedCount = 0;
  NSInteger totalCount = filesToProcess.count;

  for (NSString *filename in filesToProcess) {
    dispatch_async(_thumbnailQueue, ^{
      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
          NSLog(@"Video not found: %@", filePath);

          @synchronized(self) {
            completedCount++;
            if (completedCount >= totalCount) {
              self->_generatingThumbImages = NO;
              if (completion) {
                dispatch_async(dispatch_get_main_queue(), completion);
              }
            }
          }
          return;
        }

        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        [asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
                             completionHandler:^{
                               [self processThumbnailForAsset:asset
                                                     filename:filename
                                                     videoURL:videoURL
                                               completedCount:&completedCount
                                                   totalCount:totalCount
                                                thumbnailPath:thumbnailCachePath
                                                   completion:completion];
                             }];
      }
    });
  }
}
- (void)processThumbnailForAsset:(AVAsset *)asset
                        filename:(NSString *)filename
                        videoURL:(NSURL *)videoURL
                  completedCount:(NSInteger *)completedCount
                      totalCount:(NSInteger)totalCount
                   thumbnailPath:(NSString *)thumbnailPath
                      completion:(void (^)(void))completion {

  NSError *error = nil;

  AVKeyValueStatus trackStatus = [asset statusOfValueForKey:@"tracks"
                                                      error:&error];
  AVKeyValueStatus durationStatus = [asset statusOfValueForKey:@"duration"
                                                         error:&error];

  if (trackStatus != AVKeyValueStatusLoaded ||
      durationStatus != AVKeyValueStatusLoaded) {
    NSLog(@"Failed to load asset metadata for %@: %@", filename,
          error.localizedDescription);

    @synchronized(self) {
      (*completedCount)++;
      if (*completedCount >= totalCount) {
        self->_generatingThumbImages = NO;
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), completion);
        }
      }
    }
    return;
  }

  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    NSLog(@"No video track for %@", filename);

    @synchronized(self) {
      (*completedCount)++;
      if (*completedCount >= totalCount) {
        self->_generatingThumbImages = NO;
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), completion);
        }
      }
    }
    return;
  }

  // Configure render size properly
  AVAssetTrack *track = videoTracks.firstObject;
  CGSize naturalSize = track.naturalSize;
  CGAffineTransform transform = track.preferredTransform;
  CGSize renderSize = CGSizeApplyAffineTransform(naturalSize, transform);
  generator.maximumSize =
      CGSizeMake(fabs(renderSize.width * THUMBNAIL_QUALITY_FACTOR),
                 fabs(renderSize.height * THUMBNAIL_QUALITY_FACTOR));

  Float64 midpoint = CMTimeGetSeconds(asset.duration) / 2.0;
  CMTime targetTime = CMTimeMakeWithSeconds(midpoint, asset.duration.timescale);

  NSString *thumbName = [[filename stringByDeletingPathExtension]
      stringByAppendingPathExtension:@"png"];
  NSString *thumbPath =
      [thumbnailPath stringByAppendingPathComponent:thumbName];
  NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

  [generator
      generateCGImagesAsynchronouslyForTimes:@[ [NSValue
                                                 valueWithCMTime:targetTime] ]
                           completionHandler:^(
                               CMTime requestedTime, CGImageRef cgImage,
                               CMTime actualTime,
                               AVAssetImageGeneratorResult result,
                               NSError *imgError) {
                             if (result == AVAssetImageGeneratorSucceeded &&
                                 cgImage != NULL) {
                               CGImageRef copy = CGImageCreateCopy(cgImage);

                               CGImageDestinationRef dest =
                                   CGImageDestinationCreateWithURL(
                                       (__bridge CFURLRef)thumbURL,
                                       (__bridge CFStringRef)
                                           UTTypePNG.identifier,
                                       1, NULL);

                               if (dest) {
                                 CGImageDestinationAddImage(dest, copy, NULL);
                                 CGImageDestinationFinalize(dest);
                                 CFRelease(dest);
                               }

                               CGImageRelease(copy);

                             } else {
                               NSLog(@"Thumbnail generation failed for %@: %@",
                                     filename, imgError.localizedDescription);
                             }

                             @synchronized(self) {
                               (*completedCount)++;
                               if (*completedCount >= totalCount) {
                                 self->_generatingThumbImages = NO;
                                 if (completion) {
                                   dispatch_async(dispatch_get_main_queue(),
                                                  completion);
                                 }
                               }
                             }
                           }];
}

- (void)saveThumbnailImage:(CGImageRef)image
                  filename:(NSString *)filename
             thumbnailPath:(NSString *)thumbnailPath {

  if (!image)
    return;

  CGImageRef safeImage = CGImageCreateCopy(image);

  // Save synchronously on thumbnail queue to ensure file is written before
  // completion
  @autoreleasepool {
    if (!safeImage)
      return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:thumbnailPath]) {
      NSError *err = nil;
      [fm createDirectoryAtPath:thumbnailPath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&err];
      if (err) {
        NSLog(@"Failed to create thumbnail folder: %@", err);
        CGImageRelease(safeImage);
        return;
      }
    }

    NSString *thumbName = [[filename stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"png"];
    NSString *thumbPath =
        [thumbnailPath stringByAppendingPathComponent:thumbName];
    NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)thumbURL, kUTTypePNG, 1, NULL);

    if (!destination) {
      NSLog(@"Failed to create CGImageDestination for %@", thumbName);
      CGImageRelease(safeImage);
      return;
    }

    NSDictionary *options = @{
      (__bridge id)
      kCGImageDestinationLossyCompressionQuality : @(THUMBNAIL_QUALITY_FACTOR)
    };

    CGImageDestinationAddImage(destination, safeImage,
                               (__bridge CFDictionaryRef)options);

    if (!CGImageDestinationFinalize(destination)) {
      NSLog(@"Failed to write PNG thumbnail: %@", thumbName);
    } else {
      NSLog(@"Saved PNG thumbnail: %@", thumbName);

      // Post notification that this specific thumbnail is ready
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ThumbnailSaved"
                          object:nil
                        userInfo:@{@"path" : thumbPath}];
      });
    }

    CFRelease(destination);
    CGImageRelease(safeImage);
  }
}

- (void)videoQualityBadgeForURL:(NSURL *)url
                     completion:(void (^)(NSString *badge))completion {
  AVAsset *asset = [AVAsset assetWithURL:url];

  if (@available(macOS 15.0, *)) {

    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks,
                                     NSError *error) {
                   NSString *badge = @"";

                   if (!error && tracks.count > 0) {
                     AVAssetTrack *videoTrack = tracks.firstObject;
                     badge = [self badgeFromVideoTrack:videoTrack];
                   }
                   dispatch_async(dispatch_get_main_queue(), ^{
                     completion(badge);
                   });
                 }];

  } else {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *videoTrack =
        [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop

    NSString *badge = videoTrack ? [self badgeFromVideoTrack:videoTrack] : @"";
    completion(badge);
  }
}

- (NSString *)badgeFromVideoTrack:(AVAssetTrack *)videoTrack {
  CGSize resolution = CGSizeApplyAffineTransform(videoTrack.naturalSize,
                                                 videoTrack.preferredTransform);

  resolution.width = fabs(resolution.width);
  resolution.height = fabs(resolution.height);

  if (resolution.width >= 3840 || resolution.height >= 2160)
    return @"4K";
  if (resolution.width >= 1920 || resolution.height >= 1080)
    return @"HD";
  if (resolution.width >= 1280 || resolution.height >= 720)
    return @"SD";

  return @"";
}

- (NSImage *)image:(NSImage *)image withBadge:(NSString *)badge {
  NSImage *result = [image copy];
  [result lockFocus];

  NSDictionary *attributes = @{
    NSFontAttributeName : [NSFont boldSystemFontOfSize:QUALITY_BADGE_FONT_SIZE],
    NSForegroundColorAttributeName : [NSColor whiteColor],
    NSStrokeColorAttributeName : [NSColor blackColor],
    NSStrokeWidthAttributeName : @-2
  };

  NSSize textSize = [badge sizeWithAttributes:attributes];

  CGFloat padding = 8;
  CGFloat verticalPadding = 6;
  CGFloat cornerRadius = 8;
  CGFloat marginRight = 10;
  CGFloat marginBottom = 10;

  NSColor *bgColor = [[NSColor blackColor] colorWithAlphaComponent:0.55];
  NSRect bgRect = NSMakeRect(
      result.size.width - textSize.width - padding * 2 - marginRight,
      result.size.height - textSize.height - verticalPadding * 2 - marginBottom,
      textSize.width + padding * 2, textSize.height + verticalPadding * 2);

  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bgRect
                                                       xRadius:cornerRadius
                                                       yRadius:cornerRadius];
  [bgColor setFill];
  [path fill];

  NSPoint textPoint = NSMakePoint(
      result.size.width - textSize.width - padding - marginRight,
      result.size.height - textSize.height - verticalPadding - marginBottom);
  [badge drawAtPoint:textPoint withAttributes:attributes];

  [result unlockFocus];
  return result;
}

- (BOOL)enableAppAsLoginItem {
  NSString *agentPath = [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/LaunchAgents/com.thusvill.LiveWallpaper.plist"];

  NSString *execPath = [[NSBundle mainBundle] executablePath];

  NSDictionary *plist = @{
    @"Label" : @"com.thusvill.LiveWallpaper",
    @"ProgramArguments" : @[ execPath ],
    @"RunAtLoad" : @YES,
    @"KeepAlive" : @NO
  };

  NSError *error = nil;
  NSData *plistData = [NSPropertyListSerialization
      dataWithPropertyList:plist
                    format:NSPropertyListXMLFormat_v1_0
                   options:0
                     error:&error];

  if (!plistData) {
    NSLog(@"Failed to serialize plist: %@", error);
    return NO;
  }

  if (![plistData writeToFile:agentPath atomically:YES]) {
    NSLog(@"Failed to write LaunchAgent");
    return NO;
  }

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/bin/launchctl";
  task.arguments = @[ @"load", agentPath ];
  [task launch];

  NSLog(@"Successfully registered app as login item");
  return YES;
}

- (void)startWallpaperWithPath:(NSString *)videoPath
                    onDisplays:(NSArray<NSNumber *> *)displayIDs {

  if (!videoPath || videoPath.length == 0) {
    NSLog(@"ERROR: Invalid videoPath");
    return;
  }

  self.currentVideoPath = videoPath;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:videoPath forKey:@"LastWallpaperPath"];
  [defaults synchronize];

  const char *videoPathCStr = [videoPath UTF8String];
  std::string videoPathStr(videoPathCStr);
  std::filesystem::path p(videoPathStr);
  std::string videoName = p.stem().string();

  if (!fs::exists(videoPathStr)) {
    NSLog(@"Video file does not exist: %@", videoPath);
    return;
  }

  NSString *imageFilename =
      [NSString stringWithFormat:@"%s.png", videoName.c_str()];
  NSString *imagePath = [[self staticWallpaperCachePath]
      stringByAppendingPathComponent:imageFilename];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:imagePath] && !_generatingImages) {
    NSLog(@"Static wallpaper not found, generating for: %@", videoPath);
    [self generateStaticWallpapersForFolder:[self getFolderPath]
                             withCompletion:nil];
  }
  NSMutableArray<NSNumber *> *screensToUse = [displayIDs mutableCopy];
  if (screensToUse.count == 0) {
    screensToUse = [NSMutableArray array];
    for (const Display &display : displays) {
      [screensToUse addObject:@(display.screen)];
    }
  }

  for (NSNumber *displayNum in screensToUse) {
    CGDirectDisplayID displayID =
        (CGDirectDisplayID)[displayNum unsignedIntValue];
    [self launchDaemonOnScreen:videoPath
                     imagePath:imagePath
                     displayID:displayID];
  }
}

- (void)applyWallpaperToDisplay:(CGDirectDisplayID)displayID
                      videoPath:(NSString *)videoPath {
  NSLog(@"Applying wallpaper to display: %u with video: %@", displayID,
        videoPath);

  [self startWallpaperWithPath:videoPath onDisplays:@[ @(displayID) ]];
}

- (void)launchDaemonOnScreen:(NSString *)videoPath
                   imagePath:(NSString *)imagePath
                   displayID:(CGDirectDisplayID)displayID {
  NSString *daemonRelativePath = @"Contents/MacOS/wallpaperdaemon";
  NSString *appPath = [[NSBundle mainBundle] bundlePath];
  NSString *daemonPath =
      [appPath stringByAppendingPathComponent:daemonRelativePath];

  float volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  NSString *volumeStr = [NSString stringWithFormat:@"%.2f", volume];
  NSString *scaleMode =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"scale_mode"];

  if (!scaleMode || scaleMode.length == 0) {
    scaleMode = @"fill";
    [[NSUserDefaults standardUserDefaults] setObject:scaleMode
                                              forKey:@"scale_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }

  NSLog(@"Scaling mode: %@", scaleMode);

  if (!displayID) {
    NSLog(@"Display ID not valid %u", displayID);
    displayID = [[[NSScreen mainScreen] deviceDescription][@"NSScreenNumber"]
        unsignedIntValue];
    NSLog(@"Display ID changed to %u", displayID);
  }

  NSString *display = [NSString stringWithFormat:@"%u", displayID];

  const char *daemonPathC = [daemonPath UTF8String];
  const char *args[] = {daemonPathC,
                        [videoPath UTF8String],
                        [imagePath UTF8String],
                        [volumeStr UTF8String],
                        [scaleMode UTF8String],
                        displayID ? [display UTF8String] : "",
                        NULL};

  pid_t pid;
  int status =
      posix_spawn(&pid, daemonPathC, NULL, NULL, (char *const *)args, environ);
  if (status != 0) {
    NSLog(@"Failed to launch daemon: %d", status);
  } else {
    _daemonPIDs.push_back(pid);
    NSLog(@"Launched daemon with PID: %d", pid);
  }
  SetWallpaperDisplay(pid, displayID, std::string([videoPath UTF8String]),
                      std::string([imagePath UTF8String]));
}

- (void)killAllDaemons {
  NSTask *killTask = [[NSTask alloc] init];
  killTask.launchPath = @"/usr/bin/killall";
  killTask.arguments = @[ @"wallpaperdaemon" ];
  [killTask launch];
  [killTask waitUntilExit];

  int status = killTask.terminationStatus;
  if (status != 0) {
    NSLog(@"No running wallpaperdaemon process found or killall failed");
  } else {
    NSLog(@"wallpaperdaemon processes killed");
  }

  for (pid_t pid : _daemonPIDs) {
    kill(pid, SIGTERM);
  }
  _daemonPIDs.clear();

  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.terminate"), NULL, NULL, true);
}

- (void)checkFolderPath {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:@"WallpaperFolder"]) {
    folderPath = [defaults stringForKey:@"WallpaperFolder"];
  } else if (!folderPath) {
    folderPath = [NSHomeDirectory() stringByAppendingPathComponent:@"LiveWall"];
    [defaults setObject:folderPath forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }
}

- (NSString *)getFolderPath {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *path = [defaults stringForKey:@"WallpaperFolder"];

  if (!path) {

    NSString *cacheDir =
        [[[NSFileManager defaultManager]
             URLsForDirectory:NSCachesDirectory
                    inDomains:NSUserDomainMask].firstObject path];

    path = [cacheDir stringByAppendingPathComponent:@"LiveWallpaper"];

    [defaults setObject:path forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }

  return path;
}

- (void)scanDisplays {
  ScanDisplays();
}

- (NSArray *)getDisplays {
  NSMutableArray *result = [NSMutableArray array];

  for (const Display &d : displays) {
    DisplayObjc *obj =
        [[DisplayObjc alloc] initWithDaemon:d.daemon
                                     screen:d.screen
                                       uuid:@(d.uuid.c_str())
                                  videoPath:@(d.videoPath.c_str())
                                  framePath:@(d.framePath.c_str())];

    [result addObject:obj];
  }

  return result;
}

- (void)selctFolder:(NSString *)path {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:path forKey:@"WallpaperFolder"];
}

- (void)terminateApplication {
  SaveSystem::Save(displays);
  [self killAllDaemons];
}

- (BOOL)isFirstLaunch {
  NSString *const kFirstLaunchKey = @"HasLaunchedOnce";
  if (![[NSUserDefaults standardUserDefaults] boolForKey:kFirstLaunchKey]) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kFirstLaunchKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
  }
  return NO;
}

-(void)updateVolume:(double)value{
    float f_percentage = value;
    float volume = f_percentage / 100.0f;

      NSLog(@"Slider: %.0f%% → volume: %.2f", f_percentage, volume);


      [[NSUserDefaults standardUserDefaults] setFloat:f_percentage
                                               forKey:@"wallpapervolumeprecentage"];
      [[NSUserDefaults standardUserDefaults] setFloat:volume
                                               forKey:@"wallpapervolume"];
      [[NSUserDefaults standardUserDefaults] synchronize];

      CFNotificationCenterPostNotification(
          CFNotificationCenterGetDarwinNotifyCenter(),
          CFSTR("com.live.wallpaper.volumeChanged"), NULL, NULL, true);
    }


@end

CGImageRef CompressImageWithQuality(CGImageRef image, float qualityFactor) {
  NSBitmapImageRep *bitmapRep =
      [[NSBitmapImageRep alloc] initWithCGImage:image];

  NSData *compressedData =
      [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
                              properties:@{
                                NSImageCompressionFactor : @(qualityFactor)
                              }];

  NSBitmapImageRep *compressedRep =
      [NSBitmapImageRep imageRepWithData:compressedData];
  return [compressedRep CGImage];
}
