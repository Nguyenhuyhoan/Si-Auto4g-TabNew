// AltStore/News/NewsViewController.swift

//
//  NewsViewController.swift
//  AltStore
//

@preconcurrency import UIKit
import SwiftUI
import Network
@preconcurrency import Minimuxer
import Combine
import AltStoreCore
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

// MARK: - ViewModel Cập Nhật Tức Thì (Real-time + Background Non-blocking)
@MainActor
final class SystemCheckViewModel: ObservableObject {
    @Published var isPairingOK: Bool = false
    @Published var pairingProtocol: String = "Đang kiểm tra..."
    
    @Published var isVpnOK: Bool = false
    @Published var tunnelIP: String = "Chưa có"
    @Published var deviceIP: String = "Chưa có"
    
    @Published var isCellularOK: Bool = false
    @Published var cellularDetail: String = "Đang kiểm tra..."
    @Published var hasInternet: Bool = false
    
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.sidestore.check.network")
    private var usesCellularPath: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?
    
    init() {
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
                self.updateFastNetworkUI()
                await self.checkAllStatuses()
            }
        }
        pathMonitor.start(queue: monitorQueue)
        
        // 2. Lắng nghe thay đổi VPN/Network từ Minimuxer tức thì
        minimuxer.network.pathPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateFastNetworkUI()
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
                Task { @MainActor [weak self] in
                    await self?.checkAllStatuses()
                }
            }
            .store(in: &cancellables)
        
        // 4. Khi quay lại app từ Cài đặt hoặc LocalDevVPN -> Kiểm tra ngay lập tức
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateFastNetworkUI()
                Task { @MainActor [weak self] in
                    await self?.checkAllStatuses()
                }
            }
            .store(in: &cancellables)
        
        // 5. Vòng lặp quét định kỳ mỗi 1.5 giây để đảm bảo luôn mới nhất
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllStatuses()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    
    /// Kiểm tra thực tế xem interface 4G (pdp_ip*) có đang bật và có IP hay không
    private static func isCellularInterfaceActive() -> Bool {
        // Kiểm tra trong activeInterfaces của Minimuxer
        for iface in minimuxer.network.activeInterfaces {
            if iface.name.lowercased().hasPrefix("pdp_ip") {
                return true
            }
        }
        
        // Kiểm tra trực tiếp bằng hệ thống getifaddrs của iOS
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            if isUp, let addr = current.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                    let name = String(cString: current.pointee.ifa_name)
                    if name.lowercased().hasPrefix("pdp_ip") {
                        return true
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return false
    }
    
    /// Cập nhật ngay lập tức trạng thái 4G và IP không cần đợi ping
    private func updateFastNetworkUI() {
        let hasPdp = Self.isCellularInterfaceActive()
        
        self.isCellularOK = usesCellularPath || hasPdp
        if usesCellularPath {
            self.cellularDetail = "Ổn định • Đang dùng trực tiếp 4G / Di động"
        } else if hasPdp {
            self.cellularDetail = "Ổn định • 4G / Di động đang bật sẵn sàng"
        } else {
            self.cellularDetail = "Không ổn định • Đang tắt Dữ liệu di động (4G)"
        }
        
        self.tunnelIP = ConnectionConfig.shared.formattedTunnelIface ?? "Chưa kết nối"
        self.deviceIP = ConnectionConfig.shared.formattedTunnelPeer ?? "Chưa kết nối"
    }
    
    /// Kiểm tra chuyên sâu ở luồng ngầm (không gây khựng giao diện)
    func checkAllStatuses() async {
        updateFastNetworkUI()
        
        let tIP = ConnectionConfig.shared.formattedTunnelIface ?? "Chưa kết nối"
        let dIP = ConnectionConfig.shared.formattedTunnelPeer ?? "Chưa kết nối"
        let targetIp = ConnectionConfig.shared.overrideTunnelPeerReachable
            ? ConnectionConfig.shared.overrideTunnelPeerIp
            : (ConnectionConfig.shared.tunnelPeerIp ?? "")
        
        let bgCheck = await withCheckedContinuation { (continuation: CheckedContinuation<(vpnOK: Bool, isLoaded: Bool, proto: String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let utun = minimuxer.network.isUTunAvailable
                let pingSuccess = !targetIp.isEmpty && minimuxer.core.testDeviceConnection(ifaddr: targetIp)
                let isLoaded = minimuxer.core.isPairingFileLoaded
                
                let proto: String
                switch minimuxer.core.pairingFileType {
                case .rppairing: proto = "Remote Pairing (iOS 17+ / 27)"
                case .lockdown:  proto = "Lockdown Pairing"
                case .unknown:   proto = isLoaded ? "Đã nạp nhưng chưa xác thực" : "Chưa nạp Pairing File"
                }
                
                continuation.resume(returning: (utun && pingSuccess, isLoaded, proto))
            }
        }
        
        let verified = (try? await fetchUDID(forceLive: true)) != nil
        
        self.isVpnOK = bgCheck.vpnOK
        self.tunnelIP = tIP
        self.deviceIP = dIP
        self.isPairingOK = bgCheck.isLoaded && verified
        self.pairingProtocol = bgCheck.proto
    }
}

// MARK: - Giao Diện Chính (Tab Check)
struct SystemCheckDashboardView: SwiftUI.View {
    @StateObject private var vm = SystemCheckViewModel()
    @State private var showPairingSheet = false
    @State private var showVpnSheet = false
    @State private var showCellularSheet = false
    
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
                        subtitle: vm.isPairingOK ? "Ổn định • \(vm.pairingProtocol)" : "Không ổn định • Nhấn xem hướng dẫn",
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
                
                shortcutsSection
                automationGuideSection
            }
            .padding()
        }
        .background(SwiftUI.Color(UIColor.systemGroupedBackground))
        .refreshable {
            await vm.checkAllStatuses()
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingGuideSheetView(isPairingOK: vm.isPairingOK, protocolName: vm.pairingProtocol)
        }
        .sheet(isPresented: $showVpnSheet) {
            VpnDetailSheetView(isVpnOK: vm.isVpnOK, tunnelIP: vm.tunnelIP, deviceIP: vm.deviceIP)
        }
        .sheet(isPresented: $showCellularSheet) {
            CellularDetailSheetView(isCellularOK: vm.isCellularOK, detail: vm.cellularDetail, hasInternet: vm.hasInternet)
        }
    }
    
    private var headerBanner: some SwiftUI.View {
        let allReady = vm.isPairingOK && vm.isVpnOK && vm.isCellularOK
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
            }
        }
    }
    
    private var automationGuideSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SwiftUI.Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
                SwiftUI.Text("Lưu ý khi cài đặt Phím tắt cuối cùng")
                    .font(.subheadline.bold())
            }
            
            SwiftUI.Text("Để bật chế độ tự động chạy hằng ngày lúc 6h sáng, bạn cần vào ứng dụng **Phím tắt** ➔ bật mục **“Tự động hóa”** và thiết lập giống như 2 ảnh hướng dẫn dưới đây:")
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

// MARK: - 1. Trang Hướng Dẫn Pairing File
struct PairingGuideSheetView: SwiftUI.View {
    let isPairingOK: Bool
    let protocolName: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        SwiftUI.Image(systemName: isPairingOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(isPairingOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            SwiftUI.Text(isPairingOK ? "Pairing File Đang Ổn Định" : "Pairing File Chưa Ổn Định")
                                .font(.headline)
                            SwiftUI.Text("Trạng thái: \(protocolName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    // Hướng dẫn iOS 27
                    VStack(alignment: .leading, spacing: 12) {
                        SwiftUI.Label("Dành cho iOS 27 (Ghép nối trực tiếp không cần PC)", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        GuideStepRow(num: "1", text: "Mở **SideStore** ➔ vào tab **Cài đặt (Settings)** ➔ chọn **Pairing File Management** ➔ **Wireless Pairing** ➔ nhấn nút **Start Pairing Server**.")
                        GuideStepRow(num: "2", text: "Mở ứng dụng **Cài đặt** của iPhone ➔ **Quyền riêng tư & Bảo mật** ➔ **Chế độ nhà phát triển (Developer Mode)**.")
                        GuideStepRow(num: "3", text: "Kiểm tra danh sách thiết bị đã ghép nối: nếu có thiết bị nào đã ghép nối từ trước thì **xoá hết đi**, sau đó nhấn chọn **Pair with SideStore** và nhập mật khẩu mở máy.")
                        GuideStepRow(num: "4", text: "Quay lại ứng dụng **SideStore**, ghi nhớ **6 chữ số** hiện lên trên màn hình, rồi chuyển lại qua ứng dụng **Cài đặt** để nhập 6 số đó vào.")
                        GuideStepRow(num: "5", text: "Khi ghép nối xong, quay lại **SideStore** sẽ hiện bảng lưu tệp. Bạn hãy chọn **Lưu vào Tệp (Files)** ở vị trí dễ nhớ để dành khi cần dùng lại sau này.")
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
                        GuideStepRow(num: "5", text: "Mở **SideStore** ➔ **Cài đặt** ➔ **Pairing File Management** ➔ nhấn Import để chọn file vừa lưu là hoàn tất.")
                    }
                    .padding()
                    .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Hướng Dẫn Pairing File")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
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
                        
                        SwiftUI.Text("• **Không cần Wi-Fi:** SideStore phiên bản này cho phép bạn cài đặt IPA và làm mới (Refresh) ứng dụng trực tiếp bằng mạng **4G/5G kết hợp LocalDevVPN**.\n\n• **Trạng thái Internet:** \(hasInternet ? "Đang kết nối Internet tốt ✅" : "Chưa có kết nối Internet ❌").\n\n• **Tự động hóa hoàn toàn:** Hãy tải 3 phím tắt ở trang Check và bật Tự động hóa lúc 6h sáng để máy tự động bật 4G + VPN và gia hạn ứng dụng mỗi ngày.")
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
