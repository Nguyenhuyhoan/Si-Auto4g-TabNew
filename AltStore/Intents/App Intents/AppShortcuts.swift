//
//  AppShortcuts.swift
//  AltStore
//
//  Created by Riley Testut on 8/23/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

import AppIntents

@available(iOS 17, tvOS 17, *)
public struct ShortcutsProvider: AppShortcutsProvider
{
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshAllAppsIntent(presentsNotifications: false, mode: .wifi),
                    phrases: [
                        "Refresh All Wifi 4G with \(.applicationName)",
                        "Refresh \(.applicationName)",
                        "Refresh \(.applicationName) apps",
                        "Refresh my \(.applicationName) apps",
                        "Refresh apps with \(.applicationName)",
                    ],
                    shortTitle: "Refresh All Wifi 4G",
                    systemImageName: "wifi")

        AppShortcut(intent: RefreshAllAppsIntent(presentsNotifications: false, mode: .cellular4g),
                    phrases: [
                        "Refresh All wifi 4g with \(.applicationName)"
                    ],
                    shortTitle: "Refresh All wifi 4g",
                    systemImageName: "antenna.radiowaves.left.and.right")

        AppShortcut(intent: InstallIPAIntent(),
                    phrases: [
                        "Install IPA with \(.applicationName)",
                        "Install an IPA with \(.applicationName)",
                    ],
                    shortTitle: "Install IPA",
                    systemImageName: "square.and.arrow.down")
    }
    
    public static var shortcutTileColor: ShortcutTileColor {
        return .teal
    }
}
