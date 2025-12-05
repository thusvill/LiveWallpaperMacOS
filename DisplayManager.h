#pragma once

#include <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <algorithm>
#include <dlfcn.h>
#include <errno.h>
#include <list>
#include <set>
#include <signal.h>
#include <unistd.h>
#include <unordered_set>

// typedef for private function
typedef CFDictionaryRef (*CoreDisplayInfoFnType)(CGDirectDisplayID);

static CoreDisplayInfoFnType GetCoreDisplayInfoFn(void) {
  static CoreDisplayInfoFnType fn = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    void *h =
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
               RTLD_LAZY | RTLD_LOCAL);
    if (h)
      fn = (CoreDisplayInfoFnType)dlsym(
          h, "CoreDisplay_DisplayCreateInfoDictionary");
  });
  return fn;
}

static inline NSString *displayNameForDisplayID(CGDirectDisplayID did) {
  // Ensure main thread because we'll touch AppKit/NSScreen and ObjC objects
  if (!NSThread.isMainThread) {
    __block NSString *name = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      name = displayNameForDisplayID(did);
    });
    return name;
  }

  if (did == kCGNullDirectDisplay)
    return @"Display (unknown)";

  // 1) Try CoreDisplay (private) via dlsym
  CoreDisplayInfoFnType infoFn = GetCoreDisplayInfoFn();
  if (infoFn) {
    CFDictionaryRef info = infoFn(did); // Create rule: we own this CF object
    if (info) {
      // Transfer ownership to ARC-managed NSDictionary so ARC releases it
      // safely.
      NSDictionary *dict = (__bridge_transfer NSDictionary *)info;
      // The dictionary often contains a sub-dictionary 'DisplayProductName'
      // which itself may be a dictionary of localized names; handle both
      // CFString and NSDictionary cases.
      id nameVal = dict[@"DisplayProductName"];
      if ([nameVal isKindOfClass:[NSString class]] &&
          ((NSString *)nameVal).length > 0)
        return (NSString *)nameVal;
      if ([nameVal isKindOfClass:[NSDictionary class]]) {
        // localized dictionary: pick en or first value
        NSDictionary *localNames = (NSDictionary *)nameVal;
        NSString *en = localNames[@"en_US"] ?: localNames[@"en"] ?: nil;
        if (en.length > 0)
          return en;
        // else pick any value
        for (id v in localNames.allValues) {
          if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0)
            return (NSString *)v;
        }
      }
      // if no name, let it fall through to NSScreen fallback
    }
  }

  // 2) Fallback: loop NSScreen deviceDescription (safe, returns generic name)
  for (NSScreen *screen in NSScreen.screens) {
    NSDictionary *desc = screen.deviceDescription;
    NSNumber *num = desc[@"NSScreenNumber"];
    if (!num)
      continue;
    if ((CGDirectDisplayID)num.unsignedIntValue == did) {
      NSString *n = desc[@"NSDeviceName"];
      if (n.length > 0)
        return n;
      break;
    }
  }

  // 3) Last resort: printable fallback
  return [NSString stringWithFormat:@"Display %u", did];
}

inline CGDirectDisplayID GetDisplayID(NSScreen *screen) {
  NSNumber *num = [screen deviceDescription][@"NSScreenNumber"];
  return (CGDirectDisplayID)[num unsignedIntValue];
}

inline std::string DisplayUUIDFromID(CGDirectDisplayID displayID) {
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
  if (!uuid)
    return "";

  CFStringRef cfStr = CFUUIDCreateString(NULL, uuid);
  CFRelease(uuid);

  char buffer[64];
  CFStringGetCString(cfStr, buffer, sizeof(buffer), kCFStringEncodingUTF8);
  CFRelease(cfStr);

  return std::string(buffer);
}
inline CGDirectDisplayID DisplayIDFromUUID(const std::string &uuidString) {
  if (uuidString.empty())
    return kCGNullDirectDisplay;

  CFStringRef cfStr = CFStringCreateWithCString(NULL, uuidString.c_str(),
                                                kCFStringEncodingUTF8);

  CFUUIDRef uuid = CFUUIDCreateFromString(NULL, cfStr);
  CFRelease(cfStr);

  if (!uuid)
    return kCGNullDirectDisplay;

  CGDirectDisplayID id = CGDisplayGetDisplayIDFromUUID(uuid);
  CFRelease(uuid);

  return id;
}

inline bool KillProcessByPID(pid_t pid) {
  if (pid <= 1) {

    return false;
  }

  // Try SIGTERM first
  kill(pid, SIGTERM);

  // Wait up to 1.5 seconds
  for (int i = 0; i < 15; i++) {
    if (kill(pid, 0) != 0 && errno == ESRCH) {

      return true;
    }
    usleep(100000); // 0.1s
  }

  // Force kill
  kill(pid, SIGKILL);

  for (int i = 0; i < 10; i++) {
    if (kill(pid, 0) != 0 && errno == ESRCH) {

      return true;
    }
    usleep(100000);
  }

  return false;
}

struct Display {
public:
  pid_t daemon;
  CGDirectDisplayID screen;
  std::string uuid;
  std::string videoPath;
  std::string framePath;
};

static std::list<Display> displays{};

static void PrintDisplays(const std::list<Display> &displays) {
  NSLog(@"---- Display List ----");
  for (const auto &d : displays) {
    NSString *video = [NSString stringWithUTF8String:d.videoPath.c_str()];
    NSString *frame = [NSString stringWithUTF8String:d.framePath.c_str()];

    NSLog(@"Daemon: %d | Screen: %u | Video: %@ | Frame: %@", d.daemon,
          d.screen, video, frame);
  }
  NSLog(@"----------------------");
}

static void ScanDisplays() {
  NSArray *screens = [NSScreen screens];

  std::unordered_map<std::string, CGDirectDisplayID> runtime;
  runtime.reserve([screens count]);

  for (NSScreen *screen in screens) {
    CGDirectDisplayID did = GetDisplayID(screen);
    std::string uuid = DisplayUUIDFromID(did);
    runtime[uuid] = did;
  }

  for (auto it = displays.begin(); it != displays.end();) {
    if (runtime.find(it->uuid) == runtime.end()) {
      KillProcessByPID(it->daemon);
      it = displays.erase(it);
    } else {
      ++it;
    }
  }

  std::unordered_set<std::string> existing;
  existing.reserve(displays.size());
  for (const auto &d : displays)
    existing.insert(d.uuid);

  for (const auto &pair : runtime) {
    const std::string &uuid = pair.first;
    CGDirectDisplayID did = pair.second;

    if (!existing.count(uuid)) {
      Display d;
      d.uuid = uuid;
      d.screen = did;
      displays.push_back(d);
    }
  }

  for (auto &d : displays) {
    auto it = runtime.find(d.uuid);
    d.screen = (it != runtime.end() ? it->second : kCGNullDirectDisplay);
  }
}

static void SetWallpaperDisplay(pid_t daemon_PID, CGDirectDisplayID displayID,
                                std::string videoPath, std::string framePath) {

  for (Display &display : displays) {
    if (display.screen == displayID) {

      if (display.daemon) {
        KillProcessByPID(display.daemon);
        usleep(1);
      }

      display.daemon = daemon_PID;
      display.videoPath = videoPath;
      display.framePath = framePath;
      return;
    }
  }

  Display newDisplay;
  newDisplay.screen = displayID;
  newDisplay.videoPath = videoPath;
  newDisplay.framePath = framePath;
  newDisplay.daemon = daemon_PID;
  displays.push_back(newDisplay);
}

static void waitForScreensReady(void (^completion)(void)) {
  __block int retries = 20; // ~1 second
  void (^check)(void) = ^{
    if (NSScreen.screens.count > 0 || retries-- <= 0) {
      completion();
    } else {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.05 * NSEC_PER_SEC),
                     dispatch_get_main_queue(), check);
    }
  };
  check();
}