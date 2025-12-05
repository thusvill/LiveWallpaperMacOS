#pragma once

#import <Cocoa/Cocoa.h>

@interface LoadingOverlay : NSView

@property(nonatomic, strong) NSVisualEffectView *blurView;
@property(nonatomic, strong) NSTextField *messageLabel;
@property(nonatomic, strong) NSProgressIndicator *spinner;

+ (instancetype)sharedOverlay;

// Show overlay on a window with a message
- (void)showWithMessage:(NSString *)message onWindow:(NSWindow *)window;

// Update message safely from any thread
- (void)updateMessage:(NSString *)message;

// Hide overlay
- (void)hide;

@end

// Convenience macros
#define startLoading(msg)                                                      \
  [[LoadingOverlay sharedOverlay] showWithMessage:(msg)                        \
                                         onWindow:[NSApp mainWindow]]
#define endLoading() [[LoadingOverlay sharedOverlay] hide]
#define loadingMessage(msg) [[LoadingOverlay sharedOverlay] updateMessage:(msg)]

static inline void AsyncLoading(void (^work)(void)) {
  startLoading(@"Loading...");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (work)
      work(); // Execute the heavy task

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