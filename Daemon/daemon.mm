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
#include <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <cstdlib>

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
@property(nonatomic, strong) NSString *framePath;
@property(nonatomic, assign) NSScreen *targetScreen;
@property(nonatomic, assign) AVAsset *asset;

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSString *)scalingMode
                 targetScreen:(NSScreen *)targetScreen;
- (void)checkAndUpdatePlaybackState;
@end

@implementation VideoWallpaperDaemon

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSString *)scalingMode
                 targetScreen:(NSScreen *)targetScreen {
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
    _framePath = framePath;
    _targetScreen = targetScreen;

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

  NSRect visibleFrame = _targetScreen.frame;

  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:visibleFrame
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO
                                     screen:_targetScreen];

  window.level = kCGDesktopWindowLevel - 1;
  // window.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey - 1);

  [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle];

  [window setOpaque:NO];
  [window setBackgroundColor:[NSColor clearColor]];

  [window setHasShadow:NO];
  [window.contentView setWantsLayer:YES];

  //[window orderFrontRegardless];
  [window setSharingType:NSWindowSharingNone];

  [window setIgnoresMouseEvents:YES];

  _asset = [AVAsset assetWithURL:videoURL];
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:_asset];
  AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
  AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player
                                                     templateItem:item];

  [window.contentView setWantsLayer:YES];
  AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];

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

  layer.frame = window.contentView.bounds;

  if ([_scalingMode isEqualToString:@"center"]) {
    layer.position =
        CGPointMake(CGRectGetMidX(visibleFrame), CGRectGetMidY(visibleFrame));
  }

  layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  layer.needsDisplayOnBoundsChange = NO;
  layer.actions = @{@"contents" : [NSNull null]};
  [window.contentView.layer addSublayer:layer];

  [window setFrame:visibleFrame display:YES];

  [window makeKeyAndOrderFront:nil];

  player.volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  player.muted = NO;
  [player play];

  player.currentItem.preferredMaximumResolution = CGSizeMake(
      _targetScreen.frame.size.width, _targetScreen.frame.size.height);

  [_windows addObject:window];
  [_players addObject:player];
  [_playerLayers addObject:layer];
  [_loopers addObject:looper];

  NSLog(@"✅ Screen %@ visibleFrame: %@", _targetScreen,
        NSStringFromRect(visibleFrame));
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
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

// - (BOOL)shouldPlayWallpaper {
//   // If auto-pause is disabled, always play

//   NSRunningApplication *activeApp =
//       [[NSWorkspace sharedWorkspace] frontmostApplication];

//   // Check if Finder or our app is active - always play
//   if ([activeApp.bundleIdentifier isEqualToString:@"com.apple.finder"] ||
//       [activeApp.bundleIdentifier
//           isEqualToString:@"com.biosthusvill.LiveWallpaper"]) {
//     return YES;
//   }

//   // Check if the active app is hidden (Cmd+H)
//   if (activeApp.isHidden) {
//     return YES;
//   }

//   if (self.screen_locked) {
//     return NO;
//   }

//   // Get all on-screen windows (this excludes minimized windows)
//   CFArrayRef windowList = CGWindowListCopyWindowInfo(
//       kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
//       kCGNullWindowID);
//   BOOL hasVisibleAppWindow = NO;

//   if (windowList) {
//     NSArray *windows = (__bridge NSArray *)windowList;
//     pid_t activePID = activeApp.processIdentifier;

//     for (NSDictionary *window in windows) {
//       NSNumber *ownerPID = window[(NSString *)kCGWindowOwnerPID];
//       NSNumber *layer = window[(NSString *)kCGWindowLayer];

//       // Check if this window belongs to the active app and is a normal
//       window
//       // (layer 0)
//       if (ownerPID && [ownerPID intValue] == activePID && layer &&
//           [layer intValue] == 0) {

//         // Check if window has meaningful bounds
//         NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
//         if (bounds) {
//           CGRect rect;
//           CGRectMakeWithDictionaryRepresentation(
//               (__bridge CFDictionaryRef)bounds, &rect);

//           // If window is reasonably sized, it's visible
//           if (rect.size.width > 50 && rect.size.height > 50) {
//             hasVisibleAppWindow = YES;
//             break;
//           }
//         }
//       }
//     }
//     CFRelease(windowList);
//   }

//   // Play if no visible windows from the active app
//   return !hasVisibleAppWindow;
// }

- (void)checkAndUpdatePlaybackState {
  if (!self.autoPauseEnabled) {
    [self resumeAllPlayers];
    return;
  }

  if ([self isScreenLocked] || ![self isFrontmostAppAllowed]) {
    [self pauseAllPlayers];
  } else {
    [self resumeAllPlayers];
  }
}
- (BOOL)isScreenLocked {
  CFBooleanRef locked = (CFBooleanRef)CFPreferencesCopyAppValue(
      CFSTR("ScreenLocked"), CFSTR("com.apple.loginwindow"));

  BOOL isLocked = NO;

  if (locked && CFGetTypeID(locked) == CFBooleanGetTypeID()) {
    isLocked = (locked == kCFBooleanTrue);
  }

  if (locked)
    CFRelease(locked);

  return isLocked;
}

- (BOOL)isFrontmostAppAllowed {
  NSRunningApplication *front =
      [[NSWorkspace sharedWorkspace] frontmostApplication];

  if (!front)
    return YES;

  // Don’t pause when user is interacting with your preferences window
  if ([front.bundleIdentifier isEqualToString:@"your.app.bundle.id"])
    return YES;

  return NO;
}

- (void)activeApplicationChanged:(NSNotification *)notification {
  if (!self.autoPauseEnabled)
    return;

  if (self.screen_locked)
    return;

  NSRunningApplication *activeApp =
      notification.userInfo[NSWorkspaceApplicationKey];

  if (!activeApp)
    return;

  NSString *bundleID = activeApp.bundleIdentifier;

  BOOL allowedApp =
      [bundleID isEqualToString:@"com.apple.finder"] ||
      [bundleID isEqualToString:@"com.biosthusvill.LiveWallpaper"];

  if (allowedApp) {
    [self resumeAllPlayers];
    NSLog(@"[AutoPause] App %@ allowed → resume", bundleID);
  } else {
    [self pauseAllPlayers];
    NSLog(@"[AutoPause] App %@ not allowed → pause", bundleID);
  }
}

- (void)resumeAllPlayers {
  BOOL isPlaying = (_players.firstObject.rate > 0);
  if (!isPlaying) {
    for (AVQueuePlayer *player in _players)
      [player play];
    NSLog(@"[Daemon] Resumed playback");
  }
}

- (void)pauseAllPlayers {
  BOOL isPlaying = (_players.firstObject.rate > 0);
  if (isPlaying) {
    for (AVQueuePlayer *player in _players)
      [player pause];
    NSLog(@"[Daemon] Paused playback");
  }
}

- (void)setAutoPauseEnabled:(BOOL)enabled {
  _autoPauseEnabled = enabled;
  [[NSUserDefaults standardUserDefaults] setBool:enabled
                                          forKey:@"pauseOnAppFocus"];
  [[NSUserDefaults standardUserDefaults] synchronize];

  NSLog(@"[Daemon] Auto-pause %@", enabled ? @"enabled" : @"disabled");

  // // If disabled, ensure playback resumes
  // if (enabled) {
  //   // If enabled, immediately check current state
  //   [self checkAndUpdatePlaybackState];
  // }
}

- (void)setVolume:(float)volume {
  NSLog(@"[Daemon] setVolume called: %.2f", volume);
  for (AVQueuePlayer *player in _players) {
    player.volume = volume;
  }
  [[NSUserDefaults standardUserDefaults] setFloat:volume
                                           forKey:@"wallpapervolume"];
}
- (bool)setStaticWallpaper {
  @autoreleasepool {
    if (!_framePath)
      return false;
    if (![[NSFileManager defaultManager] fileExistsAtPath:_framePath])
      return false;
    if (!_targetScreen)
      return false;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger scaleMode = [defaults integerForKey:@"scale_mode"];

    NSImageScaling scaling = NSImageScaleProportionallyUpOrDown;
    BOOL allowClipping = NO;

    switch (scaleMode) {
    case 0:
      scaling = NSImageScaleProportionallyUpOrDown;
      allowClipping = YES;
      break;
    case 1:
      scaling = NSImageScaleProportionallyUpOrDown;
      allowClipping = NO;
      break;
    case 2:
      scaling = NSImageScaleAxesIndependently;
      allowClipping = NO;
      break;
    case 3:
      scaling = NSImageScaleNone;
      allowClipping = NO;
      break;
    case 4:
      scaling = NSImageScaleProportionallyUpOrDown;
      allowClipping = YES;
      break;
    default:
      break;
    }

    NSDictionary *options = @{
      NSWorkspaceDesktopImageScalingKey : @(scaling),
      NSWorkspaceDesktopImageAllowClippingKey : @(allowClipping)
    };

    NSURL *imageURL = [NSURL fileURLWithPath:_framePath];
    NSError *error = nil;

    BOOL success =
        [[NSWorkspace sharedWorkspace] setDesktopImageURL:imageURL
                                                forScreen:_targetScreen
                                                  options:options
                                                    error:&error];
    return success;
  }
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

static void SpaceChangeCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  [daemon setStaticWallpaper];
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

NSScreen *ScreenForDisplayID(CGDirectDisplayID displayID) {
  for (NSScreen *screen in [NSScreen screens]) {
    NSDictionary *screenDict = [screen deviceDescription];
    NSNumber *screenNumber = [screenDict objectForKey:@"NSScreenNumber"];
    if (screenNumber && [screenNumber unsignedIntValue] == displayID) {
      return screen;
    }
  }
  return nil;
}

float volume;
int main(int argc, const char *argv[]) {

  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [NSApp finishLaunching];

    if (argc < 4) {
      NSLog(@"Usage: %s <video.mp4> <frame_output.png> <volume> <scale_mode> "
            @"<display_id(optional)>",
            argv[0]);
      return 1;
    }

    NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
    NSString *framePath = [NSString stringWithUTF8String:argv[2]];
    NSString *scaleMode = [NSString stringWithUTF8String:argv[4]];
    NSScreen *targetScreen = [NSScreen mainScreen];
    if (argc >= 6) {
      NSString *displayIDStr = [NSString stringWithUTF8String:argv[5]];
      CGDirectDisplayID displayID = (CGDirectDisplayID)[displayIDStr intValue];
      targetScreen = ScreenForDisplayID(displayID);
      if (targetScreen) {
        NSLog(@"Targeting display ID %u on screen %@", displayID, targetScreen);
      } else {
        NSLog(@"Warning: No screen found for display ID %u. Using all screens.",
              displayID);
      }
    }
    volume = atof(argv[3]);
    [[NSUserDefaults standardUserDefaults] setFloat:volume
                                             forKey:@"wallpapervolume"];

    VideoWallpaperDaemon *daemon =
        [[VideoWallpaperDaemon alloc] initWithVideo:videoPath
                                        frameOutput:framePath
                                        scalingMode:scaleMode
                                       targetScreen:targetScreen];

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

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), SpaceChangeCallback,
        CFSTR("com.live.wallpaper.spaceChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [[NSRunLoop mainRunLoop] run];
  }

  return 0;
}
