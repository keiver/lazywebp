import Foundation

actor AsyncSemaphore {
    private let limit: Int
    private var count: Int = 0
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    func wait() async {
        if count < limit {
            count += 1
            return
        }
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume()
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            count -= 1
        }
    }
}
