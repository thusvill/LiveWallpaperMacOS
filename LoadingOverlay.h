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

#pragma once

#import <Cocoa/Cocoa.h>

@interface LoadingOverlay : NSView

@property(nonatomic, strong) NSVisualEffectView *blurView;
@property(nonatomic, strong) NSTextField *messageLabel;
@property(nonatomic, strong) NSProgressIndicator *spinner;

+ (instancetype)sharedOverlay;


- (void)showWithMessage:(NSString *)message onWindow:(NSWindow *)window;


- (void)updateMessage:(NSString *)message;


- (void)hide;

@end

#define startLoading(msg)                                                      \
  [[LoadingOverlay sharedOverlay] showWithMessage:(msg)                        \
                                         onWindow:[NSApp mainWindow]]
#define endLoading() [[LoadingOverlay sharedOverlay] hide]
#define loadingMessage(msg) [[LoadingOverlay sharedOverlay] updateMessage:(msg)]

static inline void AsyncLoading(void (^work)(void)) {
  startLoading(@"Loading...");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (work)
      work();

    dispatch_async(dispatch_get_main_queue(), ^{
      endLoading();
    });
  });
}


static inline void SyncLoading(NSString *initialMessage, void (^work)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        startLoading(initialMessage);
        
        if (work) {
            work();                  
        }
        
        endLoading();                
    });
}