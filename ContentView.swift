//
//  ContentView.swift
//  LiveWallpaper
//
//  Created by mac on 2025-12-11.
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine



// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @State private var showSettings = false
    @State private var selectedDisplays: Set<UInt32> = []

    var body: some View {
        VStack(spacing: 0) {
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
                    onVideoSelect: { video in
                        viewModel.startWallpaper(video: video, displays: Array(selectedDisplays))
                    }
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                
                DisplayDockView(
                    displays: viewModel.displays,
                    selectedDisplays: $selectedDisplays
                )
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .frame(minWidth: 600, minHeight: 250)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadDisplays()
            viewModel.reloadContent()
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
            .buttonStyle(.borderless)
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Video Grid View
struct VideoGridView: View {
    let videos: [VideoItem]
    let onVideoSelect: (VideoItem) -> Void
    
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 2)]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(videos) { video in
                    VideoThumbnailButton(video: video) {
                        onVideoSelect(video)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            
        }
       
    }
        
}


// MARK: - Video Thumbnail Button
struct VideoThumbnailButton: View {
    let video: VideoItem
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
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
                            ProgressView()
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

// MARK: - Display Dock View
struct DisplayDockView: View {
    let displays: [DisplayInfo]
    @Binding var selectedDisplays: Set<UInt32>
    
    var body: some View {
        
            HStack(spacing: 8) {
                ForEach(displays) { display in
                    DisplayButton(
                        display: display,
                        isSelected: selectedDisplays.contains(display.id)
                    ) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if selectedDisplays.contains(display.id) {
                                selectedDisplays.remove(display.id)
                            } else {
                                selectedDisplays.insert(display.id)
                            }
                        }
                    }
                }

            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                    Color.clear
            )
        
    }
}

// MARK: - Display Button
struct DisplayButton: View {
    let display: DisplayInfo
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Spacer()
                
                Text(display.name)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                
                Text(display.resolution)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .foregroundColor(.primary)
            .frame(width: 200, height: 80)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.yellow : Color.white.opacity(0.4),
                        lineWidth: isSelected ? 2.5 : 1.5
                    )
            )
            .shadow(
                color: isSelected ? .yellow.opacity(4) : .clear,
                radius: 20
            )
            .animation(.easeInOut(duration: 0.25), value: isSelected)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
                Button("Done") {
                    dismiss()
                }
            }
            .padding(.bottom, 8)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                    
                    // Video Scaling Mode
                    SettingRow(title: "Video Scaling Mode") {
                        Picker("", selection: $viewModel.scaleMode) {
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
                        Toggle("", isOn: $viewModel.randomOnStartup)
                            .toggleStyle(.switch)
                    }
                    
                    // Auto-Pause When App is Active
                    SettingRow(title: "Pause When App is Active") {
                        Toggle("", isOn: $viewModel.pauseOnAppFocus)
                            .toggleStyle(.switch)
                    }
                    
                    Divider()
                    
                    // Video Volume
                    SettingRow(title: "Video Volume") {
                        HStack {
                            Slider(value: $viewModel.volume, in: 0...100, step: 1)
                                .frame(width: 200)
                            
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

class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    
    private init() {
        cache.countLimit = 50 // keep only 50 thumbnails in memory
    }
    
    func image(for path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}






struct DisplayInfo: Identifiable {
    let id: UInt32
    let name: String
    let resolution: String
}

class WallpaperViewModel: ObservableObject {

    @Published var videos: [VideoItem] = []
    @Published var displays: [DisplayInfo] = []
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
                item.quality = self.engine.videoQualityBadge(for: URL(fileURLWithPath: full))
                return item
            }

            DispatchQueue.main.async {
                if reloadID == self.currentReloadID {
                    self.videos = newVideos
                }
            }
        }
    }

    func loadDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)

        displays = (0..<Int(count)).map { i in
            let id = ids[i]
            let w = CGDisplayPixelsWide(id)
            let h = CGDisplayPixelsHigh(id)
            let name = getDisplayName(for: id)
            return DisplayInfo(id: id, name: name, resolution: "\(w)x\(h)")
        }
    }

    func startWallpaper(video: VideoItem, displays: [UInt32]) {
        let arr = displays.map { NSNumber(value: $0) }
        
        engine.startWallpaper(withPath: video.path, onDisplays: arr)
    }

    func clearCache() {
        engine.clearCache()
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
}


