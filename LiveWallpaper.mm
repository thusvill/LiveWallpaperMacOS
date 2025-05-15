#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <iostream>
#include <filesystem>
#include <cstdlib>
#include <string>

namespace fs = std::filesystem;

std::string g_videoPath;
std::string frame = "";
bool reload = true;
std::string extract_middle_frame(const std::string& videoPath, const std::string& outputImage) {
    std::string ffmpegCmd = "ffmpeg -y -i \"" + videoPath + "\" -ss 00:00:05 -frames:v 1 \"" + outputImage + "\"";
    int ret = std::system(ffmpegCmd.c_str());
    return (ret == 0 && fs::exists(outputImage)) ? outputImage : "";
}

bool set_wallpaper_all_spaces(const std::string& imagePath) {
    std::string cmd = "automator -i \"" + imagePath + "\" setDesktopPix.workflow";
    return std::system(cmd.c_str()) == 0;
}

bool set_wallpaper(const std::string& imagePath) {
    NSString *imgPath = [NSString stringWithUTF8String:imagePath.c_str()];
    NSURL *imgURL = [NSURL fileURLWithPath:imgPath];
    NSError *err = nil;

    NSDictionary *options = @{
        NSWorkspaceDesktopImageAllowClippingKey: @YES,
        NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown)
    };

    for (NSScreen *screen in [NSScreen screens]) {
        BOOL success = [[NSWorkspace sharedWorkspace] setDesktopImageURL:imgURL
                                                                forScreen:screen
                                                                  options:options
                                                                    error:&err];
        if (!success || err) {
            std::cerr << "Failed to set wallpaper for screen: "
                      << [[err localizedDescription] UTF8String] << "\n";
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
@property (strong) NSWindow *window;
@property (strong) NSWindow *blurWindow;
@property (strong) NSStatusItem *statusItem;
@property (strong) AVPlayer *player;
@end

@implementation AppDelegate

NSScreen *mainScreen = NULL;
- (void)startWallpaperWithPath:(NSString *)videoPath {
    g_videoPath = [videoPath UTF8String];

    std::filesystem::path p(g_videoPath);
    std::string videoName = p.stem().string();

    if (!fs::exists(g_videoPath)) {
        std::cerr << "Video file does not exist.\n";
        return;
    }

    std::string tempImage = "/tmp/" + videoName + ".jpg";
    frame = extract_middle_frame(g_videoPath, tempImage);
    if (frame.empty()) {
        std::cerr << "Failed to extract frame from video.\n";
        return;
    }

    mainScreen = [NSScreen mainScreen];
    NSRect screenRect = [mainScreen frame];

    self.window = [[NSWindow alloc] initWithContentRect:screenRect
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    [self.window setLevel:kCGDesktopWindowLevel - 1];
    [self.window setOpaque:NO];
    [self.window setBackgroundColor:[NSColor clearColor]];
    [self.window setIgnoresMouseEvents:YES];
    [self.window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                       NSWindowCollectionBehaviorStationary |
                                       NSWindowCollectionBehaviorIgnoresCycle];

    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoURL];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = 0.0;

    AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    playerLayer.frame = self.window.contentView.bounds;
    playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    [self.window.contentView setWantsLayer:YES];
    [self.window.contentView.layer addSublayer:playerLayer];

    [self.window makeKeyAndOrderFront:nil];
    [self.player play];

    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:item
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        [self.player seekToTime:kCMTimeZero];
        [self.player play];
    }];
}

- (void)handleButtonClick:(NSButton *)sender {
    NSLog(@"Clicked: %@", sender.title);
    NSString *videoDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Livewall"];
    NSString *videoPath = [videoDir stringByAppendingPathComponent:sender.title];
    [self startWallpaperWithPath:videoPath];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        handleSpaceChange(note);
    }];

    NSRect frame = NSMakeRect(0, 0, 800, 600);
    self.blurWindow = [[NSWindow alloc] initWithContentRect:frame
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


    NSVisualEffectView *blurView = [[NSVisualEffectView alloc] initWithFrame:[[self.blurWindow contentView] bounds]];
    [blurView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [blurView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
    [blurView setMaterial:NSVisualEffectMaterialSidebar];
    [blurView setState:NSVisualEffectStateActive];

    [[self.blurWindow contentView] addSubview:blurView positioned:NSWindowBelow relativeTo:nil];
    NSView *content = [self.blurWindow contentView];

    NSString *videoDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Livewall"];
    NSArray<NSString *> *allFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:videoDir error:nil];

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF ENDSWITH[c] '.mp4' OR SELF ENDSWITH[c] '.mov'"];
    NSArray<NSString *> *videoFiles = [allFiles filteredArrayUsingPredicate:predicate];

    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];


if(reload){
for (NSString *filename in videoFiles) {
    NSString *videoPath = [videoDir stringByAppendingPathComponent:filename];
    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    imageGenerator.appliesPreferredTrackTransform = YES;

    CMTime midpoint = CMTimeMakeWithSeconds(2.0, 600); 
    CGImageRef thumbImageRef = NULL;
    NSError *error = nil;
    thumbImageRef = [imageGenerator copyCGImageAtTime:midpoint actualTime:NULL error:&error];

    NSImage *thumbImage = nil;
    if (thumbImageRef && !error) {
        thumbImage = [[NSImage alloc] initWithCGImage:thumbImageRef size:NSMakeSize(160, 90)];
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
NSLog(@"Reloaded!");
reload = false;
}




   NSUInteger columns = 4;
CGFloat spacing = 12.0;
CGFloat thumbWidth = 160.0;
CGFloat thumbHeight = thumbWidth * 9.0 / 16.0;

NSMutableArray *gridRows = [NSMutableArray array];

for (NSUInteger row = 0; row < ceil((double)[buttons count] / columns); row++) {
    NSMutableArray *rowViews = [NSMutableArray array];
    for (NSUInteger col = 0; col < columns; col++) {
        NSUInteger idx = row * columns + col;
        if (idx < [buttons count]) {
            NSButton *btn = buttons[idx];
            btn.translatesAutoresizingMaskIntoConstraints = NO;

            [btn.heightAnchor constraintEqualToAnchor:btn.widthAnchor multiplier:9.0/16.0].active = YES;
            [btn.widthAnchor constraintEqualToConstant:thumbWidth].active = YES;

            [rowViews addObject:btn];
        } else {
            NSView *empty = [[NSView alloc] init];
            [empty.widthAnchor constraintEqualToConstant:thumbWidth].active = YES;
            [empty.heightAnchor constraintEqualToConstant:thumbHeight].active = YES;
            [rowViews addObject:empty];
        }
    }
    [gridRows addObject:rowViews];
}

NSGridView *gridView = [NSGridView gridViewWithViews:gridRows];
gridView.translatesAutoresizingMaskIntoConstraints = NO;
gridView.rowSpacing = spacing;
gridView.columnSpacing = spacing;

[content addSubview:gridView];

[NSLayoutConstraint activateConstraints:@[
    [gridView.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
    [gridView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor]
]];


//self.statusBar = [NSStatusBar systemStatusBar];
self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];


NSImage *icon = [NSImage imageNamed:NSImageNameApplicationIcon];
//icon.isTemplate = true; // Adapts to dark mode
self.statusItem.button.image = icon;

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

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
}
