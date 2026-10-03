import Foundation
import XCTest

@testable import tidy

/// 跨并发域传递测试状态（单线程 runloop 驱动，实际无并发访问）
final class TestSyncBox: @unchecked Sendable {
    var done = false
    var thrown: Error?
}

/// 主线程 runloop 驱动 @MainActor 代码（本测试环境无完整 XCTest 异步基建，用 runloop 同步等待）
func runOnMain(_ body: @escaping @MainActor () throws -> Void) throws {
    let box = TestSyncBox()
    Task { @MainActor in
        do { try body() } catch { box.thrown = error }
        box.done = true
    }
    while !box.done {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if let thrown = box.thrown { throw thrown }
}

func runAsync(_ body: @escaping () async -> Void) {
    let box = TestSyncBox()
    Task {
        await body()
        box.done = true
    }
    while !box.done {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
