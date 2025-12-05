#import "LoadingOverlay.h"

@implementation LoadingOverlay

+ (instancetype)sharedOverlay {
    static LoadingOverlay *overlay = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overlay = [[LoadingOverlay alloc] initWithFrame:NSZeroRect];
        [overlay setupViews];
    });
    return overlay;
}

- (void)setupViews {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor.clearColor CGColor];

    // Blur background
    self.blurView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    self.blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.blurView.material = NSVisualEffectMaterialHUDWindow;
    self.blurView.state = NSVisualEffectStateActive;
    [self addSubview:self.blurView];

    // Spinner
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    self.spinner.style = NSProgressIndicatorSpinningStyle;
    self.spinner.controlSize = NSControlSizeRegular;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.spinner];

    // Message label
    self.messageLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.messageLabel.bezeled = NO;
    self.messageLabel.drawsBackground = NO;
    self.messageLabel.editable = NO;
    self.messageLabel.selectable = NO;
    self.messageLabel.alignment = NSTextAlignmentCenter;
    self.messageLabel.font = [NSFont boldSystemFontOfSize:14];
    self.messageLabel.textColor = NSColor.whiteColor;
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.messageLabel];

    // Center spinner and label vertically
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-10],
        [self.messageLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:10],
        [self.messageLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor]
    ]];

    self.alphaValue = 0.0;
    self.hidden = YES;
}

- (void)showWithMessage:(NSString *)message onWindow:(NSWindow *)window {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.frame = window.contentView.bounds;
        [self updateMessage:message];

        if (![self superview]) {
            [window.contentView addSubview:self];
        }

        self.hidden = NO;
        [self.spinner startAnimation:nil];

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            self.animator.alphaValue = 1.0;
        } completionHandler:nil];
    });
}

- (void)updateMessage:(NSString *)message {
    if (!message) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self && self.messageLabel) {
            self.messageLabel.stringValue = message;
            [self setNeedsDisplay:YES];
            [self displayIfNeeded];
        }
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            self.animator.alphaValue = 0.0;
        } completionHandler:^{
            self.hidden = YES;
            [self.spinner stopAnimation:nil];
        }];
    });
}

@end