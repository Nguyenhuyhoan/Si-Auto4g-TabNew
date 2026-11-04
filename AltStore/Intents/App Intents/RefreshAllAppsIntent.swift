//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents
import Minimuxer

@available(iOS 16, tvOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible, @unchecked Sendable
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        let serializedError = (error as NSError).sanitizedForSerialization()
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct InstallIPAIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource = "Install IPA"
    static var description = IntentDescription("Installs an IPA file with SideStore.")
    static var openAppWhenRun = false

    @Parameter(title: "IPA File")
    var ipaFile: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$ipaFile)")
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult
    {
        do
        {
            try await DatabaseManager.shared.start()

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let ipaURL = temporaryDirectory.appendingPathComponent("App.ipa")
            try self.ipaFile.data.write(to: ipaURL)

            let intentProgress = self.progress
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstalledApp, Error>) in
                let group = AppManager.shared.install(.url(ipaURL)) { result in
                    continuation.resume(with: result)
                }
                intentProgress.addChild(group.progress, withPendingUnitCount: 1)
            }

            return .result()
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
extension RefreshAllAppsIntent
{
    actor OperationActor
    {
        private(set) var operation: BackgroundRefreshAppsOperation?
        
        func set(_ operation: BackgroundRefreshAppsOperation?)
        {
            self.operation = operation
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static let intentClassName = "RefreshAllIntent"
    
    // Đổi tên hiển thị duy nhất
    static var title: LocalizedStringResource = "Refresh All Apps (Wifi/4G)"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps (Wifi/4G)")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps (Wifi/4G)",
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    private let operationActor = OperationActor()
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    // Đã bỏ "& ProvidesDialog" để không ép trả về thông báo văn bản
    func perform() async throws -> some IntentResult
    {
        do
        {
            let deadline: ContinuousClock.Instant = .now + .seconds(27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await self.refreshAllApps()
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    throw OperationError.timedOut
                }
                
                do
                {
                    for try await _ in taskGroup.prefix(1)
                    {
                        taskGroup.cancelAll()
                        break
                    }
                }
                catch OperationError.timedOut
                {
                    let operation = await self.operationActor.operation
                    // Đổi thành false để ngay cả khi chạy quá 27s vẫn không bắn thông báo lúc thành công
                    operation?.presentsFinishedNotification = false
                    
                    try await self.requestToContinueInForeground()
                }
            }
            
            // Trả về kết quả rỗng (Im lặng tuyệt đối khi thành công)
            return .result()
        }
        catch
        {
            // Khi có lỗi (cả Wifi lẫn 4G), quăng lỗi ra để Shortcuts hiện thông báo
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async throws
    {
        try await DatabaseManager.shared.start()

        // 1. KIỂM TRA NẾU ĐÃ CÓ PROFILE LƯU TẠM TỪ GIAI ĐOẠN 1 (TRONG VÒNG 3 PHÚT) -> CHẠY GIAI ĐOẠN 2 TIÊM PROFILE!
        if CellularRefreshManager.shared.hasRecentStagedBatches {
            defer {
                CellularRefreshManager.shared.isShortcutTwoStageMode = false
                CellularRefreshManager.shared.stagedBatches = []
            }
            let batches = CellularRefreshManager.shared.stagedBatches
            if !batches.isEmpty {
                let dbContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
                let injectContext = StandaloneOperationContext(steps: .injectBatchProfiles, dbBackgroundContext: dbContext)
                let injectOp = try InjectBatchProfilesOperation(batches: batches, context: injectContext)
                try await injectOp.execute()
                await WidgetDataManager.publishCurrentInstalledApps(in: dbContext)
                self.progress.completedUnitCount = 1
                return
            }
        }

        // 2. TỰ ĐỘNG KIỂM TRA: NẾU KHÔNG CÓ WI-FI -> TỰ ĐỘNG BẬT CHẾ ĐỘ 4G (LƯU TẠM 2 GIAI ĐOẠN)
        let isFourGMode = !minimuxer.network.isWifiSatisfied
        if isFourGMode {
            CellularRefreshManager.shared.isShortcutTwoStageMode = true
            CellularRefreshManager.shared.stagedBatches = []
        }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        do {
            try await withCheckedThrowingContinuation { continuation in
                // Luôn đặt presentsNotifications: false để tắt thông báo đẩy của hệ thống khi chạy bằng phím tắt
                let operation = try? AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: false) { (result) in
                    do
                    {
                        let results = try result.get()
                        
                        for (_, result) in results
                        {
                            guard case let .failure(error) = result else { continue }
                            throw error
                        }
                        
                        continuation.resume()
                    }
                    catch OperationError.noInstalledApps
                    {
                        continuation.resume()
                    }
                    catch
                    {
                        continuation.resume(throwing: error)
                    }
                }
                
                guard let operation else {
                    debugLog("[RefreshAllAppsIntent] backgroundRefresh instance is nil")
                    continuation.resume()
                    return 
                }
                
                operation.ignoresServerNotFoundError = isFourGMode
                
                self.progress.addChild(operation.progress, withPendingUnitCount: 1)
                
                Task {
                    await self.operationActor.set(operation)
                }
            }
            CellularRefreshManager.shared.isShortcutTwoStageMode = false
        } catch {
            CellularRefreshManager.shared.isShortcutTwoStageMode = false
            throw error
        }
    }
}
