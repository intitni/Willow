import Foundation
import Testing
@testable import CoreToast

// These tests publish through the same process-wide notification channel.
@Suite(.serialized)
struct ToastLifecycleTests {
    @Test func toastAPICanBeCalledSynchronously() {
        let toastID = Toast.info("Saved", duration: 1)
        Toast.hide(toastID)
    }

    @Test @MainActor func sheetToastsDoNotAlsoAppearInUnderlyingOrOtherHosts() async throws {
        let sheetScope = UUID()
        let otherScope = UUID()
        let root = ToastCenter()
        let sheet = ToastCenter(scope: sheetScope)
        let otherSheet = ToastCenter(scope: otherScope)
        let centers = [root, sheet, otherSheet]
        for center in centers { center.startObserving() }
        defer { for center in centers { center.stopObserving() } }

        func waitForToasts(_ expected: [[Toast.ID]]) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while centers.map({ $0.viewModel.toasts.map(\.id) }) != expected, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(centers.map { $0.viewModel.toasts.map(\.id) } == expected)
        }

        // 同时挂载底层页面和两个 sheet，成功、失败提示都只能到达指定页面。
        let global = Toast.info("Global", duration: nil)
        let saved = Toast.info("Sticker added", duration: nil, scope: sheetScope)
        let failure = Toast.error("Save failed", duration: nil, scope: sheetScope)
        let other = Toast.warning("Other sheet", duration: nil, scope: otherScope)
        try await waitForToasts([[global], [saved, failure], [other]])

        Toast.hide(saved)
        Toast.hide(failure)
        try await waitForToasts([[global], [], [other]])

        // sheet 关闭期间的提示不能回退到全局显示，也不能在重新打开时重放。
        sheet.stopObserving()
        Toast.info("Closed sheet", duration: nil, scope: sheetScope)
        sheet.startObserving()
        let reopened = Toast.info("Reopened sheet", duration: nil, scope: sheetScope)
        try await waitForToasts([[global], [reopened], [other]])
    }

    @Test @MainActor func toastObservationFollowsHostLifecycle() async throws {
        let center = ToastCenter()
        defer { center.stopObserving() }

        func waitForToasts(_ ids: [Toast.ID]) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while center.viewModel.toasts.map(\.id) != ids, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(center.viewModel.toasts.map(\.id) == ids)
        }

        // Constructing the model must not subscribe.
        Toast.info("Before appearing", duration: nil)
        center.startObserving()
        center.startObserving()
        let first = Toast.info("Visible", duration: nil)
        try await waitForToasts([first])

        // This notification is queued on the main actor when the host disappears.
        Toast.info("Queued before disappearing", duration: nil)
        center.stopObserving()
        center.stopObserving()
        #expect(center.viewModel.toasts.isEmpty)
        Toast.info("While hidden", duration: nil)

        center.startObserving()
        let next = Toast.info("Visible again", duration: nil)
        try await waitForToasts([next])
        Toast.hide(next)
        try await waitForToasts([])
    }
}
