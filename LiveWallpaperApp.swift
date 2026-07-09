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

import SwiftUI
import Darwin
import AppKit
import ApplicationServices
import ServiceManagement

let sharedEngine = WallpaperEngine.shared()


// MARK: - Single instance (one menu-bar icon)

/// Exclusive flock so Login Items + LaunchAgents cannot both own a status item.
enum LiveWallpaperSingleInstance {
    private static var lockFD: Int32 = -1
    private static let lockRelativePath =
        "Library/Application Support/LiveWallpaper/instance.lock"

    /// - Returns: true if this process is the sole owner.
    /// Secondary launches exit silently (do not ask primary to show its window —
    /// that caused the config window to pop open on every KeepAlive restart).
    @discardableResult
    static func tryBecomePrimary() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier {
            let peers = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == bundleID
                    && $0.processIdentifier != myPID
                    && !$0.isTerminated
            }
            if !peers.isEmpty {
                return false
            }
        }

        let lockPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(lockRelativePath)
        let dir = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if fd < 0 {
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let pidStr = "\(myPID)\n"
        _ = pidStr.withCString { write(fd, $0, strlen($0)) }
        lockFD = fd
        return true
    }

    static func release() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }
}

@main
struct LiveWallpaperApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
            Settings { EmptyView() }
    }
        
}


class AppDelegate: NSObject, NSApplicationDelegate {
    private var isPrimaryInstance = false

    var statusItem: NSStatusItem?
    var window: NSWindow!
    
    let engine = sharedEngine

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !LiveWallpaperSingleInstance.tryBecomePrimary() {
            isPrimaryInstance = false
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        isPrimaryInstance = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimaryInstance else { return }

        
        NSApp.setActivationPolicy(.accessory)

        
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: "Live Wallpaper")
        }

        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("Show window", comment: ""), action: #selector(showWindow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Hide window", comment: ""), action: #selector(hideWindow), keyEquivalent: "h"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: ""), action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        // Create main window with ContentView
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView,.borderless],
            backing: .buffered,
            defer: false
        )
        //hide titlebar
        //window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        
        window.center()
        window.contentView = NSHostingView(rootView: ContentView())
        window.title = "LiveWallpaper"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        
        if !hasAccessibilityAccess() {
            requestAccessibilityAccess()
        }

        
        if !isLoginItemEnabled() {
            setLoginItem(enabled: true)
        }
        

        
    }

    // Show the config window
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
    }

    // Hide the window without quitting the app
    @objc func hideWindow() {
        window.orderOut(nil)
    }

    // Quit the app completely
    func applicationWillTerminate(_ notification: Notification) {
        if isPrimaryInstance {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            LiveWallpaperSingleInstance.release()
        }
    }

    @objc func quit() {
        engine?.terminateApplication()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        LiveWallpaperSingleInstance.release()
        NSApp.terminate(nil)
    }
}

// MARK: Permission Access

func hasAccessibilityAccess() -> Bool {
    return AXIsProcessTrusted()
}

func requestAccessibilityAccess() {
    let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
    AXIsProcessTrustedWithOptions(options as CFDictionary)
}

func isLoginItemEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: UserDefaultsKeys.launchAtLogin)
}


func setLoginItem(enabled: Bool) {
    guard let bundleId = Bundle.main.bundleIdentifier else { return }

    if SMLoginItemSetEnabled(bundleId as CFString, enabled) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.launchAtLogin)
    } else {
        print("❌ Failed to update login items")
    }
}

