import Foundation
import BarFoldProtocol

/// Progress of one explicit menu bar move.
///
/// A move runs off the main thread because the drag takes about a second and a
/// cold accessibility scan takes longer; the job is the handle clients poll
/// instead of blocking on the drag. A multi-select move is a sequence of single
/// insertions planned up front, so progress and partial failure stay legible.
@MainActor
final class MenuBarMoveJob {
    enum State: String {
        case running
        case done
        case failed
    }

    let id: String
    let ids: [String]
    let group: MenuBarItemGroup
    let requestedIndex: Int
    let requestedBefore: String?
    let presetSteps: [MenuBarBatchStep]?
    let startedAt = Date()

    private(set) var state: State = .running
    private(set) var message = "准备菜单栏"
    private(set) var steps: [MenuBarBatchStep] = []
    private(set) var results: [MenuBarMoveResult] = []
    private(set) var errorCode = ""
    private(set) var errorMessage = ""
    private(set) var finishedAt: Date?

    init(
        id: String = UUID().uuidString,
        ids: [String],
        group: MenuBarItemGroup,
        index: Int,
        before: String?,
        steps: [MenuBarBatchStep]? = nil
    ) {
        self.id = id
        self.ids = ids
        self.group = group
        self.requestedIndex = index
        self.requestedBefore = before
        self.presetSteps = steps
        if let steps {
            self.steps = steps
            message = steps.isEmpty ? "已是最新布局" : "移动 \(steps.count) 个图标"
        }
    }

    func update(_ message: String) {
        guard state == .running else { return }
        self.message = message
    }

    func setSteps(_ steps: [MenuBarBatchStep]) {
        self.steps = steps
        message = steps.isEmpty ? "已是最新布局" : "移动 \(steps.count) 个图标"
    }

    func advance(_ result: MenuBarMoveResult) {
        results.append(result)
        message = "已移动 \(results.count)/\(max(steps.count, 1))"
    }

    func succeed() {
        state = .done
        message = "已完成"
        finishedAt = Date()
    }

    func fail(code: String, message: String) {
        errorCode = code
        errorMessage = message
        state = .failed
        self.message = message
        finishedAt = Date()
    }

    var isRunning: Bool { state == .running }

    func json() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "ids": .array(ids.map { .string($0) }),
            "group": .string(group.rawValue),
            "index": .number(Double(requestedIndex)),
            "before": requestedBefore.map { .string($0) } ?? .null,
            "state": .string(state.rawValue),
            "running": .bool(isRunning),
            "message": .string(message),
            "startedAt": .number(startedAt.timeIntervalSince1970),
            "durationMs": .number((((finishedAt ?? Date()).timeIntervalSince(startedAt)) * 1000 * 10).rounded() / 10),
            "planned": .number(Double(steps.count)),
            "completed": .number(Double(results.count)),
            "error": .null,
            "results": .array(results.map { result in
                .object([
                    "id": .string(result.id),
                    "group": .string(result.group.rawValue),
                    "index": .number(Double(result.index)),
                    "requestedIndex": .number(Double(result.requestedIndex)),
                    "attempts": .number(Double(result.attempts)),
                    "durationMs": .number((result.durationMs * 10).rounded() / 10),
                ])
            }),
        ]
        if !errorCode.isEmpty {
            object["error"] = .object([
                "code": .string(errorCode),
                "message": .string(errorMessage),
            ])
        }
        return .object(object)
    }
}
