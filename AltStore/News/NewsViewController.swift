
//
//  NewsViewController.swift
//  AltStore
//

@preconcurrency import UIKit
import SwiftUI
import Network
import UniformTypeIdentifiers
@preconcurrency import Minimuxer
import MinimuxerCommon
import Combine
import Darwin

private enum AnisetteDefaultsHelper {
    static var currentServerURL: String {
        let menuURL = UserDefaults.standard.menuAnisetteURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !menuURL.isEmpty {
            return menuURL
        }
        if let textInput = UserDefaults.standard.textInputAnisetteURL?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !textInput.isEmpty {
            return textInput
        }
        if let custom = UserDefaults.standard.customAnisetteURL?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return AppConstants.Anisette.Servers.defaultServerURL
    }
    
    static func selectServerFromList(_ url: String) {
        let trimmed = url.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.textServer = false
        UserDefaults.standard.menuAnisetteURL = trimmed
        UserDefaults.standard.textInputAnisetteURL = trimmed
        UserDefaults.standard.customAnisetteURL = trimmed
    }
    
    static func setCustomServerURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.menuAnisetteURL = trimmed
        UserDefaults.standard.textInputAnisetteURL = trimmed
        UserDefaults.standard.customAnisetteURL = trimmed
    }
}

class NewsViewController: UICollectionViewController {
    var source: Source?
    
    init?(source: Source?, coder: NSCoder) {
        self.source = source
        super.init(coder: coder)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.title = "Check"
        self.navigationItem.title = "Kiểm Tra Hệ Thống"
        self.collectionView.backgroundColor = .systemGroupedBackground
        
        let hostingController = UIHostingController(rootView: SystemCheckDashboardView())
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .systemGroupedBackground
        view.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
}

@MainActor
final class SystemCheckViewModel: ObservableObject {
    @Published var isPairingOK: Bool = false
    @Published var pairingProtocol: String = "Đang kiểm tra..."
    @Published var hasAnyStoredPairingFile: Bool = false
    
    @Published var isVpnOK: Bool = false
    @Published var tunnelIP: String = "Chưa kết nối"
    @Published var deviceIP: String = "Chưa kết nối"
    
    @Published var isCellularOK: Bool = false
    @Published var cellularDetail: String = "Đang kiểm tra..."
    @Published var hasInternet: Bool = false
    
    @Published var isAnisetteOK: Bool = !UserDefaults.standard.useOnDeviceAnisette
    @Published var useOnDeviceAnisette: Bool = UserDefaults.standard.useOnDeviceAnisette
    @Published var selectedAnisetteServerURL: String = AnisetteDefaultsHelper.currentServerURL
    @Published var anisetteDetail: String = "Đang kiểm tra..."
    
    private let pathMonitor = NWPathMonitor()
    private let cellularMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let monitorQueue = DispatchQueue(label: "com.sidestore.check.network")
    
    private var usesCellularPath: Bool = false
    private var isCellularPathSatisfied: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?
    
    private var isChecking: Bool = false
    private var lastVerifiedPairingSuccess: Bool = false
    
    init() {
        updateInstantStatus()
        setupRealtimeListeners()
        Task {
            _ = try? await AnisetteServersManager.shared.syncWithRemote()
        }
    }
    
    deinit {
        pathMonitor.cancel()
        cellularMonitor.cancel()
        timerTask?.cancel()
    }
    
    private func setupRealtimeListeners() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let usesCell = path.usesInterfaceType(.cellular)
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.usesCellularPath = usesCell
                self.hasInternet = satisfied
                self.updateInstantStatus()
                await self.checkAllStatuses()
            }
        }
        pathMonitor.start(queue: monitorQueue)
        
        cellularMonitor.pathUpdateHandler = { [weak self] path in
            let cellSatisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isCellularPathSatisfied = cellSatisfied
                self.updateInstantStatus()
                await self.checkAllStatuses()
            }
        }
        cellularMonitor.start(queue: monitorQueue)
        
        minimuxer.network.pathPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateInstantStatus()
                Task { @MainActor [weak self] in
                    await self?.checkAllStatuses()
                }
            }
            .store(in: &cancellables)
        
        minimuxerStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateInstantStatus()
                Task { @MainActor [weak self] in
                    await self?.checkAllStatuses()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateInstantStatus()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateInstantStatus()
                Task { @MainActor [weak self] in
                    _ = try? await AnisetteServersManager.shared.syncWithRemote()
                    await self?.checkAllStatuses(forceVerify: true)
                }
            }
            .store(in: &cancellables)
        
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllStatuses(forceVerify: false)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    
    private struct SystemInterfaceSnapshot: Sendable {
        let hasCellularIPv4: Bool
        let hasActiveUtun: Bool
        let detectedUtunIPv4: String?
    }
    
    private nonisolated static func scanSystemInterfaces() -> SystemInterfaceSnapshot {
        var hasPdpIPv4 = false
        var hasUtun = false
        var bestUtunIP: String? = nil
        
        for iface in minimuxer.network.activeInterfaces {
            let lower = iface.name.lowercased()
            if lower.hasPrefix("utun") { hasUtun = true }
        }
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let current = ptr {
                let flags = Int32(current.pointee.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
                if isUp, let addr = current.pointee.ifa_addr {
                    let family = addr.pointee.sa_family
                    let name = String(cString: current.pointee.ifa_name).lowercased()
                    
                    // Chỉ tính pdp_ip0 (data cellular chính) có địa chỉ IPv4 thực để tránh nhầm với IMS/VoLTE khi đã tắt 4G/5G
                    if family == UInt8(AF_INET), name == "pdp_ip0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            addr,
                            socklen_t(addr.pointee.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        ) == 0 {
                            let ip = String(cString: hostname)
                            if !ip.isEmpty && !ip.hasPrefix("169.254.") && ip != "0.0.0.0" {
                                hasPdpIPv4 = true
                            }
                        }
                    }
                    
                    if family == UInt8(AF_INET), name.hasPrefix("utun") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            addr,
                            socklen_t(addr.pointee.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        ) == 0 {
                            let ip = String(cString: hostname)
                            if !ip.isEmpty && !ip.hasPrefix("169.254.") {
                                if ip.hasPrefix("10.7.") {
                                    hasUtun = true
                                    bestUtunIP = ip
                                } else if bestUtunIP == nil {
                                    bestUtunIP = ip
                                    hasUtun = true
                                }
                            }
                        }
                    }
                }
                ptr = current.pointee.ifa_next
            }
        }
        
        return SystemInterfaceSnapshot(
            hasCellularIPv4: hasPdpIPv4,
            hasActiveUtun: hasUtun,
            detectedUtunIPv4: bestUtunIP
        )
    }
    
    func setUseOnDeviceAnisette(_ enabled: Bool) {
        UserDefaults.standard.useOnDeviceAnisette = enabled
        updateInstantStatus()
    }
    
    func selectAnisetteServerURL(_ urlString: String, isCustom: Bool = false) {
        if isCustom {
            AnisetteDefaultsHelper.setCustomServerURL(urlString)
        } else {
            AnisetteDefaultsHelper.selectServerFromList(urlString)
        }
        if UserDefaults.standard.useOnDeviceAnisette {
            UserDefaults.standard.useOnDeviceAnisette = false
        }
        updateInstantStatus()
    }
    
    func updateInstantStatus() {
        let snapshot = Self.scanSystemInterfaces()
        
        let cellularActive = usesCellularPath || (isCellularPathSatisfied && snapshot.hasCellularIPv4)
        self.isCellularOK = cellularActive
        if usesCellularPath {
            self.cellularDetail = "Ổn định • Đang dùng trực tiếp 4G / Di động"
        } else if cellularActive {
            self.cellularDetail = "Ổn định • 4G / Di động đang bật sẵn sàng"
        } else {
            self.cellularDetail = "Không ổn định • Đang tắt Dữ liệu di động (4G/5G)"
        }
        
        let config = ConnectionConfig.shared
        let rawTunnelIP = config.tunnelIfaceIp ?? snapshot.detectedUtunIPv4
        let rawPeerIP: String? = {
            if config.overrideTunnelPeerReachable, !config.overrideTunnelPeerIp.isEmpty {
                return config.overrideTunnelPeerIp
            }
            if let peer = config.tunnelPeerIp, !peer.isEmpty {
                return peer
            }
            if let tIP = rawTunnelIP, tIP.hasPrefix("10.7.") {
                return "10.7.0.1"
            }
            return nil
        }()
        
        self.tunnelIP = config.formattedTunnelIface ?? rawTunnelIP ?? "Chưa kết nối"
        self.deviceIP = config.formattedTunnelPeer ?? rawPeerIP ?? "Chưa kết nối"
        
        self.isVpnOK = minimuxer.network.isUTunAvailable
            || (snapshot.hasActiveUtun && rawTunnelIP != nil)
            || (config.formattedTunnelIface != nil && config.formattedTunnelPeer != nil)
        
        let hasRp = PairingFileManager.shared.hasPairingFile(for: .rppairing)
        let hasLd = PairingFileManager.shared.hasPairingFile(for: .lockdown)
        let hasUnk = PairingFileManager.shared.hasPairingFile(for: .unknown)
        let hasAnyFile = hasRp || hasLd || hasUnk
        self.hasAnyStoredPairingFile = hasAnyFile
        
        let coreLoaded = minimuxer.core.isPairingFileLoaded
        let activeType: PairingProtocol = {
            if coreLoaded && minimuxer.core.pairingFileType != .unknown {
                return minimuxer.core.pairingFileType
            }
            if let persisted = PairingFileManager.shared.persistedActiveProtocol,
               PairingFileManager.shared.hasPairingFile(for: persisted) {
                return persisted
            }
            if hasRp { return .rppairing }
            if hasLd { return .lockdown }
            return .unknown
        }()
        
        switch activeType {
        case .rppairing:
            self.pairingProtocol = "Remote Pairing (iOS 17+ / 27)"
        case .lockdown:
            self.pairingProtocol = "Lockdown Pairing"
        case .unknown:
            self.pairingProtocol = (hasAnyFile || coreLoaded) ? "Đã nạp Pairing File" : "Chưa có Pairing File"
        }
        
        if !hasAnyFile && !coreLoaded {
            self.lastVerifiedPairingSuccess = false
            self.isPairingOK = false
        } else if coreLoaded || self.lastVerifiedPairingSuccess || hasAnyFile {
            self.isPairingOK = true
        }
        
        let onDevice = UserDefaults.standard.useOnDeviceAnisette
        self.useOnDeviceAnisette = onDevice
        self.isAnisetteOK = !onDevice
        
        let selectedURL = AnisetteDefaultsHelper.currentServerURL
        self.selectedAnisetteServerURL = selectedURL
        let serverHost = URL(string: selectedURL)?.host ?? selectedURL
        self.anisetteDetail = onDevice
            ? "Chưa ổn định • Hãy tắt Use On-Device Anisette"
            : "Ổn định • Đang dùng máy chủ (\(serverHost))"
    }
    
    func checkAllStatuses(forceVerify: Bool = false) async {
        updateInstantStatus()
        
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        
        if hasAnyStoredPairingFile && !minimuxer.core.isPairingFileLoaded {
            let proto: PairingProtocol = PairingFileManager.shared.persistedActiveProtocol
                ?? (PairingFileManager.shared.hasPairingFile(for: .rppairing) ? .rppairing : .lockdown)
            try? await minimuxerSwitchPairingProtocol(to: proto)
            updateInstantStatus()
        }
        
        if isVpnOK && (hasAnyStoredPairingFile || minimuxer.core.isPairingFileLoaded) {
            if forceVerify || !lastVerifiedPairingSuccess {
                if let udid = try? await fetchUDID(forceLive: false), !udid.isEmpty {
                    self.lastVerifiedPairingSuccess = true
                    self.isPairingOK = true
                } else if minimuxer.core.isPairingFileLoaded || hasAnyStoredPairingFile {
                    self.isPairingOK = true
                }
            }
        }
        
        updateInstantStatus()
    }
}

struct SystemCheckDashboardView: SwiftUI.View {
    @StateObject private var vm = SystemCheckViewModel()
    @State private var showPairingSheet = false
    @State private var showVpnSheet = false
    @State private var showCellularSheet = false
    @State private var showAnisetteSheet = false
    
    var body: some SwiftUI.View {
        ScrollView {
            VStack(spacing: 22) {
                systemStatusSection
                serverSection
                shortcutsSection
                automationGuideSection
            }
            .padding()
        }
        .background(SwiftUI.Color(UIColor.systemGroupedBackground))
        .onAppear {
            vm.updateInstantStatus()
            Task { await vm.checkAllStatuses(forceVerify: true) }
        }
        .refreshable {
            await vm.checkAllStatuses(forceVerify: true)
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingGuideSheetView(vm: vm)
        }
        .sheet(isPresented: $showVpnSheet) {
            VpnDetailSheetView(isVpnOK: vm.isVpnOK, tunnelIP: vm.tunnelIP, deviceIP: vm.deviceIP)
        }
        .sheet(isPresented: $showCellularSheet) {
            CellularDetailSheetView(isCellularOK: vm.isCellularOK, detail: vm.cellularDetail, hasInternet: vm.hasInternet)
        }
        .sheet(isPresented: $showAnisetteSheet) {
            AnisetteDetailSheetView(vm: vm)
        }
    }
    
    private var systemStatusSection: some SwiftUI.View {
        let allReady = vm.isPairingOK && vm.isVpnOK && vm.isCellularOK && vm.isAnisetteOK
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Trạng Thái Hệ Thống",
                icon: "cpu.fill",
                color: .blue,
                statusOK: allReady
            )
            
            CheckItemButton(
                title: "Pairing File",
                subtitle: vm.isPairingOK ? "Ổn định • \(vm.pairingProtocol)" : "Không ổn định • Nhấn để Cài / Nhập Pairing",
                icon: "doc.badge.gearshape.fill",
                isStable: vm.isPairingOK
            ) {
                showPairingSheet = true
            }
            
            CheckItemButton(
                title: "LocalDevVPN",
                subtitle: vm.isVpnOK ? "Ổn định • Tunnel: \(vm.tunnelIP)" : "Không ổn định • Nhấn xem cấu hình IP",
                icon: "network.badge.shield.half.filled",
                isStable: vm.isVpnOK
            ) {
                showVpnSheet = true
            }
            
            CheckItemButton(
                title: "Mạng 4G / Di động",
                subtitle: vm.cellularDetail,
                icon: "antenna.radiowaves.left.and.right",
                isStable: vm.isCellularOK
            ) {
                showCellularSheet = true
            }
        }
    }
    
    private var serverSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Máy chủ Anisette",
                icon: "server.rack",
                color: .purple
            )
            
            CheckItemButton(
                title: "Máy chủ Anisette",
                subtitle: vm.anisetteDetail,
                icon: "server.rack",
                isStable: vm.isAnisetteOK
            ) {
                showAnisetteSheet = true
            }
        }
    }
    
    private var shortcutsSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Phím Tắt",
                icon: "bolt.circle.fill",
                color: .orange
            )
            
            ShortcutLinkRow(
                title: "Phím tắt Tắt 4G",
                subtitle: "Tắt nhanh dữ liệu di động",
                icon: "antenna.radiowaves.left.and.right.slash",
                color: .red,
                urlString: "https://www.icloud.com/shortcuts/ee47f3710b02435883faa746c7355236"
            )
            
            ShortcutLinkRow(
                title: "Phím tắt Bật 4G",
                subtitle: "Bật nhanh dữ liệu di động",
                icon: "antenna.radiowaves.left.and.right",
                color: .blue,
                urlString: "https://www.icloud.com/shortcuts/10bd8bb0aa1540c4b1221182b835fc43"
            )
            
            ShortcutLinkRow(
                title: "Tự động làm mới App hằng ngày (6h sáng)",
                subtitle: "Tự động làm mới qua 4G + VPN lúc 6:00 sáng",
                icon: "clock.arrow.2.circlepath",
                color: .green,
                urlString: "https://www.icloud.com/shortcuts/56b0ab8cb0984d0b9a98543ac879eeec"
            )
            
            ShortcutLinkRow(
                title: "Tự động làm mới App hằng ngày (3h chiều)",
                subtitle: "Tự động làm mới qua 4G + VPN lúc 15:00 chiều",
                icon: "sun.max.circle.fill",
                color: .orange,
                urlString: "https://www.icloud.com/shortcuts/9f93051e8bf142258ffc93e08f3c0849"
            )
        }
    }
    
    private var automationGuideSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(
                title: "Hướng Dẫn Tự Động Hóa",
                icon: "bell.badge.fill",
                color: .green
            )
            
            VStack(alignment: .leading, spacing: 12) {
                SwiftUI.Text("Để bật chế độ tự động chạy hăng ngày lúc 6h sáng hoặc 3h chiều, bạn hãy thiết lập giống như 2 ảnh hướng dẫn dưới đây:")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                VStack(spacing: 16) {
                    RemoteGuideImageView(
                        urlString: "https://raw.githubusercontent.com/Nguyenhuyhoan/icons/main/IMG_2589.jpeg",
                        caption: "Ảnh 1: Bật dấu thả xuống để điều chỉnh Tự động hoá"
                    )
                    RemoteGuideImageView(
                        urlString: "https://raw.githubusercontent.com/Nguyenhuyhoan/icons/main/IMG_2588.jpeg",
                        caption: "Ảnh 2: Thiết lập tự động chạy hằng ngày"
                    )
                }
            }
            .padding()
            .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
    }
}

struct SectionHeaderView: SwiftUI.View {
    let title: String
    let icon: String
    let color: SwiftUI.Color
    var statusOK: Bool? = nil
    
    var body: some SwiftUI.View {
        HStack(spacing: 8) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                SwiftUI.Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(color)
            }
            
            SwiftUI.Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            if let statusOK = statusOK {
                SwiftUI.Image(systemName: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(statusOK ? .green : .red)
                    .animation(.spring(), value: statusOK)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

struct CheckItemButton: SwiftUI.View {
    let title: String
    let subtitle: String
    let icon: String
    let isStable: Bool
    let action: () -> Void
    
    var body: some SwiftUI.View {
        SwiftUI.Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isStable ? SwiftUI.Color.green.opacity(0.15) : SwiftUI.Color.red.opacity(0.15))
                        .frame(width: 46, height: 46)
                    SwiftUI.Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isStable ? .green : .red)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    SwiftUI.Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    SwiftUI.Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                SwiftUI.Image(systemName: isStable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isStable ? .green : .red)
                    .animation(.spring(), value: isStable)
                
                SwiftUI.Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ShortcutLinkRow: SwiftUI.View {
    let title: String
    let subtitle: String
    let icon: String
    let color: SwiftUI.Color
    let urlString: String
    
    var body: some SwiftUI.View {
        SwiftUI.Button(action: {
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 42, height: 42)
                    SwiftUI.Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    SwiftUI.Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    SwiftUI.Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                SwiftUI.Text("Cài đặt")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.15))
                    .foregroundColor(color)
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct RemoteGuideImageView: SwiftUI.View {
    let urlString: String
    let caption: String
    
    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 6) {
            SwiftUI.Text(caption)
                .font(.caption.bold())
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .center)
            
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        HStack(spacing: 8) {
                            ProgressView()
                            SwiftUI.Text("Đang tải ảnh hướng dẫn...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(12)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(SwiftUI.Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    case .failure:
                        VStack(spacing: 6) {
                            SwiftUI.Image(systemName: "wifi.exclamationmark")
                                .font(.title2)
                            SwiftUI.Text("Không tải được ảnh. Hãy kiểm tra kết nối mạng.")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(12)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
    }
}

struct PairingGuideSheetView: SwiftUI.View {
    @ObservedObject var vm: SystemCheckViewModel
    @StateObject private var wirelessVM = WirelessPairViewModel()
    @StateObject private var pairingMgmtVM = PairingFileManagementViewModel()
    
    @State private var statusBannerMessage: String? = nil
    @State private var isExportSheetPresented = false
    @State private var exportFileURL: URL? = nil
    @State private var didPressInstallPairing = false
    
    @Environment(\.dismiss) private var dismiss
    
    private var installedPairingURLForExport: URL? {
        if let url = wirelessVM.shareSheetURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
    
    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusHeaderCard
                    
                    if let banner = statusBannerMessage {
                        HStack(spacing: 10) {
                            SwiftUI.Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            SwiftUI.Text(banner)
                                .font(.footnote.bold())
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(12)
                        .background(SwiftUI.Color.blue.opacity(0.12))
                        .cornerRadius(12)
                    }
                    
                    ios27DirectPairingCard
                    pcPairingGuideCard
                }
                .padding()
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SwiftUI.Text("Hướng Dẫn & Cài Pairing")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    SwiftUI.Button("Xong") { dismiss() }
                }
            }
            #if !os(tvOS)
            .fileImporter(
                isPresented: $pairingMgmtVM.showFileImporter,
                allowedContentTypes: pairingMgmtVM.allowedPairingTypes
            ) { result in
                if case .success = result {
                    // Tự động xoá toàn bộ tệp Pairing cũ trước khi nhập tệp mới
                    PairingFileManager.shared.resetAllPairingFiles()
                }
                pairingMgmtVM.handleImportResult(result)
                Task { @MainActor in
                    let proto = PairingFileManager.shared.persistedActiveProtocol
                        ?? PairingFileManager.shared.preferredProtocol
                        ?? .rppairing
                    try? await minimuxerSwitchPairingProtocol(to: proto)
                    vm.updateInstantStatus()
                    await vm.checkAllStatuses(forceVerify: true)
                    if case .success = result {
                        statusBannerMessage = "Đã xoá tệp cũ và nhập tệp Pairing mới thành công!"
                    }
                }
            }
            #endif
            .sheet(isPresented: Binding(
                get: { wirelessVM.pinCode != nil },
                set: { if !$0 { wirelessVM.pinCode = nil } }
            )) {
                if let pin = wirelessVM.pinCode {
                    if #available(iOS 16.0, tvOS 16.0, *) {
                        WirelessPairPinDialog(pin: pin) { wirelessVM.pinCode = nil }
                            .presentationDetents([.fraction(0.45), .medium])
                            .presentationDragIndicator(.visible)
                    } else {
                        WirelessPairPinDialog(pin: pin) { wirelessVM.pinCode = nil }
                    }
                }
            }
            .sheet(isPresented: $wirelessVM.isShareSheetPresented) {
                if let fileURL = wirelessVM.shareSheetURL {
                    ActivityViewController(activityItems: [fileURL])
                }
            }
            .sheet(isPresented: $isExportSheetPresented) {
                if let fileURL = exportFileURL {
                    ActivityViewController(activityItems: [fileURL])
                }
            }
            .onChange(of: wirelessVM.pairedDevice != nil) { isPaired in
                if isPaired, let pairedURL = wirelessVM.shareSheetURL {
                    PairingFileManager.shared.resetAllPairingFiles()
                    try? PairingFileManager.shared.importPairingFile(from: pairedURL, preferred: .rppairing)
                    Task { @MainActor in
                        try? await minimuxerSwitchPairingProtocol(to: .rppairing)
                        vm.updateInstantStatus()
                        await vm.checkAllStatuses(forceVerify: true)
                        statusBannerMessage = "Đã cài Pairing lên iPhone thành công! Hãy nhấn nút “Xuất tệp Pairing” để lưu vào Tệp, sau đó nhấn “Nhập tệp Pairing”."
                    }
                }
            }
        }
    }
    
    private var statusHeaderCard: some SwiftUI.View {
        HStack(spacing: 12) {
            SwiftUI.Image(systemName: vm.isPairingOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title)
                .foregroundColor(vm.isPairingOK ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                SwiftUI.Text(vm.isPairingOK ? "Pairing File Đang Ổn Định" : "Pairing File Chưa Ổn Định")
                    .font(.headline)
                SwiftUI.Text("Trạng thái: \(vm.pairingProtocol)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }
    
    private var ios27DirectPairingCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 14) {
            SwiftUI.Label("Dành cho iOS 27 (Ghép nối trực tiếp không cần PC)", systemImage: "iphone.radiowaves.left.and.right")
                .font(.headline)
                .foregroundColor(.blue)
            
            GuideStepRow(num: "1", text: "**Bước 1 - Cài Pairing lên iPhone:** Nhấn nút **“Cài Pairing lên iPhone”** bên dưới, sau đó mở ứng dụng **Cài đặt** ➔ **Quyền riêng tư & Bảo mật** ➔ **Chế độ nhà phát triển (Developer Mode)**. Xoá các thiết bị cũ nếu có, nhấn **Pair with SideStore**, nhập mật khẩu màn hình rồi nhập **6 chữ số** hiện trên ứng dụng này.")
            GuideStepRow(num: "2", text: "**Bước 2 - Xuất tệp Pairing:** Sau khi ghép nối xong, nút **“Xuất tệp Pairing”** sẽ hiện ra ngay bên dưới nút Cài Pairing. Hãy nhấn vào đó và chọn **Lưu vào Tệp (Save to Files)**.")
            GuideStepRow(num: "3", text: "**Bước 3 - Nhập tệp Pairing:** Nhấn nút **“Nhập tệp Pairing”** ở hàng cuối cùng và chọn lại tệp Pairing bạn vừa lưu trong ứng dụng Tệp (hệ thống sẽ tự động xoá tệp Pairing cũ trước khi nhập tệp mới).")
            
            Divider().padding(.vertical, 4)
            
            VStack(spacing: 12) {
                if let pin = wirelessVM.pinCode {
                    VStack(spacing: 8) {
                        SwiftUI.Text("MÃ GHÉP NỐI 6 CHỮ SỐ CỦA BẠN:")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                        SwiftUI.Text(pin)
                            .font(.system(size: 32, weight: .heavy, design: .monospaced))
                            .tracking(6)
                            .foregroundColor(.primary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(RoundedRectangle(cornerRadius: 12).fill(SwiftUI.Color.blue.opacity(0.12)))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                
                if let errorMsg = wirelessVM.errorMessage {
                    SwiftUI.Text(errorMsg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Nút 1: Cài Pairing lên iPhone
                SwiftUI.Button {
                    didPressInstallPairing = true
                    wirelessVM.togglePairing()
                } label: {
                    HStack(spacing: 10) {
                        SwiftUI.Image(systemName: wirelessVM.isAdvertising ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18, weight: .bold))
                        SwiftUI.Text(wirelessVM.isAdvertising ? "Dừng Cài Pairing" : "Cài Pairing lên iPhone")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(wirelessVM.isAdvertising ? SwiftUI.Color.red : SwiftUI.Color.accentColor)
                    .cornerRadius(14)
                }
                
                // Chỉ hiện nút Xuất tệp Pairing phía dưới nút Cài Pairing lên iPhone sau khi đã nhấn
                if didPressInstallPairing || installedPairingURLForExport != nil {
                    SwiftUI.Button {
                        if let pairedURL = installedPairingURLForExport {
                            exportFileURL = pairedURL
                            isExportSheetPresented = true
                        } else {
                            statusBannerMessage = "Hãy hoàn tất bước nhập 6 số trong Cài đặt (Developer Mode) để tạo xong tệp trước khi xuất."
                        }
                    } label: {
                        HStack(spacing: 10) {
                            SwiftUI.Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 18, weight: .bold))
                            SwiftUI.Text("Xuất tệp Pairing")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(installedPairingURLForExport != nil ? SwiftUI.Color.green : SwiftUI.Color.green.opacity(0.65))
                        .cornerRadius(14)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                
                // Nút 2: Nhập tệp Pairing (tự động xoá tệp cũ khi nhập)
                SwiftUI.Button {
                    pairingMgmtVM.promptImport(for: .rppairing)
                } label: {
                    HStack(spacing: 10) {
                        SwiftUI.Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 18, weight: .bold))
                        SwiftUI.Text("Nhập tệp Pairing")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(SwiftUI.Color.blue)
                    .cornerRadius(14)
                }
            }
            .padding(12)
            .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .padding()
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private var pcPairingGuideCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            SwiftUI.Label("Dành cho iOS dưới iOS 27 (Dùng iLoader & Máy tính)", systemImage: "laptopcomputer.and.iphone")
                .font(.headline)
                .foregroundColor(.purple)
            
            GuideStepRow(num: "1", text: "Trên máy tính (Windows / macOS), cài đặt **iTunes** & **iCloud** chính chủ từ Apple (nếu dùng Windows), sau đó tải và mở công cụ **iLoader**.")
            GuideStepRow(num: "2", text: "Kết nối iPhone với máy tính bằng cáp USB, mở khóa màn hình iPhone rồi nhấn **Tin cậy (Trust)** máy tính và nhập mật khẩu mở máy.")
            GuideStepRow(num: "3", text: "Trên giao diện **iLoader**, chọn thiết bị iPhone của bạn và nhấn chức năng tạo / xuất **Pairing File** (`.mobiledevicepairing` hoặc `.plist`).")
            GuideStepRow(num: "4", text: "Gửi tệp Pairing vừa tạo sang iPhone (qua AirDrop, Zalo, iCloud Drive...) và chọn **Lưu vào Tệp (Save to Files)**.")
            GuideStepRow(num: "5", text: "Quay lại màn hình này, nhấn nút **“Nhập tệp Pairing”** màu xanh ở trên và chọn tệp Pairing vừa lưu là hoàn tất.")
        }
        .padding()
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

struct GuideStepRow: SwiftUI.View {
    let num: String
    let text: LocalizedStringKey
    
    var body: some SwiftUI.View {
        HStack(alignment: .top, spacing: 12) {
            SwiftUI.Text(num)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(SwiftUI.Color.accentColor))
            
            SwiftUI.Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VpnDetailSheetView: SwiftUI.View {
    let isVpnOK: Bool
    let tunnelIP: String
    let deviceIP: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        SwiftUI.Image(systemName: isVpnOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(isVpnOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            SwiftUI.Text(isVpnOK ? "LocalDevVPN Đang Ổn Định" : "LocalDevVPN Chưa Kết Nối / Sai IP")
                                .font(.headline)
                            SwiftUI.Text("Đảm bảo bạn đã bật VPN trong ứng dụng LocalDevVPN.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Text("ĐỊA CHỈ IP ĐANG CÓ HIỆN TẠI")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        
                        HStack {
                            SwiftUI.Text("Tunnel IP đang có:")
                                .foregroundColor(.secondary)
                            Spacer()
                            SwiftUI.Text(tunnelIP)
                                .font(.system(.body, design: .monospaced).bold())
                        }
                        Divider()
                        HStack {
                            SwiftUI.Text("Device IP đang có:")
                                .foregroundColor(.secondary)
                            Spacer()
                            SwiftUI.Text(deviceIP)
                                .font(.system(.body, design: .monospaced).bold())
                        }
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        SwiftUI.Label("Lời khuyên cấu hình cho iOS 27", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        SwiftUI.Text("Nếu bạn đang ở **iOS 27** và đang dùng phiên bản này, bạn nên chỉnh lại cấu hình IP theo đúng thông số dưới đây để kết nối nhanh và ổn định nhất:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        CopyableIPCard(label: "Tunnel IP", value: "10.7.1.1/32")
                        CopyableIPCard(label: "Device IP", value: "10.7.0.1/32")
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Cấu Hình LocalDevVPN")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
        }
    }
}

struct CopyableIPCard: SwiftUI.View {
    let label: String
    let value: String
    @State private var copied = false
    
    var body: some SwiftUI.View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                SwiftUI.Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                SwiftUI.Text(value)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundColor(.primary)
            }
            Spacer()
            SwiftUI.Button(action: {
                UIPasteboard.general.string = value
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            }) {
                SwiftUI.Label(copied ? "Đã chép" : "Sao chép", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(copied ? SwiftUI.Color.green.opacity(0.2) : SwiftUI.Color.accentColor.opacity(0.15))
                    .foregroundColor(copied ? .green : .accentColor)
                    .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
        .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

struct CellularDetailSheetView: SwiftUI.View {
    let isCellularOK: Bool
    let detail: String
    let hasInternet: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        SwiftUI.Image(systemName: isCellularOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(isCellularOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            SwiftUI.Text(isCellularOK ? "Mạng 4G / Di Động Ổn Định" : "Mạng 4G / Di Động Đang Tắt")
                                .font(.headline)
                            SwiftUI.Text(detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Hoạt động độc lập qua 4G + VPN", systemImage: "antenna.radiowaves.left.and.right.circle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        SwiftUI.Text("• **Không cần Wi-Fi:** SideStore phiên bản này cho phép bạn cài đặt IPA và làm mới (Refresh) ứng dụng trực tiếp bằng mạng **4G/5G kết hợp LocalDevVPN**.\n\n• **Trạng thái Internet:** \(hasInternet ? "Đang kết nối Internet tốt ✅" : "Chưa có kết nối Internet ❌").\n\n• **Tự động hóa hoàn toàn:** Hãy tải các phím tắt ở trang Check và bật Tự động hóa lúc 6h sáng hoặc 3h chiều để máy tự động bật 4G + VPN và gia hạn ứng dụng mỗi ngày.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Mạng 4G / Di Động")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
        }
    }
}

@MainActor
final class AnisetteQuickListViewModel: ObservableObject {
    @Published var servers: [AnisetteServerItem] = []
    @Published var isLoading: Bool = false
    
    func loadCachedAndSync() async {
        let local = await AnisetteServersManager.shared.loadLocalServers().filter { !$0.isHidden }
        if !local.isEmpty {
            self.servers = mergeWithCurrent(local)
        }
        await refreshFromRemote()
    }
    
    func refreshFromRemote() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        
        if let synced = try? await AnisetteServersManager.shared.syncWithRemote() {
            let visible = synced.filter { !$0.isHidden }
            self.servers = mergeWithCurrent(visible)
        } else {
            let local = await AnisetteServersManager.shared.loadLocalServers().filter { !$0.isHidden }
            self.servers = mergeWithCurrent(local)
        }
    }
    
    func reloadCurrentSelection() async {
        let local = await AnisetteServersManager.shared.loadLocalServers().filter { !$0.isHidden }
        self.servers = mergeWithCurrent(local)
    }
    
    private func mergeWithCurrent(_ items: [AnisetteServerItem]) -> [AnisetteServerItem] {
        var result = items
        if result.isEmpty {
            result = [
                AnisetteServerItem(
                    name: "SideStore Official",
                    address: AppConstants.Anisette.Servers.defaultServerURL,
                    isHidden: false
                )
            ]
        }
        let current = AnisetteDefaultsHelper.currentServerURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !current.isEmpty,
           !result.contains(where: { $0.address.caseInsensitiveCompare(current) == .orderedSame }) {
            let host = URL(string: current)?.host ?? current
            result.insert(AnisetteServerItem(name: "Máy chủ tùy chỉnh (\(host))", address: current, isHidden: false), at: 0)
        }
        return result
    }
}

struct AnisetteDetailSheetView: SwiftUI.View {
    @ObservedObject var vm: SystemCheckViewModel
    @StateObject private var listVM = AnisetteQuickListViewModel()
    @State private var customServerInput: String = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        SwiftUI.Image(systemName: vm.isAnisetteOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(vm.isAnisetteOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            SwiftUI.Text(vm.isAnisetteOK ? "Cấu Hình Anisette Đang Ổn Định" : "Đang Bật Use On-Device Anisette")
                                .font(.headline)
                            SwiftUI.Text(vm.anisetteDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        SwiftUI.Label("Thiết lập Use On-Device Anisette", systemImage: "switch.2")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        Toggle(isOn: Binding(
                            get: { vm.useOnDeviceAnisette },
                            set: { vm.setUseOnDeviceAnisette($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                SwiftUI.Text("Use On-Device Anisette")
                                    .font(.subheadline.bold())
                                SwiftUI.Text(vm.useOnDeviceAnisette ? "Đang BẬT (Khuyên tắt để dùng Máy chủ Anisette ổn định hơn)" : "Đang TẮT (Chuẩn khuyên dùng ✅)")
                                    .font(.caption)
                                    .foregroundColor(vm.useOnDeviceAnisette ? .red : .green)
                            }
                        }
                        .padding(12)
                        .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(12)
                        
                        if vm.useOnDeviceAnisette {
                            SwiftUI.Button {
                                vm.setUseOnDeviceAnisette(false)
                            } label: {
                                HStack(spacing: 8) {
                                    SwiftUI.Image(systemName: "checkmark.shield.fill")
                                    SwiftUI.Text("Tắt ngay Use On-Device Anisette (Khuyên dùng)")
                                        .font(.subheadline.bold())
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(SwiftUI.Color.green)
                                .cornerRadius(12)
                            }
                        }
                        
                        SwiftUI.Text("• **Khuyên dùng:** Bạn nên **TẮT** mục **Use On-Device Anisette** để SideStore lấy dữ liệu xác thực thông qua **Máy chủ Anisette**, giúp đăng nhập Apple ID, cài IPA và làm mới ứng dụng qua 4G + VPN ổn định hơn.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SwiftUI.Label("Danh sách Máy chủ Anisette", systemImage: "server.rack")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            if listVM.isLoading {
                                ProgressView()
                            }
                        }
                        
                        VStack(spacing: 8) {
                            ForEach(listVM.servers) { server in
                                let isSelected = (vm.selectedAnisetteServerURL.caseInsensitiveCompare(server.address) == .orderedSame)
                                SwiftUI.Button {
                                    vm.selectAnisetteServerURL(server.address, isCustom: false)
                                    Task { await listVM.reloadCurrentSelection() }
                                } label: {
                                    HStack(spacing: 12) {
                                        SwiftUI.Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(isSelected ? .green : .secondary)
                                        
                                        VStack(alignment: .leading, spacing: 3) {
                                            SwiftUI.Text(server.name)
                                                .font(.subheadline.bold())
                                                .foregroundColor(.primary)
                                            SwiftUI.Text(server.address)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if isSelected {
                                            SwiftUI.Text("Đang chọn")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(SwiftUI.Color.green.opacity(0.15))
                                                .foregroundColor(.green)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .padding(12)
                                    .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        
                        Divider().padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            SwiftUI.Text("Nhập URL Máy chủ Anisette tùy chỉnh:")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 8) {
                                TextField(AppConstants.Anisette.Servers.defaultServerURL, text: $customServerInput)
                                    .keyboardType(.URL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .padding(10)
                                    .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                                    .cornerRadius(10)
                                
                                SwiftUI.Button {
                                    let trimmed = customServerInput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    vm.selectAnisetteServerURL(trimmed, isCustom: true)
                                    Task { await listVM.reloadCurrentSelection() }
                                    customServerInput = ""
                                } label: {
                                    SwiftUI.Text("Lưu")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(SwiftUI.Color.accentColor)
                                        .cornerRadius(10)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Máy Chủ Anisette")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
            .task {
                vm.updateInstantStatus()
                await listVM.loadCachedAndSync()
            }
        }
    }
}
