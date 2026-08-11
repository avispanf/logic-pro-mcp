@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class NewTrackSheetState: @unchecked Sendable {
    private let lock = NSLock()
    private var sheetPresent = true
    private var calls = 0
    private let dismissAfterClick: Bool

    init(dismissAfterClick: Bool) {
        self.dismissAfterClick = dismissAfterClick
    }

    func executeClick() -> ChannelResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if dismissAfterClick {
            sheetPresent = false
        }
        return .success("clicked")
    }

    var isSheetPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sheetPresent
    }

    var clickCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct NewTrackCreateFixture {
    let runtime: AXLogicProElements.Runtime
    let state: NewTrackSheetState
}

/// The script seam deliberately returns success in both variants. Only the AX
/// sheet transition differs, so a regression to call-result-based reporting
/// makes the persistent-sheet test fail.
private func makeNewTrackCreateFixture(dismissAfterClick: Bool) -> NewTrackCreateFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(53_300)
    let window = builder.element(53_301)
    let sheet = builder.element(53_302)
    let create = builder.element(53_303)
    let cancel = builder.element(53_304)
    let state = NewTrackSheetState(dismissAfterClick: dismissAfterClick)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, "新規トラック")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "作成")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "キャンセル")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
    builder.setChildren(sheet, [create, cancel])

    let base = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: nil,
        executeAppleScript: { _ in state.executeClick() }
    )
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 },
        ax: AXHelpers.Runtime(
            axApp: base.ax.axApp,
            attributeValue: base.ax.attributeValue,
            setAttributeValue: base.ax.setAttributeValue,
            children: { element in
                if CFEqual(element, window) {
                    return state.isSheetPresent ? [sheet] : []
                }
                return base.ax.children(element)
            },
            performAction: base.ax.performAction,
            childCount: base.ax.childCount
        ),
        executeAppleScript: base.executeAppleScript
    )

    return NewTrackCreateFixture(runtime: runtime, state: state)
}

@Suite("Issue #533 Japanese New Track sheet")
struct Issue533JapaneseNewTrackSheetTests {
    private func sheetSignals(
        description: String,
        createTitle: String,
        cancelTitle: String,
        cancelEnabled: Bool
    ) -> ModalReconciliation.ModalSignals {
        ModalReconciliation.ModalSignals(
            sheetPresent: true,
            sheetDescription: description,
            createButtonPresent: AXLocalePolicy.createButton.matches(createTitle, mode: .exact),
            cancelButtonPresent: AXLocalePolicy.cancelButton.matches(cancelTitle, mode: .exact),
            cancelButtonEnabled: cancelEnabled,
            deleteConfirmButtonPresent: false,
            strayMenuOpen: false,
            topLevelAlertPresent: false,
            topLevelAlertButtonCount: 0,
            topLevelAlertPrimaryButton: "",
            createButtonTitle: createTitle,
            cancelButtonTitle: cancelTitle,
            deletePrimaryTitle: ""
        )
    }

    @Test("Issue533 classifies the measured Japanese sheet with an enabled Cancel")
    func measuredJapaneseSheetClassifiesViaDescription() {
        let signals = sheetSignals(
            description: "新規トラック",
            createTitle: "作成",
            cancelTitle: "キャンセル",
            cancelEnabled: true
        )

        #expect(signals.createButtonPresent)
        #expect(signals.cancelButtonPresent)
        #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
    }

    @Test("Issue533 retains English and Korean New Track classification")
    func existingLocalesStillClassifyViaDescription() {
        let english = sheetSignals(
            description: "New Track",
            createTitle: "Create",
            cancelTitle: "Cancel",
            cancelEnabled: true
        )
        let korean = sheetSignals(
            description: "새로운 트랙",
            createTitle: "생성",
            cancelTitle: "취소",
            cancelEnabled: true
        )

        #expect(ModalReconciliation.classify(english) == .mandatoryNewTrack)
        #expect(ModalReconciliation.classify(korean) == .mandatoryNewTrack)
    }

    @Test("Issue533 keeps an enabled-Cancel unrelated sheet fail-closed")
    func unrelatedEnabledCancelSheetIsUnknown() {
        let signals = sheetSignals(
            description: "Some Other Sheet",
            createTitle: "作成",
            cancelTitle: "キャンセル",
            cancelEnabled: true
        )

        #expect(ModalReconciliation.classify(signals) == .unknownSheet)
    }

    @Test("Issue533 stores exactly the measured Japanese New Track variants")
    func measuredJapaneseLabelsAreExact() {
        #expect(AXLocalePolicy.newTrackSheetDescription.variants == ["새로운 트랙", "新規トラック"])
        #expect(AXLocalePolicy.createButton.variants == ["생성", "作成"])
        #expect(AXLocalePolicy.cancelButton.variants == ["취소", "キャンセル"])
    }

    @Test("Issue533 reports Create performed after the sheet disappears")
    func createActuatorReportsObservedSheetDisappearance() async {
        let fixture = makeNewTrackCreateFixture(dismissAfterClick: true)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime
        )

        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.decision == .clickCreate)
        #expect(outcome.performed)
        #expect(fixture.state.clickCalls == 1)
    }

    @Test("Issue533 does not report Create performed while the sheet remains")
    func createActuatorDoesNotReportPerformedWithoutObservedSheetDisappearance() async {
        let fixture = makeNewTrackCreateFixture(dismissAfterClick: false)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime
        )

        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.decision == .clickCreate)
        #expect(!outcome.performed)
        #expect(fixture.state.isSheetPresent)
        #expect(fixture.state.clickCalls == 1)
    }
}
