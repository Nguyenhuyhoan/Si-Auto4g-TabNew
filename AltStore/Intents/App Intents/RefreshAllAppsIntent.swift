
//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents
@preconcurrency import UIKit

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
    
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
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
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async throws
    {
        try await DatabaseManager.shared.start()
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        try await withCheckedThrowingContinuation { continuation in
            let operation = try? AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: self.presentsNotifications) { (result) in
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
                return 
            }
            
            operation.ignoresServerNotFoundError = false
            
            self.progress.addChild(operation.progress, withPendingUnitCount: 1)
            
            Task {
                await self.operationActor.set(operation)
            }
        }
    }
}

// MARK: - Cellular Refresh Two-Stage Shortcut Support

@MainActor private var shortcutBridgeBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

@MainActor private func beginShortcutBridgeBackgroundTask() {
    if shortcutBridgeBackgroundTaskID != .invalid {
        UIApplication.shared.endBackgroundTask(shortcutBridgeBackgroundTaskID)
    }
    shortcutBridgeBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "com.sidestore.CellularShortcutBridge") {
        UIApplication.shared.endBackgroundTask(shortcutBridgeBackgroundTaskID)
        shortcutBridgeBackgroundTaskID = .invalid
    }
}

@MainActor private func endShortcutBridgeBackgroundTask() {
    if shortcutBridgeBackgroundTaskID != .invalid {
        UIApplication.shared.endBackgroundTask(shortcutBridgeBackgroundTaskID)
        shortcutBridgeBackgroundTaskID = .invalid
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct CellularRefresh1Intent: AppIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static var title: LocalizedStringResource = "Cellular Refresh 1"
    static var description = IntentDescription("Giai đoạn 1: Tải Provisioning Profile qua 4G và lưu tạm.")
    static var openAppWhenRun: Bool = false

    private let operationActor = RefreshAllAppsIntent.OperationActor()

    init() {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        // Giữ cho tiến trình LiveContainer/SideStore sống ngầm xuyên suốt từ Bước 1 sang Bước 2 khi màn hình tắt
        await beginShortcutBridgeBackgroundTask()

        CellularRefreshManager.shared.isShortcutTwoStageMode = true
        CellularRefreshManager.shared.stagedBatches = []

        do {
            let deadline: ContinuousClock.Instant = .now + .seconds(27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await self.runStage1()
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    throw OperationError.timedOut
                }
                
                do {
                    for try await _ in taskGroup.prefix(1) {
                        taskGroup.cancelAll()
                        break
                    }
                } catch OperationError.timedOut {
                    let operation = await self.operationActor.operation
                    operation?.presentsFinishedNotification = false
                    try await self.requestToContinueInForeground()
                }
            }

            return .result(dialog: "Cellular Refresh 1 hoàn tất.")
        } catch {
            CellularRefreshManager.shared.isShortcutTwoStageMode = false
            await endShortcutBridgeBackgroundTask()
            throw IntentError(error)
        }
    }

    private func runStage1() async throws {
        try await DatabaseManager.shared.start()
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = try? AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: false) { result in
                do {
                    let results = try result.get()
                    for (_, res) in results {
                        guard case let .failure(error) = res else { continue }
                        throw error
                    }
                    continuation.resume()
                } catch OperationError.noInstalledApps {
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            guard let operation else {
                continuation.resume(throwing: OperationError.unknownResult)
                return
            }

            operation.ignoresServerNotFoundError = true
            self.progress.addChild(operation.progress, withPendingUnitCount: 1)
            
            Task {
                await self.operationActor.set(operation)
            }
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct CellularRefresh2Intent: AppIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static var title: LocalizedStringResource = "Cellular Refresh 2"
    static var description = IntentDescription("Giai đoạn 2: Tiêm Profile vào máy khi đã tắt 4G.")
    static var openAppWhenRun: Bool = false

    init() {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        // Tiếp tục gia hạn Background Task trong suốt quá trình tiêm Profile khi màn hình khóa
        await beginShortcutBridgeBackgroundTask()

        defer {
            CellularRefreshManager.shared.isShortcutTwoStageMode = false
            CellularRefreshManager.shared.stagedBatches = []
            Task { @MainActor in
                endShortcutBridgeBackgroundTask()
            }
        }

        do {
            let deadline: ContinuousClock.Instant = .now + .seconds(27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await self.runStage2()
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    throw OperationError.timedOut
                }
                
                do {
                    for try await _ in taskGroup.prefix(1) {
                        taskGroup.cancelAll()
                        break
                    }
                } catch OperationError.timedOut {
                    try await self.requestToContinueInForeground()
                }
            }

            return .result(dialog: "Đã làm mới tất cả ứng dụng bằng 4G!")
        } catch {
            throw IntentError(error)
        }
    }

    private func runStage2() async throws {
        try await DatabaseManager.shared.start()
        let batches = CellularRefreshManager.shared.stagedBatches
        guard !batches.isEmpty else {
            return
        }

        // Chờ 1.5s để bảng định tuyến (Routing Table) của iOS ngắt hẳn 4G và chuyển hoàn toàn sang LocalDevVPN khi màn hình tắt
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Khởi động lại EMProxy giống hệt luồng Wi-Fi Refresh trong BackgroundRefreshAppsOperation
        if UserDefaults.standard.enableEMPforWireguard {
            try? await startEMProxy()
        }

        // Đảm bảo Minimuxer đã sẵn sàng nhận kết nối qua VPN
        let isReady = await CellularRefreshManager.shared.waitForMinimuxerReady(timeout: 8.0)
        if !isReady {
            try? await ensureMinimuxerReady()
        }

        let dbContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let injectContext = StandaloneOperationContext(steps: .injectBatchProfiles, dbBackgroundContext: dbContext)
        let injectOp = try InjectBatchProfilesOperation(batches: batches, context: injectContext)
        try await injectOp.execute()

        await WidgetDataManager.publishCurrentInstalledApps(in: dbContext)
        self.progress.completedUnitCount = 1
    }
}
