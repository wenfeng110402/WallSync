//
//  ContentView.swift
//  WallSync
//
//  Created by 叶文峰 on 2026/7/25.
//

import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var modeManager: AppModeManager

    var body: some View {
        Group {
            switch modeManager.mode {
            case .controller:
                ControllerView()
            case .node:
                NodeView()
            }
        }
        .onChange(of: modeManager.mode) { _, newMode in
            print("[WallSync] 已切换至: \(newMode.rawValue)")
        }
    }
}
