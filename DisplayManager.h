#pragma once

#include <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <algorithm>
#include <errno.h>
#include <list>
#include <set>
#include <signal.h>
#include <unistd.h>

bool KillProcessByPID(pid_t pid) {
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

  // Build a set of currently connected display IDs
  std::set<CGDirectDisplayID> currentDisplayIDs;
  for (NSScreen *screen in screens) {
    NSDictionary *desc = [screen deviceDescription];
    NSNumber *screenNum = desc[@"NSScreenNumber"];
    CGDirectDisplayID displayID = [screenNum unsignedIntValue];
    currentDisplayIDs.insert(displayID);
  }

  // Remove any displays that are no longer connected
  for (auto it = displays.begin(); it != displays.end();) {
    if (currentDisplayIDs.find(it->screen) == currentDisplayIDs.end()) {
      it = displays.erase(it);
    } else {
      ++it;
    }
  }

  // Add new displays that are not in the list
  for (CGDirectDisplayID displayID : currentDisplayIDs) {
    if (std::find_if(displays.begin(), displays.end(), [&](const Display &d) {
          return d.screen == displayID;
        }) == displays.end()) {
      Display disp;
      disp.screen = displayID;
      displays.push_back(disp);
    }
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

NSString *displayNameForDisplayID(CGDirectDisplayID displayID) {
  for (NSScreen *screen in [NSScreen screens]) {
    NSDictionary *desc = [screen deviceDescription];
    NSNumber *screenNum = desc[@"NSScreenNumber"];
    if ([screenNum unsignedIntValue] == displayID) {
      // Get localized name (if available)
      NSString *name = desc[@"NSDeviceName"];
      if (name.length > 0)
        return name;

      // fallback
      return [NSString stringWithFormat:@"Display %u", displayID];
    }
  }
  return [NSString stringWithFormat:@"Display %u", displayID];
}
