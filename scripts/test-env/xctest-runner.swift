// 自制 xctest runner：为无 Xcode（仅 CLT）环境提供 `xctest` 工具的等价物。
// 用法对齐 Apple xctest：xctest [-XCTest <filter>] <bundle.xctest>
// 机制：加载测试 bundle，用 ObjC 运行时枚举 XCTestCase 子类中以 test 开头的方法
// （测试类须标注 @objcMembers），组装 XCTestCaseEntry 后交给 corelibs XCTest 的 XCTMain。
import Foundation
import ObjectiveC
import XCTest

let arguments = CommandLine.arguments
guard let bundlePath = arguments.last, bundlePath.hasSuffix(".xctest") else {
    FileHandle.standardError.write("usage: xctest [-XCTest filter] <bundle>.xctest\n".data(using: .utf8)!)
    exit(2)
}
guard let bundle = Bundle(path: bundlePath) else {
    FileHandle.standardError.write("error: cannot open bundle \(bundlePath)\n".data(using: .utf8)!)
    exit(2)
}
guard bundle.load() else {
    FileHandle.standardError.write("error: cannot load bundle \(bundlePath)\n".data(using: .utf8)!)
    exit(2)
}

// 注意：AnyClass 的 === 在 NSObject 派生类上可能走 NSForwarding（对 JSExport 等
// 系统协议类会卡死），必须全程用 ObjectIdentifier 做指针比较。
let testCaseClassID = ObjectIdentifier(XCTestCase.self)

var classCount = objc_getClassList(nil, 0)
let buffer = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(classCount))
defer { buffer.deallocate() }
classCount = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), classCount)

var entries: [XCTestCaseEntry] = []
for i in 0..<Int(classCount) {
    guard let cls = buffer[i] else { continue }
    var isTestCaseClass = false
    var current: AnyClass? = cls
    while let c = current {
        if ObjectIdentifier(c) == testCaseClassID { isTestCaseClass = true; break }
        current = class_getSuperclass(c)
    }
    guard isTestCaseClass, ObjectIdentifier(cls) != testCaseClassID else { continue }
    // 已验证继承链，直接位转换（避免 as? 对系统类触发 NSForwarding）
    let testClass = unsafeBitCast(cls, to: XCTestCase.Type.self)

    var methodCount: UInt32 = 0
    guard let methods = class_copyMethodList(cls, &methodCount) else { continue }
    var tests: [(String, XCTestCaseClosure)] = []
    for j in 0..<Int(methodCount) {
        let method = methods[j]
        let selector = method_getName(method)
        let name = NSStringFromSelector(selector)
        guard name.hasPrefix("test") else { continue }
        let implementation = method_getImplementation(method)
        if name.hasSuffix("AndReturnError:") {
            // throws 测试方法：ObjC 签名 (id, SEL, NSError **) -> BOOL
            typealias ThrowingFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
            let function = unsafeBitCast(implementation, to: ThrowingFn.self)
            let displayName = String(name.dropLast("AndReturnError:".count))
            tests.append((displayName, { instance in
                var error: NSError?
                if !function(instance, selector, &error) {
                    throw error ?? NSError(domain: "XCTestShim", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "unknown throwing test failure"])
                }
            }))
        } else {
            typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
            let function = unsafeBitCast(implementation, to: VoidFn.self)
            tests.append((name, { instance in function(instance, selector) }))
        }
    }
    if !tests.isEmpty {
        entries.append((testCaseClass: testClass, allTests: tests))
    }
}

guard !entries.isEmpty else {
    FileHandle.standardError.write("error: no tests found in \(bundlePath)\n".data(using: .utf8)!)
    exit(1)
}

// 不传 bundle 路径给 ArgumentParser，避免被当作测试过滤器
XCTMain(entries, arguments: [arguments[0]])
