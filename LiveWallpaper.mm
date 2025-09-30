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
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/SMAppService.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "LineModule.h"

#include <array>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#import <mach/mach.h>
#include <memory>
#include <spawn.h>
#include <stdexcept>
#include <string>

void LogMemoryUsage(void) {
  task_vm_info_data_t vmInfo;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

  kern_return_t kernReturn =
      task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);

  if (kernReturn == KERN_SUCCESS) {
    NSLog(@"📊 Memory in use: %llu MB", vmInfo.phys_footprint / 1024 / 1024);
  } else {
    NSLog(@"⚠️ Failed to retrieve memory usage.");
  }
}

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
    NSWorkspaceDesktopImageScalingKey : @(NSImageScaleProportionallyUpOrDown)
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

NSImage *GetSystemAppIcon(NSString *appName, NSSize size) {
  NSString *path =
      [NSString stringWithFormat:@"/System/Applications/%@.app", appName];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    path = [NSString
        stringWithFormat:@"/System/Library/CoreServices/%@.app", appName];
  }
  NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
  [icon setSize:size];
  return icon;
}

@interface AppDelegate
    : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTouchBarDelegate>
//@property(strong) NSWindow *window;
@property(nonatomic, strong) NSMutableArray *notificationObservers;

@property(strong) NSWindow *blurWindow;
@property(strong) NSStatusItem *statusItem;
//@property(strong) AVPlayer *player;
@property(strong) NSWindow *progressWindow;
@property(strong) NSTextField *progressLabel;
@property(strong) NSProgressIndicator *progressBar;
@property(strong) NSTextView *logTextView;

@property(strong) NSWindow *settingsWindow;

@property (strong) NSTextField *precentage;
@property (strong) NSTextField *touchbar_volume;
@property (strong) NSPopoverTouchBarItem *volumePopoverItem;


@end

@implementation AppDelegate

NSStackView *gridContainer = [[NSStackView alloc] init];
NSScreen *mainScreen = NULL;
NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
NSView *content;
NSString *folderPath;

void checkFolderPath() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:@"WallpaperFolder"]) {
    folderPath = [defaults stringForKey:@"WallpaperFolder"];
  }

  else if (!folderPath) {
    folderPath = [NSHomeDirectory() stringByAppendingPathComponent:@"LiveWall"];

    [defaults setObject:folderPath forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }
}

NSString *getFolderPath(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *path = [defaults stringForKey:@"WallpaperFolder"];

    if (!path) {
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"LiveWall"];
        [defaults setObject:path forKey:@"WallpaperFolder"];
        [defaults synchronize];
    }

    return path;
}
- (void)screensDidChange:(NSNotification *)note {
    [self startWallpaperWithPath:[NSString stringWithUTF8String:g_videoPath.c_str()]];
}

- (BOOL)enableAppAsLoginItem {
  NSString *agentPath = [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/LaunchAgents/com.biosthusvill.LiveWallpaper.plist"];

  NSString *execPath = [[NSBundle mainBundle] executablePath];

  NSDictionary *plist = @{
    @"Label" : @"com.biosthusvill.LiveWallpaper",
    @"ProgramArguments" : @[ execPath ],
    @"RunAtLoad" : @YES,
    @"KeepAlive" : @NO
  };

  NSError *error = nil;
  NSData *plistData = [NSPropertyListSerialization
      dataWithPropertyList:plist
                    format:NSPropertyListXMLFormat_v1_0
                   options:0
                     error:&error];
  if (!plistData) {
    NSLog(@"Failed to serialize plist: %@", error);
    return NO;
  }

  if (![plistData writeToFile:agentPath atomically:YES]) {
    NSLog(@"Failed to write LaunchAgent to %@", agentPath);
    return NO;
  }

  // Load it
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/bin/launchctl";
  task.arguments = @[ @"load", agentPath ];
  [task launch];

  NSLog(@"Successfully registered app as login item");
  return YES;
}

- (IBAction)addLoginItem:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Start LiveWallpaper at login?"];
  [alert addButtonWithTitle:@"Yes"];
  [alert addButtonWithTitle:@"No"];
  NSModalResponse response = [alert runModal];

  if (response == NSAlertFirstButtonReturn) {
    [self enableAppAsLoginItem];
  }
}
- (NSString *)thumbnailCachePath {
  NSArray *cacheDirs = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES);
  NSString *systemCacheDir = cacheDirs.firstObject;
  NSString *bundleName =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

  if (!bundleName || bundleName.length == 0) {
    bundleName = @"LiveWallpaper";
  }
  NSString *thumbnailPath = [systemCacheDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/thumbnails",
                                                          bundleName]];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:thumbnailPath]) {
    [fm createDirectoryAtPath:thumbnailPath
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  return thumbnailPath;
}

- (void)resetUserData {
    NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:appDomain];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)clearCache {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // --- Clear thumbnail cache ---
    NSString *thumbnailCachePath = [self thumbnailCachePath];
    if ([fileManager fileExistsAtPath:thumbnailCachePath]) {
        NSError *error = nil;
        NSArray *files = [fileManager contentsOfDirectoryAtPath:thumbnailCachePath
                                                          error:&error];
        if (!error) {
            for (NSString *file in files) {
                NSString *filePath = [thumbnailCachePath stringByAppendingPathComponent:file];
                [fileManager removeItemAtPath:filePath error:nil];
            }
        }
    }

    // --- Clear static wallpaper cache ---
    NSString *appSupportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                  NSUserDomainMask,
                                                                  YES) firstObject];
    NSString *customDir = [appSupportDir stringByAppendingPathComponent:@"Livewall"];

    // Ensure the directory exists
    [fileManager createDirectoryAtPath:customDir
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];

    if ([fileManager fileExistsAtPath:customDir]) {
        NSError *error = nil;
        NSArray *files = [fileManager contentsOfDirectoryAtPath:customDir
                                                          error:&error];
        if (!error) {
            for (NSString *file in files) {
                NSString *filePath = [customDir stringByAppendingPathComponent:file];
                [fileManager removeItemAtPath:filePath error:nil];
            }
        }
    }
}

- (void)generateThumbnailsForFolder:(NSString *)folderPath {
    NSLog(@"Generating Thumbnails...");
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *thumbnailCachePath = [self thumbnailCachePath];
    
    [self clearCache];
    // Create thumbnail folder if not exists
    if (![fileManager fileExistsAtPath:thumbnailCachePath]) {
        [fileManager createDirectoryAtPath:thumbnailCachePath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
    }

    NSArray<NSString *> *files = [fileManager contentsOfDirectoryAtPath:folderPath
                                                                  error:nil];

    for (NSString *filename in files) {
        if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
            ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
            continue;
        }

        NSString *filePath = [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];
        AVAsset *asset = [AVAsset assetWithURL:videoURL];
        AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        imageGenerator.appliesPreferredTrackTransform = YES;
        imageGenerator.maximumSize = CGSizeMake(160, 90); // thumbnail size

        Float64 midpoint_sec = CMTimeGetSeconds(asset.duration) / 2.0;
        CMTime midpoint = CMTimeMakeWithSeconds(midpoint_sec, asset.duration.timescale);

        NSError *error = nil;
        CGImageRef thumbImageRef = [imageGenerator copyCGImageAtTime:midpoint
                                                          actualTime:NULL
                                                               error:&error];

        if (thumbImageRef && !error) {
            NSImage *thumbImage = [[NSImage alloc] initWithCGImage:thumbImageRef
                                                             size:NSMakeSize(160, 90)];
            CGImageRelease(thumbImageRef);

            // --- Determine and embed badge ---
            NSString *badgeText = [self videoQualityBadgeForURL:videoURL]; // HD, 4K, SD
            if (badgeText.length > 0) {
                thumbImage = [self image:thumbImage withBadge:badgeText];
            }

            // Save thumbnail to JPEG
            NSData *imageData = [thumbImage TIFFRepresentation];
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:imageData];
            NSData *jpgData = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                                                properties:@{}];
            NSString *thumbName = [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
            NSString *thumbPath = [thumbnailCachePath stringByAppendingPathComponent:thumbName];
            [jpgData writeToFile:thumbPath atomically:YES];
        } else {
            NSLog(@"Error generating thumbnail for %@: %@", filename,
                  error.localizedDescription);
        }
    }
}
- (NSString *)videoQualityBadgeForURL:(NSURL *)videoURL {
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];

    if (!videoTrack) return @"";

    CGSize resolution = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
    resolution.width = fabs(resolution.width);
    resolution.height = fabs(resolution.height);

    if (resolution.width >= 3840 || resolution.height >= 2160) return @"4K";
    if (resolution.width >= 1920 || resolution.height >= 1080) return @"HD";
    if (resolution.width >= 1280 || resolution.height >= 720) return @"SD";
    return @"";
}

- (NSImage *)image:(NSImage *)image withBadge:(NSString *)badge {
    NSImage *result = [image copy];
    [result lockFocus];

    // Badge text attributes
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:14], // smaller font
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSStrokeColorAttributeName: [NSColor blackColor],
        NSStrokeWidthAttributeName: @-1
    };

    NSSize textSize = [badge sizeWithAttributes:attributes];

    // Semi-transparent "blur-like" background
    NSColor *bgColor = [[NSColor blackColor] colorWithAlphaComponent:0.55]; // softer
    NSRect bgRect = NSMakeRect(result.size.width - textSize.width - 10,
                               result.size.height - textSize.height - 8,
                               textSize.width + 4,
                               textSize.height + 2);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bgRect xRadius:3 yRadius:3];
    [bgColor setFill];
    [path fill];

    [bgColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bgRect xRadius:3 yRadius:3] fill];

    // Draw badge text
    NSPoint textPoint = NSMakePoint(result.size.width - textSize.width - 8,
                                    result.size.height - textSize.height - 6);
    [badge drawAtPoint:textPoint withAttributes:attributes];

    [result unlockFocus];
    return result;
}



- (void)selectWallpaperFolder:(id)sender {
  [NSApp activateIgnoringOtherApps:YES];
  [NSApp activateIgnoringOtherApps:YES];

  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setCanChooseFiles:NO];
  [panel setCanChooseDirectories:YES];
  [panel setAllowsMultipleSelection:NO];
  [panel setTitle:@"Select Wallpaper Folder"];
  [panel setPrompt:@"Choose"];

  [panel beginWithCompletionHandler:^(NSModalResponse result) {
    if (result == NSModalResponseOK) {
      NSURL *selectedFolderURL = [panel URL];
      if (selectedFolderURL) {
        NSString *path = [selectedFolderURL path];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:path forKey:@"WallpaperFolder"];
        [defaults synchronize];
        folderPath = path;
        if (self.settingsWindow) {
          [self.settingsWindow close];
          [self showSettingsWindow:nil];
        }
        [self clearCache];
          [self generateThumbnailsForFolder:getFolderPath()];
        [self reloadGrid:nil];

        NSLog(@"Selected wallpaper folder: %@", path);
      }
    }
  }];
}

NSButton *CreateButton(NSString *title, id target, SEL action) {
  NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)];
  [btn setTitle:title];
  [btn setBezelStyle:NSBezelStyleRounded];
  [btn setTarget:target];
  [btn setAction:action];
  return btn;
}
NSTextField *CreateLabel(NSString *string) {
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
  [tf setStringValue:string];
  [tf setBezeled:NO];
  [tf setDrawsBackground:NO];
  [tf setEditable:NO];
  [tf setSelectable:NO];
  return tf;
}
- (void)showSettingsWindow:(id)sender {
    NSRect frame = NSMakeRect(100, 100, 400, 300);

    // Create a titled window
    self.settingsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    [self.settingsWindow setTitle:@"Settings"];
    [self.settingsWindow center];
    [self.settingsWindow setOpaque:NO];
    [self.settingsWindow setBackgroundColor:[NSColor clearColor]];
    self.settingsWindow.titlebarAppearsTransparent = YES;
    self.settingsWindow.styleMask |= NSWindowStyleMaskFullSizeContentView;

    // Add glass background
    NSView *glassView = nil;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *effView = [[NSGlassEffectView alloc] initWithFrame:self.settingsWindow.contentView.bounds];
        effView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glassView = effView;
    } else {
        NSVisualEffectView *fallbackView = [[NSVisualEffectView alloc] initWithFrame:self.settingsWindow.contentView.bounds];
        fallbackView.material = NSVisualEffectMaterialHUDWindow;
        fallbackView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        fallbackView.state = NSVisualEffectStateActive;
        fallbackView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glassView = fallbackView;
    }
    [self.settingsWindow.contentView addSubview:glassView positioned:NSWindowBelow relativeTo:nil];

    // Vertical stack container
    NSStackView *stackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    stackView.alignment = NSLayoutAttributeLeading;
    stackView.spacing = 12;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    
    {
        NSView *topSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
        topSpacer.translatesAutoresizingMaskIntoConstraints = NO;
        [topSpacer.heightAnchor constraintEqualToConstant:24].active = YES; // desired gap
        [stackView addArrangedSubview:topSpacer];

    }

    // --- Folder Selection ---
    {
        LineModule *folderSelect = [[LineModule alloc] initWithFrame:NSZeroRect];
        folderSelect.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *folderLabel = CreateLabel(@"Wallpaper Folder:");
        folderLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *folderInput = [[NSTextField alloc] initWithFrame:NSZeroRect];
        folderInput.translatesAutoresizingMaskIntoConstraints = NO;
        folderInput.placeholderString = @"Select folder or type path";
        folderInput.stringValue = folderPath ?: @"";
        [folderInput.widthAnchor constraintEqualToConstant:200].active = YES;

        NSButton *openFolder = CreateButton(@"Select Folder 📁", self, @selector(selectWallpaperFolder:));
        openFolder.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *openInFinder = CreateButton(@"Show in Finder 📂", self, @selector(openWallpaperFolder:));
        openInFinder.translatesAutoresizingMaskIntoConstraints = NO;

        [folderSelect add:folderLabel];
        [folderSelect add:folderInput];
        [folderSelect add:openFolder];
        [folderSelect add:openInFinder];
        [stackView addArrangedSubview:folderSelect];
    }

    // --- Optimize Videos ---
    {
        LineModule *optimizeVideos = [[LineModule alloc] initWithFrame:NSZeroRect];
        optimizeVideos.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *optimizeLabel = CreateLabel(@"Optimize Video Codecs");
        optimizeLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *optimizeButton = CreateButton(@"Optimize 🛠️", self, @selector(convertCodec:));
        optimizeButton.translatesAutoresizingMaskIntoConstraints = NO;

        [optimizeVideos add:optimizeLabel];
        [optimizeVideos add:optimizeButton];
        [stackView addArrangedSubview:optimizeVideos];
    }

    // --- Random Wallpaper Toggle ---
    {
        LineModule *randomVid = [[LineModule alloc] initWithFrame:NSZeroRect];
        randomVid.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *randomLabel = CreateLabel(@"Random Wallpaper on Startup");
        randomLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSSwitch *randomToggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
        randomToggle.translatesAutoresizingMaskIntoConstraints = NO;
        randomToggle.target = self;
        randomToggle.action = @selector(randomToggleChanged:);
        randomToggle.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"random"] ? NSControlStateValueOn : NSControlStateValueOff;

        [randomVid add:randomLabel];
        [randomVid add:randomToggle];
        [stackView addArrangedSubview:randomVid];
    }

    // --- Video Volume ---
    {
        LineModule *videoVolume = [[LineModule alloc] initWithFrame:NSZeroRect];
        videoVolume.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *volumeLabel = CreateLabel(@"Video Volume");
        volumeLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        [slider.widthAnchor constraintEqualToConstant:200].active = YES;
        slider.minValue = 0;
        slider.maxValue = 100;
        slider.floatValue = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolumeprecentage"];
        slider.target = self;
        slider.action = @selector(sliderValueChanged:);

        self.precentage = CreateLabel(@"Percentage");
        self.precentage.translatesAutoresizingMaskIntoConstraints = NO;
        [self.precentage.widthAnchor constraintEqualToConstant:60].active = YES;
        self.precentage.editable = NO;
        self.precentage.selectable = NO;
        self.precentage.stringValue = [NSString stringWithFormat:@"%.0f%%", slider.floatValue];

        [videoVolume add:volumeLabel];
        [videoVolume add:slider];
        [videoVolume add:self.precentage];
        [stackView addArrangedSubview:videoVolume];
    }

    // --- Clear Cache ---
    {
        LineModule *clearCache = [[LineModule alloc] initWithFrame:NSZeroRect];
        clearCache.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *clearCacheLabel = CreateLabel(@"Clear Cache");
        clearCacheLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *clearCacheButton = CreateButton(@"Clear Cache 🗑️", self, @selector(clearCacheButton:));
        clearCacheButton.translatesAutoresizingMaskIntoConstraints = NO;

        [clearCache add:clearCacheLabel];
        [clearCache add:clearCacheButton];
        [stackView addArrangedSubview:clearCache];
    }

    // --- Reset UserData ---
    {
        LineModule *resetUserData = [[LineModule alloc] initWithFrame:NSZeroRect];
        resetUserData.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *m_Label = CreateLabel(@"Reset UserData 🗑️");
        m_Label.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *m_Button = CreateButton(@"Reset", self, @selector(resetButton:));
        m_Button.translatesAutoresizingMaskIntoConstraints = NO;

        [resetUserData add:m_Label];
        [resetUserData add:m_Button];
        [stackView addArrangedSubview:resetUserData];
    }

    // --- Login Item Permission ---
    {
        NSString *agentPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.biosthusvill.LiveWallpaper.plist"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:agentPath]) {
            LineModule *permissions = [[LineModule alloc] initWithFrame:NSZeroRect];
            permissions.translatesAutoresizingMaskIntoConstraints = NO;

            NSTextField *permissionLabel = CreateLabel(@"Add this to LoginItems");
            permissionLabel.translatesAutoresizingMaskIntoConstraints = NO;

            NSButton *permissionButton = CreateButton(@"Grant Permissions 􀮓", self, @selector(addLoginItem:));
            permissionButton.translatesAutoresizingMaskIntoConstraints = NO;

            [permissions add:permissionLabel];
            [permissions add:permissionButton];
            [stackView addArrangedSubview:permissions];
        }
    }

    // Attach stack to glassView
    [glassView addSubview:stackView];
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:glassView.topAnchor constant:20],
        [stackView.leadingAnchor constraintEqualToAnchor:glassView.leadingAnchor constant:20],
        [stackView.trailingAnchor constraintLessThanOrEqualToAnchor:glassView.trailingAnchor constant:-20],
        [stackView.bottomAnchor constraintLessThanOrEqualToAnchor:glassView.bottomAnchor constant:-20]
    ]];

    // Fade-in animation
    [self.settingsWindow setAlphaValue:0.0];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.settingsWindow.animator.alphaValue = 1.0;
    } completionHandler:nil];
}
- (void)randomToggleChanged:(NSSwitch *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"random"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)clearCacheButton:(id)sender {
    [self clearCache];
}
- (void)resetButton:(id)sender {
    [self resetUserData];
}

- (void)sliderValueChanged:(NSSlider *)sender {
    float f_percentage = sender.floatValue;
    float volume = f_percentage / 100.0f;

    NSLog(@"Slider: %.0f%% → volume: %.2f", f_percentage, volume);

    self.precentage.stringValue = [NSString stringWithFormat:@"%.0f%%", f_percentage];
    self.touchbar_volume.stringValue = [NSString stringWithFormat:@"%.0f%%", f_percentage];

    [[NSUserDefaults standardUserDefaults] setFloat:f_percentage forKey:@"wallpapervolumeprecentage"];
    [[NSUserDefaults standardUserDefaults] setFloat:volume forKey:@"wallpapervolume"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    self.volumePopoverItem.collapsedRepresentationImage = [self volumeIconForValue:f_percentage];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.live.wallpaper.volumeChanged"),
        NULL, NULL, true
    );
}

- (BOOL)isFirstLaunch {
  NSString *const kFirstLaunchKey = @"HasLaunchedOnce";
  if (![[NSUserDefaults standardUserDefaults] boolForKey:kFirstLaunchKey]) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kFirstLaunchKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
  }
  return NO;
}

- (void)promptForLoginItem {
  NSString *agentPath = [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/LaunchAgents/com.biosthusvill.LiveWallpaper.plist"];
  BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:agentPath];
  if (!exists) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Launch at Login"];
    [alert setInformativeText:@"Would you like to launch this app "
                              @"automatically when you log in?"];
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
    [alert setAlertStyle:NSAlertStyleInformational];

    [alert beginSheetModalForWindow:self.blurWindow
                  completionHandler:^(NSModalResponse returnCode) {
                    if (returnCode == NSAlertFirstButtonReturn) {

                      SMAppService *service = [SMAppService
                          loginItemServiceWithIdentifier:[[NSBundle mainBundle]
                                                             bundleIdentifier]];
                      NSError *error = nil;
                      [service registerAndReturnError:&error];
                      if (error) {
                        NSLog(@"Error adding to login items: %@",
                              error.localizedDescription);
                      }
                    }
                  }];
  }
}

- (void)showProgressWindowWithMax:(NSInteger)maxCount {

  if (!self.progressWindow) {
    NSRect frame = NSMakeRect(0, 0, 480, 320);
    self.progressWindow =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    [self.progressWindow setTitle:@"Optimizing Live Wallpapers"];
    [self.progressWindow center];

    NSView *contentView = self.progressWindow.contentView;

    // Progress Label
    self.progressLabel =
        [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 20)];
    [self.progressLabel setEditable:NO];
    [self.progressLabel setBezeled:NO];
    [self.progressLabel setDrawsBackground:NO];
    [self.progressLabel setStringValue:@"Starting..."];
    [contentView addSubview:self.progressLabel];

    // Progress Bar
    self.progressBar = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(20, 250, 440, 20)];
    [self.progressBar setIndeterminate:NO];
    [self.progressBar setMinValue:0];
    [self.progressBar setMaxValue:maxCount];
    [self.progressBar setDoubleValue:0];
    [self.progressBar setUsesThreadedAnimation:YES];
    [contentView addSubview:self.progressBar];

    // Scrollable TextView for logs
    NSScrollView *scrollView =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 440, 210)];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setAutohidesScrollers:YES];

    NSTextView *textView =
        [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 440, 210)];
    [textView setEditable:NO];
    [textView setSelectable:YES];
    [textView setFont:[NSFont userFixedPitchFontOfSize:12]];
    [textView setBackgroundColor:[NSColor blackColor]];
    [textView setTextColor:[NSColor greenColor]];
    [textView setString:@"Log:\n"];

    [scrollView setDocumentView:textView];
    [contentView addSubview:scrollView];

    self.logTextView = textView;
  }
  [self.progressWindow setAlphaValue:0.0];
  [self.progressWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];
  [self.progressWindow.contentView setWantsLayer:YES];
  self.progressWindow.contentView.layer.transform =
      CATransform3DMakeScale(0.92, 0.92, 1.0);

  //[self.progressWindow makeKeyAndOrderFront:nil];

  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.35;
        self.progressWindow.animator.alphaValue = 1.0;
        self.progressWindow.contentView.layer.transform = CATransform3DIdentity;
      }
      completionHandler:nil];
}
- (void)appendLogMessage:(NSString *)text {
  if (!self.logTextView)
    return;

  NSDictionary *attrs = @{
    NSForegroundColorAttributeName : [NSColor greenColor],
    NSFontAttributeName : [NSFont userFixedPitchFontOfSize:12]
  };

  NSString *fullText = [text stringByAppendingString:@"\n"];
  __block NSUInteger charIndex = 0;
  __block NSMutableAttributedString *typingBuffer =
      [[NSMutableAttributedString alloc] init];

  dispatch_async(dispatch_get_main_queue(), ^{
    NSTimer *timer = [NSTimer
        scheduledTimerWithTimeInterval:0.01
                               repeats:YES
                                 block:^(NSTimer *_Nonnull timer) {
                                   if (charIndex >= fullText.length) {
                                     [[self.logTextView textStorage]
                                         appendAttributedString:typingBuffer];
                                     NSRange range = NSMakeRange(
                                         [[self.logTextView string] length], 0);

                                     [NSAnimationContext
                                         runAnimationGroup:^(
                                             NSAnimationContext *context) {
                                           context.duration = 0.3;
                                           [[self.logTextView animator]
                                               scrollRangeToVisible:range];
                                         }
                                         completionHandler:nil];

                                     [timer invalidate];
                                     return;
                                   }

                                   NSString *nextChar = [fullText
                                       substringWithRange:NSMakeRange(charIndex,
                                                                      1)];
                                   NSAttributedString *attrChar =
                                       [[NSAttributedString alloc]
                                           initWithString:nextChar
                                               attributes:attrs];
                                   [typingBuffer
                                       appendAttributedString:attrChar];
                                   charIndex++;
                                 }];

    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  });
}

- (void)optimizeAllVideosInFolder {
  checkFolderPath();
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSArray *videoFiles = [fileManager contentsOfDirectoryAtPath:folderPath
                                                         error:nil];

  NSPredicate *predicate = [NSPredicate
      predicateWithBlock:^BOOL(NSString *filename, NSDictionary *bindings) {
        NSString *lower = filename.lowercaseString;
        return [lower hasSuffix:@".mp4"] || [lower hasSuffix:@".mov"];
      }];
  videoFiles = [videoFiles filteredArrayUsingPredicate:predicate];

  // Show the progress window on the main thread before starting conversion
  dispatch_async(dispatch_get_main_queue(), ^{
    [self showProgressWindowWithMax:videoFiles.count];
  });

  __block NSInteger currentIndex = 0;

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSString *file in videoFiles) {
          currentIndex++;
          NSString *fullPath = [folderPath stringByAppendingPathComponent:file];
          NSURL *fileURL = [NSURL fileURLWithPath:fullPath];
          AVAsset *asset = [AVAsset assetWithURL:fileURL];
          BOOL isHEVC = NO;

          for (AVAssetTrack *track in
               [asset tracksWithMediaType:AVMediaTypeVideo]) {
            CFArrayRef formatDescriptions =
                (__bridge CFArrayRef)track.formatDescriptions;
            for (CFIndex i = 0; i < CFArrayGetCount(formatDescriptions); i++) {
              CMFormatDescriptionRef fmt =
                  (CMFormatDescriptionRef)CFArrayGetValueAtIndex(
                      formatDescriptions, i);
              FourCharCode codec = CMFormatDescriptionGetMediaSubType(fmt);
              if (codec == kCMVideoCodecType_HEVC) {
                isHEVC = YES;
                break;
              }
            }
            if (isHEVC)
              break;
          }

          dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressLabel
                setStringValue:[NSString
                                   stringWithFormat:@"Processing: %@", file]];
            [self.progressBar setDoubleValue:currentIndex - 1];
          });

          if (isHEVC) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [self.progressLabel
                  setStringValue:
                      [NSString stringWithFormat:@"Skipped (already HEVC): %@",
                                                 file]];
              [NSAnimationContext
                  runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.2;
                    [self.progressBar.animator setDoubleValue:currentIndex];
                  }
                  completionHandler:nil];

              [self
                  appendLogMessage:
                      [NSString stringWithFormat:@"Skipped (already HEVC): %@",
                                                 file]];
            });
            continue;
          }

          // Safe temp file path with same extension as original
          NSString *tempName = [NSString
              stringWithFormat:@"%@.tmp.mp4", [[NSUUID UUID] UUIDString]];
          NSString *tempPath =
              [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];
          NSURL *tempURL = [NSURL fileURLWithPath:tempPath];

          AVAssetExportSession *exportSession = [[AVAssetExportSession alloc]
              initWithAsset:asset
                 presetName:AVAssetExportPresetHEVCHighestQuality];
          exportSession.outputURL = tempURL;
          exportSession.outputFileType = AVFileTypeMPEG4;
          exportSession.shouldOptimizeForNetworkUse = YES;
          dispatch_semaphore_t sema = dispatch_semaphore_create(0);

          [exportSession exportAsynchronouslyWithCompletionHandler:^{
            NSFileManager *fm = [NSFileManager defaultManager];
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
              NSError *replaceError = nil;
              // Remove original
              if ([fm fileExistsAtPath:fileURL.path]) {
                if (![fm removeItemAtURL:fileURL error:&replaceError]) {
                  NSLog(@"❌ Remove failed: %@",
                        replaceError.localizedDescription);
                }
              }
              // Move temp to original
              if (![fm moveItemAtURL:tempURL
                               toURL:fileURL
                               error:&replaceError]) {
                NSLog(@"❌ Replace failed: %@",
                      replaceError.localizedDescription);
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self appendLogMessage:
                            [NSString
                                stringWithFormat:@"❌ Replace failed: %@ (%@)",
                                                 file,
                                                 replaceError
                                                     .localizedDescription]];
                });
              } else {
                NSLog(@"✅ Converted: %@", file);
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self
                      appendLogMessage:[NSString
                                           stringWithFormat:@"✅ Converted: %@",
                                                            file]];
                });
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                [self.progressLabel
                    setStringValue:[NSString stringWithFormat:@"Converted: %@",
                                                              file]];
                [self.progressBar setDoubleValue:currentIndex];
              });
            } else {
              NSLog(@"❌ Export failed for %@ (%@)", file,
                    exportSession.error.localizedDescription);
              [fm removeItemAtURL:tempURL error:nil];
              dispatch_async(dispatch_get_main_queue(), ^{
                [self
                    appendLogMessage:
                        [NSString stringWithFormat:@"❌ Export failed: %@ (%@)",
                                                   file,
                                                   exportSession.error
                                                       .localizedDescription]];
                [self.progressLabel
                    setStringValue:[NSString
                                       stringWithFormat:@"Failed: %@", file]];
                [self.progressBar setDoubleValue:currentIndex];
              });
            }
            dispatch_semaphore_signal(sema);
          }];
          dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          [self.progressLabel setStringValue:@"All conversions done!"];
          [self.progressBar setDoubleValue:videoFiles.count];
          [self appendLogMessage:@"All conversions done!"];
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [NSAnimationContext
                    runAnimationGroup:^(NSAnimationContext *context) {
                      context.duration = 0.3;
                      self.progressWindow.animator.alphaValue = 0.0;
                    }
                    completionHandler:^{
                      [self.progressWindow orderOut:nil];
                      self.progressWindow.alphaValue = 1.0;
                    }];
              });
        });
      });
}

- (void)checkAndPromptPermissions {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults boolForKey:@"AccessibilityPermissionChecked"])
    return;
  [defaults setBool:YES forKey:@"AccessibilityPermissionChecked"];
  [defaults synchronize];

  if (!AXIsProcessTrusted()) {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
  }
}

- (void)ReloadContent {

  for (NSButton *btn in buttons) {
    [btn removeFromSuperview];
  }
  [buttons removeAllObjects];

  for (NSView *subview in gridContainer.arrangedSubviews) {
    [gridContainer removeArrangedSubview:subview];
    [subview removeFromSuperview];
  }

  checkFolderPath();
  NSArray<NSString *> *allFiles =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderPath
                                                          error:nil];

  NSPredicate *predicate =
      [NSPredicate predicateWithFormat:
                       @"SELF ENDSWITH[c] '.mp4' OR SELF ENDSWITH[c] '.mov'"];
  NSArray<NSString *> *videoFiles =
      [allFiles filteredArrayUsingPredicate:predicate];

  for (NSString *filename in videoFiles) {
    @autoreleasepool {
      NSString *videoPath =
          [folderPath stringByAppendingPathComponent:filename];
      NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

      NSButton *btn = [[NSButton alloc] init];

      NSString *cacheImagePath = [[self thumbnailCachePath]
          stringByAppendingPathComponent:
              [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"]];

      NSImage *image = [[NSImage alloc] initWithContentsOfFile:cacheImagePath];
      if (image) {
        btn.image = image;
      } else {
        NSLog(@"Thumbnail not found for %@", cacheImagePath);
          [self generateThumbnailsForFolder:getFolderPath()];
      }
        
        btn.layer.cornerRadius = 10;
        btn.layer.masksToBounds = YES;

      btn.image = image;
      btn.bezelStyle = NSBezelStyleShadowlessSquare;
      btn.imageScaling = NSImageScaleProportionallyUpOrDown;
      btn.title = @"";
      btn.target = self;
      btn.action = @selector(handleButtonClick:);
      btn.toolTip = filename;

      // btn.title = filename;
      btn.bezelStyle = NSBezelStyleShadowlessSquare;
      btn.imageScaling = NSImageScaleAxesIndependently;
      btn.translatesAutoresizingMaskIntoConstraints = NO;
      btn.tag = [videoFiles indexOfObject:filename];
      [buttons addObject:btn];
    }
  }
}
- (void)convertCodec:(id)sender {
  [self optimizeAllVideosInFolder];
}

- (void)reloadGrid:(id)sender {
  NSString *cachePath = [self thumbnailCachePath];
  NSArray *contents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cachePath
                                                          error:nil];
  if (contents.count == 0) {
    checkFolderPath();
      [self generateThumbnailsForFolder:getFolderPath()];
  }
  [self ReloadContent];

  CGFloat spacing = 12.0;
  CGFloat padding = 24.0;

  CGFloat containerWidth = NSWidth(self.blurWindow.contentView.frame) - padding;
  if (containerWidth < 0)
    containerWidth = 0;

  CGFloat minThumbWidth = 160.0;
  NSUInteger columns = (NSUInteger)(containerWidth / (minThumbWidth + spacing));
  if (columns < 1)
    columns = 1;

  CGFloat thumbWidth = (containerWidth - (columns - 1) * spacing) / columns;
  CGFloat thumbHeight = thumbWidth * 9.0 / 16.0;

  NSUInteger totalButtons = buttons.count;
  NSUInteger rows = (totalButtons + columns - 1) / columns;

  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;

        for (NSUInteger row = 0; row < rows; row++) {
          NSStackView *rowStack = [[NSStackView alloc] init];
          rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
          rowStack.spacing = spacing;
          rowStack.distribution = NSStackViewDistributionFill;

          for (NSUInteger col = 0; col < columns; col++) {
            NSUInteger idx = row * columns + col;
            if (idx < totalButtons) {
              NSButton *btn = buttons[idx];

              // Prepare for animation
              btn.alphaValue = 0.0;
              [btn setWantsLayer:YES];
              btn.layer.transform = CATransform3DMakeScale(0.85, 0.85, 1);

              [btn.widthAnchor constraintEqualToConstant:thumbWidth].active =
                  YES;
              [btn.heightAnchor constraintEqualToConstant:thumbHeight].active =
                  YES;
              [rowStack addArrangedSubview:btn];

              // Animate after slight delay per item (optional staggered effect)
              dispatch_after(
                  dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(col * 0.03 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
                    [NSAnimationContext
                        runAnimationGroup:^(NSAnimationContext *context) {
                          context.duration = 0.3;
                          btn.animator.alphaValue = 1.0;
                          btn.layer.transform = CATransform3DIdentity;
                        }
                        completionHandler:nil];
                  });
            }
          }

          [gridContainer addArrangedSubview:rowStack];
        }
      }
      completionHandler:nil];
}

void killAllDaemons() {
  NSTask *killTask = [[NSTask alloc] init];
  killTask.launchPath = @"/usr/bin/killall";
  killTask.arguments = @[ @"wallpaperdeamon" ];
  [killTask launch];
  [killTask waitUntilExit];

  int status = killTask.terminationStatus;
  if (status != 0) {
    NSLog(@"No running VideoWallpaperDaemon process found or killall failed");
  } else {
    NSLog(@"VideoWallpaperDaemon processes killed");
  }
}
extern char **environ;
void launchDeamon(NSString *videoPath, NSString *imagePath) {
  NSString *daemonRelativePath = @"Contents/MacOS/wallpaperdeamon";
  NSString *appPath = [[NSBundle mainBundle] bundlePath];
  NSString *daemonPath =
      [appPath stringByAppendingPathComponent:daemonRelativePath];


float volume = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
NSString *volumeStr = [NSString stringWithFormat:@"%.2f", volume];

const char *daemonPathC = [daemonPath UTF8String];
const char *args[] = {
    daemonPathC,
    [videoPath UTF8String],
    [imagePath UTF8String],
    [volumeStr UTF8String],
    NULL
};


   pid_t pid;
  int status =
      posix_spawn(&pid, daemonPathC, NULL, NULL, (char *const *)args, environ);
  if (status != 0) {
    NSLog(@"Failed to launch daemon: %d", status);
  }
}

- (void)startWallpaperWithPath:(NSString *)videoPath {
  LogMemoryUsage();

  for (id observer in self.notificationObservers) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
  }
  [self.notificationObservers removeAllObjects];
  killAllDaemons();

  g_videoPath = std::string([videoPath UTF8String]);

  NSString *videoPathNSString =
      [NSString stringWithUTF8String:g_videoPath.c_str()];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:videoPathNSString forKey:@"LastWallpaperPath"];
  [defaults synchronize];

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

  // Compose full output path
  NSString *imageFilename =
      [NSString stringWithFormat:@"%s.jpg", videoName.c_str()];
  NSString *imagePath =
      [customDir stringByAppendingPathComponent:imageFilename];
  frame = std::string([imagePath UTF8String]);

  NSLog(@"videoPath = %@", videoPath);

  launchDeamon(videoPath, imagePath);
  LogMemoryUsage();

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        set_wallpaper_all_spaces(frame);
      });
}

- (void)handleButtonClick:(NSButton *)sender {
  NSLog(@"Clicked: %@", sender.toolTip);

  NSString *videoPath =
      [folderPath stringByAppendingPathComponent:sender.toolTip];
    

  [self startWallpaperWithPath:videoPath];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize {

  CGFloat fixedWidth = 800;
  return NSMakeSize(fixedWidth, proposedFrameSize.height);
}
- (void)openWallpaperFolder:(id)sender {
  checkFolderPath();
  NSFileManager *fm = [NSFileManager defaultManager];

  // Create folder if it doesn't exist
  if (![fm fileExistsAtPath:folderPath]) {
    NSError *error = nil;
    BOOL created = [fm createDirectoryAtPath:folderPath
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&error];
    if (!created) {
      NSLog(@"Failed to create Livewall folder: %@", error);
      return;
    }
  }

  // Open folder in Finder
  [[NSWorkspace sharedWorkspace] openFile:folderPath];
}
// Touchbar
- (NSTouchBar *)makeTouchBar {
  NSLog(@"Touchbar created");
  NSTouchBar *touchBar = [[NSTouchBar alloc] init];
  touchBar.delegate = self;
  touchBar.defaultItemIdentifiers = @[
    NSTouchBarItemIdentifierFlexibleSpace, @"com.livewallpaper.reload",
    @"com.livewallpaper.selectfolder", @"com.livewallpaper.openfolder",
    @"com.livewallpaper.settings", @"com.livewallpaper.volume", NSTouchBarItemIdentifierFlexibleSpace
  ];
  return touchBar;
}

- (NSImage *)volumeIconForValue:(double)value {
    if (value <= 0.0) {
        return [NSImage imageNamed:NSImageNameTouchBarAudioOutputMuteTemplate];
    } else if (value < 30.0) {
        return [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeLowTemplate];
    } else if (value < 70.0) {
        return [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeMediumTemplate];
    } else {
        return [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeHighTemplate];
    }
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {

  if ([identifier isEqualToString:@"com.livewallpaper.selectfolder"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button =
        [NSButton buttonWithTitle:@"📂"
                           target:self
                           action:@selector(selectWallpaperFolder:)];
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.openfolder"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button = [NSButton
        buttonWithImage:GetSystemAppIcon(@"Finder", NSMakeSize(24, 24))
                 target:self
                 action:@selector(openWallpaperFolder:)];
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.reload"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button = [NSButton buttonWithTitle:@"􂣽"
                                          target:self
                                          action:@selector(reloadGrid:)];
    item.view = button;
    return item;
  } else if ([identifier isEqualToString:@"com.livewallpaper.settings"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSButton *button =
        [NSButton buttonWithTitle:@"⚙️"
                           target:self
                           action:@selector(showSettingsWindow:)];
    item.view = button;
    return item;
  }else if ([identifier isEqualToString:@"com.livewallpaper.volume"]) {
    
    NSPopoverTouchBarItem *popoverItem =
        [[NSPopoverTouchBarItem alloc] initWithIdentifier:identifier];

    double currentValue = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolumeprecentage"];
popoverItem.collapsedRepresentationImage = [self volumeIconForValue:currentValue];
    popoverItem.showsCloseButton = YES;              

    // Expanded bar
    NSTouchBar *expandedTouchBar = [[NSTouchBar alloc] init];
    expandedTouchBar.delegate = self;
    expandedTouchBar.defaultItemIdentifiers = @[ @"com.livewallpaper.volume.slider" ];

    popoverItem.popoverTouchBar = expandedTouchBar;
    self.volumePopoverItem = popoverItem;
    return popoverItem;
}
else if ([identifier isEqualToString:@"com.livewallpaper.volume.slider"]) {
    NSCustomTouchBarItem *item =
        [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];

    // Container
    NSStackView *container = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 280, 30)];
    container.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    container.spacing = 8.0;

    // Slider
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 220, 20)];
    slider.minValue = 0;
    slider.maxValue = 100;
    slider.doubleValue = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolumeprecentage"];
    slider.target = self;
    slider.action = @selector(sliderValueChanged:);

    // Percentage label
    NSTextField *percentageLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 40, 30)];
    percentageLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", slider.doubleValue];
    percentageLabel.editable = NO;
    percentageLabel.bezeled = NO;
    percentageLabel.drawsBackground = NO;
    percentageLabel.alignment = NSTextAlignmentCenter;
    percentageLabel.font = [NSFont systemFontOfSize:12];

    // Keep ref so we can update dynamically
    self.touchbar_volume = percentageLabel;

    [container addArrangedSubview:slider];
    [container addArrangedSubview:percentageLabel];

    item.view = container;
    return item;
}
  NSLog(@"No Item found on identifier");
  return nil;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [self.blurWindow.contentView setWantsLayer:YES];
  [self.settingsWindow.contentView setWantsLayer:YES];

    if(![self isFirstLaunch]){
        [self fadeOutWindowsWithCompletion:nil];
    }

  checkFolderPath();
  if ([self isFirstLaunch]) {
    [self promptForLoginItem];
    [self checkAndPromptPermissions];
  }
  NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    
    //Display changes
  [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screensDidChange:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];


  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_Nonnull note) {
                handleSpaceChange(note);
              }];

  NSRect frame = NSMakeRect(0, 0, 800, 600);
  self.blurWindow = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [self.blurWindow setTitle:@"LiveWallpaper by Bios"];
  [self.blurWindow center];
    
[self.blurWindow makeKeyAndOrderFront:nil];
    
  [self.blurWindow setShowsResizeIndicator:YES];
  self.blurWindow.delegate = self;
  if (@available(macOS 10.12.2, *)) {
    NSLog(@"Touchbar supported!");
    self.blurWindow.touchBar = [self makeTouchBar];

  } else {
    NSLog(@"Touchbar not supported!");
  }
    [self.blurWindow setOpaque:NO];
    
    
    [self.blurWindow setBackgroundColor:[NSColor clearColor]];
    
    NSView *effectView = nil;

    if (@available(macOS 26.0, *)) {
        // macOS 26+ uses NSGlassEffectView (Liquid Glass)
        NSGlassEffectView *blurView = [[NSGlassEffectView alloc]
                                       initWithFrame:[[self.blurWindow contentView] bounds]];
        [blurView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [blurView setWantsLayer:YES];
        effectView = blurView;
    } else {
        // fallback for macOS 15 and older
        NSVisualEffectView *blurView = [[NSVisualEffectView alloc]
                                        initWithFrame:[[self.blurWindow contentView] bounds]];
        blurView.material = NSVisualEffectMaterialHUDWindow; // or Menu, Sidebar etc.
        blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        blurView.state = NSVisualEffectStateActive;
        [blurView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [blurView setWantsLayer:YES];
        effectView = blurView;
    }

    // add the effect view below everything
    [[self.blurWindow contentView] addSubview:effectView
                                   positioned:NSWindowBelow
                                   relativeTo:nil];

    // keep content reference
    NSView *content = [self.blurWindow contentView];

    // clear layers
    content.layer.backgroundColor = [NSColor clearColor].CGColor;
    effectView.layer.backgroundColor = [NSColor clearColor].CGColor;

    // window styling
    self.blurWindow.titleVisibility = NSWindowTitleVisible; // or NSWindowTitleHidden
    self.blurWindow.titlebarAppearsTransparent = YES;
    self.blurWindow.styleMask |= NSWindowStyleMaskFullSizeContentView;
    
    


  NSStackView *mainStack = [[NSStackView alloc] init];
  mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  mainStack.distribution = NSStackViewDistributionFill;
  mainStack.alignment = NSLayoutAttributeLeading;
  mainStack.spacing = 12;
  mainStack.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:mainStack];

  [NSLayoutConstraint activateConstraints:@[
    [mainStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
    [mainStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                            constant:12],
    [mainStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                             constant:-12],
    [mainStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                           constant:-12],
  ]];

    //Titlebar space
    {
        NSView *topSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
        topSpacer.translatesAutoresizingMaskIntoConstraints = NO;
        [topSpacer.heightAnchor constraintEqualToConstant:24].active = YES; // desired gap
        [mainStack addArrangedSubview:topSpacer];

    }
  {
    LineModule *buttonPanel = [[LineModule alloc] initWithFrame:NSZeroRect];
    NSButton *settingsButton =
        CreateButton(@"⚙️", self, @selector(showSettingsWindow:));
    NSButton *reloadButton =
        CreateButton(@"􂣽", self, @selector(reloadGrid:));

    [buttonPanel add:reloadButton];
    [buttonPanel add:settingsButton];

    [mainStack addArrangedSubview:buttonPanel];
  }

  gridContainer = [[NSStackView alloc] init];
  gridContainer.orientation = NSUserInterfaceLayoutOrientationVertical;
  gridContainer.spacing = 12;
  gridContainer.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
  gridContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [gridContainer setWantsLayer:YES];

  NSScrollView *scrollView = [[NSScrollView alloc] init];

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
        constraintEqualToAnchor:scrollView.contentView.trailingAnchor],
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
           keyEquivalent:@"o"];
  [menu addItemWithTitle:@"Settings"
                  action:@selector(showSettingsWindow:)
           keyEquivalent:@"s"];
  [menu addItemWithTitle:@"Quit" action:@selector(quitApp) keyEquivalent:@"q"];
  self.statusItem.menu = menu;
    
    if (buttons.count > 0 && [[NSUserDefaults standardUserDefaults] boolForKey:@"random"] == TRUE) {
        NSLog(@"Loading Random Wallpaper...");
        NSUInteger randomIndex = arc4random_uniform((u_int32_t)buttons.count);
        NSButton *randomButton = buttons[randomIndex];
        [randomButton performClick:nil];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  NSLog(@"🚪 App terminating...");
  killAllDaemons();

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
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.blurWindow.animator.alphaValue = 0.0;
        //if (self.settingsWindow) {
          //self.settingsWindow.animator.alphaValue = 0.0;
        //}
      }
      completionHandler:^{
        [self.blurWindow orderOut:nil];
        if (self.settingsWindow) {
          [self.settingsWindow orderOut:nil];
        }
        self.blurWindow.alphaValue = 1.0;
        if (self.settingsWindow) {
          self.settingsWindow.alphaValue = 1.0;
        }
      }];
  return NO;
}
- (void)fadeOutWindowsWithCompletion:(void (^)(void))completion {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.blurWindow.animator.alphaValue = 0.0;
        if (self.settingsWindow) {
            self.settingsWindow.animator.alphaValue = 0.0;
        }
    } completionHandler:^{
        [self.blurWindow orderOut:nil];
        if (self.settingsWindow) {
            [self.settingsWindow orderOut:nil];
        }
        self.blurWindow.alphaValue = 1.0;
        if (self.settingsWindow) {
            self.settingsWindow.alphaValue = 1.0;
        }
        if (completion) completion();
    }];
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
      LogMemoryUsage();
      [delegate startWallpaperWithPath:savedPath];
      LogMemoryUsage();
    }
    

    [app run];
  }
}
