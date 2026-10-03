import Foundation
import XCTest

@testable import tidy

/// 跨并发域传递测试状态（单线程 runloop 驱动，实际无并发访问）
final class TestSyncBox: @unchecked Sendable {
    var done = false
    var thrown: Error?
}

/// 跨并发域传递测试对象（同上：单线程 runloop 驱动，实际无并发访问）
final class TestBox<T>: @unchecked Sendable {
    var value: T?
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
        // 完成标志回主线程写：与下方主线程轮询同域，避开跨线程无同步读写
        await MainActor.run { box.done = true }
    }
    while !box.done {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

/// 轮询等待异步条件成立（配合 runAsync：主线程运行泵驱动 @MainActor 任务，body 侧用 Task.sleep 让出）
func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
