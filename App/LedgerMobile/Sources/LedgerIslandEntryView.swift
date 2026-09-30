import SwiftUI

/// 纯正 Apple Wallet 风格的原生灵动岛入账核准胶囊视图
struct LedgerIslandPillView: View {
    let notice: LedgerIslandNotice
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var ringProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0
    @State private var iconScale: CGFloat = 0.2
    @State private var iconOffset: CGFloat = 0

    // 严密契合 Apple 原生灵动岛比例的微胶囊 (224 x 68)
    private let pillWidth: CGFloat = 224
    private let pillHeight: CGFloat = 68
    private let pillCornerRadius: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            // 1. 左侧：原生 SF Symbol 分类圆形徽标
            ZStack {
                Circle()
                    .fill(badgeColor.opacity(0.18))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .strokeBorder(badgeColor.opacity(0.35), lineWidth: 0.8)
                    )

                Image(systemName: notice.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(badgeColor)
            }
            .scaleEffect(isExpanded ? 1.0 : 0.2)
            .offset(x: iconOffset)
            .padding(.leading, 14)

            // 2. 中间：极简主视觉 (大金额 + 简洁次级商户/路径)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.amountText)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(notice.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .opacity(isExpanded ? 1 : 0)

            Spacer(minLength: 4)

            // 3. 右侧：Apple Pay 标志性动态合拢对勾环
            checkmarkRing
                .padding(.trailing, 14)
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(width: isExpanded ? pillWidth : 124, height: isExpanded ? pillHeight : 36)
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? pillCornerRadius : 18, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: isExpanded ? pillCornerRadius : 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(isExpanded ? 0.14 : 0.05), lineWidth: 0.6)
                )
        )
        // 极细腻的高级阴影，增加悬浮在屏幕上方的纵深

        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ledger-dynamic-island-notice")
        .accessibilityLabel("\(notice.title), \(notice.amountText)")
        .onAppear {
            playAnimationSequence()
        }
    }

    private var badgeColor: Color {
        Color(uiColor: UIColor(hex: notice.iconColorHex))
    }

    private var amountColor: Color {
        switch notice.type {
        case .income:
            return LedgerPalette.income
        case .transfer:
            return LedgerPalette.cobaltLight
        case .batchImport:
            return LedgerPalette.success
        case .expense:
            return .white
        }
    }

    private var ringColor: Color {
        switch notice.type {
        case .income:
            return LedgerPalette.income
        case .transfer:
            return LedgerPalette.cobalt
        case .batchImport:
            return LedgerPalette.success
        case .expense:
            return Color(red: 0.0, green: 0.48, blue: 1.0) // Apple Pay 经典蓝
        }
    }

    // MARK: - Checkmark Ring
    private var checkmarkRing: some View {
        ZStack {
            // 底环
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2.2)
                .frame(width: 22, height: 22)

            // 动态进度环
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(-90))

            // 精巧白色核准勾
            Path { path in
                path.move(to: CGPoint(x: 6.5, y: 11))
                path.addLine(to: CGPoint(x: 9.5, y: 14.5))
                path.addLine(to: CGPoint(x: 16, y: 7.5))
            }
            .trim(from: 0, to: checkProgress)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
            .frame(width: 22, height: 22)
        }
    }

    private func playAnimationSequence() {
        guard !reduceMotion else {
            isExpanded = true
            ringProgress = 1
            checkProgress = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                onDismiss()
            }
            return
        }

        // 触感反馈：触发录入成功
        LedgerFeedback.success()

        // 阶段 1: 物理 Spring 展开为 224x68 纵深胶囊
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            isExpanded = true
        }

        if case .transfer = notice.type {
            // 转账对冲微弹动效
            iconOffset = -5
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.05)) {
                iconOffset = 0
            }
        }

        // 阶段 2: 动态勾环合拢与画勾
        withAnimation(.easeOut(duration: 0.28).delay(0.08)) {
            ringProgress = 1.0
        }

        withAnimation(.easeOut(duration: 0.22).delay(0.24)) {
            checkProgress = 1.0
        }

        // 阶段 3: 停留 2.3 秒后 Spring 回缩收起并移除
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                isExpanded = false
                ringProgress = 0
                checkProgress = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                onDismiss()
            }
        }
    }
}

/// 顶部悬浮容器，用于挂载在全局 RootView 或当前 Window
struct LedgerIslandOverlayContainer: View {
    @Binding var currentNotice: LedgerIslandNotice?

    var body: some View {
        #if os(iOS)
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: currentNotice, initial: true) { _, newNotice in
                LedgerIslandWindowManager.shared.present(newNotice) {
                    currentNotice = nil
                }
            }
        #else
        VStack(spacing: 0) {
            if let notice = currentNotice {
                LedgerIslandPillView(notice: notice) {
                    currentNotice = nil
                }
                .id(notice.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.8)),
                    removal: .opacity.combined(with: .scale(scale: 0.6))
                ))
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all, edges: .top)
        .allowsHitTesting(currentNotice != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: currentNotice != nil)
        #endif
    }
}

#if os(iOS)
import UIKit

/// 穿透触控的 UIWindow，将灵动岛抬升至 statusBar / alert 层级之上，
/// 确保它绝不会被任何 modal sheet、formSheet 或 fullScreenCover 弹窗遮挡。
final class LedgerIslandPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else { return nil }
        // 只有当点击落在具体灵动岛药丸及其子控件内时才捕获，否则全部穿透透传给下层弹窗或主界面
        return (hitView === self || hitView === rootViewController?.view) ? nil : hitView
    }
}

@MainActor
final class LedgerIslandWindowManager {
    static let shared = LedgerIslandWindowManager()

    private var overlayWindow: LedgerIslandPassthroughWindow?
    private var dismissHandler: (() -> Void)?

    private init() {}

    func present(_ notice: LedgerIslandNotice?, onDismiss: @escaping () -> Void) {
        guard let notice else {
            destroyWindow()
            return
        }

        self.dismissHandler = onDismiss

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }

        if overlayWindow == nil || overlayWindow?.windowScene != scene {
            let window = LedgerIslandPassthroughWindow(windowScene: scene)
            // 将层级设置在 statusBar / alert 级别，保证压在所有 Modal Sheet 之上
            window.windowLevel = .statusBar + 100
            window.backgroundColor = .clear
            window.isOpaque = false
            window.clipsToBounds = false
            self.overlayWindow = window
        }

        let hosting = UIHostingController(rootView: windowContent(for: notice))
        hosting.view.backgroundColor = .clear
        hosting.view.isOpaque = false
        hosting.view.clipsToBounds = false

        overlayWindow?.rootViewController = hosting
        overlayWindow?.isHidden = false
    }

    private func windowContent(for notice: LedgerIslandNotice) -> some View {
        VStack(spacing: 0) {
            LedgerIslandPillView(notice: notice) { [weak self] in
                self?.dismissHandler?()
                self?.destroyWindow()
            }
            .id(notice.id)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                removal: .opacity.combined(with: .scale(scale: 0.6))
            ))

            Spacer()
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all, edges: .top)
    }

    private func destroyWindow() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }
}
#endif

