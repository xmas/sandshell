import Foundation
import Testing
@testable import Sandshell

/// How the background-tasks list splits a session's tasks
/// (`BackgroundTaskList`, Sandshell/UI/BackgroundTasksView.swift).
struct BackgroundTaskListTests {
    private static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func task(_ id: String, startedAt start: TimeInterval, finishedAt end: TimeInterval? = nil,
                      state: BackgroundTask.State = .running, orphaned: Bool = false) -> BackgroundTask {
        var task = BackgroundTask(id: id, kind: .shell, title: id,
                                  startedAt: Self.origin.addingTimeInterval(start))
        task.finishedAt = end.map { Self.origin.addingTimeInterval($0) }
        task.state = state
        task.orphaned = orphaned
        return task
    }

    @Test func noTasksListsNothing() {
        let list = BackgroundTaskList([])
        #expect(list.running.isEmpty)
        #expect(list.finished.isEmpty)
    }

    @Test func runningTasksComeNewestStartedFirst() {
        let list = BackgroundTaskList([
            task("old", startedAt: 0),
            task("new", startedAt: 20),
            task("mid", startedAt: 10),
        ])
        #expect(list.running.map(\.id) == ["new", "mid", "old"])
        #expect(list.finished.isEmpty)
    }

    @Test func finishedTasksComeNewestFinishedFirst() {
        // Started order differs from finished order: the list follows the finish.
        let list = BackgroundTaskList([
            task("a", startedAt: 0, finishedAt: 50, state: .completed),
            task("b", startedAt: 10, finishedAt: 30, state: .failed),
            task("c", startedAt: 20, finishedAt: 40, state: .stopped),
        ])
        #expect(list.finished.map(\.id) == ["a", "c", "b"])
        #expect(list.running.isEmpty)
    }

    @Test func finishedTaskWithoutAFinishTimeSortsByItsStart() {
        let list = BackgroundTaskList([
            task("finished", startedAt: 0, finishedAt: 15, state: .completed),
            task("undated", startedAt: 20, state: .completed),
        ])
        #expect(list.finished.map(\.id) == ["undated", "finished"])
    }

    @Test func orphanedTasksAreLeftOutOfFinished() {
        let list = BackgroundTaskList([
            task("seen", startedAt: 0, finishedAt: 5, state: .completed),
            task("orphan", startedAt: 1, finishedAt: 6, state: .stopped, orphaned: true),
        ])
        #expect(list.finished.map(\.id) == ["seen"])
    }

    @Test func eachTaskLandsInOneHalf() {
        let list = BackgroundTaskList([
            task("running", startedAt: 0),
            task("done", startedAt: 1, finishedAt: 2, state: .completed),
        ])
        #expect(list.running.map(\.id) == ["running"])
        #expect(list.finished.map(\.id) == ["done"])
    }

    @Test(arguments: [0, 1, BackgroundTaskList.finishedLimit - 1, BackgroundTaskList.finishedLimit,
                      BackgroundTaskList.finishedLimit + 1, BackgroundTaskList.finishedLimit * 2])
    func finishedKeepsOnlyTheLatest(count: Int) {
        let tasks = (0..<count).map {
            task("t\($0)", startedAt: TimeInterval($0), finishedAt: TimeInterval($0) + 0.5, state: .completed)
        }
        let list = BackgroundTaskList(tasks)
        let kept = min(count, BackgroundTaskList.finishedLimit)
        #expect(list.finished.count == kept)
        #expect(list.finished.map(\.id) == tasks.reversed().prefix(kept).map(\.id))
    }

    @Test func runningTasksAreNeverCapped() {
        let count = BackgroundTaskList.finishedLimit + 5
        let list = BackgroundTaskList((0..<count).map { task("r\($0)", startedAt: TimeInterval($0)) })
        #expect(list.running.count == count)
    }
}
