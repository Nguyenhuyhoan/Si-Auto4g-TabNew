

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
        AppShortcut(intent: RefreshAllAppsIntent(presentsNotifications: false),
                    phrases: [
                        "Refresh All Apps (Wifi/4G) with \(.applicationName)",
                        "Refresh \(.applicationName)",
                        "Refresh \(.applicationName) apps",
                        "Refresh my \(.applicationName) apps",
                        "Refresh apps with \(.applicationName)",
                    ],
                    shortTitle: "Refresh All Apps (Wifi/4G)",
                    systemImageName: "wifi")

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

