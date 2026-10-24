import UIKit

/// 找到系统标签栏右侧那个独立圆形按钮（`Tab(role: .search)`）在窗口中的位置和大小，
/// 好把上拉手势精确盖在它上面。系统没有公开这个位置，所以按无障碍标签（标签的标题）去找，并且确认：
/// - 它确实被系统单独画成了圆形（正方形外框），而不是排在胶囊里的普通标签；
/// - 它和左边胶囊里的最后一个标签之间有空隙。
/// 任何一条不满足就返回 nil：不接管，界面保持系统按钮本身（轻点直接打开），功能不受影响。
@MainActor
enum TabBarProbe {
    /// - Parameters:
    ///   - title: 「+」标签的标题
    ///   - lastTabTitle: 胶囊里最后一个普通标签的标题（用来确认「+」和胶囊是分开的）
    static func addButtonFrame(title: String, lastTabTitle: String) -> CGRect? {
        guard let window = keyWindow else { return nil }
        let bounds = window.bounds
        let bottomBand = bounds.height * 0.75

        func isCircle(_ rect: CGRect) -> Bool {
            rect.width >= 40 && rect.width <= 100 && abs(rect.width - rect.height) <= 4
        }

        var buttons: [CGRect] = []
        var lastTab: CGRect?
        visit(window) { view in
            guard let label = view.accessibilityLabel, label == title || label == lastTabTitle else { return }
            let rect = view.convert(view.bounds, to: window)
            guard rect.midY > bottomBand else { return }
            if label == title {
                buttons.append(rect)
            } else if lastTab == nil || rect.width > lastTab!.width {
                lastTab = rect
            }
        }
        guard let button = buttons.filter(isCircle).max(by: { $0.width < $1.width }) else { return nil }
        // 排在胶囊里时和左边的标签紧挨着；单独的圆形按钮和胶囊之间有空隙
        if let lastTab, button.minX < lastTab.maxX + 2 { return nil }

        // 玻璃底可能比可点按的按钮本身大：取包含按钮中心的最大圆形视图，作为水滴的大小
        var circle = button
        let center = CGPoint(x: button.midX, y: button.midY)
        visit(window) { view in
            let rect = view.convert(view.bounds, to: window)
            if isCircle(rect), rect.contains(center), rect.width > circle.width, abs(rect.midX - button.midX) <= 2, abs(rect.midY - button.midY) <= 2 {
                circle = rect
            }
        }
        return circle
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
}
