import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import Network
import IOKit.ps
import CoreLocation
import MapKit

@main
struct VeyraApp: App {
    @StateObject private var model = DashboardModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("Veyra", id: "dashboard") {
            DashboardView().environmentObject(model)
                .frame(minWidth: 900, minHeight: 500)
                .preferredColorScheme(model.theme == "Adaptive" ? nil : (model.theme == "Dark" ? .dark : .light))
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Full Screen") { model.toggleDashboardFullscreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
        Window("Veyra Ayarları", id: "settings") { PreferencesView().environmentObject(model) }
            .windowResizability(.contentSize)
            .defaultPosition(.center)
        MenuBarExtra("Veyra", systemImage: "square.grid.2x2.fill") {
            MenuContent().environmentObject(model)
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @AppStorage("theme") var theme = "Adaptive"
    @AppStorage("idleEnabled") var idleEnabled = false
    @AppStorage("idleMinutes") var idleMinutes = 5.0
    @AppStorage("idleFullscreen") var idleFullscreen = false
    @Published var idleTrigger = false
    weak var dashboardWindow: NSWindow?
    func toggleDashboardFullscreen() {
        guard let window = dashboardWindow ?? NSApp.windows.first(where: { $0.title == "Veyra" }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
    private var timer: Timer?
    private var activatedForIdle = false
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }
    private func checkIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        guard idleEnabled else { activatedForIdle = false; return }
        if idle < idleMinutes * 60 { activatedForIdle = false }
        else if !activatedForIdle {
            activatedForIdle = true
            idleTrigger.toggle()
        }
    }
}

enum Screen: String, CaseIterable {
    case dashboard = "Dashboard", music = "Music", clock = "Clock", map = "Harita", focus = "Odak"
    var icon: String {
        switch self { case .dashboard: "square.grid.2x2.fill"; case .music: "music.note"; case .clock: "clock.fill"; case .map: "map.fill"; case .focus: "scope" }
    }
}

/// Uses a monotonic clock so UI progress stays smooth between player snapshots.
struct PlaybackClock {
    var position: Double = 0
    var duration: Double = 1
    var playing = false
    var sampledAt: TimeInterval = 0
    func value(at now: TimeInterval) -> Double {
        min(duration, max(0, position + (playing ? max(0, now - sampledAt) : 0)))
    }
}

@MainActor final class MusicPlayer: ObservableObject {
    @Published var title = "Müziğin burada"
    @Published var artist = "Dinlemeye başla"
    @Published var artwork = ""
    @Published var album = ""
    @Published var shuffling = false
    @Published var repeating = false
    @Published var volume = 50.0
    @Published var playing = false
    @Published var position = 0.0
    @Published var duration = 1.0
    @Published var message = ""
    @Published var connected = false
    @Published var source: String {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source, forKey: "musicSource")
            permissionDenied = false
            connectionID = UUID()
            connecting = false
            lastAttempt = 0
            message = ""
            reset()
            connect()
        }
    }
    private var pollingTimer: Timer?
    private var progressTimer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var clock = PlaybackClock()
    private var permissionDenied = false
    private var connecting = false
    private var connectionID = UUID()
    private var lastAttempt: TimeInterval = 0
    private var appID: String { source == "Spotify" ? "com.spotify.client" : "com.apple.Music" }
    init() {
        let saved = UserDefaults.standard.string(forKey: "musicSource") ?? "Spotify"
        source = ["Spotify", "Apple Music"].contains(saved) ? saved : "Spotify"
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        pollingTimer = poll
        RunLoop.main.add(poll, forMode: .common)
        let progress = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.position = self.clock.value(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        progressTimer = progress
        RunLoop.main.add(progress, forMode: .common)
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            let observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            notifications.append(observer)
        }
        Task { @MainActor [weak self] in self?.connect() }
    }
    deinit {
        pollingTimer?.invalidate()
        progressTimer?.invalidate()
        for observer in notifications { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    private func reset() {
        connected = false; playing = false; position = 0; duration = 1
        title = "Müziğin burada"; artist = "Dinlemeye başla"; artwork = ""; album = ""
        shuffling = false; repeating = false; clock = PlaybackClock()
    }
    private func poll() {
        guard !permissionDenied, !connecting else { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty
        guard running else {
            if connected { reset(); message = "\(source) açıldığında otomatik bağlanacak." }
            return
        }
        // Retry an empty player more slowly, without opening the app repeatedly.
        let now = ProcessInfo.processInfo.systemUptime
        if !connected && now - lastAttempt < 2 { return }
        refresh()
    }
    func connect() {
        guard !connecting else { return }
        permissionDenied = false
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { message = "\(source) yüklü değil."; return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty { refresh(); return }
        connecting = true
        let requestedSource = source
        let requestID = connectionID
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.connectionID == requestID, self.source == requestedSource else { return }
                self.connecting = false
                if error != nil { self.message = "\(requestedSource) açılamadı. Yeniden bağlanmayı dene." }
                else { self.refresh() }
            }
        }
    }
    private func execute(_ body: String, allowEmptyTrack: Bool = false) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application id \"\(appID)\"\n\(body)\nend tell")?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if allowEmptyTrack && (code == -1728 || code == -1719) {
                reset()
                connected = true
                title = "Parça seç"
                artist = source
                message = "\(source) içinde bir parça seç veya oynat."
                return nil
            }
            permissionDenied = (error[NSAppleScript.errorNumber] as? Int) == -1743
            message = permissionDenied ? "Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon’dan izin ver, ardından Bağla’ya bas." : "\(source) içinde bir parça seç; otomatik bağlanacağım."
            clock.playing = false; connected = false; playing = false
            return nil
        }
        message = ""; return result
    }
    func refresh() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty else { return }
        lastAttempt = ProcessInfo.processInfo.systemUptime
        let art = source == "Spotify" ? "artwork url of current track" : "\"\""
        let shuffleProperty = source == "Spotify" ? "shuffling" : "shuffle enabled"
        guard let v = execute("return {name of current track, artist of current track, \(art), player state as text, player position, duration of current track, album of current track, \(shuffleProperty), \(source == "Spotify" ? "repeating" : "song repeat is not off"), sound volume}", allowEmptyTrack: true), v.numberOfItems == 10 else { return }
        let newTitle = v.atIndex(1)?.stringValue ?? "Parça seç"
        let newArtist = v.atIndex(2)?.stringValue ?? source
        let newAlbum = v.atIndex(7)?.stringValue ?? ""
        let trackChanged = title != newTitle || artist != newArtist || album != newAlbum
        title = newTitle; artist = newArtist; album = newAlbum
        let newArtwork = v.atIndex(3)?.stringValue ?? ""
        if artwork != newArtwork { artwork = newArtwork }
        // Clear the previous cover if Spotify has not supplied the new one yet.
        if trackChanged && newArtwork.isEmpty { artwork = "" }
        playing = v.atIndex(4)?.stringValue == "playing"
        duration = max(1, (v.atIndex(6)?.doubleValue ?? 1) / (source == "Spotify" ? 1000 : 1))
        let sample = max(0, v.atIndex(5)?.doubleValue ?? 0)
        clock = PlaybackClock(position: sample, duration: duration, playing: playing, sampledAt: ProcessInfo.processInfo.systemUptime)
        position = clock.value(at: clock.sampledAt)
        shuffling = v.atIndex(8)?.booleanValue ?? false
        repeating = v.atIndex(9)?.booleanValue ?? false
        volume = v.atIndex(10)?.doubleValue ?? 50
        connected = true
    }
    func openSource() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in } }
    }
    func seek(to value: Double) { command("set player position to \(min(duration, max(0, value)))") }
    func setVolume(_ value: Double) { command("set sound volume to \(Int(min(100, max(0, value))))") }
    func toggleShuffle() { command("set \(source == "Spotify" ? "shuffling" : "shuffle enabled") to \(shuffling ? "false" : "true")") }
    func toggleRepeat() { command(source == "Spotify" ? "set repeating to \(repeating ? "false" : "true")" : "set song repeat to \(repeating ? "off" : "all")") }
    func command(_ text: String) { guard connected else { return }; _ = execute(text); if connected { refresh() } }
}

@MainActor final class CoverCache {
    static let shared = CoverCache()
    private let data = NSCache<NSString, NSData>()
    private init() { data.totalCostLimit = 32 * 1024 * 1024 }
    func load(_ url: URL) async throws -> Data {
        if let cached = data.object(forKey: url.absoluteString as NSString) { return cached as Data }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), NSImage(data: bytes) != nil else { throw URLError(.cannotDecodeContentData) }
        data.setObject(bytes as NSData, forKey: url.absoluteString as NSString, cost: bytes.count)
        return bytes
    }
}

struct WindowAppearance: NSViewRepresentable {
    let model: DashboardModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                NSApp.applicationIconImage = icon
            }
            model.dashboardWindow = window
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .black
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = false }
            window.setContentSize(NSSize(width: 1280, height: 720))
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor final class DeviceStatus: ObservableObject {
    @Published var online = false
    @Published var wireless = false
    @Published var battery: Int?
    @Published var charging = false
    @Published var powerConnected = false
    @Published var events: [ActivityEntry] = []
    private var powerInitialized = false
    var batteryIcon: String {
        if powerConnected { return "battery.100percent.bolt" }
        let level = battery ?? 0
        return level > 87 ? "battery.100percent" : level > 62 ? "battery.75percent" : level > 37 ? "battery.50percent" : level > 12 ? "battery.25percent" : "battery.0percent"
    }
    var batteryDescription: String {
        "Pil: %\(battery ?? 0) • " + (powerConnected ? (charging ? "Şarj oluyor" : "Adaptöre bağlı") : "Pil ile çalışıyor")
    }
    func record(_ title: String, detail: String, icon: String) {
        events.insert(ActivityEntry(title: title, detail: detail, icon: icon), at: 0)
        if events.count > 30 { events.removeLast(events.count - 30) }
    }
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied; self?.wireless = path.usesInterfaceType(.wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "Veyra.connection"))
        updateBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateBattery() } }
    }
    deinit { monitor.cancel(); timer?.invalidate() }
    private func updateBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        battery = nil
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            battery = min(100, max(0, current * 100 / maximum))
            charging = values[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if powerInitialized && pluggedIn != powerConnected {
                record(pluggedIn ? "Güç adaptörü bağlandı" : "Güç adaptörü çıkarıldı", detail: "Pil: %\(battery ?? 0)", icon: pluggedIn ? "bolt.fill" : "battery.100percent")
            }
            powerConnected = pluggedIn
            powerInitialized = true
            break
        }
    }
}

struct TransportStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity).frame(height: 68)
            .background(.white.opacity(configuration.isPressed ? 0.30 : hovered ? 0.19 : 0), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(hovered ? 0.10 : 0)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}

struct SoftSlider: View {
    @Binding var value: Double
    var maximum: Double
    var label: String
    var onEditing: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, value / max(1, maximum)))
            let length = max(1, geo.size.width - 16)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 7)
                Capsule().fill(.white.opacity(0.82)).frame(width: 8 + length * fraction, height: 7)
                Capsule().fill(.white.opacity(0.95)).frame(width: dragging ? 24 : 20, height: dragging ? 15 : 12)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1).offset(x: length * fraction)
            }.frame(height: geo.size.height).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled else { return }
                    if !dragging { dragging = true; onEditing(true) }
                    value = min(maximum, max(0, (event.location.x - 8) / length * maximum))
                }.onEnded { _ in guard dragging else { return }; dragging = false; onEditing(false) })
        }.frame(height: 28).opacity(enabled ? 1 : 0.4)
            .accessibilityElement().accessibilityLabel(label).accessibilityValue("\(Int(value)) / \(Int(maximum))")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                onEditing(true)
                switch direction { case .increment: value = min(maximum, value + 5); case .decrement: value = max(0, value - 5); @unknown default: break }
                onEditing(false)
            }
    }
}

struct SourcePanel: View {
    @ObservedObject var player: MusicPlayer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Müzik kaynağı").font(.headline).padding(.bottom, 4)
            ForEach(["Spotify", "Apple Music"], id: \.self) { source in
                Button {
                    if player.source == source { player.connect() }
                    else { player.source = source }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note").foregroundStyle(source == "Spotify" ? Color.green : Color.pink).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source).font(.subheadline.weight(.semibold))
                            if player.source == source { Text(player.connected ? "Bağlı" : "Seçili").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if player.source == source { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }.padding(12).frame(maxWidth: .infinity).background(.white.opacity(player.source == source ? 0.10 : 0.03), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("\(source) kullan")
            }
            if !player.message.isEmpty { Text(player.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider().padding(.vertical, 4)
            Button("\(player.source) uygulamasını aç", systemImage: "arrow.up.forward.app") { player.openSource() }.buttonStyle(.plain)
            Text("Seçimin sonraki açılışta hatırlanır.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }.padding(22).frame(width: 310).background(Color(red: 0.10, green: 0.11, blue: 0.13))
    }
}

struct VolumePanel: View {
    @ObservedObject var player: MusicPlayer
    @State private var level = 50.0
    @State private var remembered = 50.0
    @State private var editing = false
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Müzik sesi").font(.headline)
                Spacer()
                Text("\(Int(level))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button { apply(max(0, level - 5)) } label: { Image(systemName: "speaker.fill").frame(width: 28, height: 32) }.help("Sesi azalt")
                SoftSlider(value: $level, maximum: 100, label: "Müzik ses düzeyi") { active in
                    editing = active
                    if !active { player.setVolume(level) }
                }
                Button { apply(min(100, level + 5)) } label: { Image(systemName: "speaker.wave.3.fill").frame(width: 28, height: 32) }.help("Sesi artır")
            }.disabled(!player.connected)
            Button {
                if level > 0 { remembered = level; apply(0) } else { apply(max(5, remembered)) }
            } label: {
                Label(level > 0 ? "Sessize al" : "Sesi aç", systemImage: level > 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity).padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }.disabled(!player.connected)
            Text("\(player.source) ses düzeyini değiştirir.").font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.plain).padding(22).frame(width: 320)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))
            .foregroundStyle(.white)
            .onAppear { level = player.volume }
            .onChange(of: player.volume) { _, value in if !editing { level = value } }
    }
    private func apply(_ value: Double) { level = value; player.setVolume(value) }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let icon: String
}

struct ActivityPanel: View {
    @ObservedObject var device: DeviceStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Veyra bildirimleri").font(.headline)
                Spacer()
                if !device.events.isEmpty { Button("Temizle") { device.events.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            if device.events.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Yeni bildirim yok").font(.subheadline)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(device.events) { event in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: event.icon).frame(width: 24).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title).font(.subheadline.weight(.semibold))
                                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                                    Text(event.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 280)
            }
            Divider()
            Text("Güç ve müzik bağlantısı değişiklikleri burada görünür. Diğer uygulamaların bildirimleri macOS Bildirim Merkezi’nde kalır.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 350).background(Color(red: 0.10, green: 0.11, blue: 0.13))
            .environment(\.colorScheme, .dark)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var player = MusicPlayer()
    @StateObject private var device = DeviceStatus()
    @StateObject private var weather = WeatherModel()
    @StateObject private var mapModel = EmbeddedMapModel()
    @StateObject private var focusModel = FocusModel()
    @State private var showVolume = false
    @State private var showSources = false
    @State private var showActivity = false
    @State private var screen: Screen = .music
    @State private var albumImage: NSImage?
    @State private var albumColor = Color(red: 0.52, green: 0.035, blue: 0.07)
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                dock.padding(.leading, 8).padding(.vertical, 8)
                VStack(spacing: 0) {
                    header.padding(.horizontal, 18).padding(.top, 14)
                    Group {
                        switch screen {
                        case .music: ImmersiveMusic(player: player, artwork: albumImage)
                        case .clock: ClockCard().padding(50)
                        case .map: EmbeddedMapScreen(model: mapModel)
                        case .focus: FocusScreen(model: focusModel)
                        case .dashboard:
                            HomeDashboard(player: player, device: device, weather: weather, artwork: albumImage,
                                openMusic: { screen = .music },
                                openSettings: { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) },
                                openActivity: { showActivity = true })
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(width: geo.size.width, height: geo.size.height)
        }
        .background {
            GeometryReader { geo in
                ZStack {
                    model.theme == "Dark" ? Color(white: 0.09) : model.theme == "Light" ? Color(red: 0.48, green: 0.40, blue: 0.44) : albumColor
                    if let albumImage, model.theme == "Adaptive" {
                        Image(nsImage: albumImage).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).blur(radius: 100).scaleEffect(1.25).opacity(0.40)
                    }
                    LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [.white.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: geo.size.width * 0.6)
                }.frame(width: geo.size.width, height: geo.size.height).clipped()
            }.ignoresSafeArea()
        }
        .background(WindowAppearance(model: model))
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "tr_TR"))
        .task { weather.start() }
        .task(id: player.artwork) {
            albumImage = nil
            guard let url = URL(string: player.artwork), url.scheme == "https" else { return }
            do {
                let data = try await CoverCache.shared.load(url)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else { return }
                albumImage = image
                if let color = averageColor(data) {
                    withAnimation(.easeInOut(duration: 0.25)) { albumColor = color }
                }
            } catch { if !Task.isCancelled { albumImage = nil } }
        }
        .onChange(of: player.connected) { _, connected in
            device.record(connected ? "Müzik bağlandı" : "Müzik bağlantısı kesildi", detail: player.source, icon: connected ? "music.note" : "exclamationmark.circle")
        }
        .onChange(of: model.idleTrigger) { _, _ in
            openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let window = NSApp.windows.first(where: { $0.title == "Veyra" }) {
                    window.makeKeyAndOrderFront(nil)
                    if model.idleFullscreen && !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                }
            }
        }
    }
    private var header: some View {
        HStack {
            Button { withAnimation { screen = screen == .music ? .dashboard : .music } } label: {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)).frame(width: 52, height: 52).background(.black.opacity(0.12), in: Circle()).overlay(Circle().stroke(.white.opacity(0.16)))
            }.buttonStyle(.plain).help("Geri")
            Spacer()
            HStack(spacing: 20) {
                Button { model.toggleDashboardFullscreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 17)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("Tam ekranı aç / kapat (⌃⌘F)").accessibilityLabel("Tam ekranı aç veya kapat")
                Button { showVolume.toggle() } label: {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 21)).frame(width: 36, height: 32)
                }.buttonStyle(.plain).help("Ses düzeyi").accessibilityLabel("Ses düzeyi")
                    .popover(isPresented: $showVolume, arrowEdge: .bottom) { VolumePanel(player: player).environment(\.colorScheme, .dark) }
                Button { showSources.toggle() } label: {
                    Image(systemName: "list.bullet").font(.system(size: 21)).frame(width: 36, height: 32)
                }.buttonStyle(.plain).help("Müzik kaynağı").accessibilityLabel("Müzik kaynağı")
                    .popover(isPresented: $showSources, arrowEdge: .bottom) { SourcePanel(player: player).environment(\.colorScheme, .dark) }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(.white.opacity(0.10), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.15)))
        }
    }
    private var dock: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(spacing: 8) {
                    Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 4).background(Color.orange.opacity(0.85), in: Capsule())
                    Image(systemName: device.online ? (device.wireless ? "wifi" : "network") : "wifi.slash")
                        .font(.system(size: 15, weight: .semibold)).help(device.online ? "Ağ bağlantısı var" : "Ağ bağlantısı yok")
                    if let battery = device.battery {
                        Image(systemName: device.batteryIcon)
                            .foregroundStyle(device.powerConnected ? Color.green : battery <= 20 ? Color.red : Color.white.opacity(0.85))
                            .font(.system(size: 18)).help(device.batteryDescription)
                            .accessibilityLabel(device.batteryDescription)
                    }
                    Circle().fill(player.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
                        .help(player.connected ? "Müzik bağlı" : "Müzik bağlantısı bekleniyor")
                }
            }
            Spacer()
            appButton("com.apple.Maps", fallback: "map.fill", name: "Harita") { screen = .map }
            Button { screen = .focus } label: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/Clock.app")).resizable().frame(width: 48, height: 48)
                    .overlay(alignment: .bottomTrailing) { if focusModel.running { Circle().fill(.orange).frame(width: 8, height: 8).overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1)) } }
            }.buttonStyle(.plain).help("Odak modu").accessibilityLabel("Odak modu")
            appButton(player.source == "Spotify" ? "com.spotify.client" : "com.apple.Music", fallback: "music.note", name: "Müzik") { screen = .music }
            appButton("com.apple.MobileSMS", fallback: "message.fill", name: "Mesajlar") { openApp("com.apple.MobileSMS") }
            Button { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) } label: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")).resizable().frame(width: 44, height: 44)
            }.buttonStyle(.plain).help("Ayarlar")
            Button { showActivity.toggle() } label: {
                Image(systemName: device.events.isEmpty ? "bell" : "bell.badge.fill")
                    .font(.system(size: 22)).frame(width: 40, height: 40)
            }.buttonStyle(.plain).help("Veyra bildirimleri").accessibilityLabel("Veyra bildirimleri")
                .popover(isPresented: $showActivity, arrowEdge: .trailing) { ActivityPanel(device: device) }
            Spacer()
            Button { withAnimation { screen = .dashboard } } label: { Image(systemName: "square.grid.3x3.fill").font(.system(size: 20)).frame(width: 36, height: 40) }.buttonStyle(.plain).help("Dashboard")
        }.padding(.vertical, 15).frame(width: 70).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 30)).overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.15)))
    }
    private func appButton(_ id: String, fallback: String, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
            } else { Image(systemName: fallback).font(.title2).frame(width: 44, height: 44) }
        }.buttonStyle(.plain).help(name).accessibilityLabel(name)
    }
    private func openApp(_ id: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in } }
    }
    private func averageColor(_ data: Data) -> Color? {
        guard let input = CIImage(data: data), let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let color = NSColor(srgbRed: Double(pixel[0])/255, green: Double(pixel[1])/255, blue: Double(pixel[2])/255, alpha: 1).usingColorSpace(.deviceRGB)!
        return Color(hue: Double(color.hueComponent), saturation: max(0.45, Double(color.saturationComponent)), brightness: min(0.64, max(0.28, Double(color.brightnessComponent))))
    }
}

struct ImmersiveMusic: View {
    @ObservedObject var player: MusicPlayer
    var artwork: NSImage?
    @State private var seeking = false
    @State private var seekValue = 0.0
    var body: some View {
        GeometryReader { geo in
            let coverSize = min(geo.size.width * 0.36, geo.size.height * 0.73)
            HStack(spacing: geo.size.width * 0.045) {
                VStack(spacing: 0) {
                    Spacer(minLength: 10)
                    VStack(spacing: 5) {
                        Text(player.title).font(.system(size: 27, weight: .semibold)).lineLimit(2)
                        Text(player.artist).font(.system(size: 22)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                        if !player.album.isEmpty { Text(player.album + " ›").font(.system(size: 19)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
                    }.multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(height: geo.size.height * 0.24)
                    Spacer(minLength: 20)
                    HStack(spacing: 12) {
                        control("backward.fill", name: "Önceki parça", command: "previous track")
                        control(player.playing ? "pause.fill" : "play.fill", name: player.playing ? "Duraklat" : "Oynat", command: "playpause")
                        control("forward.fill", name: "Sonraki parça", command: "next track")
                    }.padding(.horizontal, 10)
                    Spacer().frame(height: 32)
                    HStack(spacing: 10) {
                        Text(time(seeking ? seekValue : player.position)).frame(width: 44, alignment: .trailing)
                        SoftSlider(value: Binding(get: { seeking ? seekValue : min(player.position, player.duration) }, set: { seekValue = $0 }), maximum: player.duration, label: "Parça konumu") { editing in
                            if editing { seekValue = player.position; seeking = true }
                            else { player.seek(to: seekValue); seeking = false }
                        }.disabled(!player.connected)
                        Text("−" + time(max(0, player.duration - (seeking ? seekValue : player.position)))).frame(width: 46, alignment: .leading)
                    }.font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 38) {
                        Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffling ? .white : .white.opacity(0.55)) }.help("Karışık çal")
                        Button { player.toggleRepeat() } label: { Image(systemName: "repeat").foregroundStyle(player.repeating ? .white : .white.opacity(0.55)) }.help("Tekrarla")
                        Button { player.openSource() } label: { Image(systemName: "arrow.up.forward.app") }.help("Müzik uygulamasında aç")
                        Menu {
                            Button("\(player.source) aç") { player.openSource() }
                            Button("Yeniden bağlan") { player.connect() }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }.font(.system(size: 18)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).padding(.top, 30).disabled(!player.connected)
                    if !player.connected { Button("\(player.source) Bağla") { player.connect() }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 10).background(.white.opacity(0.15), in: Capsule()).padding(.top, 20) }
                    if !player.message.isEmpty { Text(player.message).font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.top, 12) }
                    Spacer(minLength: 20)
                }.frame(maxWidth: .infinity)
                Group {
                    if let artwork { Image(nsImage: artwork).resizable().scaledToFit() }
                    else {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.93, green: 0.045, blue: 0.12), Color(red: 0.48, green: 0.015, blue: 0.035)], startPoint: .topTrailing, endPoint: .bottomLeading)
                            Image(systemName: "music.note").font(.system(size: 90, weight: .ultraLight)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }.frame(width: coverSize, height: coverSize).clipShape(RoundedRectangle(cornerRadius: 8)).shadow(color: .black.opacity(0.28), radius: 18, y: 12)
            }.padding(.leading, 30).padding(.trailing, 28).frame(width: geo.size.width, height: geo.size.height)
        }
    }
    private func control(_ icon: String, name: String, command: String) -> some View {
        Button { player.command(command) } label: { Image(systemName: icon).font(.system(size: 35, weight: .bold)) }.buttonStyle(TransportStyle()).disabled(!player.connected).accessibilityLabel(name).help(name)
    }
    private func time(_ value: Double) -> String { let v = Int(max(0, value)); return String(format: "%d:%02d", v/60, v%60) }
}

struct WeatherPayload: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let is_day: Int
    }
    struct Daily: Decodable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
    }
    let current: Current
    let daily: Daily
    var description: String {
        switch current.weather_code {
        case 0: return "Açık"
        case 1, 2: return "Parçalı bulutlu"
        case 3: return "Bulutlu"
        case 45, 48: return "Sisli"
        case 51...57: return "Çisenti"
        case 61...67: return "Yağmurlu"
        case 71...77: return "Karlı"
        case 80...82: return "Sağanak yağışlı"
        case 85, 86: return "Kar sağanağı"
        case 95...99: return "Gök gürültülü"
        default: return "Hava durumu"
        }
    }
    var icon: String {
        switch current.weather_code {
        case 0: return current.is_day == 1 ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return current.is_day == 1 ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
struct WeatherCity: Decodable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?
    var detail: String { [admin1, country].compactMap { $0 }.joined(separator: ", ") }
}
struct CityResults: Decodable { let results: [WeatherCity]? }

@MainActor final class WeatherModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var weather: WeatherPayload?
    @Published var place = "Bulunduğun konum"
    @Published var message = ""
    @Published var loading = false
    @Published var updated: Date?
    @Published var automatic: Bool
    private let manager = CLLocationManager()
    private var timer: Timer?
    private var requestTask: Task<Void, Never>?
    private var locationTimeout: Task<Void, Never>?
    private var lastLocation: CLLocation?
    private var started = false
    override init() {
        automatic = UserDefaults.standard.string(forKey: "weatherMode") != "manual"
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    deinit { timer?.invalidate(); requestTask?.cancel(); locationTimeout?.cancel() }
    func start() {
        guard !started else { return }; started = true
        if automatic { useMacLocation() }
        else if let name = UserDefaults.standard.string(forKey: "weatherCity") {
            place = name
            lastLocation = CLLocation(latitude: UserDefaults.standard.double(forKey: "weatherLatitude"), longitude: UserDefaults.standard.double(forKey: "weatherLongitude"))
            refresh()
        }
    }
    func useMacLocation() {
        requestTask?.cancel(); locationTimeout?.cancel()
        weather = nil; updated = nil; lastLocation = nil
        automatic = true; place = "Bulunduğun konum"
        UserDefaults.standard.set("automatic", forKey: "weatherMode")
        for key in ["weatherCity", "weatherLatitude", "weatherLongitude"] { UserDefaults.standard.removeObject(forKey: key) }
        message = "Konum izni bekleniyor…"; loading = false
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: requestLocation()
        default: locationUnavailable()
        }
    }
    private func requestLocation() {
        locationTimeout?.cancel()
        loading = true; message = "Konum alınıyor…"
        manager.requestLocation()
        locationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.loading = false; self.message = "Konum alınamadı. Tekrar dene veya şehir seç."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard started, automatic else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: requestLocation()
        case .denied, .restricted:
            requestTask?.cancel(); locationTimeout?.cancel(); weather = nil; updated = nil; lastLocation = nil
            locationUnavailable()
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard automatic, let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else { return }
        locationTimeout?.cancel()
        lastLocation = location
        fetch(location: location, resolveName: true)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard automatic else { return }
        locationTimeout?.cancel(); loading = false
        message = "Mac’in konumu alınamadı. Konum Servisleri’ni kontrol et veya şehir seç."
    }
    private func locationUnavailable() {
        loading = false; message = "Konum izni kapalı. Şehir seç veya Sistem Ayarları’ndan Veyra’ya konum izni ver."
    }
    func select(_ city: WeatherCity) {
        automatic = false
        manager.stopUpdatingLocation(); locationTimeout?.cancel(); requestTask?.cancel()
        weather = nil; updated = nil; place = city.name
        let defaults = UserDefaults.standard
        defaults.set("manual", forKey: "weatherMode"); defaults.set(city.name, forKey: "weatherCity")
        defaults.set(city.latitude, forKey: "weatherLatitude"); defaults.set(city.longitude, forKey: "weatherLongitude")
        let location = CLLocation(latitude: city.latitude, longitude: city.longitude)
        lastLocation = location
        fetch(location: location, resolveName: false)
    }
    func refresh() {
        if automatic {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: requestLocation()
            case .notDetermined: useMacLocation()
            default: locationUnavailable()
            }
        } else if let lastLocation { fetch(location: lastLocation, resolveName: false) }
    }
    private func fetch(location: CLLocation, resolveName: Bool) {
        requestTask?.cancel(); loading = true; message = ""
        let latitude = (location.coordinate.latitude * 100).rounded() / 100
        let longitude = (location.coordinate.longitude * 100).rounded() / 100
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"), .init(name: "timezone", value: "auto")
        ]
        let url = components.url!
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                let result = try JSONDecoder().decode(WeatherPayload.self, from: bytes)
                guard !result.daily.temperature_2m_max.isEmpty, !result.daily.temperature_2m_min.isEmpty else { throw URLError(.cannotParseResponse) }
                self.weather = result; self.updated = Date(); self.loading = false
                if resolveName {
                    let places = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude), preferredLocale: Locale(identifier: "tr_TR"))
                    try Task.checkCancellation()
                    if let place = places?.first { self.place = place.locality ?? place.administrativeArea ?? "Bulunduğun konum" }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.loading = false
                self.message = self.weather == nil ? "Hava durumu alınamadı. Bağlantını kontrol edip yeniden dene." : "Yenilenemedi; son alınan veriler gösteriliyor."
            }
        }
    }
}

struct WeatherCard: View {
    @ObservedObject var model: WeatherModel
    @State private var showLocation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.place, systemImage: model.automatic ? "location.fill" : "mappin.and.ellipse").font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { showLocation = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }.help("Hava durumu konumu").accessibilityLabel("Hava durumu konumu")
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }.disabled(model.loading).help("Hava durumunu yenile")
            }
            if let weather = model.weather {
                HStack(spacing: 16) {
                    Image(systemName: weather.icon).symbolRenderingMode(.multicolor).font(.system(size: 44)).frame(width: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Int(weather.current.temperature_2m.rounded()))°").font(.system(size: 46, weight: .medium, design: .rounded))
                        Text(weather.description).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("Y: \(Int((weather.daily.temperature_2m_max.first ?? 0).rounded()))°   D: \(Int((weather.daily.temperature_2m_min.first ?? 0).rounded()))°")
                        Text("Hissedilen \(Int(weather.current.apparent_temperature.rounded()))°")
                    }.font(.caption).foregroundStyle(.white.opacity(0.65))
                }
            } else {
                Text(model.message.isEmpty ? "Konumuna göre hava durumu" : model.message).font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Button("Şehir seç") { showLocation = true }.buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            if model.weather != nil && !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.orange) }
            HStack {
                if let updated = model.updated { Text("Güncellendi \(updated.formatted(date: .omitted, time: .shortened))") }
                Spacer()
                Link("Open‑Meteo ↗", destination: URL(string: "https://open-meteo.com/")!)
            }.font(.caption2).foregroundStyle(.white.opacity(0.45))
        }.buttonStyle(.plain).modifier(HomeCard()).sheet(isPresented: $showLocation) { WeatherLocationView(model: model) }
    }
}

struct WeatherLocationView: View {
    @ObservedObject var model: WeatherModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [WeatherCity] = []
    @State private var searching = false
    @State private var error = ""
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Hava durumu konumu").font(.title2.weight(.semibold)); Spacer(); Button("Bitti") { dismiss() } }
            Text("Yaklaşık konum hava tahmini için Open‑Meteo’ya, şehir adı için Apple’a gönderilir. Mac’in koordinatları kaydedilmez.").font(.caption).foregroundStyle(.secondary)
            Button("Mac’in konumunu kullan", systemImage: "location.fill") { model.useMacLocation(); dismiss() }.buttonStyle(.borderedProminent)
            Divider()
            HStack {
                TextField("Şehir ara", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("Ara") { search() }.disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
                if searching { ProgressView().controlSize(.small) }
            }
            Text(error).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(results) { city in
                        Button { model.select(city); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(city.name).font(.headline)
                                Text(city.detail).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 190)
        }.padding(26).frame(width: 480).preferredColorScheme(.dark).onDisappear { searchTask?.cancel() }
    }
    private func search() {
        searchTask?.cancel()
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return }
        searching = true; results = []; error = ""
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "5"), .init(name: "language", value: "tr")]
        let requestURL = url.url!
        searchTask = Task {
            do {
                let (bytes, response) = try await URLSession.shared.data(for: URLRequest(url: requestURL, timeoutInterval: 15))
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                results = try JSONDecoder().decode(CityResults.self, from: bytes).results ?? []
                error = results.isEmpty ? "Şehir bulunamadı. Başka bir ad dene." : ""; searching = false
            } catch { guard !Task.isCancelled else { return }; searching = false; self.error = "Arama yapılamadı. İnternet bağlantını kontrol et." }
        }
    }
}

struct MapPlace: Identifiable {
    let id = UUID()
    let item: MKMapItem
}
@MainActor final class EmbeddedMapModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var position: MapCameraPosition = .region(MKCoordinateRegion(center: .init(latitude: 20, longitude: 0), span: .init(latitudeDelta: 100, longitudeDelta: 160)))
    @Published var query = ""
    @Published var results: [MapPlace] = []
    @Published var selected: UUID?
    @Published var location: CLLocationCoordinate2D?
    @Published var message = ""
    @Published var searching = false
    @Published var route: MKRoute?
    @Published var routing = false
    @Published var routeMessage = ""
    @Published var travelMode = "Araba" { didSet { if travelMode != oldValue { clearRoute() } } }
    private var directions: MKDirections?
    private var routeTask: Task<Void, Never>?
    var visibleRegion: MKCoordinateRegion?
    private let manager = CLLocationManager()
    private var searchTask: Task<Void, Never>?
    private var search: MKLocalSearch?
    private var started = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    func start() { guard !started else { return }; started = true; locate() }
    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: message = "Konum alınıyor…"; manager.requestLocation()
        default: message = "Konum izni kapalı. Yine de şehir veya yer arayabilirsin."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard started else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: location = nil; message = "Konum izni kapalı. Yer arama kullanılabilir."
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0, abs(fix.timestamp.timeIntervalSinceNow) < 300 else { return }
        let coordinate = CLLocationCoordinate2D(latitude: (fix.coordinate.latitude * 100).rounded() / 100, longitude: (fix.coordinate.longitude * 100).rounded() / 100)
        clearRoute()
        location = coordinate
        position = .region(.init(center: coordinate, span: .init(latitudeDelta: 0.07, longitudeDelta: 0.07)))
        message = "Yaklaşık konumun gösteriliyor."
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "Konum alınamadı. Yer arayabilir veya tekrar deneyebilirsin." }
    func runSearch() {
        clearRoute()
        search?.cancel(); searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; selected = nil; searching = false; return }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
        if let visibleRegion, visibleRegion.span.latitudeDelta < 10 { request.region = visibleRegion }
        let operation = MKLocalSearch(request: request); search = operation; searching = true; message = ""
        searchTask = Task { [weak self] in
            do {
                let response = try await operation.start()
                try Task.checkCancellation()
                guard let self else { return }
                self.results = response.mapItems.prefix(12).map { MapPlace(item: $0) }
                self.selected = nil; self.searching = false
                if self.results.isEmpty { self.message = "Sonuç bulunamadı. Başka bir yer adı dene." }
                else { self.position = .region(response.boundingRegion) }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.searching = false; self.message = "Arama tamamlanamadı. İnternet bağlantını kontrol et."
            }
        }
    }
    func select(_ place: MapPlace) {
        clearRoute()
        selected = place.id
        position = .region(.init(center: place.item.placemark.coordinate, span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012)))
    }
    var destination: MapPlace? { results.first { $0.id == selected } }
    func clearRoute() {
        directions?.cancel(); routeTask?.cancel()
        route = nil; routing = false; routeMessage = ""
    }
    func calculateRoute() {
        clearRoute()
        guard let destination else { routeMessage = "Önce arama sonuçlarından bir yer seç."; return }
        guard let location else { routeMessage = "Başlangıç için konum gerekli. Konumuma dön düğmesini kullan."; return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: location))
        request.destination = destination.item
        request.transportType = travelMode == "Yürüyüş" ? .walking : .automobile
        request.requestsAlternateRoutes = false
        let operation = MKDirections(request: request)
        directions = operation; routing = true
        routeTask = Task { [weak self] in
            do {
                let response = try await operation.calculate()
                try Task.checkCancellation()
                guard let self else { return }
                self.routing = false
                guard let route = response.routes.first else { self.routeMessage = "Bu ulaşım türü için rota bulunamadı."; return }
                self.route = route
                self.position = .rect(route.polyline.boundingMapRect.insetBy(dx: -route.polyline.boundingMapRect.width * 0.15 - 1000, dy: -route.polyline.boundingMapRect.height * 0.15 - 1000))
                self.routeMessage = "Başlangıç yaklaşık konumundur. Bu ekran rota önizlemesidir."
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.routing = false; self.routeMessage = "Rota alınamadı. Başlangıcı, hedefi ve internet bağlantını kontrol et."
            }
        }
    }

}
struct RoutePanel: View {
    @ObservedObject var model: EmbeddedMapModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let destination = model.destination {
                Text(destination.item.name ?? "Seçilen yer").font(.headline).lineLimit(2)
                Picker("Ulaşım", selection: $model.travelMode) { Text("Araba").tag("Araba"); Text("Yürüyüş").tag("Yürüyüş") }.pickerStyle(.segmented)
                Button { model.calculateRoute() } label: { Label(model.routing ? "Rota hesaplanıyor…" : "Yol tarifi al", systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(model.routing)
                if model.routing { ProgressView().controlSize(.small) }
            }
            if !model.routeMessage.isEmpty { Text(model.routeMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let route = model.route {
                HStack {
                    Label("\(max(1, Int(ceil(route.expectedTravelTime / 60)))) dk", systemImage: "clock")
                    Spacer()
                    Text(route.distance.formatted(.number.precision(.fractionLength(0))) + " m")
                }.font(.subheadline.weight(.semibold))
                if !route.advisoryNotices.isEmpty { ForEach(route.advisoryNotices, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } }
                Divider()
                Text("Yol tarifi adımları").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(route.steps.filter { !$0.instructions.isEmpty }.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.caption.weight(.semibold)).frame(width: 23, height: 23).background(.white.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.instructions).font(.caption).fixedSize(horizontal: false, vertical: true)
                            if step.distance > 0 { Text("\(Int(step.distance.rounded())) m").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Button("Rotayı temizle") { model.clearRoute() }.buttonStyle(.bordered)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EmbeddedMapScreen: View {
    @ObservedObject var model: EmbeddedMapModel
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Harita", systemImage: "map.fill").font(.title2.weight(.semibold))
                Text("Konum ve yer arama").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    TextField("Şehir, adres veya yer ara", text: $model.query).textFieldStyle(.roundedBorder).onSubmit { model.runSearch() }
                    Button { model.runSearch() } label: { Image(systemName: "magnifyingglass") }.help("Yer ara")
                }
                Button("Konumuma dön", systemImage: "location.fill") { model.locate() }.buttonStyle(.bordered)
                if model.searching { ProgressView("Aranıyor…").controlSize(.small) }
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                ScrollView {
                    VStack(spacing: 10) {
                        if model.destination != nil || !model.routeMessage.isEmpty { RoutePanel(model: model) }
                        ForEach(model.results) { place in
                            Button { model.select(place) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(place.item.name ?? "Yer").font(.subheadline.weight(.semibold))
                                    Text(place.item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white.opacity(model.selected == place.id ? 0.15 : 0.05), in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text("Harita ve aramalar Apple Maps tarafından sağlanır.").font(.caption2).foregroundStyle(.secondary)
            }.padding(22).frame(width: 285).background(.black.opacity(0.27), in: RoundedRectangle(cornerRadius: 24))
            Map(position: $model.position, selection: $model.selected) {
                if let route = model.route { MapPolyline(route.polyline).stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)) }
                if let coordinate = model.location { Annotation("Yaklaşık konum", coordinate: coordinate) { Circle().fill(.blue).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 4) } }
                ForEach(model.results) { place in Marker(place.item.name ?? "Yer", coordinate: place.item.placemark.coordinate).tag(place.id) }
            }.mapControls { MapCompass(); MapScaleView(); MapZoomStepper() }
                .onMapCameraChange(frequency: .onEnd) { model.visibleRegion = $0.region }
                .onChange(of: model.selected) { _, _ in model.clearRoute() }
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
        }.padding(24).task { model.start() }
    }
}

struct FocusCountdown {
    var remaining: TimeInterval
    var deadline: Date?
    func value(at now: Date) -> TimeInterval { max(0, deadline?.timeIntervalSince(now) ?? remaining) }
}
@MainActor final class FocusModel: ObservableObject {
    @Published var workMinutes = 25
    @Published var breakMinutes = 5
    @Published var isBreak = false
    @Published var running = false
    @Published var seconds = 1500.0
    @Published var completed = 0
    @Published var message = "Tek bir işe yer aç."
    private var clock = FocusCountdown(remaining: 1500)
    private var timer: Timer?
    private var day = ""
    private let defaults = UserDefaults.standard
    var total: Double { Double((isBreak ? breakMinutes : workMinutes) * 60) }
    var progress: Double { max(0, min(1, 1 - seconds / total)) }
    private static func dayKey() -> String { let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now); return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)" }
    init() {
        let work = defaults.integer(forKey: "focus.work")
        let rest = defaults.integer(forKey: "focus.break")
        workMinutes = [15,25,45,60].contains(work) ? work : 25
        breakMinutes = [5,10,15].contains(rest) ? rest : 5
        isBreak = defaults.bool(forKey: "focus.isBreak")
        day = Self.dayKey()
        completed = defaults.string(forKey: "focus.day") == day ? defaults.integer(forKey: "focus.completed") : 0
        let saved = defaults.object(forKey: "focus.remaining") as? Double ?? total
        clock = FocusCountdown(remaining: min(total, max(0, saved)), deadline: defaults.object(forKey: "focus.deadline") as? Date)
        running = clock.deadline != nil
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    deinit { timer?.invalidate() }
    func toggle() {
        if running { clock.remaining = clock.value(at: .now); clock.deadline = nil; running = false }
        else { if clock.remaining <= 0 { clock.remaining = total }; clock.deadline = Date().addingTimeInterval(clock.remaining); running = true; message = isBreak ? "Biraz nefes al." : "Şimdi yalnızca bu işe odaklan." }
        tick(); save()
    }
    func reset() { running = false; clock = FocusCountdown(remaining: total); seconds = total; message = "Hazır olduğunda başlat."; save() }
    func setPhase(_ rest: Bool) { isBreak = rest; reset() }
    func settingsChanged() { guard !running else { return }; reset() }
    private func tick() {
        let today = Self.dayKey()
        if day != today { day = today; completed = 0; save() }
        seconds = clock.value(at: .now)
        if running && seconds <= 0 {
            if !isBreak { completed += 1 }
            message = isBreak ? "Mola tamamlandı. Yeni bir odak turuna hazırsın." : "Odak turu tamamlandı. Mola zamanı."
            isBreak.toggle(); running = false; clock = FocusCountdown(remaining: total); seconds = total; save()
        }
    }
    private func save() {
        defaults.set(workMinutes, forKey: "focus.work"); defaults.set(breakMinutes, forKey: "focus.break")
        defaults.set(isBreak, forKey: "focus.isBreak"); defaults.set(clock.remaining, forKey: "focus.remaining")
        if let deadline = clock.deadline { defaults.set(deadline, forKey: "focus.deadline") } else { defaults.removeObject(forKey: "focus.deadline") }
        defaults.set(day, forKey: "focus.day"); defaults.set(completed, forKey: "focus.completed")
    }
}
struct FocusScreen: View {
    @ObservedObject var model: FocusModel
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        HStack(spacing: 10) { Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/Clock.app")).resizable().frame(width: 36, height: 36); Text("Odak").font(.title2.weight(.semibold)) }
                        Spacer()
                        Text("Bugün \(model.completed) tur").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Çalışma") { model.setPhase(false) }.tint(model.isBreak ? .gray : .orange)
                        Button("Mola") { model.setPhase(true) }.tint(model.isBreak ? .mint : .gray)
                    }.buttonStyle(.bordered).disabled(model.running)
                    ZStack {
                        Circle().stroke(.white.opacity(0.08), lineWidth: 10)
                        Circle().trim(from: 0, to: model.progress).stroke(model.isBreak ? Color.mint : Color.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 8) {
                            Text(model.isBreak ? "MOLA" : "ODAK ZAMANI").font(.caption.weight(.bold)).tracking(3).foregroundStyle(.secondary)
                            Text(String(format: "%02d:%02d", Int(ceil(model.seconds)) / 60, Int(ceil(model.seconds)) % 60)).font(.system(size: 70, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                    }.frame(width: min(310, geo.size.height * 0.48), height: min(310, geo.size.height * 0.48)).padding(8)
                    Text(model.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button(model.running ? "Duraklat" : "Başlat", systemImage: model.running ? "pause.fill" : "play.fill") { model.toggle() }.buttonStyle(.borderedProminent).tint(model.isBreak ? .mint : .orange)
                        Button("Sıfırla", systemImage: "arrow.counterclockwise") { model.reset() }.buttonStyle(.bordered)
                    }.controlSize(.large)
                    HStack(spacing: 24) {
                        Picker("Çalışma", selection: $model.workMinutes) { ForEach([15,25,45,60], id: \.self) { Text("\($0) dk").tag($0) } }
                        Picker("Mola", selection: $model.breakMinutes) { ForEach([5,10,15], id: \.self) { Text("\($0) dk").tag($0) } }
                    }.frame(maxWidth: 400).disabled(model.running)
                        .onChange(of: model.workMinutes) { _, _ in model.settingsChanged() }
                        .onChange(of: model.breakMinutes) { _, _ in model.settingsChanged() }
                    Text("Sayaç ekran değiştirince devam eder. macOS Odak / Rahatsız Etme ayarını değiştirmez.").font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: 760).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 28)).frame(maxWidth: .infinity).padding(24)
            }.scrollIndicators(.hidden)
        }
    }
}

struct HomeCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.12)))
    }
}

struct HomeDashboard: View {
    @ObservedObject var player: MusicPlayer
    @ObservedObject var device: DeviceStatus
    @ObservedObject var weather: WeatherModel
    var artwork: NSImage?
    var openMusic: () -> Void
    var openSettings: () -> Void
    var openActivity: () -> Void
    var body: some View {
        GeometryReader { geo in
            let height = max(530, geo.size.height - 48)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        timeCard.frame(height: height * 0.56)
                        WeatherCard(model: weather).frame(height: height * 0.44 - 20)
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 20) {
                        musicCard.frame(height: height * 0.48)
                        MonthCalendar().modifier(HomeCard()).frame(height: height * 0.52 - 20)
                    }.frame(width: max(300, (geo.size.width - 68) * 0.42))
                }.padding(24)
            }.scrollIndicators(.hidden)
        }
    }
    private var timeCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BUGÜN").font(.system(size: 11, weight: .bold)).tracking(3).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Image(systemName: Calendar.current.component(.hour, from: ctx.date) < 18 ? "sun.max" : "moon").foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 112, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.4).lineLimit(1)
                Text(ctx.date, format: .dateTime.day().month(.wide).weekday(.wide)).font(.title3).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Circle().fill(device.online ? .green : .orange).frame(width: 6, height: 6)
                    Text(device.online ? "Çevrimiçi" : "Çevrimdışı")
                    Spacer()
                    if let battery = device.battery {
                        Image(systemName: device.batteryIcon).foregroundStyle(device.powerConnected ? .green : .white.opacity(0.65))
                        Text("%\(battery)")
                    }
                }.font(.caption).foregroundStyle(.white.opacity(0.65))
            }.modifier(HomeCard())
        }
    }
    private var musicCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(player.source, systemImage: "music.note").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button(action: openMusic) { Image(systemName: "arrow.up.right").frame(width: 26, height: 26) }.buttonStyle(.plain).help("Müzik ekranını aç")
            }
            HStack(spacing: 18) {
                Group {
                    if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                    else { ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.orange) } }
                }.frame(width: 82, height: 82).clipShape(RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 6) {
                    Text(player.title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                    Text(player.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            ProgressView(value: min(player.position, player.duration), total: player.duration).tint(.orange)
            HStack(spacing: 28) {
                Spacer()
                Button { player.command("previous track") } label: { Image(systemName: "backward.end.fill").frame(width: 30, height: 32) }.help("Önceki parça")
                Button { player.command("playpause") } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()) }.help("Oynat / duraklat")
                Button { player.command("next track") } label: { Image(systemName: "forward.end.fill").frame(width: 30, height: 32) }.help("Sonraki parça")
                Spacer()
            }.buttonStyle(.plain).disabled(!player.connected)
        }.modifier(HomeCard())
    }
    private var quickCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hızlı erişim").font(.headline)
            HStack(spacing: 12) {
                shortcut("Harita", icon: "map.fill", color: .cyan) { launch("com.apple.Maps") }
                shortcut("Mesajlar", icon: "message.fill", color: .green) { launch("com.apple.MobileSMS") }
                shortcut("Bildirimler", icon: "bell.fill", color: .orange, action: openActivity)
                shortcut("Ayarlar", icon: "gearshape.fill", color: .white.opacity(0.65), action: openSettings)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: player.connected ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(player.connected ? .green : .orange)
                Text(player.connected ? "\(player.source) bağlı" : "Müzik bağlantısı bekleniyor")
            }.font(.caption).foregroundStyle(.white.opacity(0.6))
        }.modifier(HomeCard())
    }
    private func shortcut(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 23)).foregroundStyle(color).frame(height: 28)
                Text(label).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
            }.padding(.vertical, 15).frame(maxWidth: .infinity).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain)
    }
    private func launch(_ id: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in } }
    }
}

struct MonthCalendar: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let calendar = Calendar(identifier: .gregorian)
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: ctx.date)) ?? ctx.date
            let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
            let offset = (calendar.component(.weekday, from: start) + 5) % 7
            let today = calendar.component(.day, from: ctx.date)
            VStack(alignment: .leading, spacing: 12) {
                Text(ctx.date, format: .dateTime.month(.wide).year()).font(.headline)
                HStack(spacing: 3) {
                    ForEach(Array(["Pt", "Sa", "Ça", "Pe", "Cu", "Ct", "Pz"].enumerated()), id: \.offset) { _, label in
                        Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity).frame(height: 18)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 6) {
                    ForEach(0..<(offset + count), id: \.self) { cell in
                        let day = cell - offset + 1
                        Text(day > 0 ? "\(day)" : "").font(.system(size: 12, weight: day == today ? .bold : .regular)).monospacedDigit()
                            .frame(maxWidth: .infinity).frame(height: 25)
                            .background { if day == today { Circle().fill(.orange).frame(width: 26, height: 26) } }
                            .foregroundStyle(day == today ? .white : .white.opacity(0.72))
                    }
                }
            }
        }
    }
}

struct ClockCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 20) {
                Text(ctx.date, format: .dateTime.day().month(.wide).weekday(.wide)).font(.title2).foregroundStyle(.white.opacity(0.7))
                Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).font(.system(size: 120, weight: .light, design: .rounded)).monospacedDigit().minimumScaleFactor(0.4).lineLimit(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Veyra") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
        Toggle("Activate When Idle", isOn: $model.idleEnabled)
        Button("Ayarlar…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Tam ekranı aç / kapat") { model.toggleDashboardFullscreen() }
        Divider()
        Button("Quit Veyra") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var model: DashboardModel
    var body: some View {
        Form {
            Section("Pencere") {
                Button("Tam ekranı aç / kapat", systemImage: "arrow.up.left.and.arrow.down.right") { model.toggleDashboardFullscreen() }
                Text("Klavye kısayolu: Control + Command + F").font(.caption).foregroundStyle(.secondary)
            }
            Section("Görünüm") {
                Picker("Tema", selection: $model.theme) {
                    Text("Albüm rengine uyumlu").tag("Adaptive")
                    Text("Açık").tag("Light")
                    Text("Koyu").tag("Dark")
                }
            }
            Section("Boşta etkinleşme") {
                Toggle("Mac boşta kalınca Veyra’yı aç", isOn: $model.idleEnabled)
                Picker("Bekleme süresi", selection: $model.idleMinutes) {
                    ForEach([1.0, 2, 5, 10, 15, 30], id: \.self) { Text("\(Int($0)) dakika").tag($0) }
                }.disabled(!model.idleEnabled)
                Toggle("Boşta etkinleşince tam ekran aç", isOn: $model.idleFullscreen).disabled(!model.idleEnabled)
                Text("Otomatik etkinleşme için Veyra açık kalmalıdır.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 480, height: 490)
    }
}
