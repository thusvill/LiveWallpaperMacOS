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
#import <QuartzCore/QuartzCore.h>

@interface VideoWallpaperDaemon : NSObject
@property(strong) NSMutableArray<NSWindow *> *windows;
@property(strong) NSMutableArray<AVQueuePlayer *> *players;
@property(strong) NSMutableArray<AVPlayerLayer *> *playerLayers;
@property(strong) NSMutableArray<AVPlayerLooper *> *loopers;
- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath;
@end

@implementation VideoWallpaperDaemon

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath {
    self = [super init];
    if (self) {
        _windows = [NSMutableArray array];
        _players = [NSMutableArray array];
        _playerLayers = [NSMutableArray array];
        _loopers = [NSMutableArray array];

        if (framePath && videoPath) {
            NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
            AVAsset *asset = [AVAsset assetWithURL:videoURL];

            if ([[asset tracksWithMediaType:AVMediaTypeVideo] count] == 0) {
                NSLog(@"No video tracks found in %@", videoPath);
            } else {
                AVAssetImageGenerator *imageGenerator =
                    [[AVAssetImageGenerator alloc] initWithAsset:asset];
                imageGenerator.appliesPreferredTrackTransform = YES;

                // Full resolution (4K)
                imageGenerator.maximumSize = CGSizeMake(3840, 2160);

                // Zero tolerance to get exact midpoint
                imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;
                imageGenerator.requestedTimeToleranceAfter  = kCMTimeZero;

                // Calculate midpoint
                Float64 midpointSec = CMTimeGetSeconds(asset.duration) / 2.0;
                CMTime midpoint = CMTimeMakeWithSeconds(midpointSec, asset.duration.timescale);
                NSLog(@"Scheduled midpoint extraction at %f seconds", midpointSec);

                // Perform extraction after run loop starts
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *error = nil;
                    CMTime actualTime;
                    CGImageRef cgImage = [imageGenerator copyCGImageAtTime:midpoint
                                                                 actualTime:&actualTime
                                                                      error:&error];
                    if (cgImage) {
                        NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
                        NSData *data = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        [data writeToFile:framePath atomically:YES];
                        CGImageRelease(cgImage);
                        NSLog(@"Saved midpoint frame at %f sec to %@", CMTimeGetSeconds(actualTime), framePath);
                    } else {
                        NSLog(@"Frame extraction failed: %@", error.localizedDescription);
                    }
                });
            }
        }
        // Observe screen lock/unlock
        NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(screenLocked:)
                       name:@"com.apple.screenIsLocked"
                     object:nil];
        [center addObserver:self
                   selector:@selector(screenUnlocked:)
                       name:@"com.apple.screenIsUnlocked"
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
    NSRect frame = screen.frame;

    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO
                                       screen:screen];

    [window setLevel:kCGDesktopIconWindowLevel - 1];

    [window setOpaque:NO];
    [window setBackgroundColor:[NSColor clearColor]];
    [window setIgnoresMouseEvents:YES];
    [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorIgnoresCycle];
    [window setHasShadow:NO];
    [window toggleFullScreen:nil];

    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
    AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player
                                                       templateItem:item];

    [window.contentView setWantsLayer:YES];
    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.frame = window.contentView.bounds;
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    layer.needsDisplayOnBoundsChange = YES;
    layer.actions = @{@"contents" : [NSNull null]};
    [window.contentView.layer addSublayer:layer];

    NSPoint origin = frame.origin;

    [window setFrameOrigin:origin];

    NSLog(@"Screen frame: %@", NSStringFromRect(screen.frame));
    NSLog(@"ContentView bounds: %@",
          NSStringFromRect(window.contentView.bounds));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction commit];

    [window makeKeyAndOrderFront:nil];
    player.volume = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
    
    player.muted =NO;

    [_windows addObject:window];
    [_players addObject:player];
    [_playerLayers addObject:layer];
    [_loopers addObject:looper];

    [player play];
  }
}

- (void)screenLocked:(NSNotification *)note {
  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
}

- (void)screenUnlocked:(NSNotification *)note {
  for (AVQueuePlayer *player in _players) {
    [player play];
  }
}

- (void)setVolume:(float)volume {
    NSLog(@"[Daemon] setVolume called: %.2f", volume);
    for (AVQueuePlayer *player in _players) {
        player.volume = volume;
    }
    [[NSUserDefaults standardUserDefaults] setFloat:volume forKey:@"wallpapervolume"];

}

@end

static void VolumeChangedCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
    float volume = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
    [daemon setVolume:volume];
}


float volume;
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 4) {
      NSLog(@"Usage: %s <video.mp4> <frame_output.png> <volume>", argv[0]);
      return 1;
    }

    NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
    NSString *framePath = [NSString stringWithUTF8String:argv[2]];
    volume = atof(argv[3]);
    [[NSUserDefaults standardUserDefaults] setFloat:volume forKey:@"wallpapervolume"];

    VideoWallpaperDaemon *daemon =
        [[VideoWallpaperDaemon alloc] initWithVideo:videoPath
                                        frameOutput:framePath];

CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(daemon),
            VolumeChangedCallback,
            CFSTR("com.live.wallpaper.volumeChanged"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );



    [[NSRunLoop mainRunLoop] run];
  }
  return 0;
}
