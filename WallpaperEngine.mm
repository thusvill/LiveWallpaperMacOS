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
#include "SharedConstants.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <filesystem>
#import <mach/mach.h>
#include <spawn.h>
#include <unistd.h>

namespace fs = std::filesystem;

extern char **environ;

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
      _currentWallpaper = 0;
      _wallpaperList = [NSMutableArray array];
      
    ScanDisplays();

    [self killAllDaemons];
    usleep(2);

    displays = SaveSystem::Load();

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      
      _rotationType = (RotationType)[defaults integerForKey:@"rtype"];
      
      _rotationDelay = (int)[defaults integerForKey:@"rdelay"];
      
      if(_rotationType == 0){
          _rotationType = RotationTypeSequential;
      }
      if(_rotationDelay < 50){
          _rotationDelay = 60;
      }
      if([defaults boolForKey:@"rotation"]){
          [self startWallpaperRotation];
      }
      

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
                [self awakeHandle:note];
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

- (void)awakeHandle:(NSNotification *)note {

  if ([[NSUserDefaults standardUserDefaults] floatForKey:@"random_lid"]) {
    NSLog(@"Screen Aweaked!");
    [self randomWallpapersLid];
  }
}

- (void)screensDidChange:(NSNotification *)note {

  NSLog(@"Screens changed");
    ScanDisplays();
    for (Display display : displays) {

      if (!display.videoPath.empty()) {
        CGDirectDisplayID displayID = DisplayIDFromUUID(display.uuid);

        [self startWallpaperWithPath:_currentVideoPath
                          onDisplays:@[ @(displayID) ]];
      }
    }
    
    
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

- (BOOL)generateStaticImageForVideoPath:(NSString *)videoPath
                             outputPath:(NSString *)outputPath {
  if (!videoPath.length || !outputPath.length)
    return NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath])
    return NO;

  NSString *dir = [outputPath stringByDeletingLastPathComponent];
  if (dir.length) {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  NSURL *url = [NSURL fileURLWithPath:videoPath isDirectory:NO];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                          options:@{
                                            AVURLAssetPreferPreciseDurationAndTimingKey : @NO
                                          }];
  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;
  // Cap: enough for desktop fallback under icons, not full 6K aerial master.
  NSScreen *screen = [NSScreen mainScreen];
  CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2.0;
  CGFloat maxW = MIN(screen.frame.size.width * scale, 2560.0);
  CGFloat maxH = MIN(screen.frame.size.height * scale, 1600.0);
  generator.maximumSize = CGSizeMake(maxW, maxH);
  generator.requestedTimeToleranceBefore = CMTimeMake(1, 2);
  generator.requestedTimeToleranceAfter = CMTimeMake(1, 2);

  NSError *err = nil;
  CMTime t = CMTimeMakeWithSeconds(1.0, 600);
  CGImageRef image = [generator copyCGImageAtTime:t actualTime:NULL error:&err];
  if (!image) {
    image = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&err];
  }
  if (!image) {
    NSLog(@"generateStaticImageForVideoPath failed: %@ — %@", videoPath,
          err.localizedDescription);
    return NO;
  }

  CFURLRef cfURL = (__bridge CFURLRef)[NSURL fileURLWithPath:outputPath];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      cfURL, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
  BOOL ok = NO;
  if (dest) {
    CGImageDestinationAddImage(dest, image, NULL);
    ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CGImageRelease(image);
  if (ok) {
    NSLog(@"Static frame saved: %@", outputPath);
  }
  return ok;
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

  folderPath = [self normalizedFilesystemPath:folderPath ?: [self getFolderPath]];

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
  NSLog(@"Generating Thumbnails\n  folder: %@\n  cache:  %@", folderPath,
        thumbnailCachePath);

  NSFileManager *fileManager = [NSFileManager defaultManager];
  BOOL isDir = NO;
  if (![fileManager fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
    NSLog(@"Thumbnail folder missing or not a directory: %@", folderPath);
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  if (![fileManager fileExistsAtPath:thumbnailCachePath]) {
    [fileManager createDirectoryAtPath:thumbnailCachePath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
  }

  NSError *listErr = nil;
  NSArray<NSString *> *files =
      [fileManager contentsOfDirectoryAtPath:folderPath error:&listErr];
  if (listErr) {
    NSLog(@"contentsOfDirectory error: %@", listErr.localizedDescription);
  }
  if (files.count == 0) {
    NSLog(@"No files found in folder: %@", folderPath);
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  NSMutableArray<NSString *> *filesToProcess = [NSMutableArray array];
  for (NSString *filename in files) {
    NSString *ext = filename.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"mp4"] && ![ext isEqualToString:@"mov"] &&
        ![ext isEqualToString:@"m4v"]) {
      continue;
    }
    NSString *thumbName = [[filename stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"png"];
    NSString *thumbPath =
        [thumbnailCachePath stringByAppendingPathComponent:thumbName];
    if (![fileManager fileExistsAtPath:thumbPath]) {
      [filesToProcess addObject:filename];
    }
  }

  if (filesToProcess.count == 0) {
    NSLog(@"All thumbnails already exist (%lu videos scanned)",
          (unsigned long)files.count);
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  NSLog(@"Processing %lu videos for thumbnails (sync grab, concurrent=2)",
        (unsigned long)filesToProcess.count);

  // Concurrent but bounded — sync frame grab is reliable for multi-GB aerials.
  dispatch_queue_t work = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
  dispatch_group_t group = dispatch_group_create();
  dispatch_semaphore_t slots = dispatch_semaphore_create(2);
  NSString *folderCopy = [folderPath copy];
  NSString *cacheCopy = [thumbnailCachePath copy];

  for (NSString *filename in filesToProcess) {
    dispatch_group_async(group, work, ^{
      dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
      @autoreleasepool {
        [self writeThumbnailSynchronouslyForFilename:filename
                                          folderPath:folderCopy
                                       thumbnailRoot:cacheCopy];
      }
      dispatch_semaphore_signal(slots);
    });
  }

  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    self->_generatingThumbImages = NO;
    NSLog(@"Thumbnail generation finished");
    if (completion)
      completion();
  });
}

/// Reliable thumbnail for huge HEVC aerials: small max size, t≈1s, sync grab.
- (BOOL)writeThumbnailSynchronouslyForFilename:(NSString *)filename
                                    folderPath:(NSString *)folderPath
                                 thumbnailRoot:(NSString *)thumbnailRoot {
  NSString *filePath = [folderPath stringByAppendingPathComponent:filename];
  if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
    NSLog(@"Thumb skip (missing): %@", filePath);
    return NO;
  }

  NSString *thumbName = [[filename stringByDeletingPathExtension]
      stringByAppendingPathExtension:@"png"];
  NSString *thumbPath =
      [thumbnailRoot stringByAppendingPathComponent:thumbName];
  if ([[NSFileManager defaultManager] fileExistsAtPath:thumbPath])
    return YES;

  NSURL *videoURL = [NSURL fileURLWithPath:filePath isDirectory:NO];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL
                                          options:@{
                                            AVURLAssetPreferPreciseDurationAndTimingKey : @NO
                                          }];

  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;
  // Small decode target — UI card is ~300×168; 2× is plenty.
  generator.maximumSize = CGSizeMake(THUMBNAIL_WIDTH * 2.0, THUMBNAIL_HEIGHT * 2.0);
  // Wide tolerance: don't seek precisely on multi-GB masters.
  generator.requestedTimeToleranceBefore = CMTimeMake(2, 1);
  generator.requestedTimeToleranceAfter = CMTimeMake(2, 1);

  // Prefer t=1s (fast open path); fall back to zero then mid.
  NSError *err = nil;
  CMTime times[3] = {
      CMTimeMakeWithSeconds(1.0, 600),
      kCMTimeZero,
      CMTimeMakeWithSeconds(3.0, 600),
  };
  CGImageRef image = NULL;
  for (int i = 0; i < 3; i++) {
    err = nil;
    image = [generator copyCGImageAtTime:times[i] actualTime:NULL error:&err];
    if (image)
      break;
  }

  if (!image) {
    NSLog(@"Thumb FAIL %@: %@", filename, err.localizedDescription);
    return NO;
  }

  CFURLRef cfURL = (__bridge CFURLRef)[NSURL fileURLWithPath:thumbPath];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      cfURL, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
  BOOL wrote = NO;
  if (dest) {
    // JPEG-like quality via PNG is fine; keep small.
    CGImageDestinationAddImage(dest, image, NULL);
    wrote = CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CGImageRelease(image);

  if (wrote) {
    NSLog(@"Thumb OK %@", filename);
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
          postNotificationName:@"ThumbnailSaved"
                        object:nil
                      userInfo:@{@"path" : thumbPath}];
    });
  } else {
    NSLog(@"Thumb write failed %@", thumbPath);
  }
  return wrote;
}

// Kept for any legacy callers; routes into the sync writer.
- (void)processThumbnailForAsset:(AVAsset *)asset
                        filename:(NSString *)filename
                        videoURL:(NSURL *)videoURL
                  completedCount:(NSInteger *)completedCount
                      totalCount:(NSInteger)totalCount
                   thumbnailPath:(NSString *)thumbnailPath
                      completion:(void (^)(void))completion {
  NSString *folder = [videoURL.path stringByDeletingLastPathComponent];
  [self writeThumbnailSynchronouslyForFilename:filename
                                    folderPath:folder
                                 thumbnailRoot:thumbnailPath];
  if (completedCount) {
    @synchronized(self) {
      (*completedCount)++;
      if (*completedCount >= totalCount) {
        self->_generatingThumbImages = NO;
        if (completion)
          dispatch_async(dispatch_get_main_queue(), completion);
      }
    }
  }
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

    CGImageDestinationAddImage(destination, safeImage, NULL);

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
  if (![fm fileExistsAtPath:imagePath]) {
    NSLog(@"Static wallpaper missing — generating single frame for: %@",
          videoPath.lastPathComponent);
    [self generateStaticImageForVideoPath:videoPath outputPath:imagePath];
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
  

    std::string display = DisplayUUIDFromID(displayID);

  const char *daemonPathC = [daemonPath UTF8String];
  const char *args[] = {daemonPathC,
                        [videoPath UTF8String],
                        [imagePath UTF8String],
                        [volumeStr UTF8String],
                        [scaleMode UTF8String],
                        displayID ? display.c_str() : "",
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

- (void)checkWallpapers{
    if(_wallpaperList.count > 0){
        [_wallpaperList removeAllObjects];
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    folderPath = [self getFolderPath];
    NSArray<NSString *> *allFiles =
        [fileManager contentsOfDirectoryAtPath:folderPath error:&error];

    if (error) {
      NSLog(@"Error reading directory: %@", error.localizedDescription);
        NSLog(@"Wallaper List returns Empty");
        return;
      
    }
    
    for (NSString *fileName in allFiles) {
      NSString *fileExtension = [[fileName pathExtension] lowercaseString];

      if ([fileExtension isEqualToString:@"mp4"] ||
          [fileExtension isEqualToString:@"mov"]) {
        NSString *fullPath = [folderPath stringByAppendingPathComponent:fileName];
        [_wallpaperList addObject:fullPath];
          NSLog(@"detected %@", fullPath);
      }
    }

    if (_wallpaperList.count == 0) {
        NSLog(@"Folder is empty, return zero for playlist");
        return;
    }
    
}

-(void) nextWallpaper{
    
    if(_rotationType == 1){
        if (_wallpaperList == nil || _wallpaperList.count == 0) {
                NSLog(@"⚠️ Cannot rotate: wallpaperList is empty.");
                [self stopWallpaperRotation];
                return;
            }
        
        _currentWallpaper = (_currentWallpaper + 1) % _wallpaperList.count;
        for (Display display : displays) {

          if (!display.videoPath.empty()) {
            CGDirectDisplayID displayID = DisplayIDFromUUID(display.uuid);

            [self startWallpaperWithPath:
             _wallpaperList[_currentWallpaper]
                              onDisplays:@[ @(displayID) ]];
          }
        }
        
    }else if(_rotationType == 2){
        [self randomWallpapersLid];
    }
}
- (void)stopWallpaperRotation {
    [self.wallpaperTimer invalidate];
    self.wallpaperTimer = nil;
    NSLog(@"Wallpaper rotation stoped.");
}
- (void)startWallpaperRotation{
    int delay = _rotationDelay;
    [self stopWallpaperRotation];
    [self checkWallpapers];
    
    if (_currentWallpaper >= _wallpaperList.count) {
            _currentWallpaper = 0;
        }

    self.wallpaperTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)delay
                                                           target:self
                                                         selector:@selector(nextWallpaper)
                                                         userInfo:nil
                                                          repeats:YES];
    
    [self.wallpaperTimer fire];
    NSLog(@"Wallpaper rotation started with %d delay.", delay);
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

- (void)selectFolder:(NSString *)path {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:path forKey:@"WallpaperFolder"];
}

- (void)terminateApplication {
  SaveSystem::Save(displays);
  [self killAllDaemons];
    [self removeNotifications];
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

-(void)updateScaleMode:(NSInteger)mode{
    
    [[NSUserDefaults standardUserDefaults] setObject:@(mode)
                                               forKey:@"scale_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.live.wallpaper.scaleModeChanged"), NULL, NULL, true);
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

