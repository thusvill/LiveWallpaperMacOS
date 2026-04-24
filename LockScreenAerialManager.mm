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

#import "LockScreenAerialManager.h"
#import <CoreMedia/CoreMedia.h>

static NSString * const kSystemSlot   = @"/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/lw_slot.mov";
static NSString * const kCacheSubpath = @"Library/Caches/com.thusvill.LiveWallpaper/lockscreen/current.mov";
static NSString * const kIndexPlist   = @"Library/Application Support/com.apple.wallpaper/Store/Index.plist";
static NSString * const kShotID       = @"livewallpaper_custom_001";
static NSString * const kSavedChoicesKey = @"lockscreenPreviousChoices";

@implementation LockScreenAerialManager

+ (instancetype)shared {
    static LockScreenAerialManager *instance;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (BOOL)isSystemSlotInstalled {
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:kSystemSlot error:nil];
    return [attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink];
}

- (NSString *)userCachePath {
    return [NSHomeDirectory() stringByAppendingPathComponent:kCacheSubpath];
}

- (BOOL)isVideoCodecSupported:(NSString *)videoPath {
    if ([videoPath.pathExtension.lowercaseString isEqualToString:@"mov"]) return YES;
    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeVideo]) {
        for (id desc in track.formatDescriptions) {
            CMVideoFormatDescriptionRef fmt = (__bridge CMVideoFormatDescriptionRef)desc;
            CMVideoCodecType codec = CMVideoFormatDescriptionGetCodecType(fmt);
            if (codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)updateUserSymlink:(NSString *)videoPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *link = self.userCachePath;
    NSString *dir  = [link stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:link error:nil];
    NSError *linkErr;
    if (![fm createSymbolicLinkAtPath:link withDestinationPath:videoPath error:&linkErr]) {
        NSLog(@"[LockScreen] createSymbolicLink failed: %@", linkErr);
    }
}

- (BOOL)writeIndexPlist:(NSError **)outError {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:kIndexPlist];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (outError) *outError = [NSError errorWithDomain:@"LockScreenAerialManager"
            code:1001
            userInfo:@{NSLocalizedDescriptionKey:
                @"Index.plist not found — verify path with:\n"
                 "plutil -p ~/Library/Application\\ Support/com.apple.wallpaper/Store/Index.plist"}];
        return NO;
    }

    NSError *readErr;
    NSMutableDictionary *plist = [[NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListMutableContainersAndLeaves
                      format:nil
                       error:&readErr] mutableCopy];
    if (!plist) { if (outError) *outError = readErr; return NO; }

#ifdef DEBUG
    NSLog(@"[LockScreen] Index.plist top-level keys: %@", plist.allKeys);
#endif

    // Key path from research — verify with:
    // plutil -p ~/Library/Application\ Support/com.apple.wallpaper/Store/Index.plist
    NSMutableDictionary *allSpaces = [plist[@"AllSpacesAndDisplays"] mutableCopy];
    if (!allSpaces) {
        if (outError) *outError = [NSError errorWithDomain:@"LockScreenAerialManager"
            code:1002
            userInfo:@{NSLocalizedDescriptionKey:
                @"AllSpacesAndDisplays key missing — adjust writeIndexPlist: key path to match actual plist structure"}];
        return NO;
    }

    NSMutableDictionary *idle    = [allSpaces[@"Idle"]   mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *content = [idle[@"Content"]     mutableCopy] ?: [NSMutableDictionary dictionary];

    // Save current Choices for revert (serialise as XML plist for reliable round-trip)
    id existing = content[@"Choices"];
    if (existing) {
        NSData *saved = [NSPropertyListSerialization
            dataWithPropertyList:existing format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        if (saved) [[NSUserDefaults standardUserDefaults] setObject:saved forKey:kSavedChoicesKey];
    }

    // Aerial-style choice dictionary — adjust if plutil shows a different structure
    content[@"Choices"] = @[@{
        @"BackgroundColor": @{},
        @"Provider": @{
            @"Library": @{
                @"Assets": @[@{
                    @"Value": @{@"Identifier": kShotID}
                }]
            }
        }
    }];
    content[@"UsesSingleChoice"] = @YES;
    idle[@"Content"]              = content;
    allSpaces[@"Idle"]            = idle;
    plist[@"AllSpacesAndDisplays"] = allSpaces;

    NSData *out = [NSPropertyListSerialization
        dataWithPropertyList:plist
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:outError];
    if (!out) return NO;
    return [out writeToFile:path options:NSDataWritingAtomic error:outError];
}

- (BOOL)revertIndexPlist:(NSError **)outError {
    NSData *saved = [[NSUserDefaults standardUserDefaults] dataForKey:kSavedChoicesKey];
    if (!saved) return YES;  // nothing to revert

    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:kIndexPlist];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return YES;

    NSError *readErr;
    NSMutableDictionary *plist = [[NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListMutableContainersAndLeaves
                      format:nil
                       error:&readErr] mutableCopy];
    if (!plist) { if (outError) *outError = readErr; return NO; }

    id previous = [NSPropertyListSerialization
        propertyListWithData:saved options:NSPropertyListImmutable format:nil error:nil];
    if (!previous) return YES;

    NSMutableDictionary *allSpaces = [plist[@"AllSpacesAndDisplays"] mutableCopy];
    if (!allSpaces || !allSpaces[@"Idle"]) return YES;
    NSMutableDictionary *idle    = [allSpaces[@"Idle"] mutableCopy];
    NSMutableDictionary *content = [idle[@"Content"]   mutableCopy] ?: [NSMutableDictionary dictionary];
    content[@"Choices"]           = previous;
    idle[@"Content"]              = content;
    allSpaces[@"Idle"]            = idle;
    plist[@"AllSpacesAndDisplays"] = allSpaces;

    NSData *out = [NSPropertyListSerialization
        dataWithPropertyList:plist
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:outError];
    if (!out) return NO;
    return [out writeToFile:path options:NSDataWritingAtomic error:outError];
}

- (void)performPrivilegedSetupWithVideoPath:(NSString *)videoPath
                                 completion:(void(^)(NSError * _Nullable))completion {
    NSString *home      = NSHomeDirectory();
    NSString *cacheDir  = [home stringByAppendingPathComponent:
                            @"Library/Caches/com.thusvill.LiveWallpaper/lockscreen"];
    NSString *cachePath = [cacheDir stringByAppendingPathComponent:@"current.mov"];
    NSString *sysDir    = @"/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS";
    NSString *sysSlot   = [sysDir stringByAppendingPathComponent:@"lw_slot.mov"];
    NSString *entries   = @"/Library/Application Support/com.apple.idleassetsd/Customer/entries.json";

    // Bash + Python3 script: creates cache dir, system dir, system slot symlink,
    // and patches entries.json idempotently (checks shotID before appending).
    NSString *bash = [NSString stringWithFormat:
        @"#!/bin/bash\n"
         "set -e\n"
         "mkdir -p '%@'\n"
         "mkdir -p '%@'\n"
         "ln -sf '%@' '%@'\n"
         "python3 << 'PYEOF'\n"
         "import json, sys\n"
         "path = '%@'\n"
         "try:\n"
         "    with open(path, 'r') as f: data = json.load(f)\n"
         "except Exception: data = []\n"
         "if not isinstance(data, list): data = [data]\n"
         "if any(e.get('shotID') == 'livewallpaper_custom_001' for e in data): sys.exit(0)\n"
         "sample = data[0] if data else {}\n"
         "url_key = next((k for k in sample if '4K' in k and 'SDR' in k), 'url-4K-SDR-240FPS')\n"
         "data.append({'shotID': 'livewallpaper_custom_001', 'localizedNameKey': 'LiveWallpaper Custom', url_key: '4KSDR240FPS/lw_slot.mov', 'previewImage': 'snapshots/lw_slot_preview.png'})\n"
         "with open(path, 'w') as f: json.dump(data, f, indent=2)\n"
         "PYEOF\n",
        cacheDir, sysDir, cachePath, sysSlot, entries];

    NSString *scriptPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"lw_lockscreen_setup.sh"];
    NSError *writeErr;
    [bash writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
    if (writeErr) { completion(writeErr); return; }

    // NSAppleScript must run on main thread; dispatch so the caller doesn't block the UI.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *src = [NSString stringWithFormat:
            @"do shell script \"bash '%@'\" with administrator privileges", scriptPath];
        NSAppleScript *as = [[NSAppleScript alloc] initWithSource:src];
        NSDictionary *errDict;
        [as executeAndReturnError:&errDict];
        [[NSFileManager defaultManager] removeItemAtPath:scriptPath error:nil];

        if (errDict) {
            NSInteger code = [errDict[NSAppleScriptErrorNumber] integerValue];
            NSString *msg  = errDict[NSAppleScriptErrorMessage] ?: @"Privileged setup failed";
            NSError *err   = [NSError errorWithDomain:@"LockScreenAerialManager"
                code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
            completion(err);
            return;
        }

        if (videoPath.length > 0) [self updateUserSymlink:videoPath];
        completion(nil);
    });
}

@end
