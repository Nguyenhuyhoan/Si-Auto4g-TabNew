
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
        
        let checkView = SystemCheckDashboardView()
        let hostingController = UIHostingController(rootView: checkView)
        
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

// MARK: - ViewModel Cập Nhật Tức Thì & Chính Xác (Không gây nghẽn Minimuxer)
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
    
    // Trạng thái Máy chủ Anisette (Tắt Use On-Device Anisette = Ổn định / Tích xanh)
    @Published var isAnisetteOK: Bool = !UserDefaults.standard.useOnDeviceAnisette
    @Published var useOnDeviceAnisette: Bool = UserDefaults.standard.useOnDeviceAnisette
    @Published var anisetteDetail: String = "Đang kiểm tra..."
    
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.sidestore.check.network")
    private var usesCellularPath: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?
    
    // Chống gọi chồng chéo làm nghẽn kết nối tới Minimuxer
    private var isChecking: Bool = false
    private var lastVerifiedPairingSuccess: Bool = false
    
    init() {
        updateInstantStatus()
        setupRealtimeListeners()
    }
    
    deinit {
        pathMonitor.cancel()
        timerTask?.cancel()
    }
    
    private func setupRealtimeListeners() {
        // 1. Lắng nghe thay đổi mạng 4G/Internet từ iOS tức thì
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
        
        // 2. Lắng nghe thay đổi VPN/Network từ Minimuxer tức thì
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
        
        // 3. Lắng nghe thay đổi trạng thái Pairing/Muxer tức thì
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
        
        // 4. Lắng nghe thay đổi cài đặt UserDefaults (Use On-Device Anisette & Máy chủ Anisette)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateInstantStatus()
            }
            .store(in: &cancellables)
        
        // 5. Khi quay lại app từ Cài đặt hoặc LocalDevVPN -> Kiểm tra ngay lập tức
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateInstantStatus()
                Task { @MainActor [weak self] in
                    await self?.checkAllStatuses(forceVerify: true)
                }
            }
            .store(in: &cancellables)
        
        // 6. Vòng lặp cập nhật nhẹ nhàng mỗi 2 giây
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllStatuses(forceVerify: false)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    
    // MARK: - Quét trực tiếp các Interface hệ thống (4G pdp_ip* và VPN utun*)
    private struct SystemInterfaceSnapshot: Sendable {
        let hasCellularPdp: Bool
        let hasActiveUtun: Bool
        let detectedUtunIPv4: String?
    }
    
    private nonisolated static func scanSystemInterfaces() -> SystemInterfaceSnapshot {
        var hasPdp = false
        var hasUtun = false
        var bestUtunIP: String? = nil
        
        for iface in minimuxer.network.activeInterfaces {
            let lower = iface.name.lowercased()
            if lower.hasPrefix("pdp_ip") {
                hasPdp = true
            }
            if lower.hasPrefix("utun") {
                hasUtun = true
            }
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
                    
                    if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                        if name.hasPrefix("pdp_ip") {
                            hasPdp = true
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
                                // Ưu tiên nhận diện IP của LocalDevVPN / StosVPN / WireGuard (10.7.x.x)
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
            hasCellularPdp: hasPdp,
            hasActiveUtun: hasUtun,
            detectedUtunIPv4: bestUtunIP
        )
    }
    
    // MARK: - Bật/Tắt nhanh Use On-Device Anisette đồng bộ trực tiếp với Cài đặt
    func setUseOnDeviceAnisette(_ enabled: Bool) {
        UserDefaults.standard.useOnDeviceAnisette = enabled
        updateInstantStatus()
    }
    
    // MARK: - Cập nhật nhanh trạng thái UI không cần chờ đợi
    func updateInstantStatus() {
        let snapshot = Self.scanSystemInterfaces()
        
        // 1. Trạng thái 4G / Di động
        self.isCellularOK = usesCellularPath || snapshot.hasCellularPdp
        if usesCellularPath {
            self.cellularDetail = "Ổn định • Đang dùng trực tiếp 4G / Di động"
        } else if snapshot.hasCellularPdp {
            self.cellularDetail = "Ổn định • 4G / Di động đang bật sẵn sàng"
        } else {
            self.cellularDetail = "Không ổn định • Đang tắt Dữ liệu di động (4G)"
        }
        
        // 2. Trạng thái LocalDevVPN (Kiểm tra thực tế cả ConnectionConfig lẫn utun hệ thống)
        let config = ConnectionConfig.shared
        let rawTunnelIP = config.tunnelIfaceIp ?? snapshot.detectedUtunIPv4
        let rawPeerIP: String? = {
            if config.overrideTunnelPeerReachable, !config.overrideTunnelPeerIp.isEmpty {
                return config.overrideTunnelPeerIp
            }
            if let peer = config.tunnelPeerIp, !peer.isEmpty {
                return peer
            }
            // Nếu utun đang là 10.7.1.1 (cấu hình iOS 27) hoặc 10.7.0.x thì peer mặc định là 10.7.0.1
            if let tIP = rawTunnelIP, tIP.hasPrefix("10.7.") {
                return "10.7.0.1"
            }
            return nil
        }()
        
        if let formattedIface = config.formattedTunnelIface {
            self.tunnelIP = formattedIface
        } else if let tIP = rawTunnelIP {
            self.tunnelIP = tIP
        } else {
            self.tunnelIP = "Chưa kết nối"
        }
        
        if let formattedPeer = config.formattedTunnelPeer {
            self.deviceIP = formattedPeer
        } else if let pIP = rawPeerIP {
            self.deviceIP = pIP
        } else {
            self.deviceIP = "Chưa kết nối"
        }
        
        let vpnReady = minimuxer.network.isUTunAvailable
            || (snapshot.hasActiveUtun && rawTunnelIP != nil)
            || (config.formattedTunnelIface != nil && config.formattedTunnelPeer != nil)
        self.isVpnOK = vpnReady
        
        // 3. Trạng thái Pairing File hiện có
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
        
        // 4. Trạng thái Máy chủ Anisette (Tắt Use On-Device Anisette = Ổn định / Tích xanh)
        let onDevice = UserDefaults.standard.useOnDeviceAnisette
        self.useOnDeviceAnisette = onDevice
        self.isAnisetteOK = !onDevice
        
        let selectedURL = UserDefaults.standard.selectedAnisetteURL
        let serverHost = URL(string: selectedURL)?.host ?? selectedURL
        if onDevice {
            self.anisetteDetail = "Chưa ổn định • Hãy tắt Use On-Device Anisette"
        } else {
            self.anisetteDetail = "Ổn định • Đang dùng máy chủ (\(serverHost))"
        }
    }
    
    // MARK: - Kiểm tra chuyên sâu ở Background (An toàn, không làm nghẽn Cài/Refresh App)
    func checkAllStatuses(forceVerify: Bool = false) async {
        updateInstantStatus()
        
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        
        // Nếu có file Pairing trong bộ nhớ mà Minimuxer chưa nạp vào core -> nạp nhẹ nhàng
        if hasAnyStoredPairingFile && !minimuxer.core.isPairingFileLoaded {
            let proto: PairingProtocol = PairingFileManager.shared.persistedActiveProtocol
                ?? (PairingFileManager.shared.hasPairingFile(for: .rppairing) ? .rppairing : .lockdown)
            try? await minimuxerSwitchPairingProtocol(to: proto)
            updateInstantStatus()
        }
        
        // Nếu VPN và Pairing File đều đã có nhưng chưa từng verify UDID (hoặc người dùng kéo làm mới)
        if isVpnOK && (hasAnyStoredPairingFile || minimuxer.core.isPairingFileLoaded) {
            if forceVerify || !lastVerifiedPairingSuccess {
                // Dùng forceLive: false trước để tránh tranh chấp kênh nếu đang cài/refresh app
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

// MARK: - Giao Diện Chính (Tab Check)
struct SystemCheckDashboardView: SwiftUI.View {
    @StateObject private var vm = SystemCheckViewModel()
    @State private var showPairingSheet = false
    @State private var showVpnSheet = false
    @State private var showCellularSheet = false
    @State private var showAnisetteSheet = false
    
    var body: some SwiftUI.View {
        ScrollView {
            VStack(spacing: 20) {
                headerBanner
                
                VStack(alignment: .leading, spacing: 12) {
                    SwiftUI.Text("TRẠNG THÁI HỆ THỐNG (NHẤN ĐỂ XEM CHI TIẾT)")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                    
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
                    
                    CheckItemButton(
                        title: "Máy chủ Anisette",
                        subtitle: vm.anisetteDetail,
                        icon: "server.rack",
                        isStable: vm.isAnisetteOK
                    ) {
                        showAnisetteSheet = true
                    }
                }
                
                shortcutsSection
                automationGuideSection
            }
            .padding()
        }
        .background(SwiftUI.Color(UIColor.systemGroupedBackground))
        .onAppear {
            vm.updateInstantStatus()
            Task {
                await vm.checkAllStatuses(forceVerify: true)
            }
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
    
    private var headerBanner: some SwiftUI.View {
        let allReady = vm.isPairingOK && vm.isVpnOK && vm.isCellularOK && vm.isAnisetteOK
        return HStack(spacing: 14) {
            SwiftUI.Image(systemName: allReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(allReady ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 4) {
                SwiftUI.Text(allReady ? "Hệ thống Ổn định • Sẵn sàng!" : "Phát hiện mục chưa ổn định")
                    .font(.headline)
                SwiftUI.Text("Cài đặt và làm mới ứng dụng trực tiếp qua 4G + LocalDevVPN (Không cần Wi-Fi).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private var shortcutsSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            SwiftUI.Text("PHÍM TẮT DÙNG CHO CÀI & LÀM MỚI APP QUA 4G + VPN")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            
            VStack(spacing: 10) {
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
                    urlString: "https://www.icloud.com/shortcuts/22fa426ac9434b5ca5f7ccda0febd3a8"
                )
            }
        }
    }
    
    private var automationGuideSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SwiftUI.Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
                SwiftUI.Text("Lưu ý khi cài đặt Phím tắt Tự động làm mới")
                    .font(.subheadline.bold())
            }
            
            SwiftUI.Text("Để bật chế độ tự động chạy hằng ngày lúc 6h sáng hoặc 3h chiều, bạn cần vào ứng dụng **Phím tắt** ➔ bật mục **“Tự động hóa”** và thiết lập giống như 2 ảnh hướng dẫn dưới đây:")
                .font(.footnote)
                .foregroundColor(.secondary)
            
            VStack(spacing: 14) {
                RemoteGuideImageView(
                    urlString: "https://raw.githubusercontent.com/Nguyenhuyhoan/icons/main/IMG_2589.jpeg",
                    caption: "Ảnh 1: Bật mục Tự động hóa trong ứng dụng Phím tắt"
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

// MARK: - Các Component Giao Diện
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
        VStack(spacing: 6) {
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
            SwiftUI.Text(caption)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 1. Trang Hướng Dẫn & Thao Tác Trực Tiếp Pairing File
struct PairingGuideSheetView: SwiftUI.View {
    @ObservedObject var vm: SystemCheckViewModel
    @StateObject private var wirelessVM = WirelessPairViewModel()
    @StateObject private var pairingMgmtVM = PairingFileManagementViewModel()
    
    @State private var showDeleteConfirm = false
    @State private var statusBannerMessage: String? = nil
    @State private var isExportSheetPresented = false
    @State private var exportFileURL: URL? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    /// Đường dẫn file Pairing dùng để Xuất & Lưu vào Tệp (chỉ hiện sau khi Cài Pairing lên iPhone xong)
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
                    // Trạng thái hiện tại
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
                    
                    // Thông báo phản hồi nhanh khi Nhập / Xoá / Cài xong
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
                    
                    // KHU VỰC QUẢN LÝ TỆP PAIRING NHANH (Nhập & Xoá)
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Quản lý tệp Pairing nhanh", systemImage: "folder.fill.badge.gearshape")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 12) {
                            // Nút Nhập tệp Pairing
                            SwiftUI.Button {
                                pairingMgmtVM.promptImport(for: .rppairing)
                            } label: {
                                HStack(spacing: 8) {
                                    SwiftUI.Image(systemName: "square.and.arrow.down.fill")
                                    SwiftUI.Text("Nhập tệp Pairing")
                                        .font(.subheadline.bold())
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(SwiftUI.Color.blue)
                                .cornerRadius(12)
                            }
                            
                            // Nút Xoá tệp Pairing hiện tại
                            SwiftUI.Button {
                                showDeleteConfirm = true
                            } label: {
                                HStack(spacing: 8) {
                                    SwiftUI.Image(systemName: "trash.fill")
                                    SwiftUI.Text("Xoá tệp Pairing")
                                        .font(.subheadline.bold())
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(SwiftUI.Color.red)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    // HƯỚNG DẪN & NÚT CÀI PAIRING TRỰC TIẾP TRÊN iOS 27
                    VStack(alignment: .leading, spacing: 14) {
                        SwiftUI.Label("Dành cho iOS 27 (Ghép nối trực tiếp không cần PC)", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        GuideStepRow(num: "1", text: "Nhấn trực tiếp nút **“Cài Pairing lên iPhone”** ngay bên dưới để khởi chạy máy chủ ghép nối.")
                        GuideStepRow(num: "2", text: "Mở ứng dụng **Cài đặt** của iPhone ➔ **Quyền riêng tư & Bảo mật** ➔ **Chế độ nhà phát triển (Developer Mode)**.")
                        GuideStepRow(num: "3", text: "Kiểm tra danh sách thiết bị đã ghép nối: nếu có thiết bị nào đã ghép nối từ trước thì **xoá hết đi**, sau đó nhấn chọn **Pair with SideStore** và nhập mật khẩu mở máy.")
                        GuideStepRow(num: "4", text: "Quay lại màn hình này, ghi nhớ **6 chữ số** hiện lên bên dưới, rồi chuyển lại qua ứng dụng **Cài đặt** để nhập 6 số đó vào.")
                        GuideStepRow(num: "5", text: "Khi cài xong Pairing lên iPhone, nút **“Xuất và lưu file Pairing vào Tệp”** sẽ xuất hiện bên dưới để bạn lưu lại dùng về sau.")
                        
                        Divider().padding(.vertical, 4)
                        
                        // Trạng thái trực tiếp của Wireless Pairing Server
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(wirelessVM.isAdvertising ? SwiftUI.Color.green : SwiftUI.Color.secondary.opacity(0.4))
                                    .frame(width: 10, height: 10)
                                SwiftUI.Text(wirelessVM.statusText)
                                    .font(.subheadline.bold())
                                Spacer()
                            }
                            
                            SwiftUI.Text(wirelessVM.subStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Hiển thị ngay mã PIN 6 số tại đây nếu iPhone yêu cầu
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
                            
                            // Nút 1: Cài Pairing lên iPhone (Start / Stop Pairing Server)
                            SwiftUI.Button {
                                wirelessVM.togglePairing()
                            } label: {
                                HStack(spacing: 10) {
                                    SwiftUI.Image(systemName: wirelessVM.isAdvertising ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 18, weight: .bold))
                                    SwiftUI.Text(wirelessVM.isAdvertising ? "Dừng Cài Pairing (Stop Server)" : "Cài Pairing lên iPhone")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(wirelessVM.isAdvertising ? SwiftUI.Color.red : SwiftUI.Color.accentColor)
                                .cornerRadius(14)
                            }
                            
                            // Nút 2: Xuất và lưu file Pairing vào Tệp (CHỈ HIỆN KHI ĐÃ CÀI XONG PAIRING LÊN IPHONE)
                            if let pairedURL = installedPairingURLForExport {
                                SwiftUI.Button {
                                    exportFileURL = pairedURL
                                    isExportSheetPresented = true
                                } label: {
                                    HStack(spacing: 10) {
                                        SwiftUI.Image(systemName: "square.and.arrow.up.fill")
                                            .font(.system(size: 18, weight: .bold))
                                        SwiftUI.Text("Xuất và lưu file Pairing vào Tệp")
                                            .font(.headline)
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(SwiftUI.Color.green)
                                    .cornerRadius(14)
                                }
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(12)
                        .background(SwiftUI.Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(14)
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    // Hướng dẫn dưới iOS 27
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Dành cho iOS dưới iOS 27 (Dùng iLoader & Máy tính)", systemImage: "laptopcomputer.and.iphone")
                            .font(.headline)
                            .foregroundColor(.purple)
                        
                        GuideStepRow(num: "1", text: "Trên máy tính, cài đặt **iTunes** và **iCloud** (bản chính thức từ Apple), sau đó tải và mở công cụ **iLoader**.")
                        GuideStepRow(num: "2", text: "Cắm cáp kết nối iPhone vào máy tính, mở khóa màn hình iPhone và nhấn **Tin cậy (Trust)** máy tính này.")
                        GuideStepRow(num: "3", text: "Trên giao diện **iLoader**, chọn thiết bị của bạn rồi nhấn nút tạo **Pairing File** (hoặc gửi trực tiếp vào SideStore).")
                        GuideStepRow(num: "4", text: "Nếu lưu thành file trên máy tính, hãy chuyển file đó sang iPhone và lưu vào ứng dụng **Tệp (Files)**.")
                        GuideStepRow(num: "5", text: "Nhấn nút **“Nhập tệp Pairing”** màu xanh ở ngay đầu trang này để chọn file vừa lưu là hoàn tất.")
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Hướng Dẫn & Cài Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
            #if !os(tvOS)
            .fileImporter(
                isPresented: $pairingMgmtVM.showFileImporter,
                allowedContentTypes: pairingMgmtVM.allowedPairingTypes
            ) { result in
                pairingMgmtVM.handleImportResult(result)
                Task { @MainActor in
                    let proto = PairingFileManager.shared.persistedActiveProtocol
                        ?? PairingFileManager.shared.preferredProtocol
                        ?? .rppairing
                    try? await minimuxerSwitchPairingProtocol(to: proto)
                    vm.updateInstantStatus()
                    await vm.checkAllStatuses(forceVerify: true)
                    statusBannerMessage = "Đã nhập tệp Pairing thành công!"
                }
            }
            #endif
            .alert("Xoá tệp Pairing hiện tại?", isPresented: $showDeleteConfirm) {
                SwiftUI.Button("Xoá tất cả tệp Pairing", role: .destructive) {
                    PairingFileManager.shared.resetAllPairingFiles()
                    wirelessVM.shareSheetURL = nil
                    wirelessVM.pairedDevice = nil
                    statusBannerMessage = "Đã xoá toàn bộ tệp Pairing hiện tại."
                    vm.updateInstantStatus()
                    Task { @MainActor in
                        await vm.checkAllStatuses(forceVerify: true)
                    }
                }
                SwiftUI.Button("Huỷ", role: .cancel) { }
            } message: {
                SwiftUI.Text("Thao tác này sẽ xoá toàn bộ tệp Pairing đang lưu trong SideStore (gồm cả Lockdown và Remote Pairing).")
            }
            .sheet(isPresented: Binding(
                get: { wirelessVM.pinCode != nil },
                set: { if !$0 { wirelessVM.pinCode = nil } }
            )) {
                if let pin = wirelessVM.pinCode {
                    if #available(iOS 16.0, tvOS 16.0, *) {
                        WirelessPairPinDialog(pin: pin) {
                            wirelessVM.pinCode = nil
                        }
                        .presentationDetents([.fraction(0.45), .medium])
                        .presentationDragIndicator(.visible)
                    } else {
                        WirelessPairPinDialog(pin: pin) {
                            wirelessVM.pinCode = nil
                        }
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
                    try? PairingFileManager.shared.importPairingFile(from: pairedURL, preferred: .rppairing)
                    Task { @MainActor in
                        try? await minimuxerSwitchPairingProtocol(to: .rppairing)
                        vm.updateInstantStatus()
                        await vm.checkAllStatuses(forceVerify: true)
                        statusBannerMessage = "Đã cài Pairing lên iPhone thành công! Bạn có thể nhấn nút màu xanh lá bên dưới để lưu file vào Tệp."
                    }
                }
            }
        }
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

// MARK: - 2. Trang Chi Tiết LocalDevVPN
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

// MARK: - 3. Trang Chi Tiết Mạng 4G / Di Động
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

// MARK: - 4. Trang Chi Tiết & Cấu Hình Nhanh Máy Chủ Anisette
struct AnisetteDetailSheetView: SwiftUI.View {
    @ObservedObject var vm: SystemCheckViewModel
    @ObservedObject private var serversManager = AnisetteServersManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. Trạng thái hiện tại
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
                    
                    // 2. Công tắc Bật / Tắt trực tiếp (Đồng bộ 2 chiều với Cài đặt)
                    VStack(alignment: .leading, spacing: 14) {
                        SwiftUI.Label("Thiết lập Use On-Device Anisette", systemImage: "switch.2")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        Toggle(isOn: Binding(
                            get: { vm.useOnDeviceAnisette },
                            set: { newValue in
                                vm.setUseOnDeviceAnisette(newValue)
                            }
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
                        
                        SwiftUI.Text("• **Khuyên dùng:** Bạn nên **TẮT** mục **Use On-Device Anisette** để SideStore lấy dữ liệu xác thực thông qua **Máy chủ Anisette**, giúp đăng nhập Apple ID, cài IPA và làm mới ứng dụng qua 4G + VPN ổn định hơn.\n• Công tắc này được đồng bộ trực tiếp với mục **Use On-Device Anisette** trong tab Cài đặt (Settings).")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    // 3. Danh sách chọn nhanh Máy chủ Anisette
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SwiftUI.Label("Danh sách Máy chủ Anisette", systemImage: "server.rack")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            if serversManager.isLoadingPublicServers {
                                ProgressView()
                            } else {
                                SwiftUI.Button {
                                    Task {
                                        await serversManager.refreshPublicServers(force: true)
                                    }
                                } label: {
                                    SwiftUI.Label("Làm mới", systemImage: "arrow.clockwise")
                                        .font(.caption.bold())
                                }
                            }
                        }
                        
                        SwiftUI.Text("Chạm vào một máy chủ bên dưới để chọn làm Máy chủ Anisette đang hoạt động:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 8) {
                            ForEach(serversManager.allServers) { server in
                                let isSelected = (serversManager.selectedServerURL == server.url)
                                SwiftUI.Button {
                                    serversManager.selectServer(server)
                                    // Nếu đang bật On-Device Anisette thì tự động tắt khi người dùng chọn máy chủ
                                    if vm.useOnDeviceAnisette {
                                        vm.setUseOnDeviceAnisette(false)
                                    } else {
                                        vm.updateInstantStatus()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        SwiftUI.Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(isSelected ? .green : .secondary)
                                        
                                        VStack(alignment: .leading, spacing: 3) {
                                            SwiftUI.Text(server.name)
                                                .font(.subheadline.bold())
                                                .foregroundColor(.primary)
                                            SwiftUI.Text(server.url)
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
                        
                        NavigationLink(destination: AnisetteServersView()) {
                            HStack {
                                SwiftUI.Image(systemName: "slider.horizontal.3")
                                SwiftUI.Text("Quản lý / Thêm máy chủ Anisette tùy chỉnh...")
                                    .font(.subheadline.bold())
                                Spacer()
                                SwiftUI.Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                            }
                            .padding(12)
                            .background(SwiftUI.Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .cornerRadius(12)
                        }
                        .padding(.top, 4)
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
                await serversManager.refreshPublicServers()
                vm.updateInstantStatus()
            }
        }
    }
}
