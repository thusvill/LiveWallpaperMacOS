#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>


#include <array>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;

std::string g_videoPath;
std::string frame = "";
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

std::string extract_frame_avfoundation(const std::string& videoPath, const std::string& outputImage, int seconds) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:videoPath.c_str()]];
        AVAsset *asset = [AVAsset assetWithURL:url];
        AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        imageGenerator.appliesPreferredTrackTransform = YES;

        CMTime time = CMTimeMakeWithSeconds(seconds, asset.duration.timescale);
        NSError *error = nil;
        CMTime actualTime;

        CGImageRef imageRef = [imageGenerator copyCGImageAtTime:time actualTime:&actualTime error:&error];
        if (!imageRef) {
            NSLog(@"Error extracting image: %@", error);
            return "";
        }

        NSString *outPath = [NSString stringWithUTF8String:outputImage.c_str()];
        NSURL *outURL = [NSURL fileURLWithPath:outPath];

        CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)outURL, kUTTypePNG, 1, NULL);
        if (!destination) {
            NSLog(@"Could not create image destination");
            CGImageRelease(imageRef);
            return "";
        }

        CGImageDestinationAddImage(destination, imageRef, nil);
        if (!CGImageDestinationFinalize(destination)) {
            NSLog(@"Failed to write image");
            CFRelease(destination);
            CGImageRelease(imageRef);
            return "";
        }

        CFRelease(destination);
        CGImageRelease(imageRef);

        return outputImage;
    }
}



bool set_wallpaper_all_spaces(const std::string &imagePath) {
    // std::string cmd = "automator -i \"" + imagePath + "\"
    // setDesktopPix.workflow";
    std::string cmd =
        "/usr/bin/osascript -e 'tell application \"System Events\" to set "
        "picture of every desktop to POSIX file \"" +
        imagePath + "\"'";
    return std::system(cmd.c_str()) == 0;
}

bool set_wallpaper(const std::string &imagePath) {
    NSString *imgPath = [NSString stringWithUTF8String:imagePath.c_str()];
    NSURL *imgURL = [NSURL fileURLWithPath:imgPath];
    NSError *err = nil;

    NSDictionary *options = @{
        NSWorkspaceDesktopImageAllowClippingKey : @YES,
        NSWorkspaceDesktopImageScalingKey :
            @(NSImageScaleProportionallyUpOrDown)
    };

    for (NSScreen *screen in [NSScreen screens]) {
        BOOL success = [[NSWorkspace sharedWorkspace] setDesktopImageURL:imgURL
                                                               forScreen:screen
                                                                 options:options
                                                                   error:&err];
        if (!success || err) {
            std::cerr << "Failed to set wallpaper for screen: " <<
                [[err localizedDescription] UTF8String] << "\n";
            return false;
        }
    }

    return true;
}

void handleSpaceChange(NSNotification *note) {
    if (!set_wallpaper_all_spaces(frame)) {
        std::cerr << "Failed to set wallpaper on all Spaces.\n";
    } else {
        NSLog(@"🌀 macOS Space (workspace) wallpaper reapplied!");
    }
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) NSWindow *window;
@property(strong) NSWindow *blurWindow;
@property(strong) NSStatusItem *statusItem;
@property(strong) AVPlayer *player;
@end

@implementation AppDelegate

NSStackView *gridContainer = [[NSStackView alloc] init];
NSScreen *mainScreen = NULL;
NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
NSView *content;

- (void)checkAndPromptPermissions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"AccessibilityPermissionChecked"])
        return;
    [defaults setBool:YES forKey:@"AccessibilityPermissionChecked"];
    [defaults synchronize];

    if (!AXIsProcessTrusted()) {
        NSDictionary *options =
            @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
}

- (void)ReloadContent {
    if (buttons.count > 0) {
        [buttons removeAllObjects];
    }
    NSString *videoDir =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Livewall"];
    NSArray<NSString *> *allFiles =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:videoDir
                                                            error:nil];

    NSPredicate *predicate =
        [NSPredicate predicateWithFormat:
                         @"SELF ENDSWITH[c] '.mp4' OR SELF ENDSWITH[c] '.mov'"];
    NSArray<NSString *> *videoFiles =
        [allFiles filteredArrayUsingPredicate:predicate];

    for (NSString *filename in videoFiles) {
        NSString *videoPath =
            [videoDir stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

        AVAsset *asset = [AVAsset assetWithURL:videoURL];
        AVAssetImageGenerator *imageGenerator =
            [[AVAssetImageGenerator alloc] initWithAsset:asset];
        imageGenerator.appliesPreferredTrackTransform = YES;

        CMTime midpoint = CMTimeMakeWithSeconds(2.0, 600);
        CGImageRef thumbImageRef = NULL;
        NSError *error = nil;
        thumbImageRef = [imageGenerator copyCGImageAtTime:midpoint
                                               actualTime:NULL
                                                    error:&error];

        NSImage *thumbImage = nil;
        if (thumbImageRef && !error) {
            thumbImage = [[NSImage alloc] initWithCGImage:thumbImageRef
                                                     size:NSMakeSize(160, 90)];
            CGImageRelease(thumbImageRef);
        }

        NSButton *btn = [[NSButton alloc] init];
        btn.image = thumbImage ?: [NSImage imageNamed:NSImageNameCaution];
        btn.bezelStyle = NSBezelStyleShadowlessSquare;
        btn.imageScaling = NSImageScaleProportionallyUpOrDown;
        btn.title = @"";
        btn.target = self;
        btn.action = @selector(handleButtonClick:);
        btn.toolTip = filename;

        btn.title = filename;
        btn.bezelStyle = NSBezelStyleShadowlessSquare;
        btn.imageScaling = NSImageScaleAxesIndependently;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.tag = [videoFiles indexOfObject:filename];
        [buttons addObject:btn];
    }
}

- (void)reloadGrid:(id)sender {
    [self ReloadContent];

    for (NSView *subview in gridContainer.arrangedSubviews) {
        [gridContainer removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }

    CGFloat spacing = 12.0;
    CGFloat padding = 24.0;

    CGFloat containerWidth =
        NSWidth(self.blurWindow.contentView.frame) - padding;
    if (containerWidth < 0)
        containerWidth = 0;

    CGFloat minThumbWidth = 160.0;
    NSUInteger columns =
        (NSUInteger)(containerWidth / (minThumbWidth + spacing));
    if (columns < 1)
        columns = 1;

    CGFloat thumbWidth = (containerWidth - (columns - 1) * spacing) / columns;
    CGFloat thumbHeight = thumbWidth * 9.0 / 16.0;

    NSUInteger totalButtons = buttons.count;
    NSUInteger rows = (totalButtons + columns - 1) / columns;

    for (NSUInteger row = 0; row < rows; row++) {
        NSStackView *rowStack = [[NSStackView alloc] init];
        rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        rowStack.spacing = spacing;
        rowStack.distribution = NSStackViewDistributionFill;

        for (NSUInteger col = 0; col < columns; col++) {
            NSUInteger idx = row * columns + col;
            if (idx < totalButtons) {
                NSButton *btn = buttons[idx];
                [btn.widthAnchor constraintEqualToConstant:thumbWidth].active =
                    YES;
                [btn.heightAnchor constraintEqualToConstant:thumbHeight]
                    .active = YES;
                [rowStack addArrangedSubview:btn];
            }
        }
        [gridContainer addArrangedSubview:rowStack];
    }
}

- (void)startWallpaperWithPath:(NSString *)videoPath {
    [self checkAndPromptPermissions];
    {
        if (self.player) {
            [self.player pause];
            self.player = nil;
        }

        if (self.window) {
            // Remove all sublayers from contentView
            [self.window.contentView.layer.sublayers
                makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
            [self.window orderOut:nil];
            self.window = nil;
        }

        // Remove previous AVPlayerItemDidPlayToEndTimeNotification observers
        [[NSNotificationCenter defaultCenter]
            removeObserver:self
                      name:AVPlayerItemDidPlayToEndTimeNotification
                    object:nil];
    }
    g_videoPath = [videoPath UTF8String];
    {
        NSString *videoPathNSString =
            [NSString stringWithUTF8String:g_videoPath.c_str()];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:videoPathNSString forKey:@"LastWallpaperPath"];
        [defaults synchronize];
    }

    std::filesystem::path p(g_videoPath);
    std::string videoName = p.stem().string();

    if (!fs::exists(g_videoPath)) {
        std::cerr << "Video file does not exist.\n";
        return;
    }

    NSString *appSupportDir = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *customDir =
        [appSupportDir stringByAppendingPathComponent:@"Livewall"];
    [[NSFileManager defaultManager] createDirectoryAtPath:customDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    std::string tempImage = std::string([[customDir
        stringByAppendingPathComponent:[NSString
                                           stringWithFormat:@"%s.jpg",
                                                            videoName.c_str()]]
        UTF8String]);

    frame = extract_frame_avfoundation(g_videoPath, tempImage, 5);
    if (frame.empty()) {
        std::cerr << "Failed to extract frame from video.\n";
        return;
    }

    mainScreen = [NSScreen mainScreen];
    NSRect screenRect = [mainScreen frame];

    self.window =
        [[NSWindow alloc] initWithContentRect:screenRect
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    [self.window setLevel:kCGDesktopWindowLevel - 1];
    [self.window setOpaque:NO];
    [self.window setBackgroundColor:[NSColor clearColor]];
    [self.window setIgnoresMouseEvents:YES];
    [self.window
        setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorIgnoresCycle];

    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoURL];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = 0.0;

    AVPlayerLayer *playerLayer =
        [AVPlayerLayer playerLayerWithPlayer:self.player];
    playerLayer.frame = self.window.contentView.bounds;
    playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    [self.window.contentView setWantsLayer:YES];
    [self.window.contentView.layer addSublayer:playerLayer];

    [self.window makeKeyAndOrderFront:nil];
    [self.player play];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:nil
                usingBlock:^(NSNotification *note) {
                  [self.player seekToTime:kCMTimeZero];
                  [self.player play];
                }];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          set_wallpaper_all_spaces(frame);
        });
}

- (void)handleButtonClick:(NSButton *)sender {
    NSLog(@"Clicked: %@", sender.title);
    NSString *videoDir =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Livewall"];
    NSString *videoPath =
        [videoDir stringByAppendingPathComponent:sender.title];
    [self startWallpaperWithPath:videoPath];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize {

    CGFloat fixedWidth = 800;
    return NSMakeSize(fixedWidth, proposedFrameSize.height);
}
- (void)openLivewallFolder:(id)sender {
    NSString *livewallPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Livewall"];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Create folder if it doesn't exist
    if (![fm fileExistsAtPath:livewallPath]) {
        NSError *error = nil;
        BOOL created = [fm createDirectoryAtPath:livewallPath
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&error];
        if (!created) {
            NSLog(@"Failed to create Livewall folder: %@", error);
            return;
        }
    }

    // Open folder in Finder
    [[NSWorkspace sharedWorkspace] openFile:livewallPath];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *_Nonnull note) {
                  handleSpaceChange(note);
                }];

    NSRect frame = NSMakeRect(0, 0, 800, 600);
    self.blurWindow =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    [self.blurWindow setTitle:@"LiveWallpaper by Bios"];
    [self.blurWindow center];
    [self.blurWindow makeKeyAndOrderFront:nil];
    [self.blurWindow setShowsResizeIndicator:YES];
    self.blurWindow.delegate = self;

    NSVisualEffectView *blurView = [[NSVisualEffectView alloc]
        initWithFrame:[[self.blurWindow contentView] bounds]];
    [blurView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [blurView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
    [blurView setMaterial:NSVisualEffectMaterialSidebar];
    [blurView setState:NSVisualEffectStateActive];

    [[self.blurWindow contentView] addSubview:blurView
                                   positioned:NSWindowBelow
                                   relativeTo:nil];
    content = [self.blurWindow contentView];

    NSStackView *mainStack = [[NSStackView alloc] init];
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.distribution = NSStackViewDistributionFill;
    mainStack.alignment = NSLayoutAttributeLeading;
    mainStack.spacing = 12;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:mainStack];

    [NSLayoutConstraint activateConstraints:@[
        [mainStack.topAnchor constraintEqualToAnchor:content.topAnchor
                                            constant:12],
        [mainStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                                constant:12],
        [mainStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                 constant:-12],
        [mainStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                               constant:-12],
    ]];


NSStackView *buttonStack = [[NSStackView alloc] init];
buttonStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
buttonStack.spacing = 12;
buttonStack.translatesAutoresizingMaskIntoConstraints = NO;


NSButton *reloadButton = [[NSButton alloc] initWithFrame:NSZeroRect];
[reloadButton setTitle:@"Reload"];
[reloadButton setBezelStyle:NSBezelStyleRounded];
[reloadButton setTarget:self];
[reloadButton setAction:@selector(reloadGrid:)];


NSButton *openFinderButton = [[NSButton alloc] initWithFrame:NSZeroRect];
[openFinderButton setTitle:@"Open in Finder"];
[openFinderButton setBezelStyle:NSBezelStyleRounded];
[openFinderButton setTarget:self];
[openFinderButton setAction:@selector(openLivewallFolder:)];


[buttonStack addArrangedSubview:reloadButton];
[buttonStack addArrangedSubview:openFinderButton];


[mainStack addArrangedSubview:buttonStack];

    gridContainer = [[NSStackView alloc] init];
    gridContainer.orientation = NSUserInterfaceLayoutOrientationVertical;
    gridContainer.spacing = 12;
    gridContainer.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    gridContainer.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *scrollView = [[NSScrollView alloc] init];

    [mainStack addArrangedSubview:reloadButton];
    [mainStack addArrangedSubview:scrollView];

    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.documentView = gridContainer;
    scrollView.drawsBackground = NO;

    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.drawsBackground = NO;
    scrollView.documentView = gridContainer;

    gridContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [gridContainer.topAnchor
            constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [gridContainer.leadingAnchor
            constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
        [gridContainer.trailingAnchor
            constraintLessThanOrEqualToAnchor:scrollView.contentView
                                                  .trailingAnchor],
        [gridContainer.bottomAnchor
            constraintEqualToAnchor:scrollView.contentView.bottomAnchor],
    ]];

    CGFloat maxWidth = 800.0;
    [gridContainer.widthAnchor constraintLessThanOrEqualToConstant:maxWidth]
        .active = YES;

    [gridContainer
        setContentHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [gridContainer
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];

    [self reloadGrid:nil];

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
             keyEquivalent:@"O"];
    [menu addItemWithTitle:@"Quit"
                    action:@selector(quitApp)
             keyEquivalent:@"q"];
    self.statusItem.menu = menu;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"🚪 App terminating...");
    [self.player pause];
    self.player = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (void)showUIWindow {
    reload = true;
    [self.blurWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)quitApp {
    NSLog(@"💥 Quit triggered");
    [NSApp terminate:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self.blurWindow orderOut:nil];
    return NO;
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
            [delegate startWallpaperWithPath:savedPath];
        }
        [app run];
    }
}
