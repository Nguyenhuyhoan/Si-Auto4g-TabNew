
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
    
    static var title: LocalizedStringResource = "Refresh All Wifi"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Wifi")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Wifi",
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
    
    func perform() async throws -> some IntentResult & ProvidesDialog
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
                    operation?.presentsFinishedNotification = true
                    
                    try await self.requestToContinueInForeground()
                }
            }
            
            return .result(dialog: "All apps have been refreshed.")
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

        // 2. NẾU KHÔNG CÓ WI-FI (ĐANG CHẠY PHÍM TẮT 4G BƯỚC 1) -> TỰ ĐỘNG BẬT CHẾ ĐỘ LƯU TẠM 2 GIAI ĐOẠN!
        let isWifi = minimuxer.network.isWifiSatisfied
        if !isWifi {
            CellularRefreshManager.shared.isShortcutTwoStageMode = true
            CellularRefreshManager.shared.stagedBatches = []
        }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        do {
            try await withCheckedThrowingContinuation { continuation in
                let operation = try? AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: isWifi ? self.presentsNotifications : false) { (result) in
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
                
                operation.ignoresServerNotFoundError = !isWifi
                
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

@available(iOS 17.0, tvOS 17.0, *)
struct RefreshAll4GIntent: AppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static var title: LocalizedStringResource = "Refresh All 4g"
    static var description = IntentDescription("Làm mới tất cả ứng dụng bằng 4G (Tự động phân biệt Giai đoạn 1 và Giai đoạn 2).")

    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All 4g")
    }

    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All 4g",
                subtitle: ""
            )
        }
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        // Gọi trực tiếp sang RefreshAllAppsIntent (Refresh All Wifi) để xử lý tự động 2 giai đoạn
        let wifiIntent = RefreshAllAppsIntent(presentsNotifications: false)
        self.progress.addChild(wifiIntent.progress, withPendingUnitCount: 1)
        return try await wifiIntent.perform()
    }
}
