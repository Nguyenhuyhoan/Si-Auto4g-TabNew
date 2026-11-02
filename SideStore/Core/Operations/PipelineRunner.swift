
//
//  PipelineRunner.swift
//  AltStore
//
//  Created by Magesh K on 8/3/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import CoreData
import SideSign


protocol PipelineProgress: Sendable{
    func progress(for operation: AppOperation) -> Progress?
    func set(_ progress: Progress?, for operation: AppOperation)
}
protocol PipelineExecutionContext: AnyObject, Sendable {
    var isActivelyManagingAnyApp: Bool { get }
}
protocol PipelineErrorLogger: AnyObject, Sendable {
    func log(_ error: Error, operation: LoggedError.Operation, app: AppProtocol)
    func getMappedError(for operation: AppOperation, error: Error) -> Error
}


final class PipelineRunner: Sendable
{
    let progress: PipelineProgress
    let context: PipelineExecutionContext
    let logger: PipelineErrorLogger
    let defaultEntitlements: [ALTEntitlement: any Sendable]
    
    init(progress: PipelineProgress,
         context: PipelineExecutionContext,
         logger: PipelineErrorLogger,
         defaultEntitlements: [ALTEntitlement: any Sendable] = [:])
    {
        self.progress = progress
        self.context = context
        self.logger = logger
        self.defaultEntitlements = defaultEntitlements
    }
    
    @discardableResult
    func performSingleOperation(_ operation: AppOperation,
                                handler: PipelineExecutionHandler,
                                dbContext: NSManagedObjectContext,
                                completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        let group = RefreshGroup(dbContext: dbContext)
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else {
                    throw group.error ?? OperationError.unknownResult
                }
                let installedApp = try result.get()
                completionHandler(.success(installedApp))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        debugLog("[AppManager] performSingleOperation started for: \(operation.bundleIdentifier)")
        group.activeTask = Task.detached {
            do {
                debugLog("[AppManager] performSingleOperation executing task for: \(operation.bundleIdentifier)")
                try await self.perform([operation], handler: handler, group: group)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    debugLog("[AppManager] performSingleOperation task CANCELLED for: \(operation.bundleIdentifier)")
                    completionHandler(.failure(OperationError.cancelled))
                    return
                }
                debugLog("[AppManager] performSingleOperation task failed for: \(operation.bundleIdentifier) with error: \(error)")
                completionHandler(.failure(error))
            }
        }
        
        return group
    }
    
    func performVoidOperation(_ operation: AppOperation,
                              handler: PipelineExecutionHandler,
                              dbContext: NSManagedObjectContext,
                              completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        self.performSingleOperation(operation, handler: handler, dbContext: dbContext) { (result) in
            switch result {
            case .success:
                completionHandler(.success(()))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }
    
    @discardableResult
    func perform(_ operations: [AppOperation],
                 handler: PipelineExecutionHandler,
                 group: RefreshGroup) async throws -> RefreshGroup
    {
        let operations = operations.filter { progress.progress(for: $0) == nil || progress.progress(for: $0)?.isCancelled == true }
        guard !operations.isEmpty else { throw OperationError.cancelled }
        
        let backgroundTaskID = await MainActor.run {
            var taskID = UIBackgroundTaskIdentifier.invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "com.altstore.AppManager.perform") {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return taskID
        }
        
        await MainActor.run {
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.isIdleTimeoutDisableEnabled
            }
        }
        
        defer {
            for operation in operations {
                progress.set(nil, for: operation)
            }
            if let error = group.error {
                for operation in operations {
                    group.set(.failure(error), forAppWithBundleIdentifier: operation.bundleIdentifier)
                }
            }
            
            Task { @MainActor in
                if UIApplication.shared.isIdleTimerDisabled && !context.isActivelyManagingAnyApp {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        if !CellularRefreshManager.shared.isShortcutTwoStageMode {
            do {
                try await ensureMinimuxerReady()
            } catch let opError as OperationError {
                group.error = opError
                for operation in operations {
                    let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
                    operation.logSummary(status: "FAILED", elapsed: elapsed, error: opError)
                }
                throw opError
            }
        }
        
        group.progress.totalUnitCount = Int64(operations.count * 100)
        group.progress.completedUnitCount = 1
        
        for operation in operations
        {
            let progress = Progress.discreteProgress(totalUnitCount: 100)
            self.progress.set(progress, for: operation)
            group.progress.addChild(progress, withPendingUnitCount: 100)
        }
        
        if !CellularRefreshManager.shared.isShortcutTwoStageMode {
            let unhandledOperations = operations.filter { operation in
                let isSideStore = (operation.app as? ALTApplication)?.isAltStoreApp == true ||
                                   operation.bundleIdentifier.isAltStoreAppID
                
                if isSideStore {
                    return handler.preflightChecksHandler.isResignActive == true
                }
                return true
            }
            
            do {
                let preflightContext = StandaloneOperationContext(steps: .preflightChecks, dbBackgroundContext: group.dbContext)
                let validateOp = try PreflightChecksOperation(
                    operations: unhandledOperations,
                    handler: handler.preflightChecksHandler,
                    context: preflightContext
                )
                try await validateOp.execute()
            } catch {
                group.error = error
                for operation in operations {
                    let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
                    operation.logSummary(status: "FAILED", elapsed: elapsed, error: error)
                }
                throw error
            }
        }
        
        let sortedOperations = operations.sorted { op1, op2 in
            let isOp1Self = (op1.app as? ALTApplication)?.isAltStoreApp == true || op1.bundleIdentifier.isAltStoreAppID || op1.bundleIdentifier == Bundle.main.bundleIdentifier
            let isOp2Self = (op2.app as? ALTApplication)?.isAltStoreApp == true || op2.bundleIdentifier.isAltStoreAppID || op2.bundleIdentifier == Bundle.main.bundleIdentifier
            if isOp1Self != isOp2Self {
                return !isOp1Self
            }
            return false
        }
        
        let operationsCount = sortedOperations.count
        let allAreRefresh = sortedOperations.allSatisfy {
            if case .refresh = $0 { return true }
            return false
        }
        
        let isCellularRefreshGroup = ((operationsCount >= 2 || CellularRefreshManager.shared.isShortcutTwoStageMode) && CellularRefreshManager.shared.isCellularMode && allAreRefresh)
        group.isCellularRefreshGroup = isCellularRefreshGroup
        debugLog("[PipelineRunner] Configured fast pipeline for \(operationsCount) operation(s): isCellularRefreshGroup = \(isCellularRefreshGroup)")

        for operation in sortedOperations {
            try await self.performOperation(for: operation, handler: handler, group: group, operationsCount: operationsCount)
        }

        if isCellularRefreshGroup && !group.sharedContext.pendingProfiles.isEmpty {
            let orderedBatches = sortedOperations.compactMap { group.sharedContext.pendingProfiles[$0.bundleIdentifier] }
            
            if CellularRefreshManager.shared.isShortcutTwoStageMode {
                debugLog("[PipelineRunner] Shortcut Stage 1: Staged \(orderedBatches.count) app(s) for Stage 2 injection.")
                CellularRefreshManager.shared.stagedBatches = orderedBatches
                for op in sortedOperations {
                    self.progress.progress(for: op)?.completedUnitCount = 100
                }
            } else {
                debugLog("[PipelineRunner] Starting batch profile injection for \(group.sharedContext.pendingProfiles.count) app(s)...")
                let injectContext = StandaloneOperationContext(steps: .injectBatchProfiles, dbBackgroundContext: group.dbContext)
                
                let injectOp = try InjectBatchProfilesOperation(
                    batches: orderedBatches,
                    context: injectContext,
                    onAppCompleted: { [weak self] bundleID in
                        if let op = sortedOperations.first(where: { $0.bundleIdentifier == bundleID }) {
                            self?.progress.progress(for: op)?.completedUnitCount = 100
                        }
                    }
                )
                try await injectOp.execute()
                
                await WidgetDataManager.publishCurrentInstalledApps(in: group.dbContext)
            }
        }

        await MainActor.run {
            group.completionHandler?(group.results)
        }
        
        return group
    }
    
    func performOperation(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup, operationsCount: Int = 1) async throws {
        debugLog("[AppManager] performOperation: Starting execution for app: \(operation.bundleIdentifier)")
        defer {
            Task { @MainActor in
                DatabaseManager.shared.viewContext.processPendingChanges()
            }
        }
        do {
            let result = try await self.performPipeline(for: operation, handler: handler, group: group, operationsCount: operationsCount)
            if operationsCount <= 1 || !group.isCellularRefreshGroup {
                progress.set(nil, for: operation)
                debugLog("[AppManager] performOperation: completed successfully. progress was reset for installedApp: \(result.bundleIdentifier)")
            }
            
            let bundleID = result.bundleIdentifier
            let dbContext = group.dbContext
            do {
                try await dbContext.perform {
                    let hasChanges = dbContext.hasChanges
                    if hasChanges {
                        try dbContext.save()
                    }
                    debugLog("[AppManager] performOperation: Context changes were saved for installedApp: \(bundleID)")
                }
            } catch {
                debugLog("[AppManager] perform(): Failed to save InstalledApp to database. \(error.localizedDescription)")
            }
            
            group.set(.success(result), forAppWithBundleIdentifier: bundleID)
            debugLog("[AppManager] performOperation: Execution SUCCESS for app: \(operation.bundleIdentifier)")
            
            let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
            operation.logSummary(status: "SUCCESS", elapsed: elapsed)
            
            if !group.isCellularRefreshGroup {
                debugLog("[AppManager] performOperation: Reloading widget timelines...")
                await WidgetDataManager.publishCurrentInstalledApps(in: dbContext)
                debugLog("[AppManager] performOperation: Reloading COMPLETE for widget timelines.")
            }
            
            if result.bundleIdentifier == StoreApp.altstoreAppID {
                let context = StandaloneOperationContext(steps: .scheduleExpirationWarningNotification, dbBackgroundContext: group.dbContext)
                let scheduleNotifOp = try ScheduleExpirationWarningNotificationOperation(
                    installedApp: result,
                    context: context
                )
                try await scheduleNotifOp.execute()
            }
            
            if !group.isCellularRefreshGroup {
                await CellularRefreshManager.shared.turnOnDataIfNeeded()
            }
        } catch {
            if !group.isCellularRefreshGroup {
                await CellularRefreshManager.shared.turnOnDataIfNeeded()
            }
            progress.set(nil, for: operation)
            
            let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
            let isCancelled = Task.isCancelled || error is CancellationError
            let status = isCancelled ? "CANCELLED" : "FAILED"
            if isCancelled {
                debugLog("[AppManager] performOperation: Execution CANCELLED for app: \(operation.bundleIdentifier)")
            } else {
                debugLog("[AppManager] performOperation: Execution FAILED for app: \(operation.bundleIdentifier) with error: \(error.localizedDescription)")
            }
            operation.logSummary(status: status, elapsed: elapsed, error: error)
            
            if isCancelled {
                group.set(.failure(OperationError.cancelled), forAppWithBundleIdentifier: operation.bundleIdentifier)
                return
            }
            
            let mappedError = logger.getMappedError(for: operation, error: error)
            
            logger.log(error, operation: operation.loggedErrorOperation, app: operation.app)
            
            group.set(.failure(mappedError), forAppWithBundleIdentifier: operation.bundleIdentifier)
        }
    }
    
    private func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup, operationsCount: Int = 1) async throws -> InstalledApp
    {
        let pipelineSteps = PipelineStepDefinition.steps(for: operation)
        let context = InstallAppOperationContext(
            pipelineSteps: pipelineSteps,
            bundleIdentifier: operation.bundleIdentifier,
            dbBackgroundContext: group.dbContext,
            sharedContext: group.sharedContext,
            handler: handler,
            additionalEntitlements: defaultEntitlements,
            activeSigningCertificate: CertificateManager.shared.activeCertificate?.certificate
        )
        context.isCellularRefreshGroup = group.isCellularRefreshGroup
        context.groupOperationsCount = operationsCount
        
        switch operation {
            case .install(_, let customID), .reinstall(_, let customID):
                context.customBundleIdentifier = customID
            case .update(_, let customID):
                context.customBundleIdentifier = customID
                context.isStoreUpdate = true
            case .resign(_, let mode):
                context.alternateIconMode = mode
            default:
                break
        }
        
        if let app = operation.app as? InstalledApp {
            context.installedApp = app
            context.appBundleFingerprint = app.appBundleFingerprint
            context.useMainProfile = app.useMainProfile
            context.customBundleIdentifier = app.customBundleIdentifier
            context.targetAppBundle = ALTApplication(fileURL: app.fileURL)
        }
        
        context.beginInstallationHandler = { (installedApp) in
            group.beginInstallationHandler?(installedApp)
        }
        
        var downloadingApp = operation.app
        if let installedApp = operation.app as? InstalledApp {
            if case .resign = operation { downloadingApp = installedApp }
            else if let storeApp = installedApp.storeApp, !FileManager.default.fileExists(atPath: installedApp.fileURL.path) {
                downloadingApp = storeApp
            }
        }
        
        let permissionReviewMode: PermissionReviewMode
        switch operation {
            case .install, .reinstall: permissionReviewMode = .all
            case .update: permissionReviewMode = .added
            default: permissionReviewMode = .none
        }
        
        let permissionsMode = UserDefaults.standard.permissionCheckingDisabled ? .none : permissionReviewMode
        let operationProgress = progress.progress(for: operation)
        return try await PipelineExecutor.shared.executePipeline(
            steps: pipelineSteps,
            context: context,
            operation: operation,
            group: group,
            downloadingApp: downloadingApp,
            permissionsMode: permissionsMode,
            operationProgress: operationProgress
        )
    }
}

extension RefreshGroup {
    var context: StandaloneOperationContext {
        let ctx = StandaloneOperationContext(steps: [], dbBackgroundContext: dbContext)
        ctx.error = self.error
        return ctx
    }
}
