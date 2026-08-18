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

// Efficiency / reliability state
@property(nonatomic, assign) BOOL cachedWallpaperHidden;
@property(nonatomic, assign) CFAbsoluteTime lastVisibilitySample;
@property(nonatomic, assign) NSInteger loadAttempt;
@property(nonatomic, assign) BOOL assetLoadInProgress;
@property(nonatomic, strong) id playerItemObserver;
@property(nonatomic, strong) id playerItemFailObserver;

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSInteger)scalingMode
                 targetScreen:(NSScreen *)targetScreen
                  targetUUID:(NSString *)uuid;
- (void)checkAndUpdatePlaybackState;
- (void)handleDisplayReconfiguration;
- (void)reassertDesktopWindowGeometry;
- (void)ensureStaticFrameExists;
- (CGSize)pixelSizeForTargetScreen;
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

@implementation VideoWallpaperDaemon

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
    _cachedWallpaperHidden = NO;
    _lastVisibilitySample = 0;
    _loadAttempt = 0;
    _assetLoadInProgress = NO;

    CGDisplayRegisterReconfigurationCallback(DisplayReconfigCallback,
                                             (__bridge void *)self);

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

    NSNotificationCenter *wsnc =
        [[NSWorkspace sharedWorkspace] notificationCenter];
    [wsnc addObserver:self
             selector:@selector(activeApplicationChanged:)
                 name:NSWorkspaceDidActivateApplicationNotification
               object:nil];
    [wsnc addObserver:self
             selector:@selector(activeSpaceChanged:)
                 name:NSWorkspaceActiveSpaceDidChangeNotification
               object:nil];
    // Fullscreen enter/exit of *any* app — reassert desktop window so it
    // survives Space creation/destruction used by macOS fullscreen.
    [wsnc addObserver:self
             selector:@selector(fullscreenTransition:)
                 name:NSWorkspaceActiveSpaceDidChangeNotification
               object:nil];
    [wsnc addObserver:self
             selector:@selector(screensDidWake:)
                 name:NSWorkspaceDidWakeNotification
               object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(powerStateDidChange:)
               name:NSProcessInfoPowerStateDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(screenParametersChanged:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil];

    // Adaptive poll: cheaper while paused (see adjustCheckTimerInterval).
    self.checkTimer =
        [NSTimer timerWithTimeInterval:2.0
                                target:self
                              selector:@selector(checkAndUpdatePlaybackState)
                              userInfo:nil
                               repeats:YES];
    self.checkTimer.tolerance = 0.75;
    [[NSRunLoop mainRunLoop] addTimer:self.checkTimer
                              forMode:NSRunLoopCommonModes];

    [self ensureStaticFrameExists];
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
  self.loadAttempt = 0;
  [self ensureStaticFrameExists];
  [self setupWallpaperWithVideo:_videoPath];
}

- (NSInteger)resolvedScaleMode {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSInteger mode = self.scalingMode;
  id rawScale = [defaults objectForKey:@"scale_mode"];
  if ([rawScale isKindOfClass:[NSNumber class]]) {
    mode = [(NSNumber *)rawScale integerValue];
  } else if ([rawScale isKindOfClass:[NSString class]]) {
    NSString *s = [(NSString *)rawScale lowercaseString];
    if ([s isEqualToString:@"fit"] || [s isEqualToString:@"1"])
      mode = 1;
    else if ([s isEqualToString:@"stretch"] || [s isEqualToString:@"2"])
      mode = 2;
    else if ([s isEqualToString:@"center"] || [s isEqualToString:@"3"])
      mode = 3;
    else if ([s isEqualToString:@"heightfill"] || [s isEqualToString:@"4"])
      mode = 4;
    else
      mode = 0;
    [defaults setInteger:mode forKey:@"scale_mode"];
  }
  if (mode < 0 || mode > 4)
    mode = 0;
  self.scalingMode = mode;
  return mode;
}

- (CGSize)pixelSizeForTargetScreen {
  NSScreen *screen = self.targetScreen ?: [NSScreen mainScreen];
  if (!screen)
    return CGSizeMake(1920, 1080);
  CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0;
  // Cap decode at 2560px long edge when on battery; otherwise screen pixels.
  CGFloat w = screen.frame.size.width * scale;
  CGFloat h = screen.frame.size.height * scale;
  if (self.runningOnBattery || self.lowPowerModeEnabled) {
    CGFloat longEdge = MAX(w, h);
    if (longEdge > 2560.0) {
      CGFloat f = 2560.0 / longEdge;
      w *= f;
      h *= f;
    }
  } else {
    // Even on AC, cap at 3840 to avoid decoding 6K/8K aerial masters full-res
    // when the panel is smaller — big win for Apple Aerial library files.
    CGFloat longEdge = MAX(w, h);
    if (longEdge > 3840.0) {
      CGFloat f = 3840.0 / longEdge;
      w *= f;
      h *= f;
    }
  }
  return CGSizeMake(floor(w), floor(h));
}

- (void)applyVideoGravity:(AVPlayerLayer *)layer
                     mode:(NSInteger)mode
                    frame:(NSRect)visibleFrame {
  switch (mode) {
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
  default:
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    break;
  }
  if (mode != 3) {
    layer.frame = visibleFrame;
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  }
}

- (NSWindow *)buildDesktopWindowForFrame:(NSRect)frame {
  // Full display frame (not visibleFrame) so menu-bar strip is covered —
  // critical for "true" full-screen desktop wallpaper.
  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:frame
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO
                                     screen:_targetScreen];

  // Sit at desktop window level (not below icons only). -1 can vanish under
  // modern wallpaper compositing / fullscreen Space transitions.
  window.level = kCGDesktopWindowLevel;

  // Survive Spaces + macOS fullscreen Space creation.
  // Do NOT use Transient — it can hide the window when the accessory app
  // is inactive, which is always for wallpaperdaemon.
  window.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary |
      NSWindowCollectionBehaviorStationary |
      NSWindowCollectionBehaviorIgnoresCycle;

  window.opaque = NO;
  window.backgroundColor = [NSColor blackColor];
  window.hasShadow = NO;
  window.ignoresMouseEvents = YES;
  window.releasedWhenClosed = NO;
  window.animationBehavior = NSWindowAnimationBehaviorNone;
  if ([window respondsToSelector:@selector(setSharingType:)]) {
    window.sharingType = NSWindowSharingNone;
  }
  // Do not accept key / main — never steal focus from fullscreen apps.
  window.canHide = NO;
  [window.contentView setWantsLayer:YES];
  window.contentView.layer.backgroundColor = [NSColor blackColor].CGColor;

  [window setFrame:frame display:NO];
  // orderBack keeps us under normal windows; level keeps us at desktop.
  [window orderFrontRegardless];
  return window;
}

- (void)reassertDesktopWindowGeometry {
  if (!_targetScreen)
    return;
  NSRect frame = _targetScreen.frame;
  for (NSUInteger i = 0; i < _windows.count; i++) {
    NSWindow *window = _windows[i];
    window.level = kCGDesktopWindowLevel;
    window.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorIgnoresCycle;
    [window setFrame:frame display:YES];
    [window orderFrontRegardless];
    if (i < _playerLayers.count) {
      AVPlayerLayer *layer = _playerLayers[i];
      [self applyVideoGravity:layer
                         mode:[self resolvedScaleMode]
                        frame:window.contentView.bounds];
    }
  }
}

- (void)fullscreenTransition:(NSNotification *)note {
  // Debounce geometry repair after Space/fullscreen transitions.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self reassertDesktopWindowGeometry];
        [self checkAndUpdatePlaybackState];
      });
}

- (void)screensDidWake:(NSNotification *)note {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self reassertDesktopWindowGeometry];
        [self resumeAllPlayers];
        [self checkAndUpdatePlaybackState];
      });
}

- (void)screenParametersChanged:(NSNotification *)note {
  [self reassertDesktopWindowGeometry];
}

- (void)ensureStaticFrameExists {
  if (!_framePath.length || !_videoPath.length)
    return;
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:_framePath])
    return;

  NSString *dir = [_framePath stringByDeletingLastPathComponent];
  if (dir.length) {
    [fm createDirectoryAtPath:dir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  // Lightweight mid-frame grab — capped resolution for huge Apple Aerial masters.
  NSURL *url = [NSURL fileURLWithPath:_videoPath];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
    AVURLAssetPreferPreciseDurationAndTimingKey : @NO
  }];
  AVAssetImageGenerator *gen =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  gen.appliesPreferredTrackTransform = YES;
  CGSize px = [self pixelSizeForTargetScreen];
  // Static frame only needs ~1x panel; half is enough under icons.
  gen.maximumSize = CGSizeMake(px.width * 0.5, px.height * 0.5);
  gen.requestedTimeToleranceBefore = CMTimeMake(1, 2);
  gen.requestedTimeToleranceAfter = CMTimeMake(1, 2);

  CMTime t = CMTimeMakeWithSeconds(1.0, 600);
  NSError *err = nil;
  CGImageRef img = [gen copyCGImageAtTime:t actualTime:NULL error:&err];
  if (!img) {
    // Retry at t=0 for short / odd aerial assets
    img = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&err];
  }
  if (!img) {
    NSLog(@"[Daemon] static frame failed for %@: %@", _videoPath,
          err.localizedDescription);
    return;
  }

  CFURLRef cfURL = (__bridge CFURLRef)[NSURL fileURLWithPath:_framePath];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      cfURL, (__bridge CFStringRef) @"public.png", 1, NULL);
  if (dest) {
    CGImageDestinationAddImage(dest, img, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    NSLog(@"[Daemon] wrote static frame %@", _framePath);
  }
  CGImageRelease(img);
}

- (void)teardownPlayersKeepingWindows:(BOOL)keepWindows {
  if (self.playerItemObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:self.playerItemObserver];
    self.playerItemObserver = nil;
  }
  if (self.playerItemFailObserver) {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self.playerItemFailObserver];
    self.playerItemFailObserver = nil;
  }
  for (AVQueuePlayer *p in _players) {
    [p pause];
    [p removeAllItems];
  }
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
  [_loopers removeAllObjects];
  if (!keepWindows) {
    for (NSWindow *w in _windows) {
      [w close];
    }
    [_windows removeAllObjects];
  }
}

- (void)setupWallpaperWithVideo:(NSString *)videoPath {
  if (self.assetLoadInProgress) {
    NSLog(@"[Daemon] setup already in progress, skip");
    return;
  }
  if (!_targetScreen) {
    NSLog(@"[Daemon] no target screen — abort setup");
    return;
  }

  if (!videoPath.length ||
      ![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
    NSLog(@"[Daemon] video missing: %@", videoPath);
    return;
  }

  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfItemAtPath:videoPath
                       error:nil];
  unsigned long long fileSize = [attrs fileSize];
  if (fileSize < 1024) {
    NSLog(@"[Daemon] video too small (%llu bytes), likely incomplete: %@",
          fileSize, videoPath);
    return;
  }
  NSLog(@"[Daemon] loading video (%.1f MB): %@", fileSize / (1024.0 * 1024.0),
        videoPath.lastPathComponent);

  self.assetLoadInProgress = YES;
  self.loadAttempt += 1;
  self.videoPath = videoPath;

  [self teardownPlayersKeepingWindows:NO];

  NSRect screenFrame = _targetScreen.frame;
  NSWindow *window = [self buildDesktopWindowForFrame:screenFrame];
  [_windows addObject:window];

  NSURL *videoURL = [NSURL fileURLWithPath:videoPath isDirectory:NO];
  // Prefer precise timing OFF for large aerials — faster open, fine for loop.
  NSDictionary *opts = @{
    AVURLAssetPreferPreciseDurationAndTimingKey : @NO,
  };
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:videoURL options:opts];
  self.asset = urlAsset;

  __weak typeof(self) weakSelf = self;
  NSArray *keys = @[ @"playable", @"hasProtectedContent", @"tracks" ];
  [urlAsset loadValuesAsynchronouslyForKeys:keys
                          completionHandler:^{
                            dispatch_async(dispatch_get_main_queue(), ^{
                              [weakSelf finishSetupWithAsset:urlAsset
                                                      window:window
                                                 screenFrame:screenFrame];
                            });
                          }];
}

- (void)finishSetupWithAsset:(AVURLAsset *)urlAsset
                      window:(NSWindow *)window
                 screenFrame:(NSRect)screenFrame {
  self.assetLoadInProgress = NO;

  NSError *playErr = nil;
  AVKeyValueStatus playStatus =
      [urlAsset statusOfValueForKey:@"playable" error:&playErr];
  BOOL playable = (playStatus == AVKeyValueStatusLoaded) && urlAsset.playable;

  if (!playable) {
    NSLog(@"[Daemon] asset not playable (%@): %@", playErr.localizedDescription,
          self.videoPath);
    // Retry once after short delay — large aerials sometimes race Spotlight / I/O.
    if (self.loadAttempt < 3) {
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            [self setupWallpaperWithVideo:self.videoPath];
          });
    } else {
      // Fall back to static desktop image only.
      [self setStaticWallpaper];
    }
    return;
  }

  if (urlAsset.hasProtectedContent) {
    NSLog(@"[Daemon] protected content — cannot play as wallpaper: %@",
          self.videoPath);
    [self setStaticWallpaper];
    return;
  }

  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  // Pixel-based decode cap (not points) — fixes mushy/failed 4K–6K aerial decode.
  CGSize maxPixels = [self pixelSizeForTargetScreen];
  item.preferredMaximumResolution = maxPixels;
  item.preferredPeakBitRate = 0; // let decoder choose until perf mode kicks in
  if (@available(macOS 12.0, *)) {
    item.preferredForwardBufferDuration = 2.0;
  }
  item.canUseNetworkResourcesForLiveStreamingWhilePaused = NO;
  item.automaticallyPreservesTimeOffsetFromLive = NO;

  AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
  player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
  if (@available(macOS 10.12, *)) {
    player.automaticallyWaitsToMinimizeStalling = YES;
  }
  // Prevent audio from ducking other apps when volume > 0.
  player.allowsExternalPlayback = NO;

  AVPlayerLooper *looper =
      [AVPlayerLooper playerLooperWithPlayer:player templateItem:item];

  AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
  layer.needsDisplayOnBoundsChange = YES;
  layer.actions = @{@"contents" : [NSNull null], @"bounds" : [NSNull null]};
  NSInteger mode = [self resolvedScaleMode];
  [self applyVideoGravity:layer mode:mode frame:window.contentView.bounds];
  layer.contentsScale = _targetScreen.backingScaleFactor ?: 2.0;
  [window.contentView.layer addSublayer:layer];

  float vol =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  player.volume = vol;
  player.muted = (vol <= 0.001f);

  [_players addObject:player];
  [_playerLayers addObject:layer];
  [_loopers addObject:looper];

  // Failure recovery for flaky aerial masters.
  __weak typeof(self) weakSelf = self;
  self.playerItemFailObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_Nonnull note) {
                NSError *e = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
                NSLog(@"[Daemon] item failed: %@", e.localizedDescription);
                if (weakSelf.loadAttempt < 3) {
                  [weakSelf setupWallpaperWithVideo:weakSelf.videoPath];
                }
              }];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(playerItemStalled:)
             name:AVPlayerItemPlaybackStalledNotification
           object:nil];

  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vinttage_bar"] ||
      [[NSUserDefaults standardUserDefaults] floatForKey:@"vinttage_bar"] > 0) {
    CALayer *overlayLayer = [CALayer layer];
    overlayLayer.frame = window.contentView.bounds;
    overlayLayer.zPosition = 100;
    overlayLayer.autoresizingMask =
        kCALayerWidthSizable | kCALayerHeightSizable;

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

  [self reassertDesktopWindowGeometry];
  [player playImmediatelyAtRate:self.targetPlaybackRate > 0
                                    ? self.targetPlaybackRate
                                    : 1.0f];

  NSLog(@"✅ Wallpaper ready on %@ frame=%@ maxDecode=%.0fx%.0f attempt=%ld",
        _targetScreen, NSStringFromRect(screenFrame), maxPixels.width,
        maxPixels.height, (long)self.loadAttempt);

  [self setStaticWallpaper];
  [self updatePerformanceMode];
}

- (void)playerItemStalled:(NSNotification *)note {
  NSLog(@"[Daemon] playback stalled — kicking player");
  for (AVQueuePlayer *p in _players) {
    if (p.rate == 0 && !self.playbackPaused) {
      [p playImmediatelyAtRate:self.targetPlaybackRate > 0 ? self.targetPlaybackRate
                                                           : 1.0f];
    }
  }
}

- (void)adjustCheckTimerInterval {
  NSTimeInterval interval = self.playbackPaused ? 4.0 : 2.0;
  if (fabs(self.checkTimer.timeInterval - interval) < 0.1)
    return;
  [self.checkTimer invalidate];
  self.checkTimer =
      [NSTimer timerWithTimeInterval:interval
                              target:self
                            selector:@selector(checkAndUpdatePlaybackState)
                            userInfo:nil
                             repeats:YES];
  self.checkTimer.tolerance = interval * 0.4;
  [[NSRunLoop mainRunLoop] addTimer:self.checkTimer
                            forMode:NSRunLoopCommonModes];
}

- (void)applyScalingMode {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id rawScale = [defaults objectForKey:@"scale_mode"];
  if ([rawScale isKindOfClass:[NSNumber class]]) {
    _scalingMode = [(NSNumber *)rawScale integerValue];
  } else if ([rawScale isKindOfClass:[NSString class]]) {
    NSInteger mapped = 0;
    NSString *s = [(NSString *)rawScale lowercaseString];
    if ([s isEqualToString:@"fit"] || [s isEqualToString:@"1"])
      mapped = 1;
    else if ([s isEqualToString:@"stretch"] || [s isEqualToString:@"2"])
      mapped = 2;
    else if ([s isEqualToString:@"center"] || [s isEqualToString:@"3"])
      mapped = 3;
    else if ([s isEqualToString:@"heightfill"] || [s isEqualToString:@"4"])
      mapped = 4;
    _scalingMode = mapped;
    [defaults setInteger:mapped forKey:@"scale_mode"];
  } else if (self.scalingMode >= 0 && self.scalingMode <= 4) {
    _scalingMode = self.scalingMode;
  } else {
    _scalingMode = 0;
  }
  self.scalingMode = _scalingMode;

  dispatch_async(dispatch_get_main_queue(), ^{
    NSRect visibleFrame = self->_targetScreen.frame;

    for (AVPlayerLayer *layer in self.playerLayers) {
      switch (self->_scalingMode) {
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
  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
}

- (void)screenUnlocked:(NSNotification *)note {
  NSLog(@"[Daemon] Screen unlocked");
  self.screen_locked = false;
  if (self.wasPlayingBeforeSleep) {
    NSLog(@"[Daemon] Resuming playback after screen unlock");
    [self resumeAllPlayers];
  }
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self checkAndUpdatePlaybackState];
      });
}

- (void)dealloc {
  CGDisplayRemoveReconfigurationCallback(DisplayReconfigCallback,
                                         (__bridge void *)self);
  [self teardownPlayersKeepingWindows:NO];
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

  // Visibility is expensive (CGWindowList). Cache 1.5s while playing, 4s when paused.
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  CFAbsoluteTime minGap = self.playbackPaused ? 4.0 : 1.5;
  BOOL wallpaperHidden = self.cachedWallpaperHidden;
  if ((now - self.lastVisibilitySample) >= minGap) {
    wallpaperHidden = [self isWallpaperHiddenOnTargetDisplay];
    self.cachedWallpaperHidden = wallpaperHidden;
    self.lastVisibilitySample = now;
  }

  BOOL shouldPause = screenLocked;

  // Auto-pause when another app is frontmost (Finder + self exempt).
  // Fullscreen apps still pause under this policy — geometry is reasserted so
  // wallpaper is ready the instant the fullscreen Space is torn down.
  if (!shouldPause && self.autoPauseEnabled) {
    shouldPause = ![self isFrontmostAppAllowed];
  }

  if (shouldPause) {
    if (!self.playbackPaused) {
      NSLog(@"[Daemon] Pausing hidden=%@ locked=%@ autoPause=%@",
            wallpaperHidden ? @"YES" : @"NO", screenLocked ? @"YES" : @"NO",
            self.autoPauseEnabled ? @"YES" : @"NO");
    }
    [self pauseAllPlayers];
  } else {
    if (self.playbackPaused) {
      NSLog(@"[Daemon] Resuming hidden=%@ locked=%@ autoPause=%@",
            wallpaperHidden ? @"YES" : @"NO", screenLocked ? @"YES" : @"NO",
            self.autoPauseEnabled ? @"YES" : @"NO");
    }
    [self resumeAllPlayers];
  }

  [self updatePerformanceModeConsideringVisibility:wallpaperHidden
                                            paused:self.playbackPaused];
  [self adjustCheckTimerInterval];
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
  // Off active Space → treat as hidden (Mission Control / other Space).
  if (primaryWindow && !primaryWindow.isOnActiveSpace) {
    return YES;
  }

  // Coverage heuristics only — do not treat "any window above desktop level"
  // as hidden (menus, notches, HUD overlays would false-positive constantly).

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

    // Log only decisive coverings (avoid 2s timer spam).
    if (alpha > 0.2f &&
        (largeArea || (nearlyFullWidth && heightCoverage >= 0.75) ||
         (coverage >= 0.60f && nearlyFullHeight))) {
      hidden = YES;
      static NSString *lastCoverOwner = nil;
      NSString *owner = ownerName ?: @"<unknown>";
      if (![owner isEqualToString:lastCoverOwner]) {
        NSLog(@"[Visibility] covered by owner=%@ name=%@ coverage=%.2f", owner,
              windowName ?: @"<unnamed>", coverage);
        lastCoverOwner = [owner copy];
      }
      break;
    }
  }

  CFRelease(windows);
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

  // Always start from pixel budget for this panel (not points).
  CGSize targetResolution = [self pixelSizeForTargetScreen];
  if (self.reducedPerformanceMode) {
    CGFloat downscale = self.visibilityReductionActive ? 0.45f : 0.65f;
    targetResolution = CGSizeMake(MAX(floor(targetResolution.width * downscale), 640.0),
                                  MAX(floor(targetResolution.height * downscale), 360.0));
  }

  // When fully covered, slow slightly to save decode; keep 1.0 when visible.
  self.targetPlaybackRate = self.visibilityReductionActive ? 0.85f : 1.0f;

  // Bitrate soft-cap only in reduced mode (helps multi-GB HEVC aerials).
  double peakBitRate = 0.0;
  if (self.reducedPerformanceMode) {
    peakBitRate = self.visibilityReductionActive ? 3.5e6 : 8.0e6;
  } else if (self.runningOnBattery) {
    peakBitRate = 12.0e6;
  }

  CGFloat layerScale = screenScale;

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
  // Fullscreen apps create/destroy Spaces — re-pin desktop window immediately.
  [self reassertDesktopWindowGeometry];
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
  dispatch_async(dispatch_get_main_queue(), ^{
    [daemon reassertDesktopWindowGeometry];
    if ([daemon setStaticWallpaper]) {
      NSLog(@"[Daemon] static wallpaper reapplied after space change");
    }
  });
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

    // argv: 0=bin 1=video 2=frame 3=volume 4=scale [5=uuid]
    if (argc < 5) {
      NSLog(@"Usage: %s <video.mp4> <frame_output.png> <volume> <scale_mode> "
            @"[display_uuid]",
            argv[0]);
      return 1;
    }

    NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
    NSString *framePath = [NSString stringWithUTF8String:argv[2]];
    // Expand ~ if callers pass it
    videoPath = [videoPath stringByExpandingTildeInPath];
    framePath = [framePath stringByExpandingTildeInPath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
      NSLog(@"[Daemon] FATAL: video does not exist: %@", videoPath);
      return 2;
    }

    NSInteger scaleMode = (NSInteger)strtol(argv[4], NULL, 10);
    if (scaleMode < 0 || scaleMode > 4)
      scaleMode = 0;
    NSScreen *targetScreen = [NSScreen mainScreen];
    NSString *targetUUID = nil;

    if (argc >= 6 && argv[5] && strlen(argv[5]) > 0) {
      targetUUID = [NSString stringWithUTF8String:argv[5]];
      CGDirectDisplayID displayID =
          DisplayIDFromUUID(std::string([targetUUID UTF8String]));
      NSScreen *screen = ScreenForDisplayID(displayID);
      if (screen) {
        targetScreen = screen;
        NSLog(@"Targeting UUID %@ → display ID %u", targetUUID, displayID);
      } else {
        NSLog(@"Warning: No screen found for UUID %@. Using main screen.",
              targetUUID);
      }
    } else {
      // Derive UUID from main screen for reconfig stability
      NSNumber *num = targetScreen.deviceDescription[@"NSScreenNumber"];
      if (num) {
        std::string u =
            DisplayUUIDFromID((CGDirectDisplayID)num.unsignedIntValue);
        if (!u.empty())
          targetUUID = [NSString stringWithUTF8String:u.c_str()];
      }
    }

    volume = atof(argv[3]);
    [[NSUserDefaults standardUserDefaults] setFloat:volume
                                             forKey:@"wallpapervolume"];
    [[NSUserDefaults standardUserDefaults] setInteger:scaleMode
                                               forKey:@"scale_mode"];

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
