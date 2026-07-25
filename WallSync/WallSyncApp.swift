//
//  WallSyncApp.swift
//  WallSync
//
//  Created by 叶文峰 on 2026/7/25.
//

import SwiftUI

@main
struct WallSyncApp: App {
    @StateObject private var modeManager = AppModeManager()

    var body: some Scene {
        WindowGroup {
            ContentView(modeManager: modeManager)
                .frame(minWidth: 1_200, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()

                Picker("运行模式", selection: $modeManager.mode) {
                    ForEach(AppMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)

                if modeManager.isAutoMode {
                    Text("自动模式已启用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
