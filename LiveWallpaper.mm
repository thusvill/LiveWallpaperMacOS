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

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <AppKit/NSCollectionView.h>
#import <AppKit/NSCollectionViewFlowLayout.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/SMAppService.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <list>

#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>

#include <unistd.h>

#import "DisplayManager.h"
#import "LineModule.h"
#import "LoadingOverlay.h"
#import "SaveSystem.h"

#include <array>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#import <mach/mach.h>
#include <memory>
#include <spawn.h>
#include <stdexcept>
#include <string>

#define BUTTON_SIZE 250.0f
#define BUTTON_SPACING 2.0f
#define BUTTON_MIN_COLUMNS 3
#define BUTTON_MAX_COLUMNS 5

#define THUMBNAIL_QUALITY_FACTOR 0.05f
#define QUALITY_BADGE_FONT_SIZE 48.0f

#if !__has_include(<AppKit/NSGlassEffectView.h>)
@class NSVisualEffectView;
typedef NSVisualEffectView NSGlassEffectView;
#endif

void LogMemoryUsage(void) {
  task_vm_info_data_t vmInfo;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

  kern_return_t kernReturn =
      task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);

  if (kernReturn == KERN_SUCCESS) {
    NSLog(@"📊 Memory in use: %llu MB", vmInfo.phys_footprint / 1024 / 1024);
  } else {
    NSLog(@"⚠️ Failed to retrieve memory usage.");
  }
}

namespace fs = std::filesystem;

bool reload = true;

std::string run_command(const std::string &cmd) {
  std::array<char, 128> buffer;
  std::string result;

  FILE *pipe = popen(cmd.c_str(), "r");
  if (!pipe)
    throw std::runtime_error("popen() failed!");
  while (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
    result += buffer.data();
  }
  pclose(pipe);

  if (!result.empty() && result.back() == '\n') {
    result.pop_back();
  }

  return result;
}

// bool set_wallpaper_all_spaces(const std::string &imagePath) {
//   // std::string cmd = "automator -i \"" + imagePath + "\"
//   // setDesktopPix.workflow";
//   std::string cmd =
//       "/usr/bin/osascript -e 'tell application \"System Events\" to set "
//       "picture of every desktop to POSIX file \"" +
//       imagePath + "\"'";
//   return std::system(cmd.c_str()) == 0;
// }

void handleSpaceChange(NSNotification *note) {

  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.spaceChanged"), NULL, NULL, true);
}

NSImage *GetSystemAppIcon(NSString *appName, NSSize size) {
  NSString *path =
      [NSString stringWithFormat:@"/System/Applications/%@.app", appName];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = [NSString
        stringWithFormat:@"/System/Library/CoreServices/%@.app", appName];
  }
  NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
  [icon setSize:size];
  return icon;
}

@interface AppDelegate
    : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTouchBarDelegate,
                NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout>
//@property(strong) NSWindow *window;
@property(nonatomic, strong) NSMutableArray *notificationObservers;

@property(strong) NSWindow *blurWindow;
@property(strong) NSStatusItem *statusItem;
//@property(strong) AVPlayer *player;
@property(strong) NSWindow *progressWindow;
@property(strong) NSTextField *progressLabel;
@property(strong) NSProgressIndicator *progressBar;
@property(strong) NSTextView *logTextView;

@property(strong) NSWindow *settingsWindow;

@property(strong) NSTextField *precentage;
@property(strong) NSTextField *touchbar_volume;
@property(strong) NSPopoverTouchBarItem *volumePopoverItem;

@property(strong) NSString *videoPath;

@property(strong) NSStackView *dockStack;
@property(strong) NSArray<NSLayoutConstraint *> *dockWidthConstraints;

@property(nonatomic, assign) std::list<CGDirectDisplayID> selectedDisplays;

@property(assign) Boolean generatingImages;
@property(assign) Boolean generatingThumbImages;

@property(strong) NSCollectionView *collectionView;
@property(strong) NSCollectionViewFlowLayout *flowLayout;

@end

@implementation AppDelegate

NSScreen *mainScreen = NULL;
NSMutableArray *buttons = [NSMutableArray array];
NSView *content;
NSString *folderPath;
std::list<pid_t> all_deamon_created{};
void checkFolderPath() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:@"WallpaperFolder"]) {
    folderPath = [defaults stringForKey:@"WallpaperFolder"];
  }

  else if (!folderPath) {
    folderPath = [NSHomeDirectory() stringByAppendingPathComponent:@"LiveWall"];

    [defaults setObject:folderPath forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }
}

NSString *getFolderPath(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *path = [defaults stringForKey:@"WallpaperFolder"];

  if (!path) {
    path = [NSHomeDirectory() stringByAppendingPathComponent:@"LiveWall"];
    [defaults setObject:path forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }

  return path;
}

- (void)UnlockHandle:(NSNotification *)note {
  NSLog(@"Unlock detected — waiting for displays to stabilize...");
  if (buttons.count == 0)
    return;

  BOOL randomUnlock =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"random_unlock"];
  if (!randomUnlock)
    return;

  AppDelegate *weakSelf = self; // Manual weak ref

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf)
          return;

        NSLog(@"Applying random wallpaper on screen unlock...");

        ScanDisplays();
        PrintDisplays(displays);

        NSString *folderPath = getFolderPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *allFiles = [fm contentsOfDirectoryAtPath:folderPath error:nil];
        NSPredicate *videoPredicate = [NSPredicate
            predicateWithFormat:@"pathExtension IN {'mp4', 'mov'}"];
        NSArray *videoFiles =
            [allFiles filteredArrayUsingPredicate:videoPredicate];

        if (videoFiles.count == 0)
          return;

        // Fix: NSMutableArray instead of NSArray
        NSMutableArray *displaysCopy =
            [NSMutableArray arrayWithCapacity:displays.size()];
        for (Display display : displays) {
          [displaysCopy
              addObject:[NSNumber numberWithUnsignedLong:display.screen]];
        }

        NSArray *videosCopy = [[NSArray alloc] initWithArray:videoFiles];
        NSString *cacheDir = [strongSelf staticWallpaperChachePath];

        __block NSUInteger index = 0;

        void (^processNext)(void) = ^{
          if (index >= [displaysCopy count]) {
            NSLog(@"All displays randomized");
            [videosCopy release];
            return;
          }

          NSNumber *screenID = [displaysCopy objectAtIndex:index];
          NSUInteger randomIdx =
              arc4random_uniform((u_int32_t)[videosCopy count]);
          NSString *videoName = [videosCopy objectAtIndex:randomIdx];
          NSString *videoPath =
              [folderPath stringByAppendingPathComponent:videoName];

          NSString *imageName = [videoName stringByDeletingPathExtension];
          NSString *imagePath =
              [cacheDir stringByAppendingPathComponent:imageName];
          imagePath = [imagePath stringByAppendingPathExtension:@"png"];

          if (![fm fileExistsAtPath:imagePath] && !_generatingImages) {

            AsyncLoading(^{
              [strongSelf generateStaticWallpapersForFolder:folderPath];
            });

            return;
          }

          NSLog(@"Screen %lu: %@ → %@", [screenID unsignedLongValue], videoName,
                imageName);

          strongSelf->_selectedDisplays.clear();
          strongSelf->_selectedDisplays.push_back([screenID unsignedLongValue]);

          launchDaemonOnScreen(videoPath, imagePath,
                               [screenID unsignedLongValue]);

          index++;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
                         dispatch_get_main_queue(), processNext);
        };

        processNext();
      });
}

- (void)screensDidChange:(NSNotification *)note {
  // [self startWallpaperWithPath:[NSString
  //                                  stringWithUTF8String:g_videoPath.c_str()]];

  ScanDisplays();

  usleep(1);
  startLoading(@"Applying wallpapers on new screens...");
  dispatch_async(dispatch_get_main_queue(), ^{
    AppDelegate *appDelegate = (AppDelegate *)[NSApp delegate];
    [appDelegate reloadDock];
    if (!displays.empty()) {
      for (Display &display : displays) {
        _selectedDisplays.clear();
        _selectedDisplays.push_back(display.screen);

        [self startWallpaperWithPath:[NSString
                                         stringWithUTF8String:display.videoPath
                                                                  .c_str()]];

        _selectedDisplays.clear();
      }
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          endLoading();
        });
  });
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
    NSLog(@"Failed to write LaunchAgent to %@", agentPath);
    return NO;
  }

  // Load it
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/bin/launchctl";
  task.arguments = @[ @"load", agentPath ];
  [task launch];

  NSLog(@"Successfully registered app as login item");
  return YES;
}

- (IBAction)addLoginItem:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Start LiveWallpaper at login?"];
  [alert addButtonWithTitle:@"Yes"];
  [alert addButtonWithTitle:@"No"];
  NSModalResponse response = [alert runModal];

  if (response == NSAlertFirstButtonReturn) {
    [self enableAppAsLoginItem];
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

- (NSString *)staticWallpaperChachePath {
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

- (void)resetUserData {
  NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
  [[NSUserDefaults standardUserDefaults]
      removePersistentDomainForName:appDomain];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)clearCache {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  // --- Clear thumbnail cache ---
  NSString *thumbnailCachePath = [self thumbnailCachePath];
  if ([fileManager fileExistsAtPath:thumbnailCachePath]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:thumbnailCachePath
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath =
            [thumbnailCachePath stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }

  // --- Clear static wallpapers -----

  NSString *sWallpapersCachePath = [self staticWallpaperChachePath];
  if ([fileManager fileExistsAtPath:sWallpapersCachePath]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:sWallpapersCachePath
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath =
            [sWallpapersCachePath stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }

  // --- Clear static wallpaper cache ---
  NSString *appSupportDir = [NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString *customDir =
      [appSupportDir stringByAppendingPathComponent:@"Livewall"];

  // Ensure the directory exists
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

- (void)generateStaticWallpapersForFolder:(NSString *)folderPath {
  if (_generatingImages) {
    return;
  } else {
    _generatingImages = true;
  }
  NSLog(@"Generating wallpapers...");
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *wallpaperCachePath = [self staticWallpaperChachePath];

  if (folderPath == nullptr) {
    folderPath = getFolderPath();
  }

  //[self clearCache];
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
    return;
  }

  dispatch_queue_t wallpaperQueue = dispatch_queue_create(
      "com.app.wallpaperQueue", DISPATCH_QUEUE_CONCURRENT);

  static dispatch_semaphore_t wallpaperSemaphore;
  if (!wallpaperSemaphore)
    wallpaperSemaphore = dispatch_semaphore_create(2);

  for (NSString *filename in files) {
    if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
        ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
      continue;
    }

    dispatch_async(wallpaperQueue,
                   ^{
                     dispatch_semaphore_wait(wallpaperSemaphore,
                                             DISPATCH_TIME_FOREVER);

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
                                              if (status !=
                                                  AVKeyValueStatusLoaded) {
                                                NSLog(@"Failed to load tracks "
                                                      @"for %@",
                                                      filename);
                                                return;
                                              }

                                              AVAssetImageGenerator *generator =
                                                  [[AVAssetImageGenerator alloc]
                                                      initWithAsset:asset];
                                              generator
                                                  .appliesPreferredTrackTransform =
                                                  YES;

                                              NSArray<AVAssetTrack *>
                                                  *videoTracks = [asset
                                                      tracksWithMediaType:
                                                          AVMediaTypeVideo];
                                              if (videoTracks.count > 0) {
                                                AVAssetTrack *track =
                                                    videoTracks.firstObject;
                                                CGSize videoSize =
                                                    track.naturalSize;
                                                CGAffineTransform transform =
                                                    track.preferredTransform;
                                                CGSize renderSize =
                                                    CGSizeApplyAffineTransform(
                                                        videoSize, transform);
                                                generator.maximumSize =
                                                    CGSizeMake(
                                                        fabs(renderSize.width),
                                                        fabs(
                                                            renderSize.height));
                                              }

                                              Float64 midpointSec =
                                                  CMTimeGetSeconds(
                                                      asset.duration) /
                                                  2.0;
                                              CMTime midpoint =
                                                  CMTimeMakeWithSeconds(
                                                      midpointSec,
                                                      asset.duration.timescale);
                                              NSValue *timeValue = [NSValue
                                                  valueWithCMTime:midpoint];

                                              [generator generateCGImagesAsynchronouslyForTimes:
                                                             @[ timeValue ]
                                                                              completionHandler:
                                                                                  ^(CMTime
                                                                                        requestedTime,
                                                                                    CGImageRef
                                                                                        image,
                                                                                    CMTime actualTime, AVAssetImageGeneratorResult result, NSError *error) {
                                                                                    if (result ==
                                                                                            AVAssetImageGeneratorSucceeded &&
                                                                                        image !=
                                                                                            NULL) {
                                                                                      CGImageRef retainedImage =
                                                                                          CGImageRetain(
                                                                                              image);

                                                                                      NSString *thumbName =
                                                                                          [[filename
                                                                                              stringByDeletingPathExtension]
                                                                                              stringByAppendingPathExtension:
                                                                                                  @"png"];
                                                                                      NSString *thumbPath =
                                                                                          [wallpaperCachePath
                                                                                              stringByAppendingPathComponent:
                                                                                                  thumbName];
                                                                                      NSURL *thumbURL =
                                                                                          [NSURL
                                                                                              fileURLWithPath:
                                                                                                  thumbPath];

                                                                                      CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
                                                                                          (__bridge CFURLRef)
                                                                                              thumbURL,
                                                                                          (__bridge CFStringRef)
                                                                                              UTTypePNG
                                                                                                  .identifier,
                                                                                          1,
                                                                                          NULL);
                                                                                      if (dest) {
                                                                                        CGImageDestinationAddImage(
                                                                                            dest,
                                                                                            retainedImage,
                                                                                            NULL);
                                                                                        if (!CGImageDestinationFinalize(
                                                                                                dest)) {
                                                                                          NSLog(
                                                                                              @"Failed to finalize PNG for %@",
                                                                                              thumbName);
                                                                                        }
                                                                                        CFRelease(
                                                                                            dest);
                                                                                      }
                                                                                      CGImageRelease(
                                                                                          retainedImage);

                                                                                      dispatch_async(
                                                                                          dispatch_get_main_queue(),
                                                                                          ^{
                                                                                            NSString *msg = [NSString
                                                                                                stringWithFormat:
                                                                                                    @"Generated StaticWallpaper %@",
                                                                                                    thumbName];
                                                                                            loadingMessage(
                                                                                                msg);
                                                                                          });
                                                                                    } else {
                                                                                      NSLog(
                                                                                          @"Error generating image for %@: %@",
                                                                                          filename,
                                                                                          error
                                                                                              .localizedDescription);
                                                                                    }
                                                                                  }];
                                              dispatch_semaphore_signal(
                                                  wallpaperSemaphore);
                                            }];
                     }
                   });
  }
  _generatingImages = false;
}

CGImageRef CompressImageWithQuality(CGImageRef image, float qualityFactor) {
  // Create a CGImage with reduced quality
  NSBitmapImageRep *bitmapRep =
      [[NSBitmapImageRep alloc] initWithCGImage:image];

  // Reduce color depth by converting to appropriate color space
  NSData *compressedData =
      [bitmapRep representationUsingType:NSPNGFileType
                              properties:@{
                                NSImageCompressionFactor : @(qualityFactor)
                              }];

  NSBitmapImageRep *compressedRep =
      [NSBitmapImageRep imageRepWithData:compressedData];
  return [compressedRep CGImage];
}
- (void)generateThumbnailsForFolder:(NSString *)folderPath {
  if (_generatingThumbImages) {
    return;
  }
  _generatingThumbImages = true;
  NSLog(@"Generating Thumbnails...");

  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *thumbnailCachePath = [self thumbnailCachePath];

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
    _generatingThumbImages = false;
    return;
  }

  // Use serial queue instead of concurrent to limit memory usage
  dispatch_queue_t thumbnailQueue =
      dispatch_queue_create("com.app.thumbnailQueue", DISPATCH_QUEUE_SERIAL);

  __block NSInteger completedCount = 0;
  NSInteger totalCount = 0;

  for (NSString *filename in files) {
    if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
        ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
      continue;
    }
    totalCount++;

    dispatch_async(thumbnailQueue, ^{
      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
          NSLog(@"Video not found: %@", filePath);
          completedCount++;
          [self checkThumbnailGenerationComplete:completedCount
                                      totalCount:totalCount];
          return;
        }

        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        [asset
            loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
                          completionHandler:^{
                            @autoreleasepool {
                              AVKeyValueStatus tracksStatus =
                                  [asset statusOfValueForKey:@"tracks"
                                                       error:nil];
                              AVKeyValueStatus durationStatus =
                                  [asset statusOfValueForKey:@"duration"
                                                       error:nil];

                              if (tracksStatus != AVKeyValueStatusLoaded ||
                                  durationStatus != AVKeyValueStatusLoaded) {
                                NSLog(@"Failed to load asset metadata for %@",
                                      filename);
                                completedCount++;
                                [self checkThumbnailGenerationComplete:
                                          completedCount
                                                            totalCount:
                                                                totalCount];
                                return;
                              }

                              CMTime duration = asset.duration;
                              if (CMTIME_IS_INVALID(duration) ||
                                  CMTIME_IS_INDEFINITE(duration) ||
                                  CMTimeGetSeconds(duration) <= 0.0) {
                                NSLog(@"Invalid/indefinite duration for %@",
                                      filename);
                                completedCount++;
                                [self checkThumbnailGenerationComplete:
                                          completedCount
                                                            totalCount:
                                                                totalCount];
                                return;
                              }

                              AVAssetImageGenerator *generator =
                                  [[AVAssetImageGenerator alloc]
                                      initWithAsset:asset];
                              generator.appliesPreferredTrackTransform = YES;

                              NSArray<AVAssetTrack *> *videoTracks =
                                  [asset tracksWithMediaType:AVMediaTypeVideo];
                              CGSize generatorSize = CGSizeMake(640, 360);

                              if (videoTracks.count > 0) {
                                AVAssetTrack *track = videoTracks.firstObject;
                                CGSize videoSize = track.naturalSize;
                                CGAffineTransform t = track.preferredTransform;
                                CGSize renderSize =
                                    CGSizeApplyAffineTransform(videoSize, t);
                                renderSize.width = fabs(renderSize.width);
                                renderSize.height = fabs(renderSize.height);

                                CGFloat aspectRatio =
                                    renderSize.width / renderSize.height;
                                if (aspectRatio > (16.0f / 9.0f)) {
                                  generatorSize.width = 640;
                                  generatorSize.height = 640 / aspectRatio;
                                } else {
                                  generatorSize.height = 360;
                                  generatorSize.width = 360 * aspectRatio;
                                }
                              }

                              generator.maximumSize = generatorSize;

                              Float64 midpointSec =
                                  CMTimeGetSeconds(duration) / 2.0;
                              CMTime midpoint = CMTimeMakeWithSeconds(
                                  midpointSec, duration.timescale);

                              [generator
                                  generateCGImagesAsynchronouslyForTimes:@[
                                    [NSValue valueWithCMTime:midpoint]
                                  ]
                                                       completionHandler:^(
                                                           CMTime requestedTime,
                                                           CGImageRef image,
                                                           CMTime actualTime,
                                                           AVAssetImageGeneratorResult
                                                               result,
                                                           NSError *genError) {
                                                         @autoreleasepool {
                                                           if (result ==
                                                                   AVAssetImageGeneratorSucceeded &&
                                                               image != NULL) {
                                                             [self
                                                                 saveThumbnailImage:
                                                                     image
                                                                           filename:
                                                                               filename
                                                                           videoURL:
                                                                               videoURL];
                                                           } else {
                                                             NSLog(
                                                                 @"generateCGIm"
                                                                 @"ages failed "
                                                                 @"for %@: %@",
                                                                 filename,
                                                                 genError);
                                                           }

                                                           completedCount++;
                                                           [self
                                                               checkThumbnailGenerationComplete:
                                                                   completedCount
                                                                                     totalCount:
                                                                                         totalCount];
                                                         }
                                                       }];
                            }
                          }];
      }
    });
  }

  if (totalCount == 0) {
    _generatingThumbImages = false;
  }
}

- (void)saveThumbnailImage:(CGImageRef)image
                  filename:(NSString *)filename
                  videoURL:(NSURL *)videoURL {
  NSImage *thumbNSImage = [[NSImage alloc] initWithCGImage:image
                                                      size:NSZeroSize];

  NSString *qualityBadge = [self videoQualityBadgeForURL:videoURL];
  if (qualityBadge && qualityBadge.length > 0) {
    thumbNSImage = [self image:thumbNSImage withBadge:qualityBadge];
  }

  CGImageRef finalImage = [thumbNSImage CGImageForProposedRect:NULL
                                                       context:NULL
                                                         hints:NULL];

  NSString *thumbName = [[filename stringByDeletingPathExtension]
      stringByAppendingPathExtension:@"png"];
  NSString *thumbPath =
      [[self thumbnailCachePath] stringByAppendingPathComponent:thumbName];
  NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

  CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)thumbURL, (__bridge CFStringRef)UTTypePNG.identifier,
      1, NULL);

  if (destination) {
    NSDictionary *options = @{
      (__bridge id)
      kCGImageDestinationLossyCompressionQuality : @(THUMBNAIL_QUALITY_FACTOR)
    };
    CGImageDestinationAddImage(destination, finalImage,
                               (__bridge CFDictionaryRef)options);
    if (CGImageDestinationFinalize(destination)) {
      NSLog(@"Saved PNG thumbnail: %@ (Quality: %.0f%%)", thumbName,
            THUMBNAIL_QUALITY_FACTOR * 100);
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg =
            [NSString stringWithFormat:@"Generated Thumbnail %@", thumbName];
        loadingMessage(msg);
      });
    } else {
      NSLog(@"Failed to finalize PNG for %@", thumbName);
    }
    CFRelease(destination);
  }
}

- (void)checkThumbnailGenerationComplete:(NSInteger)completedCount
                              totalCount:(NSInteger)totalCount {
  if (completedCount >= totalCount) {
    _generatingThumbImages = false;
    NSLog(@"Thumbnail generation complete!");
  }
}
- (NSString *)videoQualityBadgeForURL:(NSURL *)videoURL {
  AVAsset *asset = [AVAsset assetWithURL:videoURL];

  // Use synchronous loading for compatibility
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

- (void)selectWallpaperFolder:(id)sender {
  [NSApp activateIgnoringOtherApps:YES];
  [NSApp activateIgnoringOtherApps:YES];

  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setCanChooseFiles:NO];
  [panel setCanChooseDirectories:YES];
  [panel setAllowsMultipleSelection:NO];
  [panel setTitle:@"Select Wallpaper Folder"];
  [panel setPrompt:@"Choose"];

  [panel beginWithCompletionHandler:^(NSModalResponse result) {
    if (result == NSModalResponseOK) {
      NSURL *selectedFolderURL = [panel URL];
      if (selectedFolderURL) {
        NSString *path = [selectedFolderURL path];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:path forKey:@"WallpaperFolder"];
        [defaults synchronize];
        folderPath = path;

        if (self.settingsWindow) {
          [self.settingsWindow close];
          [self showSettingsWindow:nil];
        }

        // Native GCD - no C++ std::function issues
        startLoading(@"Loading Folder data...");
        dispatch_queue_t bgQueue =
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(bgQueue, ^{
          // Background: heavy I/O work
          [self clearCache];
          [self generateThumbnailsForFolder:getFolderPath()];
          [self generateStaticWallpapersForFolder:getFolderPath()];
          NSLog(@"Background processing complete: %@", path);

          dispatch_async(dispatch_get_main_queue(), ^{
            // Main thread: UI update only
            // reloadGrid
            [self ReloadContent];
            NSLog(@"UI refreshed: %@", path);
            endLoading();
          });
        });
      }
    }
  }];
}

NSButton *CreateButton(NSString *title, id target, SEL action) {
  NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)];
  [btn setTitle:title];
  [btn setBezelStyle:NSBezelStyleRounded];
  [btn setTarget:target];
  [btn setAction:action];
  return btn;
}
NSTextField *CreateLabel(NSString *string) {
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
  [tf setStringValue:string];
  [tf setBezeled:NO];
  [tf setDrawsBackground:NO];
  [tf setEditable:NO];
  [tf setSelectable:NO];
  return tf;
}
- (void)showSettingsWindow:(id)sender {
  NSRect frame = NSMakeRect(100, 100, 400, 300);

  // Create a titled window
  self.settingsWindow = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [self.settingsWindow setTitle:@"Settings"];
  [self.settingsWindow center];
  [self.settingsWindow setOpaque:NO];
  [self.settingsWindow setBackgroundColor:[NSColor clearColor]];
  self.settingsWindow.titlebarAppearsTransparent = YES;
  self.settingsWindow.styleMask |= NSWindowStyleMaskFullSizeContentView;

  // Add glass background
  NSView *glassView = nil;
#if MACOS26
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView *effView = [[NSGlassEffectView alloc]
        initWithFrame:self.settingsWindow.contentView.bounds];
    effView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glassView = effView;
  }
#else
  NSVisualEffectView *fallbackView = [[NSVisualEffectView alloc]
      initWithFrame:self.settingsWindow.contentView.bounds];
  fallbackView.material = NSVisualEffectMaterialHUDWindow;
  fallbackView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  fallbackView.state = NSVisualEffectStateActive;
  fallbackView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  glassView = fallbackView;
#endif

  [self.settingsWindow.contentView addSubview:glassView
                                   positioned:NSWindowBelow
                                   relativeTo:nil];

  // Vertical stack container
  NSStackView *stackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
  stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
  stackView.alignment = NSLayoutAttributeLeading;
  stackView.spacing = 12;
  stackView.translatesAutoresizingMaskIntoConstraints = NO;

  {
    NSView *topSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    topSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [topSpacer.heightAnchor constraintEqualToConstant:24].active =
        YES; // desired gap
    [stackView addArrangedSubview:topSpacer];
  }

  // --- Folder Selection ---
  {
    LineModule *folderSelect = [[LineModule alloc] initWithFrame:NSZeroRect];
    folderSelect.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *folderLabel = CreateLabel(@"Wallpaper Folder:");
    folderLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *folderInput = [[NSTextField alloc] initWithFrame:NSZeroRect];
    folderInput.translatesAutoresizingMaskIntoConstraints = NO;
    folderInput.placeholderString = @"Select folder or type path";
    folderInput.stringValue = folderPath ?: @"";
    [folderInput.widthAnchor constraintEqualToConstant:200].active = YES;

    NSButton *openFolder = CreateButton(@"Select Folder 📁", self,
                                        @selector(selectWallpaperFolder:));
    openFolder.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *openInFinder = CreateButton(@"Show in Finder 📂", self,
                                          @selector(openWallpaperFolder:));
    openInFinder.translatesAutoresizingMaskIntoConstraints = NO;

    [folderSelect add:folderLabel];
    [folderSelect add:folderInput];
    [folderSelect add:openFolder];
    [folderSelect add:openInFinder];
    [stackView addArrangedSubview:folderSelect];
  }

  // --- Optimize Videos ---
  {
    LineModule *optimizeVideos = [[LineModule alloc] initWithFrame:NSZeroRect];
    optimizeVideos.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *optimizeLabel = CreateLabel(@"Optimize Video Codecs");
    optimizeLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *optimizeButton =
        CreateButton(@"Optimize 🛠️", self, @selector(convertCodec:));
    optimizeButton.translatesAutoresizingMaskIntoConstraints = NO;
    optimizeButton.enabled = false;

    [optimizeVideos add:optimizeLabel];
    [optimizeVideos add:optimizeButton];
    [stackView addArrangedSubview:optimizeVideos];
  }

  // --- Video Scaling Mode Selector ---
  {
    LineModule *scaleVid = [[LineModule alloc] initWithFrame:NSZeroRect];
    scaleVid.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *scaleLabel = CreateLabel(@"Video Scaling Mode");
    scaleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSPopUpButton *scalePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                           pullsDown:NO];
    scalePopup.translatesAutoresizingMaskIntoConstraints = NO;
    scalePopup.target = self;
    scalePopup.action = @selector(scaleModeChanged:);

    // Add menu items
    [scalePopup addItemWithTitle:@"Fill"];
    [scalePopup addItemWithTitle:@"Fit"];
    [scalePopup addItemWithTitle:@"Stretch"];
    [scalePopup addItemWithTitle:@"Center"];
    [scalePopup addItemWithTitle:@"HeightFill"];
    // height-fill

    // Load saved mode (default "fill")
    NSString *savedMode =
        [[NSUserDefaults standardUserDefaults] stringForKey:@"scale_mode"];
    NSInteger selectedIndex = 0; // Default fill
    if ([savedMode isEqualToString:@"fit"])
      selectedIndex = 1;
    else if ([savedMode isEqualToString:@"stretch"])
      selectedIndex = 2;
    else if ([savedMode isEqualToString:@"center"])
      selectedIndex = 3;
    else if ([savedMode isEqualToString:@"height-fill"])
      selectedIndex = 4;

    [scalePopup selectItemAtIndex:selectedIndex];

    [scaleVid add:scaleLabel];
    [scaleVid add:scalePopup];
    [stackView addArrangedSubview:scaleVid];
  }

  // --- Random Wallpaper Toggle ---
  {
    LineModule *randomVid = [[LineModule alloc] initWithFrame:NSZeroRect];
    randomVid.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *randomLabel = CreateLabel(@"Random Wallpaper on Startup");
    randomLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSSwitch *randomToggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    randomToggle.translatesAutoresizingMaskIntoConstraints = NO;
    randomToggle.target = self;
    randomToggle.action = @selector(randomToggleChanged:);
    randomToggle.state =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"random"]
            ? NSControlStateValueOn
            : NSControlStateValueOff;

    [randomVid add:randomLabel];
    [randomVid add:randomToggle];
    [stackView addArrangedSubview:randomVid];
  }

  // --- Random Wallpaper On Lock Toggle ---
  {
    LineModule *randomVid = [[LineModule alloc] initWithFrame:NSZeroRect];
    randomVid.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *randomLabel =
        CreateLabel(@"Random Wallpaper on Unlock[Temporarily not working]");
    randomLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSSwitch *randomToggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    randomToggle.translatesAutoresizingMaskIntoConstraints = NO;
    randomToggle.target = self;

    // TODO: Fix this
    randomToggle.enabled = NO;

    randomToggle.action = @selector(randomUnlockToggleChanged:);
    randomToggle.state =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"random_unlock"]
            ? NSControlStateValueOn
            : NSControlStateValueOff;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"random_unlock"]) {

      [[NSUserDefaults standardUserDefaults] setBool:false
                                              forKey:@"random_unlock"];
    }

    [randomVid add:randomLabel];
    [randomVid add:randomToggle];
    [stackView addArrangedSubview:randomVid];
  }

  // --- Auto-Pause When App is Focused ---
  {
    LineModule *autoPause = [[LineModule alloc] initWithFrame:NSZeroRect];
    autoPause.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *autoPauseLabel = CreateLabel(@"Pause When App is Active");
    autoPauseLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSSwitch *autoPauseToggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    autoPauseToggle.translatesAutoresizingMaskIntoConstraints = NO;
    autoPauseToggle.target = self;
    autoPauseToggle.action = @selector(autoPauseToggleChanged:);
    autoPauseToggle.state =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"pauseOnAppFocus"]
            ? NSControlStateValueOn
            : NSControlStateValueOff;

    [autoPause add:autoPauseLabel];
    [autoPause add:autoPauseToggle];
    [stackView addArrangedSubview:autoPause];
  }

  // --- Video Volume ---
  {
    LineModule *videoVolume = [[LineModule alloc] initWithFrame:NSZeroRect];
    videoVolume.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *volumeLabel = CreateLabel(@"Video Volume");
    volumeLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider.widthAnchor constraintEqualToConstant:200].active = YES;
    slider.minValue = 0;
    slider.maxValue = 100;
    slider.floatValue = [[NSUserDefaults standardUserDefaults]
        floatForKey:@"wallpapervolumeprecentage"];
    slider.target = self;
    slider.action = @selector(sliderValueChanged:);

    self.precentage = CreateLabel(@"Percentage");
    self.precentage.translatesAutoresizingMaskIntoConstraints = NO;
    [self.precentage.widthAnchor constraintEqualToConstant:60].active = YES;
    self.precentage.editable = NO;
    self.precentage.selectable = NO;
    self.precentage.stringValue =
        [NSString stringWithFormat:@"%.0f%%", slider.floatValue];

    [videoVolume add:volumeLabel];
    [videoVolume add:slider];
    [videoVolume add:self.precentage];
    [stackView addArrangedSubview:videoVolume];
  }

  // --- Clear Cache ---
  {
    LineModule *clearCache = [[LineModule alloc] initWithFrame:NSZeroRect];
    clearCache.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *clearCacheLabel = CreateLabel(@"Clear Cache");
    clearCacheLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *clearCacheButton =
        CreateButton(@"Clear Cache 🗑️", self, @selector(clearCacheButton:));
    clearCacheButton.translatesAutoresizingMaskIntoConstraints = NO;

    [clearCache add:clearCacheLabel];
    [clearCache add:clearCacheButton];
    [stackView addArrangedSubview:clearCache];
  }

  // --- Reset UserData ---
  {
    LineModule *resetUserData = [[LineModule alloc] initWithFrame:NSZeroRect];
    resetUserData.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *m_Label = CreateLabel(@"Reset UserData 🗑️");
    m_Label.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *m_Button = CreateButton(@"Reset", self, @selector(resetButton:));
    m_Button.translatesAutoresizingMaskIntoConstraints = NO;

    [resetUserData add:m_Label];
    [resetUserData add:m_Button];
    [stackView addArrangedSubview:resetUserData];
  }

  // --- Login Item Permission ---
  {
    NSString *agentPath = [NSHomeDirectory()
        stringByAppendingPathComponent:
            @"Library/LaunchAgents/com.thusvill.LiveWallpaper.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:agentPath]) {
      LineModule *permissions = [[LineModule alloc] initWithFrame:NSZeroRect];
      permissions.translatesAutoresizingMaskIntoConstraints = NO;

      NSTextField *permissionLabel = CreateLabel(@"Add this to LoginItems");
      permissionLabel.translatesAutoresizingMaskIntoConstraints = NO;

      NSButton *permissionButton =
          CreateButton(@"Grant Permissions", self, @selector(addLoginItem:));
      permissionButton.translatesAutoresizingMaskIntoConstraints = NO;

      [permissions add:permissionLabel];
      [permissions add:permissionButton];
      [stackView addArrangedSubview:permissions];
    }
  }

  // Attach stack to glassView
  [glassView addSubview:stackView];
  [NSLayoutConstraint activateConstraints:@[
    [stackView.topAnchor constraintEqualToAnchor:glassView.topAnchor
                                        constant:20],
    [stackView.leadingAnchor constraintEqualToAnchor:glassView.leadingAnchor
                                            constant:20],
    [stackView.trailingAnchor
        constraintLessThanOrEqualToAnchor:glassView.trailingAnchor
                                 constant:-20],
    [stackView.bottomAnchor
        constraintLessThanOrEqualToAnchor:glassView.bottomAnchor
                                 constant:-20]
  ]];

  // Fade-in animation
  [self.settingsWindow setAlphaValue:0.0];
  [NSApp activateIgnoringOtherApps:YES];
  [self.settingsWindow makeKeyAndOrderFront:nil];
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.settingsWindow.animator.alphaValue = 1.0;
      }
      completionHandler:nil];
}
- (void)randomToggleChanged:(NSSwitch *)sender {
  BOOL enabled = (sender.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"random"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)randomUnlockToggleChanged:(NSSwitch *)sender {
  BOOL enabled = (sender.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:enabled
                                          forKey:@"random_unlock"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)scaleModeChanged:(NSPopUpButton *)sender {
  NSArray *modes = @[ @"fill", @"fit", @"stretch", @"center", @"height-fill" ];
  NSString *selectedMode = modes[sender.indexOfSelectedItem];

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:selectedMode forKey:@"scale_mode"];
  [defaults synchronize];

  NSLog(@"Video scaling mode changed to: %@", selectedMode);

  if (self.videoPath) {
    [self startWallpaperWithPath:self.videoPath];
  }
}

- (void)autoPauseToggleChanged:(NSSwitch *)sender {
  BOOL enabled = (sender.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:enabled
                                          forKey:@"pauseOnAppFocus"];
  [[NSUserDefaults standardUserDefaults] synchronize];

  // Notify daemon about the setting change
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.autoPauseChanged"), NULL, NULL, true);
}

- (void)clearCacheButton:(id)sender {
  [self clearCache];
}
- (void)resetButton:(id)sender {
  [self resetUserData];
}

- (void)sliderValueChanged:(NSSlider *)sender {
  float f_percentage = sender.floatValue;
  float volume = f_percentage / 100.0f;

  NSLog(@"Slider: %.0f%% → volume: %.2f", f_percentage, volume);

  self.precentage.stringValue =
      [NSString stringWithFormat:@"%.0f%%", f_percentage];
  self.touchbar_volume.stringValue =
      [NSString stringWithFormat:@"%.0f%%", f_percentage];

  [[NSUserDefaults standardUserDefaults] setFloat:f_percentage
                                           forKey:@"wallpapervolumeprecentage"];
  [[NSUserDefaults standardUserDefaults] setFloat:volume
                                           forKey:@"wallpapervolume"];
  [[NSUserDefaults standardUserDefaults] synchronize];

  self.volumePopoverItem.collapsedRepresentationImage =
      [self volumeIconForValue:f_percentage];

  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.volumeChanged"), NULL, NULL, true);
}

- (void)promptForLoginItem {
  NSString *agentPath = [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/LaunchAgents/com.thusvill.LiveWallpaper.plist"];
  BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:agentPath];
  if (!exists) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Launch at Login"];
    [alert setInformativeText:@"Would you like to launch this app "
                              @"automatically when you log in?"];
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
    [alert setAlertStyle:NSAlertStyleInformational];

    [alert beginSheetModalForWindow:self.blurWindow
                  completionHandler:^(NSModalResponse returnCode) {
                    if (returnCode == NSAlertFirstButtonReturn) {

                      SMAppService *service = [SMAppService
                          loginItemServiceWithIdentifier:[[NSBundle mainBundle]
                                                             bundleIdentifier]];
                      NSError *error = nil;
                      [service registerAndReturnError:&error];
                      if (error) {
                        NSLog(@"Error adding to login items: %@",
                              error.localizedDescription);
                      }
                    }
                  }];
  }
}

- (void)showProgressWindowWithMax:(NSInteger)maxCount {

  if (!self.progressWindow) {
    NSRect frame = NSMakeRect(0, 0, 480, 320);
    self.progressWindow =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    [self.progressWindow setTitle:@"Optimizing Live Wallpapers"];
    [self.progressWindow center];

    NSView *contentView = self.progressWindow.contentView;

    // Progress Label
    self.progressLabel =
        [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 20)];
    [self.progressLabel setEditable:NO];
    [self.progressLabel setBezeled:NO];
    [self.progressLabel setDrawsBackground:NO];
    [self.progressLabel setStringValue:@"Starting..."];
    [contentView addSubview:self.progressLabel];

    // Progress Bar
    self.progressBar = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(20, 250, 440, 20)];
    [self.progressBar setIndeterminate:NO];
    [self.progressBar setMinValue:0];
    [self.progressBar setMaxValue:maxCount];
    [self.progressBar setDoubleValue:0];
    [self.progressBar setUsesThreadedAnimation:YES];
    [contentView addSubview:self.progressBar];

    // Scrollable TextView for logs
    NSScrollView *scrollView =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 440, 210)];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setAutohidesScrollers:YES];

    NSTextView *textView =
        [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 440, 210)];
    [textView setEditable:NO];
    [textView setSelectable:YES];
    [textView setFont:[NSFont userFixedPitchFontOfSize:12]];
    [textView setBackgroundColor:[NSColor blackColor]];
    [textView setTextColor:[NSColor greenColor]];
    [textView setString:@"Log:\n"];

    [scrollView setDocumentView:textView];
    [contentView addSubview:scrollView];

    self.logTextView = textView;
  }
  [self.progressWindow setAlphaValue:0.0];
  [self.progressWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];
  [self.progressWindow.contentView setWantsLayer:YES];
  self.progressWindow.contentView.layer.transform =
      CATransform3DMakeScale(0.92, 0.92, 1.0);

  //[self.progressWindow makeKeyAndOrderFront:nil];

  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.35;
        self.progressWindow.animator.alphaValue = 1.0;
        self.progressWindow.contentView.layer.transform = CATransform3DIdentity;
      }
      completionHandler:nil];
}
- (void)appendLogMessage:(NSString *)text {
  if (!self.logTextView)
    return;

  NSDictionary *attrs = @{
    NSForegroundColorAttributeName : [NSColor greenColor],
    NSFontAttributeName : [NSFont userFixedPitchFontOfSize:12]
  };

  NSString *fullText = [text stringByAppendingString:@"\n"];
  __block NSUInteger charIndex = 0;
  __block NSMutableAttributedString *typingBuffer =
      [[NSMutableAttributedString alloc] init];

  dispatch_async(dispatch_get_main_queue(), ^{
    NSTimer *timer = [NSTimer
        scheduledTimerWithTimeInterval:0.01
                               repeats:YES
                                 block:^(NSTimer *_Nonnull timer) {
                                   if (charIndex >= fullText.length) {
                                     [[self.logTextView textStorage]
                                         appendAttributedString:typingBuffer];
                                     NSRange range = NSMakeRange(
                                         [[self.logTextView string] length], 0);

                                     [NSAnimationContext
                                         runAnimationGroup:^(
                                             NSAnimationContext *context) {
                                           context.duration = 0.3;
                                           [[self.logTextView animator]
                                               scrollRangeToVisible:range];
                                         }
                                         completionHandler:nil];

                                     [timer invalidate];
                                     return;
                                   }

                                   NSString *nextChar = [fullText
                                       substringWithRange:NSMakeRange(charIndex,
                                                                      1)];
                                   NSAttributedString *attrChar =
                                       [[NSAttributedString alloc]
                                           initWithString:nextChar
                                               attributes:attrs];
                                   [typingBuffer
                                       appendAttributedString:attrChar];
                                   charIndex++;
                                 }];

    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  });
}

- (void)optimizeAllVideosInFolder {
  checkFolderPath();
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSArray *videoFiles = [fileManager contentsOfDirectoryAtPath:folderPath
                                                         error:nil];

  NSPredicate *predicate = [NSPredicate
      predicateWithBlock:^BOOL(NSString *filename, NSDictionary *bindings) {
        NSString *lower = filename.lowercaseString;
        return [lower hasSuffix:@".mp4"] || [lower hasSuffix:@".mov"];
      }];
  videoFiles = [videoFiles filteredArrayUsingPredicate:predicate];

  // Show the progress window on the main thread before starting conversion
  dispatch_async(dispatch_get_main_queue(), ^{
    [self showProgressWindowWithMax:videoFiles.count];
  });

  __block NSInteger currentIndex = 0;

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSString *file in videoFiles) {
          currentIndex++;
          NSString *fullPath = [folderPath stringByAppendingPathComponent:file];
          NSURL *fileURL = [NSURL fileURLWithPath:fullPath];
          AVAsset *asset = [AVAsset assetWithURL:fileURL];
          BOOL isHEVC = NO;

          // Get video tracks with compatibility for old and new APIs
          __block NSArray<AVAssetTrack *> *videoTracks = nil;
          if (@available(macOS 15.0, *)) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [asset loadTracksWithMediaType:AVMediaTypeVideo
                         completionHandler:^(
                             NSArray<AVAssetTrack *> *_Nullable tracks,
                             NSError *_Nullable error) {
                           videoTracks = tracks;
                           dispatch_semaphore_signal(semaphore);
                         }];
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
          } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
          }

          for (AVAssetTrack *track in videoTracks) {
            CFArrayRef formatDescriptions =
                (__bridge CFArrayRef)track.formatDescriptions;
            for (CFIndex i = 0; i < CFArrayGetCount(formatDescriptions); i++) {
              CMFormatDescriptionRef fmt =
                  (CMFormatDescriptionRef)CFArrayGetValueAtIndex(
                      formatDescriptions, i);
              FourCharCode codec = CMFormatDescriptionGetMediaSubType(fmt);
              if (codec == kCMVideoCodecType_HEVC) {
                isHEVC = YES;
                break;
              }
            }
            if (isHEVC)
              break;
          }

          dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressLabel
                setStringValue:[NSString
                                   stringWithFormat:@"Processing: %@", file]];
            [self.progressBar setDoubleValue:currentIndex - 1];
          });

          if (isHEVC) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [self.progressLabel
                  setStringValue:
                      [NSString stringWithFormat:@"Skipped (already HEVC): %@",
                                                 file]];
              [NSAnimationContext
                  runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.2;
                    [self.progressBar.animator setDoubleValue:currentIndex];
                  }
                  completionHandler:nil];

              [self
                  appendLogMessage:
                      [NSString stringWithFormat:@"Skipped (already HEVC): %@",
                                                 file]];
            });
            continue;
          }

          // Safe temp file path with same extension as original
          NSString *tempName = [NSString
              stringWithFormat:@"%@.tmp.mp4", [[NSUUID UUID] UUIDString]];
          NSString *tempPath =
              [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];
          NSURL *tempURL = [NSURL fileURLWithPath:tempPath];

          AVAssetExportSession *exportSession = [[AVAssetExportSession alloc]
              initWithAsset:asset
                 presetName:AVAssetExportPresetHEVCHighestQuality];
          exportSession.outputURL = tempURL;
          exportSession.outputFileType = AVFileTypeMPEG4;
          exportSession.shouldOptimizeForNetworkUse = YES;
          dispatch_semaphore_t sema = dispatch_semaphore_create(0);

          [exportSession exportAsynchronouslyWithCompletionHandler:^{
            NSFileManager *fm = [NSFileManager defaultManager];
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
              NSError *replaceError = nil;
              // Remove original
              if ([fm fileExistsAtPath:fileURL.path]) {
                if (![fm removeItemAtURL:fileURL error:&replaceError]) {
                  NSLog(@"Remove failed: %@",
                        replaceError.localizedDescription);
                }
              }
              // Move temp to original
              if (![fm moveItemAtURL:tempURL
                               toURL:fileURL
                               error:&replaceError]) {
                NSLog(@"Replace failed: %@", replaceError.localizedDescription);
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self
                      appendLogMessage:
                          [NSString
                              stringWithFormat:@"Replace failed: %@ (%@)", file,
                                               replaceError
                                                   .localizedDescription]];
                });
              } else {
                NSLog(@"Converted: %@", file);
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self appendLogMessage:[NSString
                                             stringWithFormat:@"Converted: %@",
                                                              file]];
                });
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                [self.progressLabel
                    setStringValue:[NSString stringWithFormat:@"Converted: %@",
                                                              file]];
                [self.progressBar setDoubleValue:currentIndex];
              });
            } else {
              NSLog(@"Export failed for %@ (%@)", file,
                    exportSession.error.localizedDescription);
              [fm removeItemAtURL:tempURL error:nil];
              dispatch_async(dispatch_get_main_queue(), ^{
                [self appendLogMessage:
                          [NSString
                              stringWithFormat:@"Export failed: %@ (%@)", file,
                                               exportSession.error
                                                   .localizedDescription]];
                [self.progressLabel
                    setStringValue:[NSString
                                       stringWithFormat:@"Failed: %@", file]];
                [self.progressBar setDoubleValue:currentIndex];
              });
            }
            dispatch_semaphore_signal(sema);
          }];
          dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          [self.progressLabel setStringValue:@"All conversions done!"];
          [self.progressBar setDoubleValue:videoFiles.count];
          [self appendLogMessage:@"All conversions done!"];
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [NSAnimationContext
                    runAnimationGroup:^(NSAnimationContext *context) {
                      context.duration = 0.3;
                      self.progressWindow.animator.alphaValue = 0.0;
                    }
                    completionHandler:^{
                      [self.progressWindow orderOut:nil];
                      self.progressWindow.alphaValue = 1.0;
                    }];
              });
        });
      });
}

- (void)checkAndPromptPermissions {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults boolForKey:@"AccessibilityPermissionChecked"])
    return;
  [defaults setBool:YES forKey:@"AccessibilityPermissionChecked"];
  [defaults synchronize];

  if (!AXIsProcessTrusted()) {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
  }
}

- (void)ReloadContent {

  for (NSButton *btn in buttons) {
    [btn removeFromSuperview];
  }
  [buttons removeAllObjects];

  checkFolderPath();
  NSArray<NSString *> *allFiles =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderPath
                                                          error:nil];

  NSPredicate *predicate =
      [NSPredicate predicateWithFormat:
                       @"SELF ENDSWITH[c] '.mp4' OR SELF ENDSWITH[c] '.mov'"];
  NSArray<NSString *> *videoFiles =
      [allFiles filteredArrayUsingPredicate:predicate];

  for (NSString *filename in videoFiles) {
    @autoreleasepool {
      NSString *videoPath =
          [folderPath stringByAppendingPathComponent:filename];
      NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

      NSButton *btn = [[NSButton alloc]
          initWithFrame:NSMakeRect(0, 0, BUTTON_SIZE,
                                   BUTTON_SIZE * 9.0f / 16.0f)];

      NSString *cacheImagePath = [[self thumbnailCachePath]
          stringByAppendingPathComponent:
              [[filename stringByDeletingPathExtension]
                  stringByAppendingPathExtension:@"png"]];

      NSImage *image = [[NSImage alloc] initWithContentsOfFile:cacheImagePath];
      if (image) {
        btn.image = image;
      } else {
        NSLog(@"Thumbnail not found for %@", cacheImagePath);
        if (_generatingThumbImages == false) {
          AsyncLoading(^{
            [self generateThumbnailsForFolder:getFolderPath()];
          });
          [self ReloadContent];
          return;
        }
      }

      // Button styling - consolidated
      btn.layer.cornerRadius = 10.0f;
      btn.layer.masksToBounds = YES;
      btn.bezelStyle = NSBezelStyleShadowlessSquare;
      btn.imageScaling = NSImageScaleAxesIndependently;
      btn.imagePosition = NSImageOnly;
      btn.title = @"";
      btn.target = self;
      btn.action = @selector(handleButtonClick:);
      btn.toolTip = filename;
      btn.translatesAutoresizingMaskIntoConstraints = YES;
      btn.tag = [videoFiles indexOfObject:filename];

      [btn.image setSize:btn.bounds.size];

      [buttons addObject:btn];
    }
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [self.collectionView reloadData];
  });
}
- (void)convertCodec:(id)sender {
  [self optimizeAllVideosInFolder];
}

void killAllDaemons() {
  NSTask *killTask = [[NSTask alloc] init];
  killTask.launchPath = @"/usr/bin/killall";
  killTask.arguments = @[ @"wallpaperdaemon" ];
  [killTask launch];
  [killTask waitUntilExit];

  int status = killTask.terminationStatus;
  if (status != 0) {
    NSLog(@"No running VideoWallpaperDaemon process found or killall failed");
  } else {
    NSLog(@"VideoWallpaperDaemon processes killed");
  }
}
extern char **environ;
void launchDaemon(NSString *videoPath, NSString *imagePath) {
  NSString *daemonRelativePath = @"Contents/MacOS/wallpaperdaemon";
  NSString *appPath = [[NSBundle mainBundle] bundlePath];
  NSString *daemonPath =
      [appPath stringByAppendingPathComponent:daemonRelativePath];

  float volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  NSString *volumeStr = [NSString stringWithFormat:@"%.2f", volume];
  NSString *scaleMode =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"scale_mode"];
  NSLog(@"Scaling mode: %@", scaleMode);

  const char *daemonPathC = [daemonPath UTF8String];
  const char *args[] = {daemonPathC,
                        [videoPath UTF8String],
                        [imagePath UTF8String],
                        [volumeStr UTF8String],
                        [scaleMode UTF8String],

                        NULL};

  pid_t pid;
  int status =
      posix_spawn(&pid, daemonPathC, NULL, NULL, (char *const *)args, environ);
  if (status != 0) {
    NSLog(@"Failed to launch daemon: %d", status);
  }
}

void launchDaemonOnScreen(NSString *videoPath, NSString *imagePath,
                          CGDirectDisplayID displayID) {
  NSString *daemonRelativePath = @"Contents/MacOS/wallpaperdaemon";
  NSString *appPath = [[NSBundle mainBundle] bundlePath];
  NSString *daemonPath =
      [appPath stringByAppendingPathComponent:daemonRelativePath];

  float volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  NSString *volumeStr = [NSString stringWithFormat:@"%.2f", volume];
  NSString *scaleMode =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"scale_mode"];

  // Set default scale mode if not set to prevent daemon crash
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
  }
  all_deamon_created.push_back(pid);

  SetWallpaperDisplay(pid, displayID, std::string([videoPath UTF8String]),
                      std::string([imagePath UTF8String]));
}

- (void)startWallpaperWithPath:(NSString *)videoPath {

  if (!videoPath || videoPath.length == 0 || videoPath == nil) {
    NSLog(@"ERROR: Invalid videoPath");
    return;
  }

  // If display selection empty -> select all displays
  if (_selectedDisplays.empty()) {
    for (auto ID : displays) {
      _selectedDisplays.push_back(ID.screen);
    }
  }
  LogMemoryUsage();

  // killAllDaemons();
  // usleep(300000);

  std::string g_videoPath = std::string([videoPath UTF8String]);

  NSString *videoPathNSString =
      [NSString stringWithUTF8String:g_videoPath.c_str()];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:videoPathNSString forKey:@"LastWallpaperPath"];
  [defaults synchronize];

  std::filesystem::path p(g_videoPath);
  std::string videoName = p.stem().string();

  if (!fs::exists(g_videoPath)) {
    std::cerr << "Video file does not exist.\n";
    return;
  }

  checkFolderPath();

  NSString *imageFilename =
      [NSString stringWithFormat:@"%s.png", (const char *)videoName.c_str()];
  NSString *imagePath = [[self staticWallpaperChachePath]
      stringByAppendingPathComponent:imageFilename];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:imagePath] && !_generatingImages) {
    NSLog(@"Static wallpaper not found, generating for: %@", videoPath);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      [self generateStaticWallpapersForFolder:getFolderPath()];
    });
  }

  NSLog(@"videoPath = %@", videoPath);

  for (CGDirectDisplayID dID : _selectedDisplays) {
    AsyncLoading(^{
      NSString *msg =
          [NSString stringWithFormat:@"Applying Wallpaper on Display: %@ ...",
                                     displayNameForDisplayID(dID)];

      loadingMessage(msg);

      launchDaemonOnScreen(videoPath, imagePath, dID);
    });
  }

  PrintDisplays(displays);

  LogMemoryUsage();
}

- (void)handleButtonClick:(NSButton *)sender {
  NSString *videoPath =
      [folderPath stringByAppendingPathComponent:sender.toolTip];
  if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath])
    return;

  [self startWallpaperWithPath:videoPath];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize {

  [self.collectionView reloadData];

  return proposedFrameSize;
}

- (void)openWallpaperFolder:(id)sender {
  checkFolderPath();
  NSFileManager *fm = [NSFileManager defaultManager];

  // Create folder if it doesn't exist
  if (![fm fileExistsAtPath:folderPath]) {
    NSError *error = nil;
    BOOL created = [fm createDirectoryAtPath:folderPath
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&error];
    if (!created) {
      NSLog(@"Failed to create Livewall folder: %@", error);
      return;
    }
  }

  // Open folder in Finder
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:folderPath]];
}
// Touchbar
- (NSTouchBar *)makeTouchBar {
  NSLog(@"Touchbar created");
  NSTouchBar *touchBar = [[NSTouchBar alloc] init];
  touchBar.delegate = self;
  touchBar.defaultItemIdentifiers = @[
    NSTouchBarItemIdentifierFlexibleSpace, @"com.livewallpaper.reload",
    @"com.livewallpaper.selectfolder", @"com.livewallpaper.openfolder",
    @"com.livewallpaper.settings", @"com.livewallpaper.volume",
    NSTouchBarItemIdentifierFlexibleSpace
  ];
  return touchBar;
}

- (NSImage *)volumeIconForValue:(double)value {
  if (value <= 0.0) {
    return [NSImage imageNamed:NSImageNameTouchBarAudioOutputMuteTemplate];
  } else if (value < 30.0) {
    return [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeLowTemplate];
  } else if (value < 70.0) {
    return
        [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeMediumTemplate];
  } else {
    return
        [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeHighTemplate];
  }
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {

  if ([identifier isEqualToString:@"com.livewallpaper.selectfolder"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button =
        [NSButton buttonWithTitle:@"📂"
                           target:self
                           action:@selector(selectWallpaperFolder:)];
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.openfolder"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button = [NSButton
        buttonWithImage:GetSystemAppIcon(@"Finder", NSMakeSize(24, 24))
                 target:self
                 action:@selector(openWallpaperFolder:)];
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.reload"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button;
    if (@available(macOS 11.0, *)) {
      NSImage *reloadIcon =
          [NSImage imageWithSystemSymbolName:@"arrow.clockwise"
                    accessibilityDescription:@"Reload"];
      button = [NSButton buttonWithImage:reloadIcon
                                  target:self
                                  action:@selector(ReloadContent)];
    } else {
      button = [NSButton buttonWithTitle:@"↻"
                                  target:self
                                  action:@selector(ReloadContent)];
    }
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.settings"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button =
        [NSButton buttonWithTitle:@"⚙️"
                           target:self
                           action:@selector(showSettingsWindow:)];
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.volume"]) {

    NSPopoverTouchBarItem *popoverItem =
        [[NSPopoverTouchBarItem alloc] initWithIdentifier:identifier];

    double currentValue = [[NSUserDefaults standardUserDefaults]
        floatForKey:@"wallpapervolumeprecentage"];
    popoverItem.collapsedRepresentationImage =
        [self volumeIconForValue:currentValue];
    popoverItem.showsCloseButton = YES;

    // Expanded bar
    NSTouchBar *expandedTouchBar = [[NSTouchBar alloc] init];
    expandedTouchBar.delegate = self;
    expandedTouchBar.defaultItemIdentifiers =
        @[ @"com.livewallpaper.volume.slider" ];

    popoverItem.popoverTouchBar = expandedTouchBar;
    self.volumePopoverItem = popoverItem;
    return popoverItem;
  } else if ([identifier isEqualToString:@"com.livewallpaper.volume.slider"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];

    // Container
    NSStackView *container =
        [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 280, 30)];
    container.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    container.spacing = 8.0;

    // Slider
    NSSlider *slider =
        [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 220, 20)];
    slider.minValue = 0;
    slider.maxValue = 100;
    slider.doubleValue = [[NSUserDefaults standardUserDefaults]
        floatForKey:@"wallpapervolumeprecentage"];
    slider.target = self;
    slider.action = @selector(sliderValueChanged:);

    // Percentage label
    NSTextField *percentageLabel =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 40, 30)];
    percentageLabel.stringValue =
        [NSString stringWithFormat:@"%.0f%%", slider.doubleValue];
    percentageLabel.editable = NO;
    percentageLabel.bezeled = NO;
    percentageLabel.drawsBackground = NO;
    percentageLabel.alignment = NSTextAlignmentCenter;
    percentageLabel.font = [NSFont systemFontOfSize:12];

    // Keep ref so we can update dynamically
    self.touchbar_volume = percentageLabel;

    [container addArrangedSubview:slider];
    [container addArrangedSubview:percentageLabel];

    item.view = container;
    return item;
  }
  NSLog(@"No Item found on identifier");
  return nil;
}

void generateStaticWallpapersForFolderCallback(CFNotificationCenterRef center,
                                               void *observer, CFStringRef name,
                                               const void *object,
                                               CFDictionaryRef userInfo) {
  AppDelegate *self = (__bridge AppDelegate *)observer;

  // Call your Objective-C method safely
  NSString *folderPath = getFolderPath();
  if (folderPath &&
      [[NSFileManager defaultManager] fileExistsAtPath:folderPath]) {
    [self generateStaticWallpapersForFolder:folderPath];
  }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [[NSUserDefaults standardUserDefaults]
      registerDefaults:@{@"pauseOnAppFocus" : @YES}];

  CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      (__bridge const void *)(self), generateStaticWallpapersForFolderCallback,
      CFSTR("com.live.wallpaper.generateCache"), NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);

  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.terminate"), NULL, NULL, true);

  [self.blurWindow.contentView setWantsLayer:YES];
  [self.settingsWindow.contentView setWantsLayer:YES];

  if (![self isFirstLaunch]) {
    [self fadeOutWindowsWithCompletion:nil];
  }

  checkFolderPath();
  if ([self isFirstLaunch]) {
    [self promptForLoginItem];
    [self checkAndPromptPermissions];
  }
  NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};

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
                handleSpaceChange(note);
              }];

  NSDistributedNotificationCenter *center =
      [NSDistributedNotificationCenter defaultCenter];

  [center addObserver:self
             selector:@selector(UnlockHandle:)
                 name:@"com.apple.screenIsUnlocked"
               object:nil];

  NSRect frame = NSMakeRect(0, 0, 800, 600);
  self.blurWindow = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [self.blurWindow setTitle:@"LiveWallpaper by Bios"];
  [self.blurWindow center];
  [self.blurWindow
      setCollectionBehavior:NSWindowCollectionBehaviorMoveToActiveSpace];

  [self.blurWindow makeKeyAndOrderFront:nil];

  self.blurWindow.delegate = self;

  if (@available(macOS 10.12.2, *)) {
    NSLog(@"Touchbar supported!");
    self.blurWindow.touchBar = [self makeTouchBar];
  } else {
    NSLog(@"Touchbar not supported!");
  }
  [self.blurWindow setOpaque:NO];
  [self.blurWindow setBackgroundColor:[NSColor clearColor]];
  self.blurWindow.minSize = NSMakeSize(600, 250);

  NSView *effectView = nil;
#if MACOS26
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView *blurView = [[NSGlassEffectView alloc]
        initWithFrame:[[self.blurWindow contentView] bounds]];
    [blurView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [blurView setWantsLayer:YES];
    effectView = blurView;
  }
#else
  NSVisualEffectView *blurView = [[NSVisualEffectView alloc]
      initWithFrame:[[self.blurWindow contentView] bounds]];
  blurView.material = NSVisualEffectMaterialHUDWindow;
  blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  blurView.state = NSVisualEffectStateActive;
  [blurView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [blurView setWantsLayer:YES];
  effectView = blurView;
#endif

  [[self.blurWindow contentView] addSubview:effectView
                                 positioned:NSWindowBelow
                                 relativeTo:nil];

  NSView *content = [self.blurWindow contentView];
  content.layer.backgroundColor = [NSColor clearColor].CGColor;
  effectView.layer.backgroundColor = [NSColor clearColor].CGColor;

  self.blurWindow.titleVisibility = NSWindowTitleVisible;
  self.blurWindow.titlebarAppearsTransparent = YES;
  self.blurWindow.styleMask |= NSWindowStyleMaskFullSizeContentView;

  NSView *contentContainer = [[NSView alloc] init];
  contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:contentContainer];

  [NSLayoutConstraint activateConstraints:@[
    [contentContainer.topAnchor constraintEqualToAnchor:content.topAnchor
                                               constant:12],
    [contentContainer.leadingAnchor
        constraintEqualToAnchor:content.leadingAnchor
                       constant:12],
    [contentContainer.trailingAnchor
        constraintEqualToAnchor:content.trailingAnchor
                       constant:-12],
    [contentContainer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                  constant:-12]
  ]];

  NSStackView *mainStack = [[NSStackView alloc] init];
  mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  mainStack.spacing = 12;
  mainStack.distribution = NSStackViewDistributionFillProportionally;
  mainStack.translatesAutoresizingMaskIntoConstraints = NO;
  [contentContainer addSubview:mainStack];

  [NSLayoutConstraint activateConstraints:@[
    [mainStack.topAnchor constraintEqualToAnchor:contentContainer.topAnchor],
    [mainStack.leadingAnchor
        constraintEqualToAnchor:contentContainer.leadingAnchor],
    [mainStack.trailingAnchor
        constraintEqualToAnchor:contentContainer.trailingAnchor],
    [mainStack.bottomAnchor
        constraintEqualToAnchor:contentContainer.bottomAnchor]
  ]];

  NSView *topSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
  [topSpacer.heightAnchor constraintEqualToConstant:24].active = YES;
  [mainStack addArrangedSubview:topSpacer];

  LineModule *buttonPanel = [[LineModule alloc] initWithFrame:NSZeroRect];
  NSButton *settingsButton =
      CreateButton(@"⚙️", self, @selector(showSettingsWindow:));
  NSButton *reloadButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)];
  if (@available(macOS 11.0, *)) {
    NSImage *reloadIcon = [NSImage imageWithSystemSymbolName:@"arrow.clockwise"
                                    accessibilityDescription:@"Reload"];
    [reloadButton setImage:reloadIcon];
    [reloadButton setImagePosition:NSImageOnly];
  } else {
    [reloadButton setTitle:@"↻"];
  }
  [reloadButton setBezelStyle:NSBezelStyleRounded];
  [reloadButton setTarget:self];
  [reloadButton setAction:@selector(ReloadContent)];
  [buttonPanel add:reloadButton];
  [buttonPanel add:settingsButton];
  [mainStack addArrangedSubview:buttonPanel];

  [self setupCollectionViewInStack:mainStack];
  [self ReloadContent];

  [self setupFloatingDock];
  ScanDisplays();
  [self LoadDisplayConfig];
  usleep(1);
  dispatch_async(dispatch_get_main_queue(), ^{
    AppDelegate *appDelegate = (AppDelegate *)[NSApp delegate];
    [appDelegate reloadDock];
  });

  self.statusItem = [[NSStatusBar systemStatusBar]
      statusItemWithLength:NSSquareStatusItemLength];
  if (@available(macOS 11.0, *)) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"play.rectangle"
                              accessibilityDescription:@"Play Display"];

    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
        configurationWithTextStyle:NSFontTextStyleBody];
    NSImage *configuredIcon = [icon imageWithSymbolConfiguration:config];

    self.statusItem.button.image = configuredIcon;
    self.statusItem.button.contentTintColor = nil;
  } else {
    NSImage *icon = [NSImage imageNamed:NSImageNameApplicationIcon];
    self.statusItem.button.image = icon;
  }

  NSMenu *menu = [[NSMenu alloc] init];
  [menu addItemWithTitle:@"Open UI"
                  action:@selector(showUIWindow)
           keyEquivalent:@"o"];
  [menu addItemWithTitle:@"Settings"
                  action:@selector(showSettingsWindow:)
           keyEquivalent:@"s"];
  [menu addItemWithTitle:@"Quit" action:@selector(quitApp) keyEquivalent:@"q"];
  self.statusItem.menu = menu;
}

- (void)setupCollectionViewInStack:(NSStackView *)mainStack {
  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.drawsBackground = NO;
  scrollView.borderType = NSBorderType::NSNoBorder;

  self.flowLayout = [[NSCollectionViewFlowLayout alloc] init];
  self.flowLayout.minimumInteritemSpacing = BUTTON_SPACING;
  self.flowLayout.minimumLineSpacing = BUTTON_SPACING;
  self.flowLayout.sectionInset = NSEdgeInsetsMake(12, 24, 12, 24);

  self.flowLayout.scrollDirection = NSCollectionViewScrollDirectionVertical;

  self.flowLayout.itemSize = NSMakeSize(BUTTON_SIZE, BUTTON_SIZE * 0.5625f);
  self.flowLayout.estimatedItemSize = NSZeroSize;

  self.collectionView = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
  self.collectionView.collectionViewLayout = self.flowLayout;
  self.collectionView.dataSource = self;
  self.collectionView.delegate = self;
  self.collectionView.backgroundColors = @[ [NSColor clearColor] ];
  self.collectionView.selectable = NO;

  [self.collectionView registerClass:[NSCollectionViewItem class]
               forItemWithIdentifier:@"VideoItem"];

  scrollView.documentView = self.collectionView;
  [mainStack addArrangedSubview:scrollView];

  [self setMaxWindowWidth];
}

- (void)setMaxWindowWidth {
  CGFloat horizontalInset = 24 + 24;
  CGFloat totalButtonWidth = BUTTON_SIZE * BUTTON_MAX_COLUMNS;
  CGFloat totalSpacing = BUTTON_SPACING * (BUTTON_MAX_COLUMNS - 1);
  CGFloat scrollbarWidth = 15;

  CGFloat maxWidth =
      totalButtonWidth + totalSpacing + horizontalInset + scrollbarWidth;

  NSSize maxSize = NSMakeSize(maxWidth, MAXFLOAT);
  [self.blurWindow setContentMaxSize:maxSize];
}

- (NSInteger)collectionView:(NSCollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
  return buttons.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
     itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {

  NSCollectionViewItem *item =
      [collectionView makeItemWithIdentifier:@"VideoItem"
                                forIndexPath:indexPath];

  NSUInteger idx = indexPath.item;

  if (idx < buttons.count) {

    NSButton *btn = buttons[idx];

    [item.view.subviews
        makeObjectsPerformSelector:@selector(removeFromSuperview)];

    btn.frame = item.view.bounds;
    btn.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [item.view addSubview:btn];
  }

  return item;
}

- (void)setupFloatingDock {
  NSView *content = self.blurWindow.contentView;

  // Create dock container
  NSView *dockView = [[NSView alloc] init];
  dockView.wantsLayer = YES;
  dockView.layer.cornerRadius = 12;
  dockView.layer.masksToBounds = YES;
  dockView.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:dockView];

  CGFloat dockHeight = 80;
  CGFloat bottomOffset = 20;

  // Floating dock constraints
  [NSLayoutConstraint activateConstraints:@[
    [dockView.centerXAnchor
        constraintEqualToAnchor:content.centerXAnchor], // center horizontally
    [dockView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                          constant:-bottomOffset],
    [dockView.heightAnchor constraintEqualToConstant:dockHeight]
  ]];

  // Background blur / liquid glass
  NSView *effectView;
#if MACOS26
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView *blurView =
        [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.style = NSGlassEffectViewStyleClear;
    effectView = blurView;
  }
#else
  NSVisualEffectView *blurView =
      [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
  blurView.material = NSVisualEffectMaterialHUDWindow;
  blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  blurView.state = NSVisualEffectStateActive;
  blurView.translatesAutoresizingMaskIntoConstraints = NO;
  effectView = blurView;
#endif

  [dockView addSubview:effectView positioned:NSWindowBelow relativeTo:nil];
  [NSLayoutConstraint activateConstraints:@[
    [effectView.topAnchor constraintEqualToAnchor:dockView.topAnchor],
    [effectView.bottomAnchor constraintEqualToAnchor:dockView.bottomAnchor],
    [effectView.leadingAnchor constraintEqualToAnchor:dockView.leadingAnchor],
    [effectView.trailingAnchor constraintEqualToAnchor:dockView.trailingAnchor]
  ]];

  // Horizontal stack view for buttons
  self.dockStack = [[NSStackView alloc] init];
  self.dockStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.dockStack.alignment = NSLayoutAttributeCenterY;
  self.dockStack.distribution = NSStackViewDistributionFill;
  self.dockStack.spacing = 8;
  self.dockStack.translatesAutoresizingMaskIntoConstraints = NO;
  [dockView addSubview:self.dockStack];

  [NSLayoutConstraint activateConstraints:@[
    [self.dockStack.topAnchor constraintEqualToAnchor:dockView.topAnchor
                                             constant:5],
    [self.dockStack.bottomAnchor constraintEqualToAnchor:dockView.bottomAnchor
                                                constant:-5],
    [self.dockStack.leadingAnchor constraintEqualToAnchor:dockView.leadingAnchor
                                                 constant:8],
    [self.dockStack.trailingAnchor
        constraintEqualToAnchor:dockView.trailingAnchor
                       constant:-8]
  ]];

  // Rebuild buttons and adjust dock width dynamically
  [self reloadDock];
}
- (void)reloadDock {
  if (!self.dockStack)
    return; // safety check

  // Remove all old buttons
  for (NSView *v in self.dockStack.arrangedSubviews) {
    [self.dockStack removeArrangedSubview:v];
    [v removeFromSuperview];
  }

  // Get dock height
  CGFloat dockHeight = self.dockStack.frame.size.height;
  CGFloat buttonSpacing = self.dockStack.spacing;
  CGFloat totalWidth = 16; // padding 8+8

  // Rebuild buttons from displays list

  for (const Display &disp : displays) {
    NSLog(@"Button creating for : %@", displayNameForDisplayID(disp.screen));
    // NSButton *btn =
    //     [NSButton buttonWithTitle:displayNameForDisplayID(disp.screen)
    //                        target:self
    //                        action:@selector(dockButtonToggled:)];

    CGFloat button_width = 200;

    NSButton *btn = CreateDisplayButtonWithSize(disp.screen, self,
                                                @selector(dockButtonToggled:),
                                                button_width, dockHeight);

    btn.tag = disp.screen;
    btn.translatesAutoresizingMaskIntoConstraints = NO;

    // Glow styling
    btn.layer.cornerRadius = 6;
    btn.layer.backgroundColor = [NSColor clearColor].CGColor;
    btn.layer.shadowOpacity = 0;
    btn.layer.shadowRadius = 10;
    btn.layer.shadowColor = [NSColor yellowColor].CGColor;
    btn.layer.shadowOffset = CGSizeZero;

    [self.dockStack addArrangedSubview:btn];

    totalWidth += button_width + buttonSpacing;
  }

  // Update dock container width dynamically
  [NSLayoutConstraint deactivateConstraints:self.dockWidthConstraints];
  self.dockWidthConstraints = @[ [self.dockStack.superview.widthAnchor
      constraintEqualToConstant:totalWidth] ];
  for (NSLayoutConstraint *c in self.dockWidthConstraints) {
    c.active = YES;
  }
}

// Toggle button with multi-selection & yellow glow
- (IBAction)dockButtonToggled:(NSButton *)sender {

  if ([sender state] == NSControlStateValueOn) {

    sender.layer.borderColor = [NSColor yellowColor].CGColor;
    sender.layer.shadowOpacity = 1;
    sender.layer.borderWidth = 2.5;

  } else {
    sender.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.4].CGColor;
    sender.layer.shadowOpacity = 0;
    sender.layer.borderWidth = 1.5;
  }
  _selectedDisplays.clear();
  for (NSButton *btn in self.dockStack.arrangedSubviews) {
    if ([btn state] == NSControlStateValueOn) {
      _selectedDisplays.push_back(btn.tag);
    }
  }

  {
    NSMutableString *logString =
        [NSMutableString stringWithString:@"Selected displays: ["];

    for (CGDirectDisplayID displayID : _selectedDisplays) {
      [logString appendFormat:@"%u, ", displayID];
    }

    [logString appendString:@"]"];
    NSLog(@"%@", logString);
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  NSLog(@"🚪 App terminating...");
  killAllDaemons();
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.terminate"), NULL, NULL, true);

  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (void)showUIWindow {
  reload = true;
  [self.blurWindow makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)quitApp {

  SaveDisplayConfig();

  NSLog(@"💥 Quit triggered");

  killAllDaemons();
  AsyncLoading(^{
    loadingMessage(@"Killing all daemons exsist...");
    for (pid_t pid : all_deamon_created) {

      KillProcessByPID(pid);
    }
  });

  [NSApp terminate:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.blurWindow.animator.alphaValue = 0.0;
        // if (self.settingsWindow) {
        // self.settingsWindow.animator.alphaValue = 0.0;
        //}
      }
      completionHandler:^{
        [self.blurWindow orderOut:nil];
        if (self.settingsWindow) {
          [self.settingsWindow orderOut:nil];
        }
        self.blurWindow.alphaValue = 1.0;
        if (self.settingsWindow) {
          self.settingsWindow.alphaValue = 1.0;
        }
      }];
  return NO;
}
- (void)fadeOutWindowsWithCompletion:(void (^)(void))completion {
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.blurWindow.animator.alphaValue = 0.0;
        if (self.settingsWindow) {
          self.settingsWindow.animator.alphaValue = 0.0;
        }
      }
      completionHandler:^{
        [self.blurWindow orderOut:nil];
        if (self.settingsWindow) {
          [self.settingsWindow orderOut:nil];
        }
        self.blurWindow.alphaValue = 1.0;
        if (self.settingsWindow) {
          self.settingsWindow.alphaValue = 1.0;
        }
        if (completion)
          completion();
      }];
}

NSButton *CreateDisplayButtonWithSize(CGDirectDisplayID displayID, id target,
                                      SEL action, CGFloat width,
                                      CGFloat height) {
  NSString *displayName = @"Unknown Display";
  NSString *resolution = @"";
  CGSize size = CGSizeZero;

  if (CGDisplayIsActive(displayID)) {
    size.width = CGDisplayPixelsWide(displayID);
    size.height = CGDisplayPixelsHigh(displayID);
    resolution =
        [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];

    for (NSScreen *screen in [NSScreen screens]) {
      NSDictionary *deviceDesc = screen.deviceDescription;
      NSNumber *screenNumber = deviceDesc[@"NSScreenNumber"];
      if (screenNumber && [screenNumber unsignedLongValue] == displayID) {
        displayName = screen.localizedName;
        break;
      }
    }
  }

  NSSize imageSize = NSMakeSize(width, height);
  NSImage *image = [[NSImage alloc] initWithSize:imageSize];
  [image lockFocus];

  [[NSColor clearColor] set];
  NSRectFill(NSMakeRect(0, 0, width, height));

  // Dynamic font sizing based on button size
  CGFloat nameFontSize = MAX(12, height * 0.15);
  CGFloat resFontSize = MAX(10, height * 0.1);
  CGFloat arrowFontSize = MAX(12, height * 0.12);

  NSDictionary *nameAttrs = @{
    NSFontAttributeName : [NSFont boldSystemFontOfSize:nameFontSize],
    NSForegroundColorAttributeName : [NSColor whiteColor]
  };
  NSDictionary *resAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:resFontSize],
    NSForegroundColorAttributeName : [NSColor lightGrayColor]
  };
  NSDictionary *arrowAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:arrowFontSize],
    NSForegroundColorAttributeName : [NSColor whiteColor]
  };

  NSSize nameSize = [displayName sizeWithAttributes:nameAttrs];
  NSSize resSize = [resolution sizeWithAttributes:resAttrs];
  CGFloat margin = width * 0.04;
  CGFloat arrowSize = arrowFontSize;

  CGFloat nameX = (width - nameSize.width) / 2;
  CGFloat nameY = height - nameSize.height - margin - arrowSize;

  CGFloat resX = (width - resSize.width) / 2;
  CGFloat resY = margin;

  // Draw display name
  [displayName drawAtPoint:NSMakePoint(nameX, nameY) withAttributes:nameAttrs];
  // Draw resolution
  [resolution drawAtPoint:NSMakePoint(resX, resY) withAttributes:resAttrs];
  // Draw arrows
  NSString *topLeftArrow = @"↖";
  NSString *bottomRightArrow = @"↘";
  [topLeftArrow drawAtPoint:NSMakePoint(margin, height - arrowSize - margin)
             withAttributes:arrowAttrs];
  [bottomRightArrow drawAtPoint:NSMakePoint(width - arrowSize - margin, margin)
                 withAttributes:arrowAttrs];

  [image unlockFocus];

  NSButton *button =
      [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
  [button setButtonType:NSButtonTypeToggle];
  button.target = target;
  button.action = action;
  button.image = image;
  button.imagePosition = NSImageOnly;
  button.bezelStyle = NSBezelStyleRegularSquare;
  button.wantsLayer = YES;
  button.layer.cornerRadius = 12;
  button.layer.masksToBounds = YES;
  button.bordered = NO;
  button.layer.backgroundColor = [NSColor clearColor].CGColor;

  button.layer.borderWidth = 1.5;
  button.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.4].CGColor;

  return [button autorelease];
}

void SaveDisplayConfig() { SaveSystem::Save(displays); }

- (void)LoadDisplayConfig {
  ScanDisplays();
  std::list<Display> detected = displays;

  displays.clear();
  displays = SaveSystem::Load();
  for (Display &display : displays) {
    display.screen = DisplayIDFromUUID(display.uuid);
  }
  if (displays.empty()) {

    ScanDisplays();
  }

  if (!displays.empty()) {

    displays.remove_if([&detected](const Display &d) {
      auto it = std::find_if(
          detected.begin(), detected.end(),
          [&d](const Display &det) { return det.screen == d.screen; });
      return it == detected.end();
    });

    if (buttons.count > 0 &&
        [[NSUserDefaults standardUserDefaults] boolForKey:@"random"] == TRUE) {
      for (const Display &det : detected) {
        auto it = std::find_if(
            displays.begin(), displays.end(),
            [&det](const Display &d) { return d.screen == det.screen; });
        if (it == displays.end()) {
          displays.push_back(det);
        }
      }
    }

    for (Display &display : displays) {
      if (std::any_of(detected.begin(), detected.end(),
                      [&display](const Display &d) {
                        return d.screen == display.screen;
                      })) {

        _selectedDisplays.clear();
        _selectedDisplays.push_back(display.screen);

        if (buttons.count > 0 && [[NSUserDefaults standardUserDefaults]
                                     boolForKey:@"random"] == TRUE) {
          NSLog(@"Loading Random Wallpaper...");
          NSUInteger randomIndex = arc4random_uniform((u_int32_t)buttons.count);
          NSButton *randomButton = buttons[randomIndex];
          [randomButton performClick:nil];
        } else {

          [self
              startWallpaperWithPath:[NSString
                                         stringWithUTF8String:display.videoPath
                                                                  .c_str()]];
        }

        _selectedDisplays.clear();
      }
    }
  }
}

@end

int main(int argc, const char *argv[]) {
  setenv("PATH",
         "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin", 1);
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    AppDelegate *delegate = [[AppDelegate alloc] init];
    [app setDelegate:delegate];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedPath = [defaults stringForKey:@"LastWallpaperPath"];
    if (savedPath &&
        [[NSFileManager defaultManager] fileExistsAtPath:savedPath]) {
      LogMemoryUsage();
      [delegate startWallpaperWithPath:savedPath];
      LogMemoryUsage();
    }

    [app run];
  }
}
