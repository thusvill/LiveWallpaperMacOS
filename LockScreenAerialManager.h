#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LockScreenAerialManager : NSObject

+ (instancetype)shared;

/// YES after privileged setup has created the system-level symlink slot.
@property (nonatomic, readonly) BOOL isSystemSlotInstalled;

/// Absolute path: ~/Library/Caches/com.thusvill.LiveWallpaper/lockscreen/current.mov
@property (nonatomic, readonly) NSString *userCachePath;

/// YES for .mov (always); for .mp4 only if codec is H.264 or HEVC.
- (BOOL)isVideoCodecSupported:(NSString *)videoPath;

/// Creates/replaces user-level symlink at userCachePath → videoPath. No admin required.
- (void)updateUserSymlink:(NSString *)videoPath;

/// Writes Index.plist to select livewallpaper_custom_001 as active lock screen asset.
- (BOOL)writeIndexPlist:(NSError **)error;

/// Reverts Index.plist to value saved before writeIndexPlist was first called.
- (BOOL)revertIndexPlist:(NSError **)error;

/// Admin-required: creates system slot symlink + patches entries.json via NSAppleScript.
/// Calls updateUserSymlink: after success. Completion always fires on main thread.
- (void)performPrivilegedSetupWithVideoPath:(NSString *)videoPath
                                 completion:(void(^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
