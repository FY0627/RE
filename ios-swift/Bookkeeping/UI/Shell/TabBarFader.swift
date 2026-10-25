import SwiftUI
import UIKit

/// 标签栏随卡片详情显隐，动画和详情页左上角返回按钮一样：淡入淡出并缩放。
///
/// SwiftUI 的 `toolbarVisibility` 只能让标签栏整条滑出屏幕，所以这里直接改系统 TabView 那条标签栏
/// （`UITabBarController.tabBar`）的透明度和缩放，标签栏本身仍是系统的液态玻璃标签栏。
/// 找不到系统标签栏时返回 false，调用方退回 `toolbarVisibility`。
@MainActor
enum TabBarFader {
    /// 和返回按钮的 `.scale(scale: 0.6)` 转场一致
    static let hiddenScale: CGFloat = 0.6
    private static var visible = true

    @discardableResult
    static func setVisible(_ show: Bool, animation: Animation) -> Bool {
        guard let bar = tabBar() else { return false }
        visible = show
        bar.isUserInteractionEnabled = show
        bar.accessibilityElementsHidden = !show
        let hidden = CGAffineTransform(scaleX: hiddenScale, y: hiddenScale)
        // 完全隐藏后缩放已复位，重新出现时从缩小的状态开始
        if show, bar.alpha < 0.01 { bar.transform = hidden }
        UIView.animate(animation) {
            bar.alpha = show ? 1 : 0
            bar.transform = show ? .identity : hidden
        } completion: {
            // 隐藏后复位缩放：标签栏控制器重新布局时按没有变换的尺寸计算位置
            if !visible { bar.transform = .identity }
        }
        return true
    }

    private static func tabBar() -> UITabBar? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let controller = tabBarController(in: window.rootViewController) { return controller.tabBar }
        }
        return nil
    }

    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }
}
