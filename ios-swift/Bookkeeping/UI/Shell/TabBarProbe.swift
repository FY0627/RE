import UIKit

/// 找到系统标签栏右侧那个独立圆形按钮（`Tab(role: .search)`）在窗口中的位置，
/// 好把上拉手势精确盖在它上面。系统没有公开这个位置，所以：
/// 1. 先按无障碍标签（标签的标题）找；
/// 2. 找不到时，在 `UITabBar` 范围内找右侧的正圆形视图。
/// 两种都找不到就返回 nil：界面退回系统按钮本身（轻点直接打开），功能不受影响。
@MainActor
enum TabBarProbe {
    static func addButtonFrame(title: String) -> CGRect? {
        guard let window = keyWindow else { return nil }
        let bounds = window.bounds

        func plausible(_ rect: CGRect) -> Bool {
            rect.width >= 36 && rect.width <= 96 && abs(rect.width - rect.height) <= 6
                && rect.midY > bounds.height * 0.75 && rect.midX > bounds.width * 0.6
        }

        var labelled: CGRect?
        var tabBar: CGRect?
        visit(window) { view in
            let rect = view.convert(view.bounds, to: window)
            if view is UITabBar, tabBar == nil { tabBar = rect }
            if view.accessibilityLabel == title, plausible(rect) {
                if labelled == nil || rect.width > labelled!.width { labelled = rect }
            }
        }
        if let labelled { return labelled }

        guard let bar = tabBar else { return nil }
        var best: CGRect?
        visit(window) { view in
            let rect = view.convert(view.bounds, to: window)
            guard plausible(rect), rect.midY >= bar.minY - 12, rect.midY <= bar.maxY + 12 else { return }
            if best == nil || rect.width > best!.width || (rect.width == best!.width && rect.midX > best!.midX) { best = rect }
        }
        return best
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func visit(_ view: UIView, _ body: (UIView) -> Void) {
        guard !view.isHidden, view.alpha > 0.01 else { return }
        body(view)
        for subview in view.subviews { visit(subview, body) }
    }

    /// 透明的标签图标：上拉层接管「+」的绘制时，系统按钮只保留玻璃底。
    static let blankIcon: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }
}
