import SwiftUI

/// 圆形加号的上拉手势（原型 `lib/widgets/gesture_add_button.dart` 的逐项移植）：
/// - 阈值：屏幕高度 × 15%；未达阈值松手 → 600ms 阻尼回弹；达到阈值松手 → 240ms 收回下方水滴后打开面板；
/// - 回弹公式：e^(-d·t)(cos ωt + d/ω sin ωt)，d 随拉动比例在 8.4→8.0 间插值，ω = 4π，负向位移软限制 4.5→6pt；
/// - 拖动中断（系统取消手势、App 进入后台）按未达阈值处理；收回/打开期间忽略新的拖动；
///   回弹过程中再次按下会从当前位置继续拉动。
/// - VoiceOver：直接激活即可打开；开启「减弱动态效果」时，轻点即可打开且不播放回弹/收回动画。
struct PullAddButton: View {
    enum Phase: Equatable {
        case idle
        case dragging
        case returning
        case retracting
        case opening
    }

    let screenHeight: CGFloat
    let label: String
    let sheetActive: Bool
    @Binding var isInteracting: Bool
    let onTrigger: () -> Void

    static let diameter: CGFloat = 52
    static let radius: CGFloat = 26

    @State private var phase: Phase = .idle
    @State private var headPull: CGFloat = 0
    @State private var basePull: CGFloat = 0
    @State private var dragStartY: CGFloat = 0
    @State private var startPull: CGFloat = 0
    @State private var releasePull: CGFloat = 0
    @State private var releaseFootRadius: CGFloat = 26
    @State private var isReady = false
    @State private var animationStart: Date = .distantPast
    @State private var runID = 0
    @State private var hapticToken = 0
    @State private var nudgeToken = 0
    @GestureState private var touching = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    private var threshold: CGFloat { max(1, screenHeight * 0.15) }
    private var blocked: Bool { phase == .retracting || phase == .opening }
    private var animating: Bool { phase == .returning || phase == .retracting }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { context in
            let pulls = currentPulls(at: context.date)
            droplet(head: pulls.head, base: pulls.base)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(dragGesture)
        .onTapGesture { handleTap() }
        .onChange(of: touching) { _, isTouching in
            // 系统取消手势时不会调用 onEnded：GestureState 复位即视为中断
            if !isTouching, phase == .dragging { returnHome() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active, phase == .dragging { returnHome() }
        }
        .onChange(of: sheetActive) { _, active in
            if !active, phase == .opening { reset() }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: hapticToken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("向上拉动约屏幕高度的百分之十五后松开；也可以直接激活")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { triggerDirectly() }
    }

    // MARK: 绘制

    private func droplet(head headPull: CGFloat, base basePull: CGFloat) -> some View {
        let palette = Theme(scheme: scheme)
        let lift = max(0, max(headPull, basePull))
        let overshoot = max(0, -min(headPull, basePull))
        let height = Self.diameter + lift + overshoot
        let head = CGPoint(x: Self.radius, y: lift - headPull + Self.radius)
        let base = CGPoint(x: Self.radius, y: lift - basePull + Self.radius)
        let stretch = min(1, max(0, (base.y - head.y) / threshold))
        let shape = DropletShape(head: head, base: base, threshold: threshold, fixedFootRadius: phase == .retracting ? releaseFootRadius : nil)
        let pulledTint = palette.isDark ? Color.white.opacity(0.19) : Color(hex: 0xC0BFC8, opacity: 0.15)
        let tintOpacity = easeOut(stretch)

        return ZStack(alignment: .topLeading) {
            Color.clear
            shape.fill(pulledTint.opacity(tintOpacity))
            if PerfFlags.shared.dropletHighlight {
                shape.stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(palette.isDark ? 0.45 : 0.68), location: 0),
                            .init(color: .white.opacity(palette.isDark ? 0.18 : 0.32), location: 0.55),
                            .init(color: .white.opacity(0), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0.5, y: max(0, (head.y - Self.radius) / height)),
                        endPoint: UnitPoint(x: 0.5, y: min(1, (head.y - Self.radius + Self.radius * 0.82) / height))
                    ),
                    lineWidth: 0.75
                )
            }
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(palette.ink)
                .position(head)
        }
        .frame(width: Self.diameter, height: height)
        .chromeBackground(shape)
        .opacity(phase == .opening ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: phase == .opening)
        .frame(width: Self.diameter, height: Self.diameter, alignment: .bottom)
        .offset(y: overshoot)
    }

    private func easeOut(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }

    /// 动画阶段的位置由开始时间直接算出，不依赖逐帧状态写入。
    private func currentPulls(at date: Date) -> (head: CGFloat, base: CGFloat) {
        switch phase {
        case .returning:
            let t: Double = min(1, max(0, date.timeIntervalSince(animationStart) / 0.6))
            let pull = Double(releasePull)
            let ratio: Double = min(1, max(0, pull / Double(threshold)))
            let damping: Double = 8.4 + (8.0 - 8.4) * ratio
            let frequency: Double = Double.pi * 4
            let oscillation: Double = cos(frequency * t) + damping / frequency * sin(frequency * t)
            let spring: Double = t >= 1 ? 0 : exp(-damping * t) * oscillation
            let displacement: Double = pull * spring
            let bounceLimit: Double = 4.5 + (6.0 - 4.5) * ratio
            let head: Double = displacement < 0 ? displacement / (1 + -displacement / bounceLimit) : displacement
            return (CGFloat(head), 0)
        case .retracting:
            let t: Double = min(1, max(0, date.timeIntervalSince(animationStart) / 0.24))
            let eased: Double = 1 - pow(1 - t, 3)
            return (releasePull, releasePull * CGFloat(eased))
        default:
            return (headPull, basePull)
        }
    }

    // MARK: 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if phase != .dragging { start(at: value.startLocation.y) }
                update(to: value.location.y)
            }
            .onEnded { _ in release() }
    }

    private func start(at y: CGFloat) {
        guard !blocked else { return }
        // 回弹中再次按下：从当前（正向）位置继续
        let current = currentPulls(at: Date()).head
        runID += 1
        dragStartY = y
        startPull = max(0, current)
        headPull = startPull
        basePull = 0
        isReady = startPull >= threshold
        phase = .dragging
        isInteracting = true
    }

    private func update(to y: CGFloat) {
        guard phase == .dragging else { return }
        let travel = max(0, startPull + dragStartY - y)
        headPull = min(travel, threshold)
        basePull = 0
        isReady = travel >= threshold
    }

    private func release() {
        guard phase == .dragging else { return }
        if isReady { retract() } else { returnHome() }
    }

    private func returnHome() {
        guard !blocked, phase != .idle else { return }
        releasePull = max(0, phase == .returning ? currentPulls(at: Date()).head : headPull)
        isReady = false
        basePull = 0
        if reduceMotion || releasePull < 0.5 {
            reset()
            return
        }
        animationStart = Date()
        phase = .returning
        runID += 1
        let run = runID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if run == runID, phase == .returning { reset() }
        }
    }

    private func retract() {
        guard !blocked else { return }
        releasePull = max(0, headPull)
        releaseFootRadius = DropletShape.footRadius(pull: releasePull, threshold: threshold)
        isInteracting = true
        hapticToken += 1
        isReady = true
        if reduceMotion || releasePull < 0.5 {
            headPull = releasePull
            basePull = releasePull
            open()
            return
        }
        animationStart = Date()
        phase = .retracting
        runID += 1
        let run = runID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            if run == runID, phase == .retracting { open() }
        }
    }

    private func open() {
        guard phase != .opening else { return }
        let signpost = AppServices.signposter.beginInterval("AddPanelOpen")
        headPull = releasePull
        basePull = releasePull
        phase = .opening
        runID += 1
        let run = runID
        onTrigger()
        AppServices.signposter.endInterval("AddPanelOpen", signpost)
        // 面板盖住按钮后再复位位置，避免看到按钮跳回
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            if run == runID, phase == .opening {
                headPull = 0
                basePull = 0
            }
            // 面板没有成功弹出（例如已有其他面板）时，不让按钮一直保持隐藏
            try? await Task.sleep(for: .milliseconds(600))
            if run == runID, phase == .opening, !sheetActive { reset() }
        }
    }

    private func reset() {
        runID += 1
        phase = .idle
        headPull = 0
        basePull = 0
        isReady = false
        isInteracting = false
    }

    private func handleTap() {
        guard !blocked else { return }
        if reduceMotion {
            triggerDirectly()
            return
        }
        // 普通轻点只给一个上提提示，保持「上拉才触发」的语义
        guard phase == .idle else { return }
        releasePull = min(14, threshold * 0.2)
        animationStart = Date()
        phase = .returning
        isInteracting = true
        runID += 1
        let run = runID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if run == runID, phase == .returning { reset() }
        }
    }

    /// 辅助功能与减弱动态效果的替代操作：直接打开面板。
    private func triggerDirectly() {
        guard !blocked else { return }
        releasePull = 0
        isInteracting = true
        hapticToken += 1
        open()
    }
}

/// 头部圆与下方水滴由切线相接的一整块形状（原型 `_liquidTether`）。
struct DropletShape: Shape {
    var head: CGPoint
    var base: CGPoint
    var threshold: CGFloat
    var fixedFootRadius: CGFloat?

    static let radius: CGFloat = 26

    static func footRadius(pull: CGFloat, threshold: CGFloat) -> CGFloat {
        let t = min(1, max(0, pull / max(1, threshold)))
        return 26 + (14 - 26) * t
    }

    func path(in rect: CGRect) -> Path {
        let radius = Self.radius
        let distance = max(0, base.y - head.y)
        let footRadius = fixedFootRadius ?? Self.footRadius(pull: distance, threshold: threshold)
        if distance <= 0.5 || (fixedFootRadius != nil && distance <= radius - footRadius) {
            return Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2))
        }
        let stretch = min(1, max(0, distance / max(1, threshold)))
        let headAngleLimit = CGFloat.pi * 35 / 180
        let footAngleLimit = CGFloat.pi * 25 / 180
        let merge = min(1, distance / (radius * sin(headAngleLimit) + footRadius * sin(footAngleLimit) + 18))
        var headAngle = headAngleLimit * merge
        var footAngle = footAngleLimit * merge
        var neckAmount: CGFloat = 1
        if fixedFootRadius != nil, distance < radius + footRadius {
            // 收回时下方水滴半径固定，逐渐并入头部
            neckAmount = (distance - (radius - footRadius)) / (2 * footRadius)
            let headIntersection = acos(min(1, max(-1, (radius * radius + distance * distance - footRadius * footRadius) / (2 * radius * distance))))
            let footIntersection = acos(min(1, max(-1, (footRadius * footRadius + distance * distance - radius * radius) / (2 * footRadius * distance))))
            headAngle = .pi / 2 - headIntersection - (.pi / 2 - headAngle) * neckAmount
            footAngle = .pi / 2 - footIntersection - (.pi / 2 - footAngle) * neckAmount
        }
        let hx = radius * cos(headAngle)
        let fx = footRadius * cos(footAngle)
        let hy = head.y + radius * sin(headAngle)
        let fy = base.y - footRadius * sin(footAngle)
        let attachmentWidth = min(hx, fx)
        let waist = attachmentWidth + (min(attachmentWidth, 7.5) - attachmentWidth) * stretch * stretch * neckAmount
        let midY = hy + (fy - hy) * 0.62
        let upperSpan = max(0, midY - hy)
        let lowerSpan = max(0, fy - midY)
        let headHandle = min(upperSpan * 0.65, (hx - waist) * 0.85 / max(0.001, sin(headAngle)))
        let footHandle = min(lowerSpan * 0.65, (fx - waist) * 0.85 / max(0.001, sin(footAngle)))
        let waistHandle = min(upperSpan, lowerSpan) * 0.5
        let cx = head.x

        var path = Path()
        path.move(to: CGPoint(x: cx - hx, y: hy))
        // 头部大圆弧：从左侧切点经顶部到右侧切点
        path.addArc(center: head, radius: radius, startAngle: .radians(.pi - headAngle), endAngle: .radians(headAngle), clockwise: false)
        path.addCurve(
            to: CGPoint(x: cx + waist, y: midY),
            control1: CGPoint(x: cx + hx - sin(headAngle) * headHandle, y: hy + cos(headAngle) * headHandle),
            control2: CGPoint(x: cx + waist, y: midY - waistHandle)
        )
        path.addCurve(
            to: CGPoint(x: cx + fx, y: fy),
            control1: CGPoint(x: cx + waist, y: midY + waistHandle),
            control2: CGPoint(x: cx + fx - sin(footAngle) * footHandle, y: fy - cos(footAngle) * footHandle)
        )
        // 下方水滴圆弧：从右侧切点经底部到左侧切点
        path.addArc(center: base, radius: footRadius, startAngle: .radians(-footAngle), endAngle: .radians(.pi + footAngle), clockwise: false)
        path.addCurve(
            to: CGPoint(x: cx - waist, y: midY),
            control1: CGPoint(x: cx - fx + sin(footAngle) * footHandle, y: fy - cos(footAngle) * footHandle),
            control2: CGPoint(x: cx - waist, y: midY + waistHandle)
        )
        path.addCurve(
            to: CGPoint(x: cx - hx, y: hy),
            control1: CGPoint(x: cx - waist, y: midY - waistHandle),
            control2: CGPoint(x: cx - hx + sin(headAngle) * headHandle, y: hy + cos(headAngle) * headHandle)
        )
        path.closeSubpath()
        return path
    }
}
