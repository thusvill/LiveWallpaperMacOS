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
import CoreFoundation
import CoreGraphics
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
        // Prefer system material; glass effect only on macOS 26+
        if #available(macOS 26.0, *) {
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
        LanguageManager.shared.localizedString(self)
    }
}

// MARK: - Darwin notify helper (cross-process → wallpaperdaemon)
enum LiveWallpaperNotify {
    static func post(_ name: String) {
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cfName,
            nil,
            nil,
            true
        )
    }

    static let volumeChanged = "com.live.wallpaper.volumeChanged"
    static let scaleModeChanged = "com.live.wallpaper.scaleModeChanged"
    static let autoPauseChanged = "com.live.wallpaper.autoPauseChanged"
    static let spaceChanged = "com.live.wallpaper.spaceChanged"
    static let terminate = "com.live.wallpaper.terminate"
}

// MARK: - Language Manager
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var currentLanguage: String {
        didSet {
            UserDefaults.standard.set(currentLanguage, forKey: UserDefaultsKeys.appLanguage)
            if currentLanguage == "auto" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([currentLanguage], forKey: "AppleLanguages")
            }
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
        let language: String
        if currentLanguage == "auto" {
            language = Locale.preferredLanguages.first ?? "en"
        } else {
            language = currentLanguage
        }

        let candidates = [
            language,
            language.components(separatedBy: "-").first ?? language,
            "en",
        ]

        for code in candidates {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                let bundle = Bundle(path: path)
            {
                let value = NSLocalizedString(key, tableName: nil, bundle: bundle, comment: "")
                if value != key {
                    return value
                }
            }
        }
        return NSLocalizedString(key, comment: "")
    }
}

// MARK: - Localization (keys must match *.lproj/Localizable.strings)
enum L {
    static var selectWallpaperFolder: String { "select_wallpaper_folder".localized }
    static var generating: String { "generating".localized }
    static var settings: String { "settings".localized }
    static var wallpaperFolder: String { "wallpaper_folder".localized }
    static var selectFolderEmoji: String { "select_folder_emoji".localized }
    static var showInFinder: String { "show_in_finder".localized }
    static var videoScalingMode: String { "video_scaling_mode".localized }
    static var scaleFill: String { "scale_fill".localized }
    static var scaleFit: String { "scale_fit".localized }
    static var scaleStretch: String { "scale_stretch".localized }
    static var scaleCenter: String { "scale_center".localized }
    static var scaleHeightFill: String { "scale_height_fill".localized }
    static var randomOnStartup: String { "random_on_startup".localized }
    static var randomOnLid: String { "random_on_lid".localized }
    static var pauseWhenActive: String { "pause_when_active".localized }
    static var videoVolume: String { "video_volume".localized }
    static var optimizeCodecs: String { "optimize_codecs".localized }
    static var optimize: String { "optimize".localized }
    static var clearCache: String { "clear_cache".localized }
    static var clearCacheButton: String { "clear_cache_button".localized }
    static var resetUserData: String { "reset_userdata".localized }
    static var reset: String { "reset".localized }
    static var selectFolderTitle: String { "select_folder_title".localized }
    static var choose: String { "choose".localized }
    static var selectFolderOrType: String { "select_folder_or_type".localized }
    static var wallpaperRotation: String { "wallpaper_rotation".localized }
    static var rotationType: String { "wallpaper_rotation_type".localized }
    static var vignetteBar: String { "vignette_bar".localized }
    static var rotationDelay: String { "wallpaper_rotation_delay".localized }
    static var rotationSequential: String { "rotation_sequential".localized }
    static var rotationRandom: String { "rotation_random".localized }
    static var engineLoading: String { "engine_loading".localized }
    static var launchAtLogin: String { "launch_at_login".localized }
    static var appLanguage: String { "app_language".localized }
    static var systemLanguage: String { "system_language".localized }
    static var languageChangedTitle: String { "language_changed_title".localized }
    static var languageChangedMessage: String { "language_changed_message".localized }
    static var ok: String { "ok".localized }
    static var optimizeRunning: String { "optimize_running".localized }
    static var optimizeDone: String { "optimize_done".localized }
}

// MARK: - UserDefaults Keys
enum UserDefaultsKeys {
    static let wallpaperFolder = "WallpaperFolder"
    /// Integer 0...4 (Fill, Fit, Stretch, Center, HeightFill). Migrated from legacy strings.
    static let scaleMode = "scale_mode"
    static let randomOnStartup = "random"
    static let randomOnLid = "random_lid"
    static let pauseOnAppFocus = "pauseOnAppFocus"
    /// Historical typo preserved for compatibility with installed daemons.
    static let volumePercentage = "wallpapervolumeprecentage"
    static let volume = "wallpapervolume"
    static let launchAtLogin = "LaunchAtLogin"
    static let appLanguage = "app_language"
    /// Historical typo preserved for daemon vignette toggle.
    static let vignetteBar = "vinttage_bar"
    static let rotation = "rotation"
    static let rdelay = "rdelay"
    static let rtype = "rtype"
}

// MARK: - Scale mode helpers
enum ScaleMode: Int, CaseIterable {
    case fill = 0
    case fit = 1
    case stretch = 2
    case center = 3
    case heightFill = 4

    static func migrateFromDefaults(_ defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.object(forKey: UserDefaultsKeys.scaleMode)
        if let n = raw as? NSNumber {
            let v = n.intValue
            return (0...4).contains(v) ? v : 0
        }
        if let s = raw as? String {
            let mapped: Int
            switch s.lowercased() {
            case "fill", "aspectfill", "0": mapped = 0
            case "fit", "aspect", "aspectfit", "1": mapped = 1
            case "stretch", "resize", "2": mapped = 2
            case "center", "3": mapped = 3
            case "heightfill", "height_fill", "4": mapped = 4
            default: mapped = 0
            }
            defaults.set(mapped, forKey: UserDefaultsKeys.scaleMode)
            return mapped
        }
        return 0
    }
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
            .onAppear {
                viewModel.loadDisplays()
                viewModel.reloadContent()
                // Window visibility is owned by AppDelegate (starts hidden).
                // Do not auto-dismiss/show here — that fought single-instance + LaunchAgents.
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
        }
        .animation(.easeInOut, value: showSettings)
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
                .help(L.selectWallpaperFolder)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
                .buttonStyle(.glass)
                .help(L.settings)
            } else {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
                .help("reload".localized)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
                .help(L.settings)
            }
        }
    }
}

// MARK: - Video Grid View
struct VideoGridView: View {
    let videos: [VideoItem]
    let viewModel: WallpaperViewModel
    let onVideoSelect: (VideoItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: THUMBNAIL_WIDTH, maximum: THUMBNAIL_WIDTH), spacing: 6)
    ]

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
                        sharedEngine?.selectFolder(url.path)
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
                LazyVGrid(columns: columns, spacing: 6) {
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
                        .frame(height: THUMBNAIL_HEIGHT)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: THUMBNAIL_HEIGHT)
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
@MainActor
final class DisplayManager: ObservableObject {
    @Published var displays: [DisplayObjc] = []
    @Published var selectedDisplays: Set<UInt32> = []

    init() {
        sharedEngine?.scanDisplays()
        updateDisplays()
        // AppKit notification (Swift 6–safe). Engine also handles reconfig.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func onScreensChanged(_ note: Notification) {
        updateDisplays()
    }

    func updateDisplays() {
        sharedEngine?.scanDisplays()
        let next = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
        let liveIDs = Set(next.map { $0.screen })
        // Keep selections that still exist; do not wipe everything on reconfig
        selectedDisplays = selectedDisplays.intersection(liveIDs)
        displays = next
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
    @AppStorage(UserDefaultsKeys.scaleMode) var scaleMode: Int = 0
    @State private var localMinutes: Int = 60
    @State private var isOptimizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L.settings)
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingRow(title: L.wallpaperFolder) {
                        HStack {
                            TextField(L.selectFolderOrType, text: $viewModel.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Button(action: selectFolder) {
                                Image("openfolder").resizable().frame(width: 23, height: 23)
                            }
                            .help(L.selectFolderEmoji)
                            Button(action: openInFinder) {
                                Image("folder").resizable().frame(width: 23, height: 23)
                            }
                            .help(L.showInFinder)
                            Button("Aerials") {
                                useAppleAerialsFolder()
                            }
                            .help("Point at Apple downloaded Aerial videos")
                        }
                    }

                    Divider()

                    SettingRow(title: L.videoScalingMode) {
                        Picker("", selection: $scaleMode) {
                            Text(L.scaleFill).tag(0)
                            Text(L.scaleFit).tag(1)
                            Text(L.scaleStretch).tag(2)
                            Text(L.scaleCenter).tag(3)
                            Text(L.scaleHeightFill).tag(4)
                        }
                        .onChange(of: scaleMode) { newValue in
                            let mode = ScaleMode.migrateFromDefaults()
                            let resolved = (0...4).contains(newValue) ? newValue : mode
                            viewModel.engine.updateScaleMode(resolved)
                        }
                    }

                    Divider()

                    SettingRow(title: L.appLanguage) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { LanguageManager.shared.currentLanguage },
                                set: { newValue in
                                    LanguageManager.shared.currentLanguage = newValue
                                    let alert = NSAlert()
                                    alert.messageText = L.languageChangedTitle
                                    alert.informativeText = L.languageChangedMessage
                                    alert.alertStyle = .informational
                                    alert.addButton(withTitle: L.ok)
                                    alert.runModal()
                                }
                            )
                        ) {
                            Text(L.systemLanguage).tag("auto")
                            Text("简体中文").tag("zh-Hans")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    Divider()

                    SettingRow(title: L.launchAtLogin) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { isLoginItemEnabled() },
                                set: { setLoginItem(enabled: $0) }
                            )
                        )
                        .toggleStyle(.switch)
                    }

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
                                    UserDefaults.standard.synchronize()
                                    LiveWallpaperNotify.post(LiveWallpaperNotify.autoPauseChanged)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    SettingRow(title: L.vignetteBar) {
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
                            TextField("", value: $localMinutes, format: .number)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 40)
                                .onSubmit {
                                    localMinutes = min(max(localMinutes, 1), 1440)
                                    persistRotationDelay()
                                }

                            Stepper("", value: $localMinutes, in: 1...1440, step: 1)
                                .labelsHidden()
                                .onChange(of: localMinutes) { _ in
                                    persistRotationDelay()
                                }

                            Text(formatTime(localMinutes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize()
                        }
                    }
                    .onAppear {
                        let seconds = UserDefaults.standard.integer(forKey: UserDefaultsKeys.rdelay)
                        localMinutes = max(1, seconds > 0 ? seconds / 60 : 1)
                    }

                    if let engine = sharedEngine {
                        SettingRow(title: L.rotationType) {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { engine.rotationType },
                                    set: { newValue in
                                        engine.rotationType = newValue
                                        let stored =
                                            (newValue == RotationType.sequential) ? 1 : 2
                                        UserDefaults.standard.set(
                                            stored, forKey: UserDefaultsKeys.rtype)
                                    }
                                )
                            ) {
                                Text(L.rotationSequential).tag(RotationType.sequential)
                                Text(L.rotationRandom).tag(RotationType.random)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }
                    } else {
                        Text(L.engineLoading)
                    }

                    Divider()

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

                    SettingRow(title: L.optimizeCodecs) {
                        Button(isOptimizing ? L.optimizeRunning : L.optimize) {
                            guard !isOptimizing else { return }
                            isOptimizing = true
                            viewModel.optimizeVideos { converted, skipped, failed in
                                isOptimizing = false
                                let alert = NSAlert()
                                alert.messageText = L.optimizeDone
                                alert.informativeText = String(
                                    format: "optimize_done_detail".localized,
                                    converted, skipped, failed)
                                alert.alertStyle = .informational
                                alert.addButton(withTitle: L.ok)
                                alert.runModal()
                                viewModel.reloadContent()
                            }
                        }
                        .disabled(isOptimizing)
                    }

                    SettingRow(title: L.clearCache) {
                        Button(L.clearCacheButton) {
                            viewModel.clearCache()
                        }
                    }

                    SettingRow(title: L.resetUserData) {
                        Button(L.reset) {
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
        .compatibleGlass(cornerRadius: 1)
        .onAppear {
            scaleMode = ScaleMode.migrateFromDefaults()
        }
    }

    private func persistRotationDelay() {
        let minutes = min(max(localMinutes, 1), 1440)
        localMinutes = minutes
        let seconds = minutes * 60
        sharedEngine?.rotationDelay = Int32(seconds)
        UserDefaults.standard.set(seconds, forKey: UserDefaultsKeys.rdelay)
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.rotation) {
            sharedEngine?.startWallpaperRotation()
        }
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
            sharedEngine?.selectFolder(url.path)
            viewModel.reloadContent()
        }
    }

    private func openInFinder() {
        let path = viewModel.folderPath
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: nil)
            NSWorkspace.shared.open(url)
        }
    }

    /// Point library at Apple's Aerial cache (multi-GB HEVC masters).
    private func useAppleAerialsFolder() {
        let aerials = (NSHomeDirectory() as NSString)
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/aerials/videos")
        guard FileManager.default.fileExists(atPath: aerials) else {
            let alert = NSAlert()
            alert.messageText = "Apple Aerials not found"
            alert.informativeText =
                "Download aerials via System Settings → Wallpaper → Aerials, then try again.\n\nExpected:\n\(aerials)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: L.ok)
            alert.runModal()
            return
        }
        // Always write a real filesystem path (spaces, not %20)
        viewModel.folderPath = aerials
        sharedEngine?.selectFolder(aerials)
        UserDefaults.standard.set(aerials, forKey: UserDefaultsKeys.wallpaperFolder)
        UserDefaults.standard.synchronize()
        // Fill scale is best for cinematic aerials
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.scaleMode)
        viewModel.engine.updateScaleMode(0)
        viewModel.reloadContent()
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
struct VideoItem: Identifiable, Equatable, Sendable {
    let id: String
    let filename: String
    let path: String
    let thumbnailPath: String
    var quality: String?

    nonisolated init(filename: String, path: String, thumbnailPath: String, quality: String? = nil) {
        self.id = path
        self.filename = filename
        self.path = path
        self.thumbnailPath = thumbnailPath
        self.quality = quality
    }

    @MainActor
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
    @Published var scaleMode: Int = 0
    @Published var randomOnStartup: Bool = false
    @Published var pauseOnAppFocus: Bool = true
    @Published var volume: Double = 50.0
    @Published var vignetteBar: Bool = true

    private var currentReloadID = UUID()
    private let reloadIDLock = NSLock()
    private let defaults = UserDefaults.standard
    let engine: WallpaperEngine

    init(engine: WallpaperEngine = sharedEngine ?? WallpaperEngine.shared()) {
        self.engine = engine
        _ = ScaleMode.migrateFromDefaults()
        loadSettings()
        self.engine.setupNotifications()
    }

    func invalidate() {
        engine.removeNotifications()
    }

    func loadSettings() {
        folderPath = engine.getFolderPath()
        scaleMode = ScaleMode.migrateFromDefaults()
        randomOnStartup = defaults.bool(forKey: UserDefaultsKeys.randomOnStartup)
        pauseOnAppFocus = defaults.bool(forKey: UserDefaultsKeys.pauseOnAppFocus)
        let pct = defaults.float(forKey: UserDefaultsKeys.volumePercentage)
        volume = pct > 0 ? Double(pct) : Double(defaults.float(forKey: UserDefaultsKeys.volume) * 100)
        vignetteBar = defaults.bool(forKey: UserDefaultsKeys.vignetteBar)
    }

    /// Decode %20 / file:// paths so Aerials folder actually resolves on disk.
    private func normalizedPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file:"), let url = URL(string: path) {
            path = url.path
        }
        if let decoded = path.removingPercentEncoding, !decoded.isEmpty {
            path = decoded
        }
        return (path as NSString).expandingTildeInPath
    }

    func reloadContent() {
        engine.checkFolderPath()
        ThumbnailCache.shared.clearCache()
        folderPath = normalizedPath(engine.getFolderPath() ?? "")
        // Heal prefs if UI/engine still had a percent-encoded path
        if !folderPath.isEmpty {
            sharedEngine?.selectFolder(folderPath)
        }

        guard !folderPath.isEmpty,
            let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath)
        else {
            NSLog("reloadContent: cannot list folder: \(folderPath)")
            videos = []
            return
        }

        let videoFiles = files.filter { f in
            let e = (f as NSString).pathExtension.lowercased()
            return e == "mp4" || e == "mov" || e == "m4v"
        }.sorted()

        NSLog("reloadContent: \(videoFiles.count) videos in \(folderPath)")

        let reloadID = UUID()
        reloadIDLock.lock()
        currentReloadID = reloadID
        reloadIDLock.unlock()

        let folder = folderPath
        let thumbRoot = engine.thumbnailCachePath() ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let newVideos: [VideoItem] = videoFiles.map { f in
                let full = (folder as NSString).appendingPathComponent(f)
                let base = (f as NSString).deletingPathExtension
                let thumbPath = (thumbRoot as NSString).appendingPathComponent("\(base).png")
                return VideoItem(filename: f, path: full, thumbnailPath: thumbPath)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.reloadIDLock.lock()
                let isValid = reloadID == self.currentReloadID
                self.reloadIDLock.unlock()

                guard isValid else { return }

                self.videos = newVideos

                let missingThumbnails = newVideos.filter { $0.loadThumbnail() == nil }
                if !missingThumbnails.isEmpty {
                    NSLog(
                        "Found \(missingThumbnails.count) videos without thumbnails, generating...")
                    self.engine.generateThumbnails()
                }

                // Quality badges after list is on screen (cheap metadata probe)
                for item in newVideos {
                    let path = item.path
                    self.engine.videoQualityBadge(for: URL(fileURLWithPath: path)) { badge in
                        DispatchQueue.main.async {
                            self.reloadIDLock.lock()
                            let stillValid = reloadID == self.currentReloadID
                            self.reloadIDLock.unlock()
                            guard stillValid else { return }
                            guard let idx = self.videos.firstIndex(where: { $0.path == path })
                            else { return }
                            if self.videos[idx].quality != badge {
                                self.videos[idx].quality = badge
                            }
                        }
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

    func optimizeVideos(completion: @escaping @Sendable (Int, Int, Int) -> Void) {
        let path = folderPath
        engine.optimizeVideos(
            inFolder: path,
            withCompletion: { converted, skipped, failed in
                let c = Int(converted)
                let s = Int(skipped)
                let f = Int(failed)
                DispatchQueue.main.async {
                    completion(c, s, f)
                }
            })
    }
}

#Preview {
    ContentView()
}

#Preview {
    SettingsView(viewModel: WallpaperViewModel())
}
