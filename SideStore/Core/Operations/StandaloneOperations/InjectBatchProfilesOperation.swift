
//
//  InjectBatchProfilesOperation.swift
//  SideStore
//
//  Created by Magesh K on 14/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CoreData
import SideSign

final class InjectBatchProfilesOperation: BaseStandaloneOperation<StandaloneOperationContext, Void>, @unchecked Sendable {
    let batches: [PendingProfileBatch]
    var onAppCompleted: (@Sendable (String) -> Void)?

    init(
        batches: [PendingProfileBatch],
        context: StandaloneOperationContext,
        onAppCompleted: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.batches = batches
        self.onAppCompleted = onAppCompleted
        try super.init(context: context)
    }

    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[InjectBatchProfilesOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[InjectBatchProfilesOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)

        guard !self.batches.isEmpty else {
            debugLog("[InjectBatchProfilesOperation] No pending profiles collected across batch, skipping")
            return
        }

        // Sắp xếp để ứng dụng chính (lc+ss / SideStore) luôn được tiêm profile cuối cùng
        let sortedBatches = self.batches.sorted { b1, b2 in
            let isB1Self = (b1.bundleID == StoreApp.altstoreAppID) || b1.bundleID.isAltStoreAppID || (b1.bundleID == Bundle.main.bundleIdentifier)
            let isB2Self = (b2.bundleID == StoreApp.altstoreAppID) || b2.bundleID.isAltStoreAppID || (b2.bundleID == Bundle.main.bundleIdentifier)
            if isB1Self != isB2Self {
                return !isB1Self
            }
            return false
        }

        debugLog("[InjectBatchProfilesOperation] Running batch injection for \(sortedBatches.count) app(s)")

        // Tắt 4G đúng 1 lần duy nhất (nếu chạy trong app; nếu chạy qua Shortcut 2 giai đoạn thì tự bỏ qua)
        await CellularRefreshManager.shared.turnOffDataIfNeeded()
        
        // Khởi động EMProxy và Minimuxer giống hệt Wi-Fi Refresh (vì ở Bước 1 đã bỏ qua ensureMinimuxerReady)
        if UserDefaults.standard.enableEMPforWireguard {
            try? await startEMProxy()
        }
        _ = await CellularRefreshManager.shared.waitForMinimuxerReady(timeout: 5.0)
        try? await ensureMinimuxerReady()
        
        do {
            for batch in sortedBatches {
                debugLog("[InjectBatchProfilesOperation] Installing \(batch.profiles.count) profile(s) for \(batch.bundleID)...")
                for profileData in batch.profiles {
                    do {
                        try await installProvisioningProfiles(profileData)
                    } catch {
                        debugLog("[InjectBatchProfilesOperation] First attempt failed for \(batch.bundleID), retrying: \(error)")
                        _ = await CellularRefreshManager.shared.waitForMinimuxerReady(timeout: 3.0)
                        try await installProvisioningProfiles(profileData)
                    }
                }

                if let installedApp = batch.app, let dbContext = installedApp.managedObjectContext {
                    debugLog("[InjectBatchProfilesOperation] Updating database record for \(batch.bundleID)...")
                    try? await dbContext.perform {
                        if let certStatus = batch.certStatus {
                            installedApp.certificateStatus = certStatus
                        }
                        if dbContext.hasChanges {
                            try dbContext.save()
                        }
                    }
                }

                self.onAppCompleted?(batch.bundleID)
                debugLog("[InjectBatchProfilesOperation] Successfully processed \(batch.bundleID)")
            }
            
            // Bật lại 4G ngay sau khi tiêm xong tất cả
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
        } catch {
            // Đảm bảo luôn bật lại 4G nếu có lỗi bất ngờ
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
            throw error
        }

        debugLog("[InjectBatchProfilesOperation] Batch profile injection completed for all \(sortedBatches.count) app(s)")
        self.setProgress(100)
    }
}
