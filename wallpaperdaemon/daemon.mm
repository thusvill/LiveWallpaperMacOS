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

#import <IOKit/graphics/IOGraphicsLib.h>

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#include <cstdlib>
#include <float.h>

#include "../DisplayManager.h"

@interface VideoWallpaperDaemon : NSObject
@property(strong) NSMutableArray<NSWindow *> *windows;
@property(strong) NSMutableArray<AVQueuePlayer *> *players;
@property(strong) NSMutableArray<AVPlayerLayer *> *playerLayers;
@property(strong) NSMutableArray<AVPlayerLooper *> *loopers;
@property(nonatomic, assign) BOOL autoPauseEnabled;
@property(nonatomic, assign) BOOL wasPlayingBeforeSleep;
@property(nonatomic, assign) BOOL screen_locked;
@property(strong) NSTimer *checkTimer;

@property(nonatomic, assign) NSInteger scalingMode;
@property(nonatomic, strong) NSString *framePath;
@property(nonatomic, strong) NSString *videoPath;
@property(nonatomic, strong) NSString *targetUUID;
@property(nonatomic, weak) NSScreen *targetScreen;
@property(nonatomic, strong) AVAsset *asset;
@property(nonatomic, assign) CGFloat targetPlaybackRate;
@property(nonatomic, assign) BOOL reducedPerformanceMode;
@property(nonatomic, assign) CGDirectDisplayID targetDisplayID;
@property(nonatomic, assign) BOOL runningOnBattery;
@property(nonatomic, assign) BOOL lowPowerModeEnabled;
@property(nonatomic, assign) BOOL visibilityReductionActive;
@property(nonatomic, assign) BOOL playbackPaused;

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSInteger)scalingMode
                 targetScreen:(NSScreen *)targetScreen
                  targetUUID:(NSString *)uuid;
- (void)checkAndUpdatePlaybackState;
- (void)handleDisplayReconfiguration;
NSScreen *ScreenForDisplayID(CGDirectDisplayID displayID);
@end

static void DisplayReconfigCallback(CGDirectDisplayID display,
                                     CGDisplayChangeSummaryFlags flags,
                                     void *ctx) {
  if (flags & kCGDisplayBeginConfigurationFlag) return;
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)ctx;
  dispatch_async(dispatch_get_main_queue(), ^{
    [daemon handleDisplayReconfiguration];
  });
}

@implementation VideoWallpaperDaemon {
    CMTime         _lockVideoTime;   // player position at lock time
    CFAbsoluteTime _lockSystemTime;  // wall-clock at lock time
    CMTime         _videoDuration;   // cached; kCMTimeInvalid if asset not loaded
}

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSInteger)scalingMode
                 targetScreen:(NSScreen *)targetScreen
                  targetUUID:(NSString *)uuid {
  self = [super init];
  if (self) {
    _windows = [NSMutableArray array];
    _players = [NSMutableArray array];
    _playerLayers = [NSMutableArray array];
    _loopers = [NSMutableArray array];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _autoPauseEnabled = [defaults boolForKey:@"pauseOnAppFocus"];
    _wasPlayingBeforeSleep = YES;
    _scalingMode = scalingMode ?: 0;
    _framePath = framePath;
    _videoPath = videoPath;
    _targetScreen = targetScreen;
    _targetPlaybackRate = 1.0f;
    _reducedPerformanceMode = NO;

    NSNumber *screenNumber = targetScreen.deviceDescription[@"NSScreenNumber"];
    _targetDisplayID = screenNumber
                           ? (CGDirectDisplayID)screenNumber.unsignedIntValue
                           : kCGNullDirectDisplay;

    if (uuid && uuid.length > 0) {
      _targetUUID = uuid;
    } else {
      std::string uuidStr = DisplayUUIDFromID(_targetDisplayID);
      _targetUUID = uuidStr.empty() ? nil : [NSString stringWithUTF8String:uuidStr.c_str()];
    }

    _runningOnBattery = [self isRunningOnBatteryPower];
    _lowPowerModeEnabled = [self currentLowPowerModeState];
    _visibilityReductionActive = NO;
    _playbackPaused = NO;

    CGDisplayRegisterReconfigurationCallback(DisplayReconfigCallback, (__bridge void *)self);

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

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeApplicationChanged:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeSpaceChanged:)
               name:NSWorkspaceActiveSpaceDidChangeNotification
             object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(powerStateDidChange:)
               name:NSProcessInfoPowerStateDidChangeNotification
             object:nil];

    self.checkTimer =
        [NSTimer timerWithTimeInterval:2.0
                                target:self
                              selector:@selector(checkAndUpdatePlaybackState)
                              userInfo:nil
                               repeats:YES];
    self.checkTimer.tolerance = 0.5;
    [[NSRunLoop mainRunLoop] addTimer:self.checkTimer
                              forMode:NSRunLoopCommonModes];

    [self setupWallpaperWithVideo:videoPath];

    [self updatePerformanceMode];
    [self checkAndUpdatePlaybackState];
  }
  return self;
}

- (void)handleDisplayReconfiguration {
  if (!_targetUUID) return;

  CGDirectDisplayID newID = DisplayIDFromUUID(std::string([_targetUUID UTF8String]));
  if (newID == kCGNullDirectDisplay) {
    NSLog(@"[Daemon] Display UUID %@ not found after reconfiguration, waiting...", _targetUUID);
    return;
  }

  NSScreen *newScreen = ScreenForDisplayID(newID);
  if (!newScreen) {
    NSLog(@"[Daemon] No NSScreen for display ID %u after reconfiguration", newID);
    return;
  }

  if (newID == _targetDisplayID && newScreen == _targetScreen) return;

  NSLog(@"[Daemon] Display reconfigured: ID %u → %u, re-attaching to UUID %@",
        _targetDisplayID, newID, _targetUUID);

  _targetDisplayID = newID;
  _targetScreen = newScreen;

  for (NSWindow *window in _windows) {
    [window setReleasedWhenClosed:YES];
    [window close];
  }
  [_windows removeAllObjects];
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
  [_loopers removeAllObjects];

  [self setupWallpaperWithVideo:_videoPath];
}

- (void)setupWallpaperWithVideo:(NSString *)videoPath {

  NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

  NSRect visibleFrame = _targetScreen.frame;

  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:visibleFrame
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO
                                     screen:_targetScreen];

  window.level = kCGDesktopWindowLevel - 1;

  [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle];

  [window setOpaque:NO];
  [window setBackgroundColor:[NSColor clearColor]];
  [window setHasShadow:NO];
  [window.contentView setWantsLayer:YES];
  [window setSharingType:NSWindowSharingNone];
  [window setIgnoresMouseEvents:YES];

  _asset = [AVAsset assetWithURL:videoURL];
  AVPlayerItem *item = nil;
  @try {
    item = [AVPlayerItem playerItemWithURL:videoURL];
  } @catch (NSException *e) {
    NSLog(@"[Daemon] AVPlayerItem init failed: %@, falling back", e.reason);
    item = [[AVPlayerItem alloc] initWithURL:videoURL];
  }
  AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
  AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player
                                                     templateItem:item];

  [window.contentView setWantsLayer:YES];
  AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSInteger _scalingMode = [defaults integerForKey:@"scale_mode"];

  switch (_scalingMode) {
  case 1:
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    break;
  case 2:
    layer.videoGravity = AVLayerVideoGravityResize;
    break;
  case 3:
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.anchorPoint = CGPointMake(0.5, 0.5);
    layer.position =
        CGPointMake(CGRectGetMidX(visibleFrame), CGRectGetMidY(visibleFrame));
    break;
  case 0:
  case 4:
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    break;
  default:
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    break;
  }
  if (_scalingMode != 3) {
    layer.frame = window.contentView.bounds;
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
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

  if ([[NSUserDefaults standardUserDefaults] floatForKey:@"vinttage_bar"]) {
    CALayer *overlayLayer = [CALayer layer];
    overlayLayer.frame = window.contentView.bounds;
    overlayLayer.zPosition = 100;

    CAGradientLayer *vignetteBar = [CAGradientLayer layer];
    CGFloat barHeight = 50.0;
    vignetteBar.frame =
        CGRectMake(0, window.contentView.bounds.size.height - barHeight,
                   window.contentView.bounds.size.width, barHeight);
    vignetteBar.colors = @[
      (id)[NSColor colorWithDeviceWhite:0.0 alpha:0.8].CGColor,
      (id)[NSColor colorWithDeviceWhite:0.0 alpha:0.1].CGColor
    ];
    vignetteBar.startPoint = CGPointMake(0.5, 1.0);
    vignetteBar.endPoint = CGPointMake(0.5, 0.15);
    vignetteBar.autoresizingMask = kCALayerWidthSizable | kCALayerMinYMargin;
    [overlayLayer addSublayer:vignetteBar];
    [window.contentView.layer addSublayer:overlayLayer];
  }

  [window.contentView.layer setNeedsDisplay];

  NSLog(@"✅ Screen %@ visibleFrame: %@", _targetScreen,
        NSStringFromRect(visibleFrame));

  [self setStaticWallpaper];
}

- (void)applyScalingMode {
  _scalingMode =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"scale_mode"];

  dispatch_async(dispatch_get_main_queue(), ^{
    NSRect visibleFrame = self->_targetScreen.frame;

    for (AVPlayerLayer *layer in self.playerLayers) {
      switch (_scalingMode) {
      case 1:
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        break;
      case 2:
        layer.videoGravity = AVLayerVideoGravityResize;
        break;
      case 3:
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        layer.anchorPoint = CGPointMake(0.5, 0.5);
        layer.position = CGPointMake(CGRectGetMidX(visibleFrame),
                                     CGRectGetMidY(visibleFrame));
        break;
      case 0:
      case 4:
      default:
        layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        break;
      }

      if (_scalingMode != 3) {
        layer.frame = visibleFrame;
        layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
      }
    }
  });
}

- (void)screenLocked:(NSNotification *)note {
  self.wasPlayingBeforeSleep = (_players.firstObject.rate > 0);
  NSLog(@"[Daemon] Screen locked - saving playback state: %@",
        self.wasPlayingBeforeSleep ? @"playing" : @"paused");
  self.screen_locked = true;

  _lockVideoTime  = _players.firstObject.currentItem.currentTime;
  _lockSystemTime = CFAbsoluteTimeGetCurrent();
  CMTime d = _asset.duration;
  _videoDuration = (CMTIME_IS_VALID(d) && !CMTIME_IS_INDEFINITE(d)) ? d : kCMTimeInvalid;

  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
}

- (void)screenUnlocked:(NSNotification *)note {
  NSLog(@"[Daemon] Screen unlocked");
  self.screen_locked = false;

  if (self.wasPlayingBeforeSleep) {
    // Seek to elapsed position so desktop resumes where the lock screen left off.
    if (CMTIME_IS_VALID(_videoDuration) && !CMTIME_IS_INDEFINITE(_videoDuration)) {
      CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - _lockSystemTime;
      double lockSecs        = CMTimeGetSeconds(_lockVideoTime);
      double durSecs         = CMTimeGetSeconds(_videoDuration);
      if (durSecs > 0.0) {
        double resumeSecs = fmod(lockSecs + elapsed, durSecs);
        CMTime resumeTime = CMTimeMakeWithSeconds(resumeSecs, 600);
        [_players.firstObject seekToTime:resumeTime
                       toleranceBefore:kCMTimeZero
                        toleranceAfter:kCMTimeZero];
      }
    }

    // Set windows to invisible so the fade-in hides the WVE->daemon seam.
    // Do NOT kill WallpaperVideoExtension — idleassetsd owns its lifecycle;
    // killing it breaks the next lock cycle (black lock screen on re-lock).
    for (NSWindow *window in _windows) {
      window.alphaValue = 0.0;
    }

    NSLog(@"[Daemon] Resuming playback after screen unlock");
    [self resumeAllPlayers];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
      ctx.duration = 0.4;
      for (NSWindow *window in self->_windows) {
        window.animator.alphaValue = 1.0;
      }
    }];
  }

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self checkAndUpdatePlaybackState];
      });
}

- (void)dealloc {
  CGDisplayRemoveReconfigurationCallback(DisplayReconfigCallback, (__bridge void *)self);

  for (NSWindow *window in _windows) {
    [window setReleasedWhenClosed:YES];
    [window close];
  }
  [_windows removeAllObjects];
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
  [self.checkTimer invalidate];
  self.checkTimer = nil;
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

static void terminateWallpaperDaemonCallback(CFNotificationCenterRef center,
                                             void *observer, CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  [daemon terminateWallpaperDaemon];
}

- (void)terminateWallpaperDaemon {
  NSLog(@"Received terminate notification");
  CGDisplayRemoveReconfigurationCallback(DisplayReconfigCallback, (__bridge void *)self);
  for (NSWindow *window in _windows) {
    [window setReleasedWhenClosed:YES];
    [window close];
  }
  [_windows removeAllObjects];
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  exit(0);
}

- (void)checkAndUpdatePlaybackState {
  BOOL screenLocked = self.screen_locked || [self isScreenLocked];
  self.screen_locked = screenLocked;

  BOOL wallpaperHidden = NO;

  BOOL shouldPause = screenLocked || wallpaperHidden;

  if (!shouldPause && self.autoPauseEnabled) {
    shouldPause = ![self isFrontmostAppAllowed];
  }

  if (shouldPause) {
    if (!self.playbackPaused) {
      NSLog(@"[Daemon] Pausing because hidden=%@ locked=%@ autoPause=%@",
            wallpaperHidden ? @"YES" : @"NO", screenLocked ? @"YES" : @"NO",
            self.autoPauseEnabled ? @"YES" : @"NO");
    }
    [self pauseAllPlayers];
  } else {
    if (self.playbackPaused) {
      NSLog(@"[Daemon] Resuming because hidden=%@ locked=%@ autoPause=%@",
            wallpaperHidden ? @"YES" : @"NO", screenLocked ? @"YES" : @"NO",
            self.autoPauseEnabled ? @"YES" : @"NO");
    }
    [self resumeAllPlayers];
  }

  [self updatePerformanceModeConsideringVisibility:wallpaperHidden
                                            paused:self.playbackPaused];
}

- (CGRect)targetDisplayBounds {
  if (self.targetScreen)
    return self.targetScreen.frame;
  if (self.targetDisplayID != kCGNullDirectDisplay)
    return CGDisplayBounds(self.targetDisplayID);
  NSScreen *fallback = [NSScreen mainScreen];
  return fallback ? fallback.frame : CGRectZero;
}

- (BOOL)isWallpaperHiddenOnTargetDisplay {
  NSWindow *primaryWindow = _windows.firstObject;
  if (primaryWindow && !primaryWindow.isOnActiveSpace) {
    return YES;
  }

  if (primaryWindow) {
    CGWindowID wallpaperWindowID = (CGWindowID)primaryWindow.windowNumber;
    if (wallpaperWindowID != kCGNullWindowID) {
      CFArrayRef aboveWindows =
          CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenAboveWindow |
                                         kCGWindowListExcludeDesktopElements,
                                     wallpaperWindowID);
      if (aboveWindows) {
        CFIndex aboveCount = CFArrayGetCount(aboveWindows);
        if (aboveCount > 0) {
          CFDictionaryRef topWindow =
              (CFDictionaryRef)CFArrayGetValueAtIndex(aboveWindows, 0);
          NSDictionary *info = (__bridge NSDictionary *)topWindow;
          NSString *owner =
              info[(NSString *)kCGWindowOwnerName] ?: @"<unknown>";
          NSString *name = info[(NSString *)kCGWindowName] ?: @"<unnamed>";
          NSLog(@"[Visibility] Windows above wallpaper detected. Top owner=%@ "
                @"name=%@",
                owner, name);
          CFRelease(aboveWindows);
          return YES;
        }
        CFRelease(aboveWindows);
      }
    }
  }

  CGRect targetFrame = [self targetDisplayBounds];
  if (CGRectIsEmpty(targetFrame))
    return NO;

  CGFloat targetArea = fabs(targetFrame.size.width * targetFrame.size.height);
  if (targetArea < FLT_EPSILON)
    return NO;

  CGWindowListOption options =
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
  CFArrayRef windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID);
  if (!windows)
    return NO;

  BOOL hidden = NO;
  pid_t selfPID = getpid();
  CFIndex count = CFArrayGetCount(windows);

  for (CFIndex i = 0; i < count; ++i) {
    NSDictionary *window =
        (__bridge NSDictionary *)CFArrayGetValueAtIndex(windows, i);

    NSNumber *ownerPID = window[(NSString *)kCGWindowOwnerPID];
    if (ownerPID && ownerPID.intValue == selfPID)
      continue;

    NSNumber *layerNumber = window[(NSString *)kCGWindowLayer];
    if (layerNumber && layerNumber.integerValue > 0)
      continue;

    NSString *windowName = window[(NSString *)kCGWindowName];
    NSString *ownerName = window[(NSString *)kCGWindowOwnerName];
    if ([ownerName isEqualToString:@"Dock"] &&
        [windowName isEqualToString:@"Desktop Picture"]) {
      continue;
    }

    if ([ownerName isEqualToString:@"LiveWallpaper"] ||
        [ownerName isEqualToString:@"wallpaperdaemon"]) {
      continue;
    }

    NSDictionary *boundsDict = window[(NSString *)kCGWindowBounds];
    if (!boundsDict)
      continue;

    CGRect windowBounds = CGRectZero;
    if (!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)boundsDict, &windowBounds))
      continue;

    CGRect intersection = CGRectIntersection(windowBounds, targetFrame);
    if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection))
      continue;

    CGFloat coverage =
        fabs(intersection.size.width * intersection.size.height) / targetArea;
    CGFloat widthCoverage = fabs(intersection.size.width) /
                            MAX(fabs(targetFrame.size.width), FLT_EPSILON);
    CGFloat heightCoverage = fabs(intersection.size.height) /
                             MAX(fabs(targetFrame.size.height), FLT_EPSILON);

    NSNumber *alphaNumber = window[(NSString *)kCGWindowAlpha];
    CGFloat alpha = alphaNumber ? alphaNumber.doubleValue : 1.0;

    BOOL nearlyFullWidth = widthCoverage >= 0.95;
    BOOL nearlyFullHeight = heightCoverage >= 0.90;
    BOOL largeArea = coverage >= 0.80f;

    if (coverage > 0.10f) {
      NSLog(@"[Visibility] owner=%@ name=%@ coverage=%.2f width=%.2f "
            @"height=%.2f alpha=%.2f",
            ownerName ?: @"<unknown>", windowName ?: @"<unnamed>", coverage,
            widthCoverage, heightCoverage, alpha);
    }

    if (alpha > 0.2f &&
        (largeArea || (nearlyFullWidth && heightCoverage >= 0.75) ||
         (coverage >= 0.60f && nearlyFullHeight))) {
      hidden = YES;
      NSLog(@"[Visibility] treating owner=%@ name=%@ as covering the wallpaper",
            ownerName ?: @"<unknown>", windowName ?: @"<unnamed>");
      break;
    }
  }

  CFRelease(windows);
  if (!hidden) {
    NSLog(@"[Visibility] No covering windows detected (hidden=%@)",
          hidden ? @"YES" : @"NO");
  }
  return hidden;
}

- (BOOL)isRunningOnBatteryPower {
  CFTypeRef info = IOPSCopyPowerSourcesInfo();
  if (!info)
    return NO;

  CFArrayRef sources = IOPSCopyPowerSourcesList(info);
  if (!sources) {
    CFRelease(info);
    return NO;
  }

  BOOL onBattery = NO;
  CFIndex count = CFArrayGetCount(sources);
  static NSString *typeKey = nil;
  static NSString *stateKey = nil;
  static NSString *internalBattery = nil;
  static NSString *batteryPower = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    typeKey = [[NSString alloc] initWithUTF8String:kIOPSTypeKey];
    stateKey = [[NSString alloc] initWithUTF8String:kIOPSPowerSourceStateKey];
    internalBattery =
        [[NSString alloc] initWithUTF8String:kIOPSInternalBatteryType];
    batteryPower = [[NSString alloc] initWithUTF8String:kIOPSBatteryPowerValue];
  });

  for (CFIndex idx = 0; idx < count; ++idx) {
    CFTypeRef source = CFArrayGetValueAtIndex(sources, idx);
    CFDictionaryRef description = IOPSGetPowerSourceDescription(info, source);
    if (!description)
      continue;

    NSDictionary *details = (__bridge NSDictionary *)description;
    NSString *type = details[typeKey];
    NSString *state = details[stateKey];

    if (!type || !state)
      continue;

    if ([type isEqualToString:internalBattery] &&
        [state isEqualToString:batteryPower]) {
      onBattery = YES;
      break;
    }
  }

  CFRelease(sources);
  CFRelease(info);
  return onBattery;
}

- (BOOL)currentLowPowerModeState {
  NSProcessInfo *processInfo = [NSProcessInfo processInfo];
  if ([processInfo respondsToSelector:@selector(isLowPowerModeEnabled)]) {
    return processInfo.isLowPowerModeEnabled;
  }
  return NO;
}

- (void)powerStateDidChange:(NSNotification *)notification {
  self.runningOnBattery = [self isRunningOnBatteryPower];
  self.lowPowerModeEnabled = [self currentLowPowerModeState];
  [self checkAndUpdatePlaybackState];
}

- (void)updatePerformanceMode {
  [self updatePerformanceModeConsideringVisibility:NO
                                            paused:self.playbackPaused];
}

- (void)updatePerformanceModeConsideringVisibility:(BOOL)wallpaperHidden
                                            paused:(BOOL)isPaused {
  BOOL battery = [self isRunningOnBatteryPower];
  BOOL lowPower = [self currentLowPowerModeState];
  BOOL visibilityReduction = !isPaused && wallpaperHidden;

  BOOL stateChanged = (battery != self.runningOnBattery) ||
                      (lowPower != self.lowPowerModeEnabled) ||
                      (visibilityReduction != self.visibilityReductionActive);

  self.runningOnBattery = battery;
  self.lowPowerModeEnabled = lowPower;
  self.visibilityReductionActive = visibilityReduction;

  BOOL reduce = battery || lowPower || visibilityReduction;

  if (reduce != self.reducedPerformanceMode || stateChanged) {
    self.reducedPerformanceMode = reduce;
    NSLog(@"[Daemon] %@ performance mode (battery=%@, lowPower=%@, hidden=%@)",
          reduce ? @"Entering" : @"Leaving", battery ? @"YES" : @"NO",
          lowPower ? @"YES" : @"NO", visibilityReduction ? @"YES" : @"NO");
    [self applyPerformanceSettings];
  }
}

- (void)applyPerformanceSettings {
  NSScreen *mainScreen = [NSScreen mainScreen];
  CGFloat screenScale =
      self.targetScreen ? self.targetScreen.backingScaleFactor
                        : (mainScreen ? mainScreen.backingScaleFactor : 1.0);
  if (screenScale <= 0.0)
    screenScale = 1.0;

  CGSize targetResolution = CGSizeZero;
  CGFloat downscaleFactor = self.visibilityReductionActive ? 0.5f : 0.75f;

  if (self.reducedPerformanceMode) {
    CGRect bounds = [self targetDisplayBounds];
    CGFloat width = MAX(bounds.size.width * downscaleFactor, 640.0f);
    CGFloat height = MAX(bounds.size.height * downscaleFactor, 360.0f);
    targetResolution = CGSizeMake(width, height);
  }

  self.targetPlaybackRate = self.visibilityReductionActive ? 0.75f : 1.0f;

  double peakBitRate = self.reducedPerformanceMode ? 6e6 : 0.0;
  CGFloat layerScale = self.reducedPerformanceMode ? 1.0f : screenScale;

  for (AVPlayerLayer *layer in _playerLayers) {
    layer.contentsScale = layerScale;
  }

  for (AVQueuePlayer *player in _players) {
    AVPlayerItem *item = player.currentItem;
    if (item) {
      item.preferredMaximumResolution = targetResolution;
      item.preferredPeakBitRate = peakBitRate;
    }
  }

  for (AVPlayerLooper *looper in _loopers) {
    for (AVPlayerItem *loopItem in looper.loopingPlayerItems) {
      loopItem.preferredMaximumResolution = targetResolution;
      loopItem.preferredPeakBitRate = peakBitRate;
    }
  }

  [self applyCurrentPlaybackRateToActivePlayers];
}

- (void)applyCurrentPlaybackRateToActivePlayers {
  for (AVQueuePlayer *player in _players) {
    if (player.rate > 0.0f) {
      [player playImmediatelyAtRate:self.targetPlaybackRate];
    }
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

- (void)activeApplicationChanged:(NSNotification *)notification {
  if (self.screen_locked)
    return;
  [self checkAndUpdatePlaybackState];
}

- (void)activeSpaceChanged:(NSNotification *)notification {
  if (self.screen_locked)
    return;
  [self checkAndUpdatePlaybackState];
}

- (BOOL)isFrontmostAppAllowed {
  NSRunningApplication *front =
      [[NSWorkspace sharedWorkspace] frontmostApplication];
  if (!front)
    return YES;

  static NSSet<NSString *> *allowedBundleIDs;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    allowedBundleIDs = [NSSet
        setWithArray:@[ @"com.apple.finder", @"com.thusvill.LiveWallpaper" ]];
  });

  return [allowedBundleIDs containsObject:front.bundleIdentifier];
}

- (void)resumeAllPlayers {
  if (_players.count == 0)
    return;
  if (!self.playbackPaused)
    return;

  for (AVQueuePlayer *player in _players) {
    player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    [player playImmediatelyAtRate:self.targetPlaybackRate];
  }

  CFTimeInterval resumeTime = CACurrentMediaTime();
  for (AVPlayerLayer *layer in _playerLayers) {
    CFTimeInterval pausedTime = layer.timeOffset;
    layer.speed = 1.0f;
    layer.timeOffset = 0.0f;
    CFTimeInterval timeSincePause =
        [layer convertTime:resumeTime fromLayer:nil] - pausedTime;
    layer.beginTime = timeSincePause;
  }

  self.playbackPaused = NO;
  NSLog(@"[Daemon] Resumed playback");
}

- (void)pauseAllPlayers {
  if (self.playbackPaused)
    return;
  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
  self.playbackPaused = YES;
  NSLog(@"[Daemon] Paused playback");
}

- (void)setAutoPauseEnabled:(BOOL)enabled {
  _autoPauseEnabled = enabled;
  [[NSUserDefaults standardUserDefaults] setBool:enabled
                                          forKey:@"pauseOnAppFocus"];
  [[NSUserDefaults standardUserDefaults] synchronize];
  NSLog(@"[Daemon] Auto-pause %@", enabled ? @"enabled" : @"disabled");
  [self checkAndUpdatePlaybackState];
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
      NSWorkspaceDesktopImageAllowClippingKey : @(allowClipping),
      NSWorkspaceDesktopImageFillColorKey : [NSColor blackColor]
    };

    NSURL *imageURL = [NSURL fileURLWithPath:_framePath];
    NSError *error = nil;

    {
      std::string uuidString = DisplayUUIDFromID(
          (CGDirectDisplayID)[_targetScreen.deviceDescription
                                  [@"NSScreenNumber"] unsignedIntValue]);

      if (!uuidString.empty()) {
        NSString *uuid = [NSString stringWithUTF8String:uuidString.c_str()];
        if (uuid) {
          NSMutableDictionary *desktopSpec = [NSMutableDictionary dictionary];
          desktopSpec[@"ImageFilePath"] = _framePath;
          desktopSpec[@"ImageFileURL"] = [imageURL absoluteString];
          desktopSpec[@"NewDisplayDictionary"] = @{
            @"desktop-picture-options" : @{
              @"picture-options" : @(scaling),
              @"allow-clipping" : @(allowClipping),
              @"fill-color" : @"0 0 0"
            }
          };

          CFPreferencesSetAppValue((__bridge CFStringRef)uuid,
                                   (__bridge CFPropertyListRef)desktopSpec,
                                   CFSTR("com.apple.desktop"));
          CFPreferencesAppSynchronize(CFSTR("com.apple.desktop"));
        }
      }
    }

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
  if ([daemon setStaticWallpaper]) {
    NSLog(@"Wallpaper applied successfully!");
  }
}

static void scaleModeChangeCallback(CFNotificationCenterRef center,
                                    void *observer, CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  [daemon applyScalingMode];
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
            @"<display_uuid(optional)>",
            argv[0]);
      return 1;
    }

    NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
    NSString *framePath = [NSString stringWithUTF8String:argv[2]];
    NSInteger scaleMode = (NSInteger)strtol(argv[4], NULL, 10);
    NSScreen *targetScreen = [NSScreen mainScreen];
    NSString *targetUUID = nil;

    if (argc >= 6) {
      targetUUID = [NSString stringWithUTF8String:argv[5]];
      CGDirectDisplayID displayID = DisplayIDFromUUID(std::string([targetUUID UTF8String]));
      NSScreen *screen = ScreenForDisplayID(displayID);
      if (screen) {
        targetScreen = screen;
        NSLog(@"Targeting UUID %@ → display ID %u", targetUUID, displayID);
      } else {
        NSLog(@"Warning: No screen found for UUID %@. Using main screen.", targetUUID);
      }
    }

    volume = atof(argv[3]);
    [[NSUserDefaults standardUserDefaults] setFloat:volume
                                             forKey:@"wallpapervolume"];

    VideoWallpaperDaemon *daemon =
        [[VideoWallpaperDaemon alloc] initWithVideo:videoPath
                                        frameOutput:framePath
                                        scalingMode:scaleMode
                                       targetScreen:targetScreen
                                        targetUUID:targetUUID];

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

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)daemon, terminateWallpaperDaemonCallback,
        CFSTR("com.live.wallpaper.terminate"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)daemon, scaleModeChangeCallback,
        CFSTR("com.live.wallpaper.scaleModeChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [[NSRunLoop mainRunLoop] run];
  }

  return 0;
}
