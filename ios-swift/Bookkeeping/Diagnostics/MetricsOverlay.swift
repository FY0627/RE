import SwiftUI
import QuartzCore
import Darwin

/// App 内调试指标：帧率、超过两个刷新周期的长帧次数、内存占用。
/// 用于没有 Instruments 的真机对照：打开后录屏，比较同一操作在不同开关下的读数。
/// 读数只是粗略参考，不等同于 Instruments 的帧耗时测量。
@MainActor
@Observable
final class FrameMonitor {
    private(set) var fps: Int = 0
    private(set) var longFrames: Int = 0
    private(set) var memoryMB: Int = 0
    private(set) var maxRefresh: Int = 0

    private var link: CADisplayLink?
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var proxy: Proxy?

    private final class Proxy: NSObject {
        weak var owner: FrameMonitor?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }
    }

    func start() {
        guard link == nil else { return }
        let proxy = Proxy()
        proxy.owner = self
        self.proxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(Proxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        windowStart = CACurrentMediaTime()
        lastTimestamp = 0
        frames = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
    }

    private func tick(_ link: CADisplayLink) {
        frames += 1
        let expected = link.targetTimestamp - link.timestamp
        if lastTimestamp > 0, expected > 0, link.timestamp - lastTimestamp > expected * 2.1 { longFrames += 1 }
        lastTimestamp = link.timestamp
        let elapsed = link.timestamp - windowStart
        if elapsed >= 1 {
            fps = Int((Double(frames) / elapsed).rounded())
            if expected > 0 { maxRefresh = Int((1 / expected).rounded()) }
            frames = 0
            windowStart = link.timestamp
            memoryMB = Self.footprintMB()
        }
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }
}

struct MetricsOverlay: View {
    @State private var monitor = FrameMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(monitor.fps) fps / \(monitor.maxRefresh) Hz")
            Text("长帧 \(monitor.longFrames) · 内存 \(monitor.memoryMB) MB")
            Text(PerfFlags.shared.summary)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
