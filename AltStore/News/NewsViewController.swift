
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
        self.navigationItem.largeTitleDisplayMode = .never
        self.collectionView.backgroundColor = .systemGroupedBackground
        self.collectionView.contentInsetAdjustmentBehavior = .never
        
        let hostingController = UIHostingController(rootView: SystemCheckDashboardView())
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .systemGroupedBackground
        view.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.navigationController?.navigationBar.prefersLargeTitles = false
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
            self.cellularDetail = "Ổn định • Đang dùng trực tiếp 4G / 5G"
        } else if cellularActive {
            self.cellularDetail = "Ổn định • 4G / 5G đang bật sẵn sàng"
        } else {
            self.cellularDetail = "Chưa bật • Hãy bật Dữ liệu di động (4G/5G)"
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
            ? "Chưa tối ưu • Hãy tắt Use On-Device Anisette"
            : "Ổn định • Máy chủ: \(serverHost)"
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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                systemStatusSection
                
                serverSection
                    .padding(.top, 6)
                
                shortcutsSection
                    .padding(.top, 6)
                
                automationGuideSection
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
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
                subtitle: vm.isPairingOK ? "Ổn định • \(vm.pairingProtocol)" : "Chưa có • Nhấn để Cài / Nhập Pairing",
                icon: "doc.badge.gearshape.fill",
                isStable: vm.isPairingOK
            ) {
                showPairingSheet = true
            }
            
            CheckItemButton(
                title: "LocalDevVPN",
                subtitle: vm.isVpnOK ? "Ổn định • Tunnel: \(vm.tunnelIP)" : "Chưa kết nối • Nhấn xem cấu hình IP",
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
                title: "Tự động làm mới App (6:00 sáng)",
                subtitle: "Làm mới tự động qua 4G + VPN mỗi sáng",
                icon: "clock.arrow.2.circlepath",
                color: .green,
                urlString: "https://www.icloud.com/shortcuts/56b0ab8cb0984d0b9a98543ac879eeec"
            )
            
            ShortcutLinkRow(
                title: "Tự động làm mới App (15:00 chiều)",
                subtitle: "Làm mới tự động qua 4G + VPN mỗi chiều",
                icon: "sun.max.circle.fill",
                color: .orange,
                urlString: "https://www.icloud.com/shortcuts/9f93051e8bf142258ffc93e08f3c0849"
            )
        }
    }
    
    private var automationGuideSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(
                title: "Hướng Dẫn Tự Động Hóa",
                icon: "bell.badge.fill",
                color: .green
            )
            
            VStack(alignment: .leading, spacing: 14) {
                SwiftUI.Text("Thiết lập tự động gia hạn ứng dụng hằng ngày (6:00 hoặc 15:00) theo 2 bước dưới đây:")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                VStack(spacing: 14) {
                    RemoteGuideImageView(
                        urlString: "https://raw.githubusercontent.com/Nguyenhuyhoan/icons/main/IMG_2589.jpeg",
                        caption: "Bước 1: Mở mục Tự động hoá và chọn chạy ngay lập tức"
                    )
                    RemoteGuideImageView(
                        urlString: "https://raw.githubusercontent.com/Nguyenhuyhoan/icons/main/IMG_2588.jpeg",
                        caption: "Bước 2: Chọn giờ cố định lặp lại Hằng ngày"
                    )
                }
            }
            .padding(14)
            .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(SwiftUI.Color.primary.opacity(0.05), lineWidth: 1)
            )
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                SwiftUI.Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
            }
            
            SwiftUI.Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            if let statusOK = statusOK {
                SwiftUI.Image(systemName: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(statusOK ? .green : .red)
                    .animation(.spring(), value: statusOK)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
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
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isStable ? SwiftUI.Color.green.opacity(0.14) : SwiftUI.Color.red.opacity(0.14))
                        .frame(width: 44, height: 44)
                    SwiftUI.Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(isStable ? .green : .red)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    SwiftUI.Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    SwiftUI.Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                SwiftUI.Image(systemName: isStable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(isStable ? .green : .red)
                    .animation(.spring(), value: isStable)
                
                SwiftUI.Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SwiftUI.Color(UIColor.tertiaryLabel))
            }
            .padding(13)
            .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(SwiftUI.Color.primary.opacity(0.05), lineWidth: 1)
            )
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
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(color.opacity(0.14))
                        .frame(width: 42, height: 42)
                    SwiftUI.Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    SwiftUI.Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    SwiftUI.Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                SwiftUI.Text("Nhận")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.14))
                    .foregroundColor(color)
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(15)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(SwiftUI.Color.primary.opacity(0.05), lineWidth: 1)
            )
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
                            SwiftUI.Text("Đang tải ảnh...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(12)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(SwiftUI.Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    case .failure:
                        VStack(spacing: 6) {
                            SwiftUI.Image(systemName: "wifi.exclamationmark")
                                .font(.title3)
                            SwiftUI.Text("Không tải được ảnh. Vui lòng kiểm tra mạng.")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 110)
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    statusHeaderCard
                    
                    if let banner = statusBannerMessage {
                        HStack(spacing: 10) {
                            SwiftUI.Image(systemName: "checkmark.seal.fill")
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
                .padding(16)
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Hướng Dẫn Cài Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SwiftUI.Button("Xong") { dismiss() }
                        .font(.headline)
                }
            }
            #if !os(tvOS)
            .fileImporter(
                isPresented: $pairingMgmtVM.showFileImporter,
                allowedContentTypes: pairingMgmtVM.allowedPairingTypes
            ) { result in
                if case .success = result {
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
                        statusBannerMessage = "Đã thay thế tệp cũ và nạp tệp Pairing mới thành công! Trạng thái đã chuyển sang Tích xanh."
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
                        statusBannerMessage = "Ghép nối iOS 27 thành công! Hãy nhấn nút “Xuất tệp Pairing” (màu xanh lá) để Lưu vào Tệp, sau đó nhấn “Nhập tệp Pairing”."
                    }
                }
            }
        }
    }
    
    private var statusHeaderCard: some SwiftUI.View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(vm.isPairingOK ? SwiftUI.Color.green.opacity(0.15) : SwiftUI.Color.red.opacity(0.15))
                    .frame(width: 44, height: 44)
                SwiftUI.Image(systemName: vm.isPairingOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(vm.isPairingOK ? .green : .red)
            }
            VStack(alignment: .leading, spacing: 3) {
                SwiftUI.Text(vm.isPairingOK ? "Pairing File Đang Ổn Định" : "Chưa Có Tệp Pairing")
                    .font(.headline)
                SwiftUI.Text(vm.pairingProtocol)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private var ios27DirectPairingCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SwiftUI.Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    SwiftUI.Text("PHẦN 1: DÀNH CHO iOS 27")
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                    SwiftUI.Text("Ghép nối trực tiếp trên iPhone (Không cần PC)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
            
            HStack(alignment: .top, spacing: 8) {
                SwiftUI.Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.subheadline)
                SwiftUI.Text("**Điều kiện bắt buộc trước khi làm:**\n• Đã bật **Chế độ nhà phát triển (Developer Mode)**.\n• Đã bật **LocalDevVPN** (Cấu hình khuyên dùng: Tunnel IP `10.7.1.1/32` • Device IP `10.7.0.1/32`).\n• Đang có kết nối mạng **Wi-Fi** hoặc **4G/5G**.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(SwiftUI.Color.orange.opacity(0.1))
            .cornerRadius(10)
            
            VStack(alignment: .leading, spacing: 12) {
                GuideStepRow(
                    num: "1",
                    title: "Bắt đầu phát tín hiệu Pairing",
                    text: "Nhấn vào nút **“Cài Pairing lên iPhone”** bên dưới để ứng dụng khởi tạo kết nối với hệ thống."
                )
                
                GuideStepRow(
                    num: "2",
                    title: "Mở Cài đặt Nhà phát triển",
                    text: "Thoát ra màn hình chính (không vuốt tắt ứng dụng này), mở **Cài đặt (Settings)** ➔ **Quyền riêng tư & Bảo mật (Privacy & Security)** ➔ kéo xuống cuối chọn **Chế độ nhà phát triển (Developer Mode)**."
                )
                
                GuideStepRow(
                    num: "3",
                    title: "Nhập mã PIN 6 chữ số",
                    text: "Trong mục Chế độ nhà phát triển, nhấn vào dòng **Pair with SideStore** (hoặc tên thiết bị hiện ra). Một bảng mã **6 chữ số** sẽ xuất hiện trên màn hình ➔ hãy nhập chính xác 6 chữ số đó rồi nhấn **Pair (Ghép đôi)**."
                )
                
                GuideStepRow(
                    num: "4",
                    title: "Xuất tệp Pairing lưu vào máy",
                    text: "Quay trở lại màn hình này, nhấn nút **“Xuất tệp Pairing”** (màu xanh lá) ➔ chọn **Lưu vào Tệp (Save to Files)** để lưu trữ tệp Pairing dự phòng trong ứng dụng Tệp của iPhone."
                )
                
                GuideStepRow(
                    num: "5",
                    title: "Nhập tệp để kích hoạt hoàn tất",
                    text: "Nhấn nút **“Nhập tệp Pairing”** (màu xanh dương) ➔ chọn lại đúng tệp Pairing bạn vừa lưu trong ứng dụng **Tệp**. Hệ thống sẽ tự động xóa tệp cũ, nạp tệp mới và báo **Tích xanh**!"
                )
            }
            
            Divider().padding(.vertical, 2)
            
            VStack(spacing: 10) {
                if let pin = wirelessVM.pinCode {
                    VStack(spacing: 6) {
                        SwiftUI.Text("MÃ GHÉP NỐI 6 CHỮ SỐ")
                            .font(.caption2.bold())
                            .foregroundColor(.blue)
                        SwiftUI.Text(pin)
                            .font(.system(size: 30, weight: .heavy, design: .monospaced))
                            .tracking(6)
                            .foregroundColor(.primary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 18)
                            .background(RoundedRectangle(cornerRadius: 10).fill(SwiftUI.Color.blue.opacity(0.12)))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                }
                
                if let errorMsg = wirelessVM.errorMessage {
                    SwiftUI.Text(errorMsg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                SwiftUI.Button {
                    didPressInstallPairing = true
                    wirelessVM.togglePairing()
                } label: {
                    HStack(spacing: 8) {
                        SwiftUI.Image(systemName: wirelessVM.isAdvertising ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 17, weight: .bold))
                        SwiftUI.Text(wirelessVM.isAdvertising ? "Dừng Cài Pairing" : "Cài Pairing lên iPhone")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(wirelessVM.isAdvertising ? SwiftUI.Color.red : SwiftUI.Color.accentColor)
                    .cornerRadius(13)
                }
                
                if didPressInstallPairing || installedPairingURLForExport != nil {
                    SwiftUI.Button {
                        if let pairedURL = installedPairingURLForExport {
                            exportFileURL = pairedURL
                            isExportSheetPresented = true
                        } else {
                            statusBannerMessage = "Vui lòng thực hiện Bước 2 & Bước 3 (nhập xong 6 chữ số trong Cài đặt ➔ Chế độ nhà phát triển) trước khi xuất tệp."
                        }
                    } label: {
                        HStack(spacing: 8) {
                            SwiftUI.Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 17, weight: .bold))
                            SwiftUI.Text("Xuất tệp Pairing")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(installedPairingURLForExport != nil ? SwiftUI.Color.green : SwiftUI.Color.green.opacity(0.65))
                        .cornerRadius(13)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                
                SwiftUI.Button {
                    pairingMgmtVM.promptImport(for: .rppairing)
                } label: {
                    HStack(spacing: 8) {
                        SwiftUI.Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 17, weight: .bold))
                        SwiftUI.Text("Nhập tệp Pairing")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(SwiftUI.Color.blue)
                    .cornerRadius(13)
                }
            }
            .padding(12)
            .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .padding(16)
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private var pcPairingGuideCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SwiftUI.Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    SwiftUI.Text("PHẦN 2: DƯỚI iOS 27 (iOS 16 / 17 / 18...)")
                        .font(.caption.bold())
                        .foregroundColor(.purple)
                    SwiftUI.Text("Tạo tệp Pairing qua Máy tính (Windows / Mac)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
            
            HStack(alignment: .top, spacing: 8) {
                SwiftUI.Image(systemName: "info.circle.fill")
                    .foregroundColor(.purple)
                    .font(.subheadline)
                SwiftUI.Text("**Lưu ý quan trọng:** Các phiên bản iOS dưới 27 chưa hỗ trợ tự tạo tệp Pairing trực tiếp trên điện thoại. Bạn chỉ cần dùng máy tính tạo tệp **1 lần duy nhất**, sau đó sử dụng vĩnh viễn trên iPhone qua 4G / Wi-Fi.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(SwiftUI.Color.purple.opacity(0.1))
            .cornerRadius(10)
            
            VStack(alignment: .leading, spacing: 12) {
                GuideStepRow(
                    num: "1",
                    title: "Chuẩn bị công cụ trên Máy tính",
                    text: "• **Nếu dùng Windows:** Cài đặt **iTunes** và **iCloud** bản chính thức từ trang chủ Apple (không tải từ Microsoft Store) để máy tính có đầy đủ Driver nhận diện iPhone.\n• **Tải công cụ tạo Pairing:** Tải phần mềm **iLoader** (hoặc **idevice_pair / jitterbugpair**) về máy tính."
                )
                
                GuideStepRow(
                    num: "2",
                    title: "Kết nối cáp & Tin cậy thiết bị",
                    text: "Mở khóa màn hình iPhone, cắm cáp kết nối iPhone vào máy tính. Khi điện thoại hiện thông báo **“Tin cậy máy tính này?” (Trust This Computer?)** ➔ nhấn **Tin cậy (Trust)** và nhập mật khẩu khóa màn hình iPhone."
                )
                
                GuideStepRow(
                    num: "3",
                    title: "Xuất tệp Pairing từ công cụ",
                    text: "Mở công cụ **iLoader** (hoặc **idevice_pair**) trên máy tính:\n• Chọn đúng tên thiết bị iPhone của bạn.\n• Nhấn nút **Generate / Export Pairing File** để phần mềm tạo ra tệp có đuôi **`.mobiledevicepairing`** hoặc **`.plist`**."
                )
                
                GuideStepRow(
                    num: "4",
                    title: "Chuyển tệp sang iPhone & Lưu vào Tệp",
                    text: "Gửi tệp Pairing vừa tạo từ máy tính sang iPhone (qua **Zalo, Telegram, iCloud Drive** hoặc **AirDrop**). Mở tệp đó trên iPhone, nhấn nút **Chia sẻ** ➔ chọn **Lưu vào Tệp (Save to Files)**."
                )
                
                GuideStepRow(
                    num: "5",
                    title: "Nhập tệp Pairing vào ứng dụng",
                    text: "Nhấn vào nút **“Nhập tệp Pairing”** ở ngay bên dưới (hoặc ở khung trên) ➔ chọn đúng tệp Pairing bạn vừa lưu trong ứng dụng **Tệp**. Ứng dụng sẽ tự động xóa tệp cũ, nạp tệp mới và báo **Tích xanh**!"
                )
            }
            
            SwiftUI.Button {
                pairingMgmtVM.promptImport(for: .rppairing)
            } label: {
                HStack(spacing: 8) {
                    SwiftUI.Image(systemName: "folder.fill.badge.plus")
                        .font(.system(size: 17, weight: .bold))
                    SwiftUI.Text("Nhập tệp Pairing (Từ ứng dụng Tệp)")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(SwiftUI.Color.purple)
                .cornerRadius(13)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

struct GuideStepRow: SwiftUI.View {
    let num: String
    var title: String? = nil
    let text: LocalizedStringKey
    
    var body: some SwiftUI.View {
        HStack(alignment: .top, spacing: 10) {
            SwiftUI.Text(num)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(SwiftUI.Color.accentColor))
                .padding(.top, 1)
            
            VStack(alignment: .leading, spacing: 3) {
                if let title = title {
                    SwiftUI.Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                }
                SwiftUI.Text(text)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(isVpnOK ? SwiftUI.Color.green.opacity(0.15) : SwiftUI.Color.red.opacity(0.15))
                                .frame(width: 44, height: 44)
                            SwiftUI.Image(systemName: isVpnOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(isVpnOK ? .green : .red)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            SwiftUI.Text(isVpnOK ? "LocalDevVPN Đang Ổn Định" : "LocalDevVPN Chưa Kết Nối")
                                .font(.headline)
                            SwiftUI.Text("Hãy bật công tắc VPN trong ứng dụng LocalDevVPN.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Text("THÔNG SỐ KẾT NỐI HIỆN TẠI")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        
                        HStack {
                            SwiftUI.Text("Tunnel IP")
                                .foregroundColor(.secondary)
                            Spacer()
                            SwiftUI.Text(tunnelIP)
                                .font(.system(.body, design: .monospaced).bold())
                        }
                        Divider()
                        HStack {
                            SwiftUI.Text("Device IP")
                                .foregroundColor(.secondary)
                            Spacer()
                            SwiftUI.Text(deviceIP)
                                .font(.system(.body, design: .monospaced).bold())
                        }
                    }
                    .padding(16)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Cấu hình khuyên dùng cho iOS 27", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        SwiftUI.Text("Nếu dùng iOS 27, hãy đặt IP trong LocalDevVPN theo thông số sau để kết nối nhanh nhất:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        CopyableIPCard(label: "Tunnel IP", value: "10.7.1.1/32")
                        CopyableIPCard(label: "Device IP", value: "10.7.0.1/32")
                    }
                    .padding(16)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding(16)
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("LocalDevVPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SwiftUI.Button("Xong") { dismiss() }
                        .font(.headline)
                }
            }
        }
    }
}

struct CopyableIPCard: SwiftUI.View {
    let label: String
    let value: String
    @State private var copied = false
    
    var body: some SwiftUI.View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(isCellularOK ? SwiftUI.Color.green.opacity(0.15) : SwiftUI.Color.red.opacity(0.15))
                                .frame(width: 44, height: 44)
                            SwiftUI.Image(systemName: isCellularOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(isCellularOK ? .green : .red)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            SwiftUI.Text(isCellularOK ? "Mạng 4G / Di Động Ổn Định" : "Mạng 4G / Di Động Đang Tắt")
                                .font(.headline)
                            SwiftUI.Text(detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Cài & Gia hạn App qua 4G + VPN", systemImage: "antenna.radiowaves.left.and.right.circle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        SwiftUI.Text("• **Không cần Wi-Fi:** Cài đặt IPA và làm mới ứng dụng trực tiếp qua **4G/5G + LocalDevVPN**.\n\n• **Kết nối Internet:** \(hasInternet ? "Đang hoạt động tốt ✅" : "Chưa có kết nối ❌").\n\n• **Tự động hóa:** Kết hợp phím tắt làm mới lúc 6:00 hoặc 15:00 để tự động gia hạn ứng dụng mỗi ngày.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding(16)
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Mạng 4G / Di Động")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SwiftUI.Button("Xong") { dismiss() }
                        .font(.headline)
                }
            }
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(vm.isAnisetteOK ? SwiftUI.Color.green.opacity(0.15) : SwiftUI.Color.red.opacity(0.15))
                                .frame(width: 44, height: 44)
                            SwiftUI.Image(systemName: vm.isAnisetteOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(vm.isAnisetteOK ? .green : .red)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            SwiftUI.Text(vm.isAnisetteOK ? "Máy Chủ Anisette Ổn Định" : "Đang Bật On-Device Anisette")
                                .font(.headline)
                            SwiftUI.Text(vm.anisetteDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Chế độ xác thực Anisette", systemImage: "switch.2")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        Toggle(isOn: Binding(
                            get: { vm.useOnDeviceAnisette },
                            set: { vm.setUseOnDeviceAnisette($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                SwiftUI.Text("Use On-Device Anisette")
                                    .font(.subheadline.bold())
                                SwiftUI.Text(vm.useOnDeviceAnisette ? "Đang BẬT (Khuyên tắt để ổn định hơn)" : "Đang TẮT (Chuẩn khuyên dùng ✅)")
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
                                    SwiftUI.Text("Tắt ngay Use On-Device Anisette")
                                        .font(.subheadline.bold())
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(SwiftUI.Color.green)
                                .cornerRadius(12)
                            }
                        }
                        
                        SwiftUI.Text("Nên **TẮT** mục này để sử dụng Máy chủ Anisette, giúp cài IPA và gia hạn qua 4G + VPN không bị lỗi.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SwiftUI.Label("Chọn Máy chủ Anisette", systemImage: "server.rack")
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
                                        
                                        VStack(alignment: .leading, spacing: 2) {
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
                                            SwiftUI.Text("Đang dùng")
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
                        
                        Divider().padding(.vertical, 2)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            SwiftUI.Text("Hoặc nhập URL máy chủ tùy chỉnh:")
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
                    .padding(16)
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding(16)
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Máy Chủ Anisette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SwiftUI.Button("Xong") { dismiss() }
                        .font(.headline)
                }
            }
            .task {
                vm.updateInstantStatus()
                await listVM.loadCachedAndSync()
            }
        }
    }
}
