import Foundation
import Combine
import SwiftUI

/// 应用运行模式
enum AppMode: String, CaseIterable, Identifiable {
    case controller = "主控模式 (Controller)"
    case node = "节点模式 (Node)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .controller:
            return "rectangle.3.group.fill"
        case .node:
            return "desktopcomputer"
        }
    }
}

/// 应用模式管理器
/// 管理当前实例是主控还是节点
@MainActor
final class AppModeManager: ObservableObject {
    @Published var mode: AppMode {
        didSet {
            UserDefaults.standard.set(mode == .controller, forKey: "WallSync.isController")
            onModeChange?(mode)
        }
    }

    @Published var isAutoMode: Bool {
        didSet {
            UserDefaults.standard.set(isAutoMode, forKey: "WallSync.autoMode")
        }
    }

    var onModeChange: ((AppMode) -> Void)?

    init() {
        let savedIsController = UserDefaults.standard.bool(forKey: "WallSync.isController")
        let savedAutoMode = UserDefaults.standard.object(forKey: "WallSync.autoMode") as? Bool ?? false

        self.isAutoMode = savedAutoMode
        self.mode = savedAutoMode ? .node : (savedIsController ? .controller : .controller)
    }

    /// 自动检测并设置模式
    /// 如果发现局域网已有主控，则设为节点；否则设为主控
    func autoDetectMode(hasControllerInNetwork: Bool) {
        guard isAutoMode else { return }
        mode = hasControllerInNetwork ? .node : .controller
    }

    /// 切换模式
    func switchMode() {
        mode = mode == .controller ? .node : .controller
    }

    /// 是否为控制器模式
    var isController: Bool {
        mode == .controller
    }
}
