/// Runs `work` off the main actor. Unlike awaiting a bare `Task.detached`, cancelling the
/// caller cancels the work too, so superseded scans and searches stop early.
func runDetached<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: @escaping @Sendable () -> T
) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}
