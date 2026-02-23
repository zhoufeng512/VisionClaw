import Foundation
import UIKit
import SwiftUI
import Combine

public enum ToolCallStatus {
    case idle
}
public enum OpenClawConnectionState {
    case notConfigured
}
public class OpenClawBridge {
    public var connectionState: OpenClawConnectionState = .notConfigured
    public var lastToolCallStatus: ToolCallStatus = .idle
    public func checkConnection() async {}
    public func resetSession() {}
}
public class ToolCallRouter {
    public init(bridge: OpenClawBridge) {}
    public func handleToolCall(_ call: Any, completion: @escaping ([String: Any]) -> Void) {}
    public func cancelToolCalls(ids: [String]) {}
    public func cancelAll() {}
}
public enum StreamingMode {
    case glasses, iPhone
}
