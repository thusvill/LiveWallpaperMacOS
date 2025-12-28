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
import AVFoundation
import UniformTypeIdentifiers
import Combine
import AppKit



// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @State private var showSettings = false
    @StateObject private var displayManager = DisplayManager()
    
    
    @Environment(\.dismiss) private var dismiss
        static var didCloseOnLaunch = false


    var body: some View {
        VStack(spacing: 0) {
//            HStack {
//                            Image(systemName: "play.circle")
//                            Text("LiveWallpaper Settings")
//                                .font(.headline)
//                            Spacer()
//                            Button(action: {
//                                NSApp.mainWindow?.orderOut(nil)
//                            }) {
//                                Image(systemName: "xmark.circle.fill")
//                            }
//                            .buttonStyle(BorderlessButtonStyle())
//                            .glassEffect(.clear.tint(.red))
//                            .font(Font.system(size: 15, weight: .bold, design: .default))
//                        }
//                        .padding()
//                        .glassEffect(.regular, in: .rect(cornerRadius: 1))
//                        
//                        Divider()
            Spacer(minLength: 20)
            
            // Top toolbar
            ToolbarView(
                showSettings: $showSettings,
                onReload: { viewModel.reloadContent() }
            )
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 12)

            
            ZStack(alignment: .bottom) {
                
                VideoGridView(
                    videos: viewModel.videos,
                    viewModel: viewModel,
                    onVideoSelect: { video in
                        viewModel.startWallpaper(video: video, displays: Array(displayManager.selectedDisplays))
                    }
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                
                DisplayDockView(
                    displays: displayManager.displays,
                    selectedDisplays: $displayManager.selectedDisplays
                        )
                        
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.all)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .frame(minWidth: 600, minHeight: 250)
        
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadDisplays()
            viewModel.reloadContent()
            
            if (!Self.didCloseOnLaunch && !(sharedEngine?.isFirstLaunch())!) {
                                Self.didCloseOnLaunch = true
                                dismiss()
                            }
            
            
        }
        
    }
}


// MARK: - Toolbar View
struct ToolbarView: View {
    @Binding var showSettings: Bool
    let onReload: () -> Void
    
    var body: some View {
        HStack {
            Spacer()
            
            Button(action: onReload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
            }
            .buttonStyle(.glass)
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .font(.system(size: 16))
            }
            .buttonStyle(.glass)
        }
    }
}

// MARK: - Video Grid View
struct VideoGridView: View {
    let videos: [VideoItem]
    let viewModel: WallpaperViewModel
    let onVideoSelect: (VideoItem) -> Void
    
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 2)]
    
    var body: some View {
        ScrollView {
            if videos.isEmpty {
                Button {
                    
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.title = "Select Wallpaper Folder"
                    panel.prompt = "Choose"
                    
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.folderPath = url.path
                        sharedEngine?.selctFolder(url.path())
                        viewModel.reloadContent()
                    }
                    
                } label: {
                    Text("Select a wallpaper folder")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(videos) { video in
                        VideoThumbnailButton(video: video) {
                            onVideoSelect(video)
                        }
                        .id(video.id)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: columns)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
    }
        
}


// MARK: - Video Thumbnail Button
struct VideoThumbnailButton: View {
    let video: VideoItem
    let action: () -> Void
    @ObservedObject private var cache = ThumbnailCache.shared
    
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                
                let _ = cache.lastUpdate
                
                if let thumbnail = video.loadThumbnail() {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 140)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 140)
                        .overlay {
                            VStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Generating...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                }
                
                if let quality = video.quality, !quality.isEmpty {
                    QualityBadge(text: quality)
                        .padding(8)
                }
            }
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .padding(2)
        .help(video.filename)
    }
}

// MARK: - Quality Badge
struct QualityBadge: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.black, lineWidth: 1)
            )
    }
}
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayObjc] = []
    @Published var selectedDisplays: Set<UInt32> = []

    init() {
        sharedEngine?.scanDisplays()
        updateDisplays()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func updateDisplays() {
        
        sharedEngine?.scanDisplays()
        
        DispatchQueue.main.async { [weak self] in
                    self?.displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
                }
        
        
        
    }
}

private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: UInt32,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.updateDisplays()
        manager.selectedDisplays.removeAll()
        
    }
    
}


// MARK: - Display Dock View
struct DisplayDockView: View {
    let displays: [DisplayObjc]
    @Binding var selectedDisplays: Set<UInt32>
    @Namespace private var namespace
    
    var body: some View {
        GlassEffectContainer(spacing: 10.0) {
            HStack(spacing: 10) {
                ForEach(displays, id: \.screen) { display in
                    DisplayButton(
                        display: display,
                        isSelected: selectedDisplays.contains(display.screen)
                    ) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if selectedDisplays.contains(display.screen) {
                                selectedDisplays.remove(display.screen)
                            } else {
                                selectedDisplays.insert(display.screen)
                            }
                        }
                    }
                    .matchedGeometryEffect(id: display.screen, in: namespace)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: displays.map { $0.screen })
        }
    }
}

// MARK: - Display Button
struct DisplayButton: View {
    let display: DisplayObjc
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Spacer()

                Text(display.getDisplayName())
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)

                Text(display.getResolution())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .frame(width: 200, height: 80)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .glassEffect(
                .clear.interactive(),
                in: .rect(cornerRadius: isSelected ? 26 : 20, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: 26,
                        style: .continuous
                    )
                    .stroke(Color.yellow, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .shadow(
            color: isSelected
                ? Color.yellow.opacity(0.45)
                : Color.black.opacity(0.15),
            radius: isSelected ? 20 : 10,
            y: 8
        )
        .animation(
            .spring(
                response: 0.45,
                dampingFraction: 0.75
            ),
            value: isSelected
        )
    }
    
}


// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: {
                                                dismiss()
                                            }) {
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                            .glassEffect(.clear.tint(.red))
                                                                       .font(Font.system(size: 16, weight: .bold, design: .default))
                
            }
            
            .padding(.bottom, 8)
            
            ScrollView {
                VStack(alignment: .leading, spacing:20) {
                    // Folder Selection
                    SettingRow(title: "Wallpaper Folder") {
                        HStack {
                            TextField("Select folder or type path", text: $viewModel.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            
                            Button("Select Folder 📁") {
                                selectFolder()
                            }
                            
                            Button("Show in Finder 🗂") {
                                openInFinder()
                            }
                        }
                    }
                    
                    Divider()
                    
                    //Scale mode
                    SettingRow(title: "Video Scaling Mode") {
                        Picker("", selection: Binding(
                            get: {
                                let mode = UserDefaults.standard.integer(forKey: "scale_mode")
                                switch mode {
                                case 0: return "fill"
                                case 1: return "fit"
                                case 2: return "stretch"
                                case 3: return "center"
                                case 4: return "height-fill"
                                default: return "fill"
                                }
                            },
                            set: { newValue in
                                let intValue: Int
                                switch newValue {
                                case "fill": intValue = 0
                                case "fit": intValue = 1
                                case "stretch": intValue = 2
                                case "center": intValue = 3
                                case "height-fill": intValue = 4
                                default: intValue = 0
                                }
                                UserDefaults.standard.set(intValue, forKey: "scale_mode")
                            }
                        )) {
                            Text("Fill").tag("fill")
                            Text("Fit").tag("fit")
                            Text("Stretch").tag("stretch")
                            Text("Center").tag("center")
                            Text("HeightFill").tag("height-fill")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                    
                    Divider()
                    
                    // Random Wallpaper on Startup
                    SettingRow(title: "Random Wallpaper on Startup") {
                        Toggle("", isOn: Binding(
                                get: { UserDefaults.standard.bool(forKey: "random") },
                                set: { UserDefaults.standard.set($0, forKey: "random") }
                            ))
                            .toggleStyle(.switch)

                            
                    }
                    
                    // Random Wallpaper on Weakup
                    SettingRow(title: "Random Wallpaper on Lid Weakup (Required Application Restart)") {
                        Toggle("", isOn: Binding(
                                get: { UserDefaults.standard.bool(forKey: "random_lid") },
                                set: { UserDefaults.standard.set($0, forKey: "random_lid") }
                            ))
                            .toggleStyle(.switch)

                            
                    }
                    
                    // Auto-Pause When App is Active
                    SettingRow(title: "Pause When App is Active") {
                        Toggle("", isOn: Binding(
                                get: { UserDefaults.standard.bool(forKey: "pauseOnAppFocus") },
                                set: { UserDefaults.standard.set($0, forKey: "pauseOnAppFocus") }
                            ))
                            .toggleStyle(.switch)
                    }
                    
                    Divider()
                    
                    // Video Volume
                    SettingRow(title: "Video Volume") {
                        HStack {
                            Slider(value: $viewModel.volume, in: 0...100, step: 1)
                                .frame(width: 200)
                                .onChange(of: viewModel.volume) { newValue in
                                    sharedEngine?.updateVolume(newValue)
                                }
                                
                            
                            Text("\(Int(viewModel.volume))%")
                                .frame(width: 60, alignment: .leading)
                                .monospacedDigit()
                        }
                    }
                    
                    Divider()
                    
                    // Optimize Videos
                    SettingRow(title: "Optimize Video Codecs") {
                        Button("Optimize 🛠️") {
                            viewModel.optimizeVideos()
                        }
                        .disabled(true) // Match original
                    }
                    
                    // Clear Cache
                    SettingRow(title: "Clear Cache") {
                        Button("Clear Cache 🗑️") {
                            viewModel.clearCache()
                        }
                    }
                    
                    // Reset User Data
                    SettingRow(title: "Reset UserData") {
                        Button("Reset") {
                            viewModel.resetUserData()
                        }
                    }
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .background(.ultraThinMaterial)
        .glassEffect(.regular, in: .rect(cornerRadius: 1))
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Wallpaper Folder"
        panel.prompt = "Choose"
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.folderPath = url.path
            sharedEngine?.selctFolder(url.path())
            viewModel.reloadContent()
        }
    }
    
    private func openInFinder() {
        if let url = URL(string: "file://\(viewModel.folderPath)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Setting Row
struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack {
            Text(title)
                .frame(width: 200, alignment: .leading)
            content
            Spacer()
        }
    }
}

struct VideoItem: Identifiable {
    let id = UUID()
    let filename: String
    let path: String
    let thumbnailPath: String
    var quality: String?
    
    func loadThumbnail() -> NSImage? {
        return ThumbnailCache.shared.image(for: thumbnailPath)
    }
}
class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    @Published var lastUpdate = Date()
    
    private init() {
        cache.countLimit = 100
        
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thumbnailSaved(_:)),
            name: NSNotification.Name("ThumbnailSaved"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thumbnailsGenerated),
            name: NSNotification.Name("ThumbnailsGenerated"),
            object: nil
        )
    }
    
    @objc private func thumbnailSaved(_ notification: Notification) {
        if let path = notification.userInfo?["path"] as? String {
            
            cache.removeObject(forKey: path as NSString)
        }
        DispatchQueue.main.async {
            self.lastUpdate = Date()
        }
    }
    
    @objc private func thumbnailsGenerated() {
        
        cache.removeAllObjects()
        DispatchQueue.main.async {
            self.lastUpdate = Date()
        }
    }
    
    func image(for path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        
        guard FileManager.default.fileExists(atPath: path),
              let img = NSImage(contentsOfFile: path) else {
            return nil
        }
        
        cache.setObject(img, forKey: path as NSString)
        return img
    }
    
    func clearCache() {
        cache.removeAllObjects()
        lastUpdate = Date()
    }
}





class WallpaperViewModel: ObservableObject {

    @Published var videos: [VideoItem] = []
    @Published var displays: [DisplayObjc] = []
    @Published var folderPath: String = ""
    @Published var scaleMode: String = "fill"
    @Published var randomOnStartup: Bool = false
    @Published var pauseOnAppFocus: Bool = true
    @Published var volume: Double = 50.0
    private var currentReloadID = UUID()

    private let defaults = UserDefaults.standard
    let engine: WallpaperEngine

    init(engine: WallpaperEngine = sharedEngine ?? WallpaperEngine.shared()) {
        self.engine = engine
        loadSettings()
        self.engine.setupNotifications()
    }

    deinit {
        engine.removeNotifications()
    }

    func loadSettings() {
        folderPath = engine.getFolderPath()
        scaleMode = defaults.string(forKey: "scale_mode") ?? "fill"
        randomOnStartup = defaults.bool(forKey: "random")
        pauseOnAppFocus = defaults.bool(forKey: "pauseOnAppFocus")
        volume = Double(defaults.float(forKey: "wallpapervolumeprecentage"))
    }
    
    func reloadContent() {
        engine.checkFolderPath()
        
        // Clear thumbnail cache to force fresh load
        ThumbnailCache.shared.clearCache()
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath) else { return }

        let videoFiles = files.filter { f in
            let e = (f as NSString).pathExtension.lowercased()
            return e == "mp4" || e == "mov"
        }

        let reloadID = UUID()
        currentReloadID = reloadID

        DispatchQueue.global(qos: .userInitiated).async {
            let newVideos: [VideoItem] = videoFiles.map { f in
                let full = (self.folderPath as NSString).appendingPathComponent(f)
                let base = (f as NSString).deletingPathExtension
                let thumbPath = (self.engine.thumbnailCachePath() as NSString?)?.appendingPathComponent("\(base).png") ?? ""
                
                var item = VideoItem(filename: f, path: full, thumbnailPath: thumbPath)
                
//                item.quality = self.engine.videoQualityBadge(for: URL(fileURLWithPath: full))
                self.engine.videoQualityBadge(for: URL(fileURLWithPath: full)){badge in item.quality = badge}
                return item
            }

            DispatchQueue.main.async {
                if reloadID == self.currentReloadID {
                    self.videos = newVideos
                    
                    // Check if any thumbnails are missing and generate once
                    let missingThumbnails = newVideos.filter { $0.loadThumbnail() == nil }
                    if !missingThumbnails.isEmpty {
                        NSLog("Found \(missingThumbnails.count) videos without thumbnails, generating...")
                        self.engine.generateThumbnails()
                    }
                }
            }
        }
    }

    func loadDisplays() {
        displays = sharedEngine?.getDisplays() as! [DisplayObjc]
    }

    func startWallpaper(video: VideoItem, displays: [UInt32]) {
        let arr = displays.map { NSNumber(value: $0) }
        engine.startWallpaper(withPath: video.path, onDisplays: arr)
    }

    func clearCache() {
        engine.clearCache()
        ThumbnailCache.shared.clearCache()
        reloadContent()
    }

    func resetUserData() {
        engine.resetUserData()
        loadSettings()
        reloadContent()
    }

    func optimizeVideos() {
        engine.generateStaticWallpapers(forFolder: folderPath) {}
    }

    private func getDisplayName(for id: CGDirectDisplayID) -> String {
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == id {
                return s.localizedName
            }
        }
        return "Display \(id)"
    }
}


#Preview {
    ContentView()
    SettingsView(viewModel: WallpaperViewModel())
}


