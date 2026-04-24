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

import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Compatibility Bridge
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

extension View {
    @ViewBuilder
    func compatibleGlass(
        material: NSVisualEffectView.Material = .headerView, cornerRadius: CGFloat = 16
    ) -> some View {
        if #available(macOS 20.0, *) {
            self.background(
                VisualEffectView(material: material)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
        } else {
            self.background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - String Localization Extension
extension String {
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
}

// MARK: - Language Manager
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var currentLanguage: String {
        didSet {
            UserDefaults.standard.set(currentLanguage, forKey: UserDefaultsKeys.appLanguage)
            UserDefaults.standard.set([currentLanguage], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }

    var availableLanguages: [(code: String, name: String)] {
        [
            ("auto", "system_language".localized),
            ("zh-Hans", "简体中文"),
            ("en", "English"),
        ]
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.appLanguage) ?? "auto"
        self.currentLanguage = saved
    }

    func localizedString(_ key: String) -> String {
        let language =
            currentLanguage == "auto" ? Locale.preferredLanguages.first ?? "en" : currentLanguage
        guard
            let path = Bundle.main.path(forResource: language, ofType: "lproj")
                ?? Bundle.main.path(
                    forResource: language.components(separatedBy: "-").first, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, comment: "")
        }
        return NSLocalizedString(key, tableName: nil, bundle: bundle, comment: "")
    }
}

// MARK: - Localization
enum L {
    static let selectWallpaperFolder = NSLocalizedString("📁", comment: "")
    static let generating = NSLocalizedString("Generating...", comment: "")
    static let settings = NSLocalizedString("Settings", comment: "")
    static let wallpaperFolder = NSLocalizedString("Wallpaper folder", comment: "")
    static let selectFolderEmoji = NSLocalizedString("📁", comment: "")
    static let showInFinder = NSLocalizedString("📂", comment: "")
    static let videoScalingMode = NSLocalizedString("Video scaling mode", comment: "")
    static let scaleFill = NSLocalizedString("Scale fill", comment: "")
    static let scaleFit = NSLocalizedString("Scale fit", comment: "")
    static let scaleStretch = NSLocalizedString("Scale stretch", comment: "")
    static let scaleCenter = NSLocalizedString("Scale center", comment: "")
    static let scaleHeightFill = NSLocalizedString("Scale height fill", comment: "")
    static let randomOnStartup = NSLocalizedString("Random on startup", comment: "")
    static let randomOnLid = NSLocalizedString("Random on lid", comment: "")
    static let pauseWhenActive = NSLocalizedString("Pause when active", comment: "")
    static let videoVolume = NSLocalizedString("Video volume", comment: "")
    static let optimizeCodecs = NSLocalizedString("Optimize codecs", comment: "")
    static let optimize = NSLocalizedString("Optimize", comment: "")
    static let clearCache = NSLocalizedString("Clear cache", comment: "")
    static let clearCacheButton = NSLocalizedString("Clear cache", comment: "")
    static let resetUserData = NSLocalizedString("Reset userdata", comment: "")
    static let reset = NSLocalizedString("Reset", comment: "")
    static let selectFolderTitle = NSLocalizedString("Select folder title", comment: "")
    static let choose = NSLocalizedString("Choose", comment: "")
    static let selectFolderOrType = NSLocalizedString("Select folder or type", comment: "")
    static let wallpaperRotation = NSLocalizedString("Wallpaper rotation", comment: "")
    static let rotationType = NSLocalizedString("Wallpaper rotation type", comment: "")
    static let vinttageBar = NSLocalizedString(
        "Vignette bar (Reapply the wallpaper after change)", comment: "")

    static let rotationDelay = NSLocalizedString("Wallpaper rotation delay", comment: "")
    static let lockScreenVideo = NSLocalizedString("lock_screen_video", comment: "")
    static let lockScreenVideoSubtitle = NSLocalizedString("lock_screen_video_subtitle", comment: "")
}

// MARK: - UserDefaults Keys
enum UserDefaultsKeys {
    static let wallpaperFolder = "WallpaperFolder"
    static let scaleMode = "scale_mode"
    static let randomOnStartup = "random"
    static let randomOnLid = "random_lid"
    static let pauseOnAppFocus = "pauseOnAppFocus"
    static let volumePercentage = "wallpapervolumeprecentage"
    static let launchAtLogin = "LaunchAtLogin"
    static let appLanguage = "app_language"
    static let vignetteBar = "vinttage_bar"
    static let rotation = "rotation"
    static let rdelay = "rdelay"
    static let rtype = "rtype"
    static let lockScreenVideo = "lockscreenVideoEnabled"

}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @State private var showSettings = false
    @StateObject private var displayManager = DisplayManager()

    @Environment(\.dismiss) private var dismiss
    static var didCloseOnLaunch = false

    var body: some View {

        ZStack {

            VStack(spacing: 0) {
                Spacer(minLength: 20)
                ToolbarView(showSettings: $showSettings, onReload: { viewModel.reloadContent() })
                    .padding(.horizontal).padding(.top, 24).padding(.bottom, 12)

                ZStack(alignment: .bottom) {
                    VideoGridView(
                        videos: viewModel.videos, viewModel: viewModel,
                        onVideoSelect: { video in
                            viewModel.startWallpaper(
                                video: video, displays: Array(displayManager.selectedDisplays))
                        }
                    )
                    .padding(.horizontal, 24).padding(.bottom, 24)

                    DisplayDockView(
                        displays: displayManager.displays,
                        selectedDisplays: $displayManager.selectedDisplays
                    )
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            .ignoresSafeArea(.all)
            .compatibleGlass(cornerRadius: 16)
            .frame(minWidth: 600, minHeight: 250)
            //.sheet(isPresented: $showSettings) { SettingsView(viewModel: viewModel) }
            .onAppear {
                viewModel.loadDisplays()
                viewModel.reloadContent()
                if !Self.didCloseOnLaunch, let engine = sharedEngine, !engine.isFirstLaunch() {
                    Self.didCloseOnLaunch = true
                    dismiss()
                }
            }

            if showSettings {

                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showSettings = false

                    }

                SettingsView(viewModel: viewModel)
                    .shadow(radius: 3)
                    .cornerRadius(15)
                    .onTapGesture {}
                    .animation(.easeInOut, value: showSettings)
            }

        }.animation(.easeInOut, value: showSettings)
    }
}

// MARK: - Toolbar View
struct ToolbarView: View {
    @Binding var showSettings: Bool
    let onReload: () -> Void

    var body: some View {
        HStack {
            Spacer()

            if #available(macOS 26.0, *) {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
                .buttonStyle(.glass)
            } else {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
            }

            if #available(macOS 26.0, *) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
                .buttonStyle(.glass)
            } else {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
            }
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
                    panel.title = L.selectFolderTitle
                    panel.prompt = L.choose

                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.folderPath = url.path
                        sharedEngine?.selectFolder(url.path())
                        viewModel.reloadContent()
                    }
                } label: {
                    Text(L.selectWallpaperFolder)
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
                        .aspectRatio(16 / 9, contentMode: .fill)
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
                                Text(L.generating)
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

// MARK: - Display Manager
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayObjc] = []
    @Published var selectedDisplays: Set<UInt32> = []

    init() {
        sharedEngine?.scanDisplays()
        updateDisplays()
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func updateDisplays() {
        sharedEngine?.scanDisplays()
        DispatchQueue.main.async { [weak self] in
            self?.displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
        }
    }
}

nonisolated(unsafe) private let displayReconfigCallback: CGDisplayReconfigurationCallBack = {
    display, flags, userInfo in
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

// MARK: - Display Button
struct DisplayButton: View {
    let display: DisplayObjc
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Spacer()
                Text(display.getDisplayName()).font(.system(size: 12, weight: .bold)).lineLimit(1)
                Text(display.getResolution()).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(width: 200, height: 80)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(
                        .regular.interactive(), in: .rect(cornerRadius: isSelected ? 26 : 20))
                } else {
                    VisualEffectView(material: isSelected ? .selection : .headerView)
                        .clipShape(RoundedRectangle(cornerRadius: isSelected ? 26 : 20))
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(
                        Color.yellow, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .shadow(
            color: isSelected ? Color.yellow.opacity(0.45) : Color.black.opacity(0.15),
            radius: isSelected ? 20 : 10, y: 8
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    @AppStorage(UserDefaultsKeys.scaleMode) var scaleMode: Int = 0
    @State private var localMinutes: Int = 60
    @State private var isShowingView = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack {
                Text(L.settings)
                    .font(.title2)
                    .fontWeight(.bold)

            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Folder Selection
                    SettingRow(title: L.wallpaperFolder) {
                        HStack {
                            TextField(L.selectFolderOrType, text: $viewModel.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Button(action: selectFolder) {
                                //Image(systemName: "folder.fill")
                                Image("openfolder").resizable().frame(width: 23, height: 23)
                            }
                            Button(action: openInFinder) {
                                Image("folder").resizable().frame(width: 23, height: 23)
                            }
                            
                            
                        }
                    }

                    Divider()

                    // Scale Mode
                    SettingRow(title: L.videoScalingMode) {

                        Picker("", selection: $scaleMode) {
                            Text(L.scaleFill).tag(0)
                            Text(L.scaleFit).tag(1)
                            Text(L.scaleStretch).tag(2)
                            Text(L.scaleCenter).tag(3)
                            Text(L.scaleHeightFill).tag(4)
                        }
                        .onChange(of: scaleMode) {

                            viewModel.engine.updateScaleMode(scaleMode)
                        }

                    }

                    Divider()

                    // Language Selection
                    SettingRow(title: NSLocalizedString("App language", comment: "")) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { LanguageManager.shared.currentLanguage },
                                set: { newValue in
                                    LanguageManager.shared.currentLanguage = newValue
                                    let alert = NSAlert()
                                    alert.messageText = NSLocalizedString(
                                        "language_changed_title", comment: "")
                                    alert.informativeText = NSLocalizedString(
                                        "language_changed_message", comment: "")
                                    alert.alertStyle = .informational
                                    alert.addButton(withTitle: NSLocalizedString("ok", comment: ""))
                                    alert.runModal()
                                }
                            )
                        ) {
                            Text(NSLocalizedString("system_language", comment: "")).tag("auto")
                            Text("简体中文").tag("zh-Hans")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    Divider()

                    // Random Wallpaper on Startup
                    SettingRow(title: L.randomOnStartup) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(
                                        forKey: UserDefaultsKeys.randomOnStartup)
                                },
                                set: {
                                    UserDefaults.standard.set(
                                        $0, forKey: UserDefaultsKeys.randomOnStartup)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    // Random Wallpaper on Wakeup
                    SettingRow(title: L.randomOnLid) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(forKey: UserDefaultsKeys.randomOnLid)
                                },
                                set: {
                                    UserDefaults.standard.set(
                                        $0, forKey: UserDefaultsKeys.randomOnLid)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    // Auto-Pause When App is Active
                    SettingRow(title: L.pauseWhenActive) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(
                                        forKey: UserDefaultsKeys.pauseOnAppFocus)
                                },
                                set: {
                                    UserDefaults.standard.set(
                                        $0, forKey: UserDefaultsKeys.pauseOnAppFocus)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    //Vinttage Bar
                    SettingRow(title: L.vinttageBar) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(forKey: UserDefaultsKeys.vignetteBar)
                                },
                                set: {
                                    UserDefaults.standard.set(
                                        $0, forKey: UserDefaultsKeys.vignetteBar)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingRow(title: L.wallpaperRotation) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(forKey: UserDefaultsKeys.rotation)
                                },
                                set: { newValue in
                                    guard let engine = sharedEngine else { return }

                                    engine.isrotationrunning = newValue
                                    if newValue {

                                        engine.startWallpaperRotation()

                                    } else {
                                        engine.stopWallpaperRotation()
                                    }
                                    UserDefaults.standard.set(
                                        newValue, forKey: UserDefaultsKeys.rotation)
                                }
                            )
                        ).toggleStyle(.switch)

                    }

                    SettingRow(title: L.rotationDelay) {
                        HStack(spacing: 8) {
                            // 1. The Typeable Field
                            TextField("", value: $localMinutes, format: .number)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 40)  // Keeps it compact
                                .onSubmit {
                                    // Ensure the typed value stays within your bounds
                                    localMinutes = min(max(localMinutes, 1), 1440)
                                }

                            // 2. The Stepper (with an empty label)
                            Stepper("", value: $localMinutes, in: 1...1440, step: 4)
                                .labelsHidden()  // This hides the extra space Stepper usually takes
                                .onChange(of: localMinutes) { newValue in
                                    sharedEngine?.rotationDelay = Int32(newValue * 60)
                                    UserDefaults.standard.set(
                                        (newValue * 60), forKey: UserDefaultsKeys.rdelay)
                                    print("Delay updated to: \(sharedEngine?.rotationDelay ?? 0)")
                                }

                            // 3. The Formatted Unit
                            Text(formatTime(localMinutes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize()
                        }

                    }

                    .onAppear {
                        if let engine = sharedEngine {
                            localMinutes =
                                UserDefaults.standard.integer(forKey: UserDefaultsKeys.rdelay) / 60
                        }
                    }

                    if let engine = sharedEngine {
                        SettingRow(title: L.rotationType) {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { engine.rotationType },
                                    set: { newValue in
                                        engine.rotationType = newValue

                                    }
                                )
                            ) {
                                Text("Sequential").tag(RotationType.sequential)
                                Text("Random").tag(RotationType.random)
                            }
                            .onChange(of: engine.rotationType) {
                                if engine.rotationType == RotationType.sequential {
                                    UserDefaults.standard.set(1, forKey: UserDefaultsKeys.rtype)
                                } else {
                                    UserDefaults.standard.set(2, forKey: UserDefaultsKeys.rtype)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }
                    } else {
                        Text("Engine Loading...")  // Or EmptyView()
                    }

                    Divider()

                    // Video Volume
                    SettingRow(title: L.videoVolume) {
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
                    SettingRow(title: L.optimizeCodecs) {
                        Button(L.optimize) {
                            viewModel.optimizeVideos()
                        }
                        .disabled(true)
                    }

                    // Clear Cache
                    SettingRow(title: L.clearCache) {
                        Button(L.clearCacheButton) {
                            viewModel.clearCache()
                        }
                    }

                    // Reset User Data
                    SettingRow(title: L.resetUserData) {
                        Button(L.reset) {
                            viewModel.resetUserData()
                        }
                    }

                    Divider()

                    // Lock Screen Video
                    VStack(alignment: .leading, spacing: 4) {
                        SettingRow(title: L.lockScreenVideo) {
                            Toggle("", isOn: Binding(
                                get: { viewModel.lockScreenVideoEnabled },
                                set: { viewModel.setLockScreenVideo($0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        if !viewModel.lockScreenVideoEnabled {
                            Text(L.lockScreenVideoSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 8)
                        }
                        if let error = viewModel.lockScreenVideoError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.leading, 8)
                        }
                    }
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .background(.ultraThinMaterial)
        .compatibleGlass(cornerRadius: 1)

    }
    func formatTime(_ totalMinutes: Int) -> String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m) min"
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L.selectFolderTitle
        panel.prompt = L.choose

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.folderPath = url.path
            sharedEngine?.selectFolder(url.path())
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

// MARK: - Video Item
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

// MARK: - Thumbnail Cache
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
            let img = NSImage(contentsOfFile: path)
        else {
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

// MARK: - Wallpaper View Model
@MainActor
class WallpaperViewModel: ObservableObject {

    @Published var videos: [VideoItem] = []
    @Published var displays: [DisplayObjc] = []
    @Published var folderPath: String = ""
    @Published var scaleMode: String = "fill"
    @Published var randomOnStartup: Bool = false
    @Published var pauseOnAppFocus: Bool = true
    @Published var volume: Double = 50.0
    @Published var vinttageBar: Bool = true
    @Published var lockScreenVideoEnabled: Bool = false
    @Published var lockScreenVideoError: String? = nil

    private var currentReloadID = UUID()
    private let reloadIDLock = NSLock()
    private let defaults = UserDefaults.standard
    let engine: WallpaperEngine

    init(engine: WallpaperEngine = sharedEngine ?? WallpaperEngine.shared()) {
        self.engine = engine
        loadSettings()
        self.engine.setupNotifications()
    }

    func invalidate() {
        engine.removeNotifications()
    }

    func loadSettings() {
        folderPath = engine.getFolderPath()
        scaleMode = defaults.string(forKey: UserDefaultsKeys.scaleMode) ?? "fill"
        randomOnStartup = defaults.bool(forKey: UserDefaultsKeys.randomOnStartup)
        pauseOnAppFocus = defaults.bool(forKey: UserDefaultsKeys.pauseOnAppFocus)
        volume = Double(defaults.float(forKey: UserDefaultsKeys.volumePercentage))
        vinttageBar = defaults.bool(forKey: UserDefaultsKeys.vignetteBar)
        lockScreenVideoEnabled = defaults.bool(forKey: UserDefaultsKeys.lockScreenVideo)
    }

    func setLockScreenVideo(_ enabled: Bool) {
        let manager = LockScreenAerialManager.shared()
        if enabled {
            guard let rawPath = engine.currentVideoPath as String?, !rawPath.isEmpty else {
                lockScreenVideoError = "No wallpaper is currently active."
                lockScreenVideoEnabled = false
                return
            }
            let videoPath = rawPath
            if manager.isSystemSlotInstalled {
                manager.updateUserSymlink(videoPath)
                manager.writeIndexPlist(nil)
                defaults.set(true, forKey: UserDefaultsKeys.lockScreenVideo)
                lockScreenVideoEnabled = true
                lockScreenVideoError = nil
            } else {
                manager.performPrivilegedSetup(withVideoPath: videoPath) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let error {
                            self.lockScreenVideoError = error.localizedDescription
                            self.lockScreenVideoEnabled = false
                        } else {
                            LockScreenAerialManager.shared().writeIndexPlist(nil)
                            self.defaults.set(true, forKey: UserDefaultsKeys.lockScreenVideo)
                            self.lockScreenVideoEnabled = true
                            self.lockScreenVideoError = nil
                        }
                    }
                }
            }
        } else {
            var revertError: NSError?
            if !manager.revertIndexPlist(&revertError) {
                lockScreenVideoError = revertError?.localizedDescription ?? "Failed to restore lock screen settings."
            } else {
                lockScreenVideoError = nil
            }
            defaults.set(false, forKey: UserDefaultsKeys.lockScreenVideo)
            lockScreenVideoEnabled = false
        }
    }

    func reloadContent() {
        engine.checkFolderPath()
        ThumbnailCache.shared.clearCache()

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath) else {
            return
        }

        let videoFiles = files.filter { f in
            let e = (f as NSString).pathExtension.lowercased()
            return e == "mp4" || e == "mov"
        }

        let reloadID = UUID()
        reloadIDLock.lock()
        currentReloadID = reloadID
        reloadIDLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let newVideos: [VideoItem] = videoFiles.map { f in
                let full = (self.folderPath as NSString).appendingPathComponent(f)
                let base = (f as NSString).deletingPathExtension
                let thumbPath =
                    (self.engine.thumbnailCachePath() as NSString?)?.appendingPathComponent(
                        "\(base).png") ?? ""

                var item = VideoItem(filename: f, path: full, thumbnailPath: thumbPath)
                self.engine.videoQualityBadge(for: URL(fileURLWithPath: full)) { badge in
                    item.quality = badge
                }
                return item
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.reloadIDLock.lock()
                let isValid = reloadID == self.currentReloadID
                self.reloadIDLock.unlock()

                if isValid {
                    self.videos = newVideos

                    let missingThumbnails = newVideos.filter { $0.loadThumbnail() == nil }
                    if !missingThumbnails.isEmpty {
                        NSLog(
                            "Found \(missingThumbnails.count) videos without thumbnails, generating..."
                        )
                        self.engine.generateThumbnails()
                    }
                }
            }
        }
    }

    func loadDisplays() {
        displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
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
                n.uint32Value == id
            {
                return s.localizedName
            }
        }
        return "Display \(id)"
    }
}

#Preview {
    ContentView()
}

#Preview {
    SettingsView(viewModel: WallpaperViewModel())
}
