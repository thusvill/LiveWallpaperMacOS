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
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface VideoWallpaperDaemon : NSObject
@property(strong) NSMutableArray<NSWindow *> *windows;
@property(strong) NSMutableArray<AVQueuePlayer *> *players;
@property(strong) NSMutableArray<AVPlayerLayer *> *playerLayers;
@property(strong) NSMutableArray<AVPlayerLooper *> *loopers;
@property(nonatomic, assign) BOOL autoPauseEnabled;
@property(nonatomic, assign) BOOL wasPlayingBeforeSleep;
@property(nonatomic, assign) BOOL screen_locked;
@property(strong) NSTimer *checkTimer;

@property(nonatomic, strong) NSString *scalingMode;

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSString *)scalingMode;
- (void)checkAndUpdatePlaybackState;
@end

@implementation VideoWallpaperDaemon

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSString *)scalingMode {
  self = [super init];
  if (self) {
    _windows = [NSMutableArray array];
    _players = [NSMutableArray array];
    _playerLayers = [NSMutableArray array];
    _loopers = [NSMutableArray array];
    _autoPauseEnabled =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"pauseOnAppFocus"];
    _wasPlayingBeforeSleep = YES;
    _scalingMode = scalingMode ?: @"stretch";

    // Start a timer to periodically check if we should play/pause (for
    // minimized windows detection)
    _checkTimer = [NSTimer
        scheduledTimerWithTimeInterval:1.0
                                target:self
                              selector:@selector(checkAndUpdatePlaybackState)
                              userInfo:nil
                               repeats:YES];

    if (framePath && videoPath) {
      NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
      AVAsset *asset = [AVAsset assetWithURL:videoURL];

      // Check for video tracks with compatibility
      __block NSArray<AVAssetTrack *> *videoTracks = nil;
      if (@available(macOS 15.0, *)) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [asset
            loadTracksWithMediaType:AVMediaTypeVideo
                  completionHandler:^(NSArray<AVAssetTrack *> *_Nullable tracks,
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

      if (videoTracks.count == 0) {
        NSLog(@"No video tracks found in %@", videoPath);
      } else {
        AVAssetImageGenerator *imageGenerator =
            [[AVAssetImageGenerator alloc] initWithAsset:asset];
        imageGenerator.appliesPreferredTrackTransform = YES;

        // Full resolution (4K)
        imageGenerator.maximumSize = CGSizeMake(3840, 2160);

        // Zero tolerance to get exact midpoint
        imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;
        imageGenerator.requestedTimeToleranceAfter = kCMTimeZero;

        // Calculate midpoint
        Float64 midpointSec = CMTimeGetSeconds(asset.duration) / 2.0;
        CMTime midpoint =
            CMTimeMakeWithSeconds(midpointSec, asset.duration.timescale);
        NSLog(@"Scheduled midpoint extraction at %f seconds", midpointSec);

        // Perform extraction after run loop starts
        dispatch_async(dispatch_get_main_queue(), ^{
          __block CGImageRef cgImage = NULL;
          __block CMTime actualTime = kCMTimeZero;
          __block NSError *error = nil;

          if (@available(macOS 15.0, *)) {
            // Use new async API
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [imageGenerator
                generateCGImageAsynchronouslyForTime:midpoint
                                   completionHandler:^(
                                       CGImageRef _Nullable image, CMTime time,
                                       NSError *_Nullable genError) {
                                     if (image && !genError) {
                                       cgImage = CGImageRetain(image);
                                       actualTime = time;
                                     } else {
                                       error = genError;
                                     }
                                     dispatch_semaphore_signal(semaphore);
                                   }];
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
          } else {
// Use deprecated API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cgImage = [imageGenerator copyCGImageAtTime:midpoint
                                             actualTime:&actualTime
                                                  error:&error];
#pragma clang diagnostic pop
          }

          if (cgImage) {
            NSBitmapImageRep *bitmapRep =
                [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
            NSData *data =
                [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
                                        properties:@{}];
            [data writeToFile:framePath atomically:YES];
            CGImageRelease(cgImage);
            NSLog(@"Saved midpoint frame at %f sec to %@",
                  CMTimeGetSeconds(actualTime), framePath);
          } else {
            NSLog(@"Frame extraction failed: %@", error.localizedDescription);
          }
        });
      }
    }
    // Observe screen lock/unlock
    NSDistributedNotificationCenter *center =
        [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(screenLocked:)
                   name:@"com.apple.screenIsLocked"
                 object:nil];
    [center addObserver:self
               selector:@selector(screenUnlocked:)
                   name:@"com.apple.screenIsUnlocked"
                 object:nil];

    // Observe active application changes for auto-pause feature
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeApplicationChanged:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];

    // Setup wallpaper with video
    [self setupWallpaperWithVideo:videoPath];
  }
  return self;
}
- (void)setupWallpaperWithVideo:(NSString *)videoPath {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

  for (NSScreen *screen in screens) {
    // 1. Use VISIBLE frame (excludes menu bar)
    NSRect visibleFrame = screen.visibleFrame;

    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:visibleFrame
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO
                                       screen:screen];

    [window setLevel:kCGDesktopWindowLevel];

    [window
        setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorFullScreenAuxiliary |
                              NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorIgnoresCycle];

    [window setOpaque:NO];
    [window setBackgroundColor:[NSColor clearColor]];
    [window setIgnoresMouseEvents:YES];
    [window setHasShadow:NO];

    // 3. CREATE player FIRST
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
    AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player
                                                       templateItem:item];

    // 4. LAYER BEFORE window display
    [window.contentView setWantsLayer:YES];
    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];

    // Apply scaling
    if ([_scalingMode isEqualToString:@"fit"]) {
      layer.videoGravity = AVLayerVideoGravityResizeAspect;
    } else if ([_scalingMode isEqualToString:@"stretch"]) {
      layer.videoGravity = AVLayerVideoGravityResize;
    } else if ([_scalingMode isEqualToString:@"center"]) {
      layer.videoGravity = AVLayerVideoGravityResizeAspect;
    } else if ([_scalingMode isEqualToString:@"fill"]) {

      layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    } else {

      layer.videoGravity = AVLayerVideoGravityResizeAspectFill;

      layer.anchorPoint = CGPointMake(0.5, 0.5);
      layer.position =
          CGPointMake(CGRectGetMidX(visibleFrame), CGRectGetMidY(visibleFrame));
    }

    // 5. Set frame AFTER gravity
    layer.frame = visibleFrame;
    if ([_scalingMode isEqualToString:@"center"]) {
      layer.position =
          CGPointMake(CGRectGetMidX(visibleFrame), CGRectGetMidY(visibleFrame));
    }

    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    layer.needsDisplayOnBoundsChange = YES;
    layer.actions = @{@"contents" : [NSNull null]};
    [window.contentView.layer addSublayer:layer];

    // 6. NO toggleFullScreen - set frame directly
    [window setFrame:visibleFrame display:YES];

    [window makeKeyAndOrderFront:nil];

    player.volume =
        [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
    player.muted = NO;
    [player play];

    // Store
    [_windows addObject:window];
    [_players addObject:player];
    [_playerLayers addObject:layer];
    [_loopers addObject:looper];

    NSLog(@"✅ Screen %@ visibleFrame: %@", screen,
          NSStringFromRect(visibleFrame));
  }
}

- (void)screenLocked:(NSNotification *)note {
  // Save current playback state
  self.wasPlayingBeforeSleep = (_players.firstObject.rate > 0);
  NSLog(@"[Daemon] Screen locked - saving playback state: %@",
        self.wasPlayingBeforeSleep ? @"playing" : @"paused");

  self.screen_locked = true;

  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
}

- (void)screenUnlocked:(NSNotification *)note {
  NSLog(@"[Daemon] Screen unlocked");

  self.screen_locked = false;
  // Resume if it was playing before sleep
  if (self.wasPlayingBeforeSleep) {
    NSLog(@"[Daemon] Resuming playback after screen unlock");
    for (AVQueuePlayer *player in _players) {
      [player play];
    }
    // Let the timer check if it should pause based on current app state
  }
}
- (void)dealloc {

  for (NSWindow *window in _windows) {
    [window setReleasedWhenClosed:YES];
    [window close];
  }
  [_windows removeAllObjects];
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
}

- (void)checkAndUpdatePlaybackState {
  if (!self.autoPauseEnabled) {
    return;
  }

  BOOL shouldPlay = [self shouldPlayWallpaper];
  BOOL isCurrentlyPlaying = (_players.firstObject.rate > 0);

  if (shouldPlay && !isCurrentlyPlaying) {
    NSLog(@"[Daemon] Timer: Starting playback - desktop is visible");
    for (AVQueuePlayer *player in _players) {
      [player play];
    }
  } else if (!shouldPlay && isCurrentlyPlaying) {
    NSLog(@"[Daemon] Timer: Pausing playback - app window is visible");
    for (AVQueuePlayer *player in _players) {
      [player pause];
    }
  }
}

- (BOOL)shouldPlayWallpaper {
  // If auto-pause is disabled, always play

  NSRunningApplication *activeApp =
      [[NSWorkspace sharedWorkspace] frontmostApplication];

  // Check if Finder or our app is active - always play
  if ([activeApp.bundleIdentifier isEqualToString:@"com.apple.finder"] ||
      [activeApp.bundleIdentifier
          isEqualToString:@"com.biosthusvill.LiveWallpaper"]) {
    return YES;
  }

  // Check if the active app is hidden (Cmd+H)
  if (activeApp.isHidden) {
    return YES;
  }

  if (self.screen_locked) {
    return NO;
  }

  // Get all on-screen windows (this excludes minimized windows)
  CFArrayRef windowList = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  BOOL hasVisibleAppWindow = NO;

  if (windowList) {
    NSArray *windows = (__bridge NSArray *)windowList;
    pid_t activePID = activeApp.processIdentifier;

    for (NSDictionary *window in windows) {
      NSNumber *ownerPID = window[(NSString *)kCGWindowOwnerPID];
      NSNumber *layer = window[(NSString *)kCGWindowLayer];

      // Check if this window belongs to the active app and is a normal window
      // (layer 0)
      if (ownerPID && [ownerPID intValue] == activePID && layer &&
          [layer intValue] == 0) {

        // Check if window has meaningful bounds
        NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
        if (bounds) {
          CGRect rect;
          CGRectMakeWithDictionaryRepresentation(
              (__bridge CFDictionaryRef)bounds, &rect);

          // If window is reasonably sized, it's visible
          if (rect.size.width > 50 && rect.size.height > 50) {
            hasVisibleAppWindow = YES;
            break;
          }
        }
      }
    }
    CFRelease(windowList);
  }

  // Play if no visible windows from the active app
  return !hasVisibleAppWindow;
}

- (void)activeApplicationChanged:(NSNotification *)notification {

  if (self.screen_locked)
    for (AVQueuePlayer *player in _players) {
      [player pause];
    }
  return;
  //[self checkAndUpdatePlaybackState];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (self.screen_locked) {
          for (AVQueuePlayer *player in _players) {
            [player pause];
          }

          return;
        }

        [self checkAndUpdatePlaybackState];
      });
}

- (void)setAutoPauseEnabled:(BOOL)enabled {
  _autoPauseEnabled = enabled;
  [[NSUserDefaults standardUserDefaults] setBool:enabled
                                          forKey:@"pauseOnAppFocus"];
  [[NSUserDefaults standardUserDefaults] synchronize];

  NSLog(@"[Daemon] Auto-pause %@", enabled ? @"enabled" : @"disabled");

  // If disabled, ensure playback resumes
  if (enabled) {
    // If enabled, immediately check current state
    [self checkAndUpdatePlaybackState];
  }
}

- (void)setVolume:(float)volume {
  NSLog(@"[Daemon] setVolume called: %.2f", volume);
  for (AVQueuePlayer *player in _players) {
    player.volume = volume;
  }
  [[NSUserDefaults standardUserDefaults] setFloat:volume
                                           forKey:@"wallpapervolume"];
}

@end

static void VolumeChangedCallback(CFNotificationCenterRef center,
                                  void *observer, CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  float volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  [daemon setVolume:volume];
}

static void AutoPauseChangedCallback(CFNotificationCenterRef center,
                                     void *observer, CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  BOOL enabled =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"pauseOnAppFocus"];
  [daemon setAutoPauseEnabled:enabled];
}

float volume;
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 4) {
      NSLog(@"Usage: %s <video.mp4> <frame_output.png> <volume> <scale_mode>",
            argv[0]);
      return 1;
    }

    NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
    NSString *framePath = [NSString stringWithUTF8String:argv[2]];
    NSString *scaleMode = [NSString stringWithUTF8String:argv[4]];
    volume = atof(argv[3]);
    [[NSUserDefaults standardUserDefaults] setFloat:volume
                                             forKey:@"wallpapervolume"];

    VideoWallpaperDaemon *daemon =
        [[VideoWallpaperDaemon alloc] initWithVideo:videoPath
                                        frameOutput:framePath
                                        scalingMode:scaleMode];

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), VolumeChangedCallback,
        CFSTR("com.live.wallpaper.volumeChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), AutoPauseChangedCallback,
        CFSTR("com.live.wallpaper.autoPauseChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [[NSRunLoop mainRunLoop] run];
  }
  return 0;
}
