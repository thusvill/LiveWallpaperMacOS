#import "WallpaperEngine.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <mach/mach.h>
#include <filesystem>
#include <spawn.h>
#include <unistd.h>


#include "DisplayManager.h"

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

    _wallpaperQueue = dispatch_queue_create("com.app.wallpaperQueue",
                                            DISPATCH_QUEUE_CONCURRENT);
    _thumbnailQueue =
        dispatch_queue_create("com.app.thumbnailQueue", DISPATCH_QUEUE_SERIAL);

    _wallpaperSemaphore = dispatch_semaphore_create(2);
      ScanDisplays();
  }
  return self;
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

  NSDistributedNotificationCenter *center =
      [NSDistributedNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(unlockHandle:)
                 name:@"com.apple.screenIsUnlocked"
               object:nil];
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

- (void)unlockHandle:(NSNotification *)note {
  NSLog(@"Unlock detected");
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
    NSArray *files =
        [fileManager contentsOfDirectoryAtPath:thumbnailPath error:&error];
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
    NSArray *files =
        [fileManager contentsOfDirectoryAtPath:staticPath error:&error];
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
    NSArray *files =
        [fileManager contentsOfDirectoryAtPath:customDir error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath = [customDir stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
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

  NSArray<NSString *> *files =
      [fileManager contentsOfDirectoryAtPath:folderPath error:nil];
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
      dispatch_semaphore_wait(_wallpaperSemaphore, DISPATCH_TIME_FOREVER);

      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                             completionHandler:^{
                               AVKeyValueStatus status = [asset
                                   statusOfValueForKey:@"tracks"
                                                 error:nil];
                               if (status != AVKeyValueStatusLoaded) {
                                 NSLog(@"Failed to load tracks for %@",
                                       filename);
                                 completedCount++;
                                 dispatch_semaphore_signal(_wallpaperSemaphore);
                                 return;
                               }

                               [self generateStaticImageFromAsset:asset
                                                         filename:filename
                                                   wallpaperPath:
                                                       wallpaperCachePath];

                               completedCount++;

                               if (completedCount >= totalCount) {
                                 _generatingImages = NO;
                                 if (completion) {
                                   dispatch_async(dispatch_get_main_queue(),
                                                  completion);
                                 }
                               }

                               dispatch_semaphore_signal(_wallpaperSemaphore);
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
                                   if (result == AVAssetImageGeneratorSucceeded && image != NULL) {
                                       CGImageRef retainedImage = CGImageCreateCopy(image);

                                       NSString *thumbName =
                                           [[filename stringByDeletingPathExtension]
                                               stringByAppendingPathExtension:@"png"];
                                       NSString *thumbPath =
                                           [wallpaperPath stringByAppendingPathComponent:thumbName];
                                       NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

                                       CGImageDestinationRef dest =
                                           CGImageDestinationCreateWithURL(
                                               (__bridge CFURLRef)thumbURL,
                                               (__bridge CFStringRef)UTTypePNG.identifier,
                                               1, NULL);

                                       if (dest) {
                                           CGImageDestinationAddImage(dest, retainedImage, NULL);
                                           CGImageDestinationFinalize(dest);
                                           CFRelease(dest);
                                       }

                                       CGImageRelease(retainedImage);
                                   }

                           }];
}

- (void)generateThumbnailsForFolder:(NSString *)folderPath
                     withCompletion:(void (^)(void))completion {
  if (_generatingThumbImages) {
    if (completion)
      completion();
    return;
  }

  _generatingThumbImages = YES;
  NSLog(@"Generating Thumbnails...");

  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *thumbnailCachePath = [self thumbnailCachePath];

  if (![fileManager fileExistsAtPath:thumbnailCachePath]) {
    [fileManager createDirectoryAtPath:thumbnailCachePath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
  }

  NSArray<NSString *> *files =
      [fileManager contentsOfDirectoryAtPath:folderPath error:nil];
  if (files.count == 0) {
    NSLog(@"No files found in folder: %@", folderPath);
    _generatingThumbImages = NO;
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

    dispatch_async(_thumbnailQueue, ^{
      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
          NSLog(@"Video not found: %@", filePath);
          completedCount++;

          if (completedCount >= totalCount) {
            _generatingThumbImages = NO;
            if (completion) {
              dispatch_async(dispatch_get_main_queue(), completion);
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

  if (totalCount == 0) {
    _generatingThumbImages = NO;
    if (completion)
      completion();
  }
}

- (void)processThumbnailForAsset:(AVAsset *)asset
                        filename:(NSString *)filename
                        videoURL:(NSURL *)videoURL
                  completedCount:(NSInteger *)completedCount
                      totalCount:(NSInteger)totalCount
                   thumbnailPath:(NSString *)thumbnailPath
                      completion:(void (^)(void))completion {

  AVKeyValueStatus tracksStatus =
      [asset statusOfValueForKey:@"tracks" error:nil];
  AVKeyValueStatus durationStatus =
      [asset statusOfValueForKey:@"duration" error:nil];

  if (tracksStatus != AVKeyValueStatusLoaded ||
      durationStatus != AVKeyValueStatusLoaded) {
    NSLog(@"Failed to load asset metadata for %@", filename);
    (*completedCount)++;

    if (*completedCount >= totalCount) {
      _generatingThumbImages = NO;
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), completion);
      }
    }
    return;
  }

  CMTime duration = asset.duration;
  if (CMTIME_IS_INVALID(duration) || CMTIME_IS_INDEFINITE(duration) ||
      CMTimeGetSeconds(duration) <= 0.0) {
    NSLog(@"Invalid duration for %@", filename);
    (*completedCount)++;

    if (*completedCount >= totalCount) {
      _generatingThumbImages = NO;
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), completion);
      }
    }
    return;
  }

  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  CGSize generatorSize = CGSizeMake(640, 360);

  if (videoTracks.count > 0) {
    AVAssetTrack *track = videoTracks.firstObject;
    CGSize videoSize = track.naturalSize;
    CGAffineTransform t = track.preferredTransform;
    CGSize renderSize = CGSizeApplyAffineTransform(videoSize, t);
    renderSize.width = fabs(renderSize.width);
    renderSize.height = fabs(renderSize.height);

    CGFloat aspectRatio = renderSize.width / renderSize.height;
    if (aspectRatio > (16.0f / 9.0f)) {
      generatorSize.width = 640;
      generatorSize.height = 640 / aspectRatio;
    } else {
      generatorSize.height = 360;
      generatorSize.width = 360 * aspectRatio;
    }
  }

  generator.maximumSize = generatorSize;

  Float64 midpointSec = CMTimeGetSeconds(duration) / 2.0;
  CMTime midpoint = CMTimeMakeWithSeconds(midpointSec, duration.timescale);

  [generator generateCGImagesAsynchronouslyForTimes:@[
    [NSValue valueWithCMTime:midpoint]
  ]
      completionHandler:^(CMTime requestedTime, CGImageRef image,
                          CMTime actualTime,
                          AVAssetImageGeneratorResult result,
                          NSError *genError) {
        @autoreleasepool {
          if (result == AVAssetImageGeneratorSucceeded && image != NULL) {
            [self saveThumbnailImage:image
                            filename:filename
                       thumbnailPath:thumbnailPath];
          } else {
            NSLog(@"generateCGImages failed for %@: %@", filename, genError);
          }

          (*completedCount)++;

          if (*completedCount >= totalCount) {
              self->_generatingThumbImages = NO;
            if (completion) {
              dispatch_async(dispatch_get_main_queue(), completion);
            }
          }
        }
      }];
}

- (void)saveThumbnailImage:(CGImageRef)image
                  filename:(NSString *)filename
             thumbnailPath:(NSString *)thumbnailPath {

    if (!image) return;

    
    CGImageRef safeImage = CGImageCreateCopy(image);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!safeImage) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:thumbnailPath]) {
            NSError *err = nil;
            [fm createDirectoryAtPath:thumbnailPath
           withIntermediateDirectories:YES
                            attributes:nil error:&err];
            if (err) {
                NSLog(@"Failed to create thumbnail folder: %@", err);
                CGImageRelease(safeImage);
                return;
            }
        }

        NSString *thumbName =
            [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:@"png"];
        NSString *thumbPath = [thumbnailPath stringByAppendingPathComponent:thumbName];
        NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

        CGImageDestinationRef destination =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)thumbURL,
                                            kUTTypePNG,
                                            1,
                                            NULL);

        if (!destination) {
            NSLog(@"Failed to create CGImageDestination for %@", thumbName);
            CGImageRelease(safeImage);
            return;
        }

        NSDictionary *options = @{
            (__bridge id)kCGImageDestinationLossyCompressionQuality: @(THUMBNAIL_QUALITY_FACTOR)
        };

        CGImageDestinationAddImage(destination, safeImage, (__bridge CFDictionaryRef)options);

        if (!CGImageDestinationFinalize(destination)) {
            NSLog(@"Failed to write PNG thumbnail: %@", thumbName);
        } else {
            NSLog(@"Saved PNG thumbnail: %@", thumbName);
        }

        CFRelease(destination);
        CGImageRelease(safeImage);
    });
}





- (NSString *)videoQualityBadgeForURL:(NSURL *)videoURL {
  AVAsset *asset = [AVAsset assetWithURL:videoURL];

  __block AVAssetTrack *videoTrack = nil;
  if (@available(macOS 15.0, *)) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> *_Nullable tracks,
                                     NSError *_Nullable error) {
                   if (!error && tracks.count > 0) {
                     videoTrack = tracks.firstObject;
                   }
                   dispatch_semaphore_signal(semaphore);
                 }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
  }

  if (!videoTrack)
    return @"";

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
      result.size.height - textSize.height - verticalPadding * 2 -
          marginBottom,
      textSize.width + padding * 2, textSize.height + verticalPadding * 2);

  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bgRect
                                                       xRadius:cornerRadius
                                                       yRadius:cornerRadius];
  [bgColor setFill];
  [path fill];

  NSPoint textPoint =
      NSMakePoint(result.size.width - textSize.width - padding - marginRight,
                  result.size.height - textSize.height - verticalPadding -
                      marginBottom);
  [badge drawAtPoint:textPoint withAttributes:attributes];

  [result unlockFocus];
  return result;
}

- (BOOL)enableAppAsLoginItem {
  NSString *agentPath = [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/LaunchAgents/com.biosthusvill.LiveWallpaper.plist"];

  NSString *execPath = [[NSBundle mainBundle] executablePath];

  NSDictionary *plist = @{
    @"Label" : @"com.biosthusvill.LiveWallpaper",
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
  NSString *imagePath =
      [[self staticWallpaperCachePath] stringByAppendingPathComponent:imageFilename];

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
    CGDirectDisplayID displayID = (CGDirectDisplayID)[displayNum unsignedIntValue];
    [self launchDaemonOnScreen:videoPath
                     imagePath:imagePath
                     displayID:displayID];
  }
}

- (void)applyWallpaperToDisplay:(CGDirectDisplayID)displayID
                      videoPath:(NSString *)videoPath {
  NSLog(@"Applying wallpaper to display: %u with video: %@", displayID,
        videoPath);

  [self startWallpaperWithPath:videoPath
                    onDisplays:@[ @(displayID) ]];
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
    SetWallpaperDisplay(pid, displayID, std::string([videoPath UTF8String]), std::string([imagePath UTF8String]));
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
        
        NSString *cacheDir = [[[NSFileManager defaultManager]
                                URLsForDirectory:NSCachesDirectory
                                inDomains:NSUserDomainMask].firstObject path];


        path = [cacheDir stringByAppendingPathComponent:@"LiveWallpaper"];
        
        [defaults setObject:path forKey:@"WallpaperFolder"];
        [defaults synchronize];
    }

    return path;
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
