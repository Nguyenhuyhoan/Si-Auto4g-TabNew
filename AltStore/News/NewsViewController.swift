// AltStore/News/NewsViewController.swift

//
//  NewsViewController.swift
//  AltStore
//

@preconcurrency import UIKit
import SwiftUI
import Network
import Minimuxer
import Combine

class NewsViewController: UICollectionViewController {
    // Giữ lại biến `source` để tương thích 100% với Storyboard
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
                guard let self else { return }
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
                guard let self else { return }
                self.updateFastNetworkUI()
                Task { await self.checkAllStatuses() }
            }
            .store(in: &cancellables)
        
        // 3. Lắng nghe thay đổi trạng thái Pairing/Muxer tức thì
        minimuxerStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.checkAllStatuses() }
            }
            .store(in: &cancellables)
        
        // 4. Khi quay lại app từ Cài đặt hoặc LocalDevVPN -> Kiểm tra ngay lập tức
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateFastNetworkUI()
                Task { await self.checkAllStatuses() }
            }
            .store(in: &cancellables)
        
        // 5. Vòng lặp quét định kỳ mỗi 1.5 giây để đảm bảo luôn mới nhất
        timerTask = Task {
            while !Task.isCancelled {
                await checkAllStatuses()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    
    /// Cập nhật ngay lập tức trạng thái 4G và IP không cần đợi ping
    private func updateFastNetworkUI() {
        let interfaces: [LocalInterfaceInfo] = minimuxer.network.activeInterfaces
        var hasPdp = false
        for iface in interfaces {
            if iface.name.lowercased().hasPrefix("pdp_ip") && !iface.address.isEmpty {
                hasPdp = true
                break
            }
        }
        
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
        
        let result = await Task.detached(priority: .userInitiated) { () -> (vpnOK: Bool, tIP: String, dIP: String, pairOK: Bool, proto: String) in
            let utun = minimuxer.network.isUTunAvailable
            let tIP = ConnectionConfig.shared.formattedTunnelIface ?? "Chưa kết nối"
            let dIP = ConnectionConfig.shared.formattedTunnelPeer ?? "Chưa kết nối"
            
            let targetIp = ConnectionConfig.shared.overrideTunnelPeerReachable
                ? ConnectionConfig.shared.overrideTunnelPeerIp
                : (ConnectionConfig.shared.tunnelPeerIp ?? "")
            let pingSuccess = !targetIp.isEmpty && minimuxer.core.testDeviceConnection(ifaddr: targetIp)
            
            let isLoaded = minimuxer.core.isPairingFileLoaded
            let verified = (try? await fetchUDID(forceLive: true)) != nil
            
            let proto: String
            switch minimuxer.core.pairingFileType {
            case .rppairing: proto = "Remote Pairing (iOS 17+ / 27)"
            case .lockdown:  proto = "Lockdown Pairing"
            case .unknown:   proto = isLoaded ? "Đã nạp nhưng chưa xác thực" : "Chưa nạp Pairing File"
            }
            
            return (utun && pingSuccess, tIP, dIP, isLoaded && verified, proto)
        }.value
        
        self.isVpnOK = result.vpnOK
        self.tunnelIP = result.tIP
        self.deviceIP = result.dIP
        self.isPairingOK = result.pairOK
        self.pairingProtocol = result.proto
    }
}

// MARK: - Giao Diện Chính (Tab Check)
struct SystemCheckDashboardView: View {
    @StateObject private var vm = SystemCheckViewModel()
    @State private var showPairingSheet = false
    @State private var showVpnSheet = false
    @State private var showCellularSheet = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerBanner
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("TRẠNG THÁI HỆ THỐNG (NHẤN ĐỂ XEM CHI TIẾT)")
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
        .background(Color(UIColor.systemGroupedBackground))
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
    
    private var headerBanner: some View {
        let allReady = vm.isPairingOK && vm.isVpnOK && vm.isCellularOK
        return HStack(spacing: 14) {
            Image(systemName: allReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(allReady ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(allReady ? "Hệ thống Ổn định • Sẵn sàng!" : "Phát hiện mục chưa ổn định")
                    .font(.headline)
                Text("Cài đặt và làm mới ứng dụng trực tiếp qua 4G + LocalDevVPN (Không cần Wi-Fi).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PHÍM TẮT DÙNG CHO CÀI & LÀM MỚI APP QUA 4G + VPN")
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
    
    private var automationGuideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
                Text("Lưu ý khi cài đặt Phím tắt cuối cùng")
                    .font(.subheadline.bold())
            }
            
            Text("Để bật chế độ tự động chạy hằng ngày lúc 6h sáng, bạn cần vào ứng dụng **Phím tắt** ➔ bật mục **“Tự động hóa”** và thiết lập giống như 2 ảnh hướng dẫn dưới đây:")
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
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

// MARK: - Các Component Giao Diện
struct CheckItemButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let isStable: Bool
    let action: () -> Void
    
    var body: some View {
        SwiftUI.Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isStable ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isStable ? .green : .red)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: isStable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isStable ? .green : .red)
                    .animation(.spring(), value: isStable)
                
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ShortcutLinkRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let urlString: String
    
    var body: some View {
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
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text("Cài đặt")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.15))
                    .foregroundColor(color)
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct RemoteGuideImageView: View {
    let urlString: String
    let caption: String
    
    var body: some View {
        VStack(spacing: 6) {
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang tải ảnh hướng dẫn...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .background(Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(12)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    case .failure:
                        VStack(spacing: 6) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.title2)
                            Text("Không tải được ảnh. Hãy kiểm tra kết nối mạng.")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(12)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            Text(caption)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 1. Trang Hướng Dẫn Pairing File
struct PairingGuideSheetView: View {
    let isPairingOK: Bool
    let protocolName: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: isPairingOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(isPairingOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isPairingOK ? "Pairing File Đang Ổn Định" : "Pairing File Chưa Ổn Định")
                                .font(.headline)
                            Text("Trạng thái: \(protocolName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    // Hướng dẫn iOS 27
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Dành cho iOS 27 (Ghép nối trực tiếp không cần PC)", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        GuideStepRow(num: "1", text: "Mở **SideStore** ➔ vào tab **Cài đặt (Settings)** ➔ chọn **Pairing File Management** ➔ **Wireless Pairing** ➔ nhấn nút **Start Pairing Server**.")
                        GuideStepRow(num: "2", text: "Mở ứng dụng **Cài đặt** của iPhone ➔ **Quyền riêng tư & Bảo mật** ➔ **Chế độ nhà phát triển (Developer Mode)**.")
                        GuideStepRow(num: "3", text: "Kiểm tra danh sách thiết bị đã ghép nối: nếu có thiết bị nào đã ghép nối từ trước thì **xoá hết đi**, sau đó nhấn chọn **Pair with SideStore** và nhập mật khẩu mở máy.")
                        GuideStepRow(num: "4", text: "Quay lại ứng dụng **SideStore**, ghi nhớ **6 chữ số** hiện lên trên màn hình, rồi chuyển lại qua ứng dụng **Cài đặt** để nhập 6 số đó vào.")
                        GuideStepRow(num: "5", text: "Khi ghép nối xong, quay lại **SideStore** sẽ hiện bảng lưu tệp. Bạn hãy chọn **Lưu vào Tệp (Files)** ở vị trí dễ nhớ để dành khi cần dùng lại sau này.")
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    // Hướng dẫn dưới iOS 27
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Dành cho iOS dưới iOS 27 (Dùng iLoader & Máy tính)", systemImage: "laptopcomputer.and.iphone")
                            .font(.headline)
                            .foregroundColor(.purple)
                        
                        GuideStepRow(num: "1", text: "Trên máy tính, cài đặt **iTunes** và **iCloud** (bản chính thức từ Apple), sau đó tải và mở công cụ **iLoader**.")
                        GuideStepRow(num: "2", text: "Cắm cáp kết nối iPhone vào máy tính, mở khóa màn hình iPhone và nhấn **Tin cậy (Trust)** máy tính này.")
                        GuideStepRow(num: "3", text: "Trên giao diện **iLoader**, chọn thiết bị của bạn rồi nhấn nút tạo **Pairing File** (hoặc gửi trực tiếp vào SideStore).")
                        GuideStepRow(num: "4", text: "Nếu lưu thành file trên máy tính, hãy chuyển file đó sang iPhone và lưu vào ứng dụng **Tệp (Files)**.")
                        GuideStepRow(num: "5", text: "Mở **SideStore** ➔ **Cài đặt** ➔ **Pairing File Management** ➔ nhấn Import để chọn file vừa lưu là hoàn tất.")
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Hướng Dẫn Pairing File")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
        }
    }
}

struct GuideStepRow: View {
    let num: String
    let text: LocalizedStringKey
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 2. Trang Chi Tiết LocalDevVPN
struct VpnDetailSheetView: View {
    let isVpnOK: Bool
    let tunnelIP: String
    let deviceIP: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: isVpnOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(isVpnOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isVpnOK ? "LocalDevVPN Đang Ổn Định" : "LocalDevVPN Chưa Kết Nối / Sai IP")
                                .font(.headline)
                            Text("Đảm bảo bạn đã bật VPN trong ứng dụng LocalDevVPN.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ĐỊA CHỈ IP ĐANG CÓ HIỆN TẠI")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("Tunnel IP đang có:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(tunnelIP)
                                .font(.system(.body, design: .monospaced).bold())
                        }
                        Divider()
                        HStack {
                            Text("Device IP đang có:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(deviceIP)
                                .font(.system(.body, design: .monospaced).bold())
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Lời khuyên cấu hình cho iOS 27", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        Text("Nếu bạn đang ở **iOS 27** và đang dùng phiên bản này, bạn nên chỉnh lại cấu hình IP theo đúng thông số dưới đây để kết nối nhanh và ổn định nhất:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        CopyableIPCard(label: "Tunnel IP", value: "10.7.1.1/32")
                        CopyableIPCard(label: "Device IP", value: "10.7.0.1/32")
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Cấu Hình LocalDevVPN")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
        }
    }
}

struct CopyableIPCard: View {
    let label: String
    let value: String
    @State private var copied = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
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
                Label(copied ? "Đã chép" : "Sao chép", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(copied ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.15))
                    .foregroundColor(copied ? .green : .accentColor)
                    .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - 3. Trang Chi Tiết Mạng 4G / Di Động
struct CellularDetailSheetView: View {
    let isCellularOK: Bool
    let detail: String
    let hasInternet: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: isCellularOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(isCellularOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isCellularOK ? "Mạng 4G / Di Động Ổn Định" : "Mạng 4G / Di Động Đang Tắt")
                                .font(.headline)
                            Text(detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Hoạt động độc lập qua 4G + VPN", systemImage: "antenna.radiowaves.left.and.right.circle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        Text("• **Không cần Wi-Fi:** SideStore phiên bản này cho phép bạn cài đặt IPA và làm mới (Refresh) ứng dụng trực tiếp bằng mạng **4G/5G kết hợp LocalDevVPN**.\n\n• **Trạng thái Internet:** \(hasInternet ? "Đang kết nối Internet tốt ✅" : "Chưa có kết nối Internet ❌").\n\n• **Tự động hóa hoàn toàn:** Hãy tải 3 phím tắt ở trang Check và bật Tự động hóa lúc 6h sáng để máy tự động bật 4G + VPN và gia hạn ứng dụng mỗi ngày.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Mạng 4G / Di Động")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Xong") { dismiss() })
        }
    }
}
