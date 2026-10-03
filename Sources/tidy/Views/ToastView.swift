import SwiftUI

/// 底部 toast 浮层（详设 §2.6）
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
