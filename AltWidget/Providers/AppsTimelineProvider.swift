
//
//  AppsTimelineProvider.swift
//  AltWidgetExtension
//
//  Created by Riley Testut on 8/23/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import WidgetKit

struct AppsEntry<T>: TimelineEntry
{
    var date: Date
    var relevance: TimelineEntryRelevance?
    
    var apps: [AppSnapshot]
    var isPlaceholder: Bool = false
    
    var context: T?
}

class AppsTimelineProviderBase<T>
{
    typealias Entry = AppsEntry<T>
    
    func placeholder(in context: TimelineProviderContext) -> AppsEntry<T>
    {
        debugLog("[AppsTimelineProviderBase] placeholder requested (isPreview: \(context.isPreview))")
        return Entry(date: Date(), apps: [], isPlaceholder: true)
    }
    
    func snapshot(for appBundleIDs: [String], in context: T? = nil) async -> AppsEntry<T>
    {
        debugLog("[AppsTimelineProvider] Snapshot requested for bundleIDs: \(appBundleIDs)")
        do
        {
            try await self.prepare()
            
            var apps = try await self.fetchApps(withBundleIDs: appBundleIDs)
            
            apps = getUpdatedData(apps, context)
            
            verboseLog("[AppsTimelineProvider] Prepared snapshot entry with \(apps.count) app(s)")
            let entry = Entry(date: Date(), apps: apps, context: context)
            return entry
        }
        catch
        {
            debugLog("Failed to prepare widget snapshot: \(error)")
            
            let entry = Entry(date: Date(), apps: [], context: context)
            return entry
        }
    }
    
    func timeline(for appBundleIDs: [String], in context: T? = nil) async -> Timeline<AppsEntry<T>>
    {
        debugLog("[AppsTimelineProvider] Timeline requested for bundleIDs: \(appBundleIDs)")
        do
        {
            try await self.prepare()
            
            var apps = try await self.fetchApps(withBundleIDs: appBundleIDs)

            apps = getUpdatedData(apps, context)

            let entries = self.makeEntries(for: apps, in: context)
            verboseLog("[AppsTimelineProvider] Generated timeline with \(entries.count) entries")
            let timeline = Timeline(entries: entries, policy: .atEnd)
            return timeline
        }
        catch
        {
            debugLog("Failed to prepare widget timeline: \(error)")
            
            let entry = Entry(date: Date(), apps: [], context: context)
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            return timeline
        }
    }
    
    func getUpdatedData(_ apps: [AppSnapshot], _ context: T?) -> [AppSnapshot]{
        // override in subclasses as required
        return apps
    }
}

extension AppsTimelineProviderBase
{
    private func prepare() async throws
    {
        // No-op in push-pull architecture: widget snapshot JSON is read directly from App Group container.
    }
    
    private func fetchApps(withBundleIDs bundleIDs: [String]) async throws -> [AppSnapshot]
    {
        let snapshot = WidgetDataManager.shared.fetchSnapshot()
        let matchingItems = snapshot.allApps.filter { bundleIDs.contains($0.bundleIdentifier) }
        let apps = matchingItems.map { AppSnapshot(item: $0) }
        let sortedApps = apps.sorted { $0.name < $1.name }
        return sortedApps
    }
    
    func makeEntries(for snapshots: [AppSnapshot], in context: T? = nil) -> [AppsEntry<T>]
    {
        let sortedAppsByExpirationDate = snapshots.sorted { $0.expirationDate < $1.expirationDate }
        guard let firstExpiringApp = sortedAppsByExpirationDate.first, let lastExpiringApp = sortedAppsByExpirationDate.last else {
            return [Entry(date: Date(), apps: [], context: context)]
        }
        
        // Lấy thời gian thực tế hiện tại (thay vì 0h sáng như code cũ)
        let now = Date()
        
        // Nếu tất cả các app đều đã hết hạn
        if lastExpiringApp.expirationDate <= now {
            let entry = Entry(date: now, relevance: TimelineEntryRelevance(score: 1.0), apps: snapshots, context: context)
            return [entry]
        }
        
        var entries: [AppsEntry<T>] = []
        
        // Tạo lịch trình cập nhật mỗi 1 tiếng cho 24 giờ tiếp theo.
        // Sau 24 giờ, hệ thống sẽ tự động gọi lại hàm này để lấy 24 giờ mới (nhờ policy: .atEnd).
        let maxHours = 24
        
        for hourOffset in 0 ... maxHours {
            guard let entryDate = Calendar.current.date(byAdding: .hour, value: hourOffset, to: now) else { continue }
            
            // Tính điểm ưu tiên (Relevance score) để hiển thị trên Smart Stack của iOS
            let timeSinceRefresh = entryDate.timeIntervalSince(firstExpiringApp.refreshedDate)
            let totalTime = firstExpiringApp.expirationDate.timeIntervalSince(firstExpiringApp.refreshedDate)
            
            var score: Float = 0.0
            if totalTime > 0 {
                score = (entryDate <= firstExpiringApp.expirationDate) ? Float(timeSinceRefresh / totalTime) : 1.0
            } else {
                score = 1.0
            }
            
            if snapshots.allSatisfy({ $0.expirationDate > entryDate }) {
                score = 0.0
            }
            
            let entry = Entry(date: entryDate, relevance: TimelineEntryRelevance(score: score), apps: snapshots, context: context)
            entries.append(entry)
            
            // Dừng tạo thêm lịch nếu mốc thời gian này đã vượt qua hạn của tất cả các app
            if entryDate >= lastExpiringApp.expirationDate {
                break
            }
        }
        
        return entries
    }
    
    func fetchActiveAppBundleIDs() async -> [String]
    {
        let snapshot = WidgetDataManager.shared.fetchSnapshot()
        let bundleIDs = snapshot.activeApps.map { $0.bundleIdentifier }
        return bundleIDs.isEmpty ? [Bundle.Info.storeAppBundleIdentifier] : bundleIDs
    }
}

typealias Intent = ViewAppIntent

class AppsTimelineProvider: AppsTimelineProviderBase<Intent>, IntentTimelineProvider
{
    func getSnapshot(for intent: Intent, in context: Context, completion: @escaping (AppsEntry<Intent>) -> Void)
    {
        debugLog("[AppsTimelineProvider] Legacy getSnapshot for app: \(intent.app?.identifier ?? "default")")
        Task {
            let bundleID = await self.resolvedBundleID(for: intent)
            let snapshot = await self.snapshot(for: [bundleID], in: intent)
            completion(snapshot)
        }
    }
    
    func getTimeline(for intent: Intent, in context: Context, completion: @escaping (Timeline<AppsEntry<Intent>>) -> Void)
    {
        debugLog("[AppsTimelineProvider] Legacy getTimeline for app: \(intent.app?.identifier ?? "default")")
        Task {
            let bundleID = await self.resolvedBundleID(for: intent)
            let timeline = await self.timeline(for: [bundleID], in: intent)
            completion(timeline)
        }
    }
    
    private func resolvedBundleID(for intent: Intent) async -> String
    {
        if let id = intent.app?.identifier {
            return id
        }
        let activeIDs = await self.fetchActiveAppBundleIDs()
        let resolved = activeIDs.first ?? Bundle.Info.storeAppBundleIdentifier
        return resolved
    }
}

// Modern AppIntents-based provider for AppDetailWidget on iOS 17+.
// Replaces AppsTimelineProvider (IntentTimelineProvider) which uses the legacy
// SiriKit Intents framework that breaks containerBackground on iOS 17+.
@available(iOS 17.0, *)
class SelectAppTimelineProvider: AppsTimelineProviderBase<SelectAppIntent>, AppIntentTimelineProvider
{
    typealias Intent = SelectAppIntent

    func snapshot(for intent: SelectAppIntent, in context: Context) async -> AppsEntry<SelectAppIntent>
    {
        debugLog("[SelectAppTimelineProvider] AppIntent snapshot for app: \(intent.app?.id ?? "none") (isPreview: \(context.isPreview))")
        let bundleID = await resolvedBundleID(for: intent)
        return await self.snapshot(for: [bundleID], in: intent)
    }

    func timeline(for intent: SelectAppIntent, in context: Context) async -> Timeline<AppsEntry<SelectAppIntent>>
    {
        debugLog("[SelectAppTimelineProvider] AppIntent timeline for app: \(intent.app?.id ?? "none") (isPreview: \(context.isPreview))")
        let bundleID = await resolvedBundleID(for: intent)
        return await self.timeline(for: [bundleID], in: intent)
    }

    // If the user hasn't picked an app yet, fall back to the first active app
    // rather than a hardcoded bundle ID that may not exist in the database.
    private func resolvedBundleID(for intent: SelectAppIntent) async -> String
    {
        if let id = intent.app?.id {
            verboseLog("[SelectAppTimelineProvider] resolvedBundleID from intent: \(id)")
            return id
        }
        let activeIDs = await self.fetchActiveAppBundleIDs()
        let resolved = activeIDs.first ?? Bundle.Info.storeAppBundleIdentifier
        verboseLog("[SelectAppTimelineProvider] resolvedBundleID fallback: \(resolved)")
        return resolved
    }
}
