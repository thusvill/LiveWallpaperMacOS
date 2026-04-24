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

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LockScreenAerialManager : NSObject

+ (instancetype)shared;

/// YES after privileged setup has created the system-level symlink slot.
@property (nonatomic, readonly) BOOL isSystemSlotInstalled;

/// YES if entries.json already contains the custom asset UUID (readable without admin).
@property (nonatomic, readonly) BOOL isEntriesJsonPatched;

/// Absolute path: ~/Library/Caches/com.thusvill.LiveWallpaper/lockscreen/current.mov
@property (nonatomic, readonly) NSString *userCachePath;

/// YES for .mov (always); for .mp4 only if codec is H.264 or HEVC.
- (BOOL)isVideoCodecSupported:(NSString *)videoPath;

/// Creates/replaces user-level symlink at userCachePath → videoPath. No admin required.
- (void)updateUserSymlink:(NSString *)videoPath;

/// Writes Index.plist to select livewallpaper_custom_001 as active lock screen asset.
/// NS_SWIFT_NOTHROW: not imported as throws; pass nil to ignore errors.
- (BOOL)writeIndexPlist:(NSError * _Nullable * _Nullable)error NS_SWIFT_NOTHROW;

/// Reverts Index.plist to value saved before writeIndexPlist was first called.
/// NS_SWIFT_NOTHROW: not imported as throws; pass nil to ignore errors.
- (BOOL)revertIndexPlist:(NSError * _Nullable * _Nullable)error NS_SWIFT_NOTHROW;

/// Admin-required: creates system slot symlink + patches entries.json via NSAppleScript.
/// Calls updateUserSymlink: after success. Completion always fires on main thread.
- (void)performPrivilegedSetupWithVideoPath:(NSString *)videoPath
                                 completion:(void(^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
