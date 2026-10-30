//
//  ImmersiveSpaceCoordinator.swift
//  UntoldSharePlay
//
//  The one place that opens and dismisses the immersive space. visionOS
//  allows a single immersive-space request at a time: a second open while one
//  is pending or presented fails. A space has several would-be openers (the
//  window button, a launch argument, the group-immersion signal, the join),
//  and an engine tears down asynchronously after the space closes, so the
//  requests go through this phase machine: at most one in flight, an open
//  during a close deferred until teardown completes, one retry after an
//  error, a space presented without a renderer recovered by a dismiss. A
//  space opened before the session joined stays private, so the join cycles
//  an open space. Lifted from CoolSaber's SaberArenaPresenter.
//

import Foundation
import Observation

@MainActor
@Observable
public final class ImmersiveSpaceCoordinator {
    public enum Phase: Sendable, Equatable {
        case closed
        case opening
        case open
        case closing
    }

    public enum OpenResult: Sendable, Equatable {
        case opened
        case userCancelled
        case error
    }

    public let id: String
    /// Whether the app reports `spaceDidTearDown()` after the space closes
    /// (an engine app: the render thread's exit). Until then a reopen waits.
    public let tracksTeardown: Bool
    /// A second join cycle within this many seconds is ignored.
    public var joinCycleGuard: TimeInterval = 3

    public private(set) var phase: Phase = .closed
    /// Presented but the renderer never attached: only a dismiss recovers.
    public private(set) var presentedEmpty = false
    /// A join cycle is under way: the open space is being dismissed to be
    /// reopened shared. The system reports the group's immersion as ended
    /// while that dismiss runs (a RealityView space, Oche 2026-10-29), and
    /// such a report must not cancel the reopen.
    public private(set) var isCycling = false
    public private(set) var lastOpenResult = "—"

    @ObservationIgnored private var openAction: (@MainActor () async -> OpenResult)?
    @ObservationIgnored private var dismissAction: (@MainActor () async -> Void)?
    @ObservationIgnored private var pendingOpen = false
    @ObservationIgnored private var pendingDismiss = false
    @ObservationIgnored private var tearingDown = false
    @ObservationIgnored private var lastJoinCycleUptime: TimeInterval = -1000

    public init(id: String, tracksTeardown: Bool = true) {
        self.id = id
        self.tracksTeardown = tracksTeardown
    }

    public var phaseLabel: String {
        switch phase {
        case .closed: tearingDown ? "closed (tearing down)" : "closed"
        case .opening: "opening…"
        case .open: presentedEmpty ? "OPEN (empty!)" : "OPEN"
        case .closing: "closing…"
        }
    }

    public var isTearingDown: Bool {
        tearingDown
    }

    /// The SwiftUI actions, as closures (`bind(open:dismiss:)` with the
    /// environment actions on visionOS).
    public func bind(open: @escaping @MainActor () async -> OpenResult, dismiss: @escaping @MainActor () async -> Void) {
        openAction = open
        dismissAction = dismiss
    }

    // MARK: Requests

    public func open(reason: String) {
        switch phase {
        case .open, .opening:
            log("open (\(reason)) ignored — already \(phase)")
        case .closing:
            log("open (\(reason)) deferred — closing")
            pendingOpen = true
        case .closed:
            guard !tearingDown else {
                log("open (\(reason)) deferred — teardown still running")
                pendingOpen = true
                return
            }
            guard let openAction else {
                log("open (\(reason)) dropped — not bound yet")
                return
            }
            phase = .opening
            pendingOpen = false
            log("opening (\(reason))")
            Task { @MainActor [weak self] in
                let result = await openAction()
                self?.openDidFinish(result)
            }
        }
    }

    public func dismiss(reason: String) {
        switch phase {
        case .closed:
            log("dismiss (\(reason)) ignored — already closed")
            pendingOpen = false
        case .closing:
            log("dismiss (\(reason)) ignored — already closing")
            pendingOpen = false
        case .opening:
            log("dismiss (\(reason)) deferred — opening")
            pendingDismiss = true
        case .open:
            guard let dismissAction else { return }
            phase = .closing
            pendingDismiss = false
            log("dismissing (\(reason))")
            Task { @MainActor [weak self] in
                await dismissAction()
                self?.dismissDidFinish()
            }
        }
    }

    /// The session wants the group immersive space. A closed space opens; an
    /// open one is cycled, because a space presented before the join stays
    /// private.
    public func joinGroup(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastJoinCycleUptime < joinCycleGuard {
            log("joinGroup (\(reason)) ignored — cycled \(String(format: "%.1f", now - lastJoinCycleUptime)) s ago")
            return
        }
        lastJoinCycleUptime = now
        switch phase {
        case .closed:
            open(reason: reason)
        case .opening:
            log("joinGroup (\(reason)) — open in flight, cycling once it is up")
            isCycling = true
            pendingDismiss = true
            pendingOpen = true
        case .open:
            log("joinGroup (\(reason)) — cycling the open space to make it shared")
            isCycling = true
            pendingOpen = true
            dismiss(reason: reason)
        case .closing:
            isCycling = true
            pendingOpen = true
        }
    }

    // MARK: Lifecycle reports

    /// From the space's content: it is presented. `rendering` false means the
    /// renderer could not attach (a teardown race): the space is cycled.
    public func spaceDidStart(rendering: Bool = true) {
        presentedEmpty = !rendering
        if phase != .open {
            log("space started (rendering: \(rendering)) while \(phase)")
            phase = .open
        }
        if pendingDismiss || !rendering {
            pendingDismiss = false
            if !rendering { pendingOpen = true }
            dismiss(reason: rendering ? "deferred dismiss" : "recover empty space")
        }
    }

    /// From the engine's shutdown completion (or `onDisappear` on a RealityView
    /// space without `tracksTeardown`): safe to open again.
    public func spaceDidTearDown() {
        log("space torn down (was \(phase), pending open: \(pendingOpen))")
        phase = .closed
        tearingDown = false
        presentedEmpty = false
        if pendingOpen {
            pendingOpen = false
            open(reason: "reopen after teardown")
        } else {
            isCycling = false
        }
    }

    private func openDidFinish(_ result: OpenResult) {
        lastOpenResult = String(describing: result)
        log("open → \(result)")
        switch result {
        case .opened:
            if phase == .opening { phase = .open }
            if pendingDismiss {
                pendingDismiss = false
                dismiss(reason: "deferred dismiss")
            } else {
                isCycling = false
            }
        case .userCancelled, .error:
            phase = .closed
            pendingDismiss = false
            if pendingOpen {
                // One retry: the failed request may have raced a closing space.
                pendingOpen = false
                log("retrying open after \(result)")
                open(reason: "retry")
            } else {
                isCycling = false
            }
        }
    }

    private func dismissDidFinish() {
        guard phase == .closing else { return }
        if tracksTeardown {
            tearingDown = true
            phase = .closed
            log("dismissed; waiting for teardown")
        } else {
            spaceDidTearDown()
        }
    }

    private func log(_ message: String) {
        SharePlayLog.info("space \(id): \(message)")
    }
}

#if os(visionOS)
    import SwiftUI

    public extension ImmersiveSpaceCoordinator {
        /// The environment's actions for the space with this coordinator's id.
        func bind(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) {
            let id = id
            bind(open: {
                switch await open(id: id) {
                case .opened: return .opened
                case .userCancelled: return .userCancelled
                case .error: return .error
                @unknown default: return .error
                }
            }, dismiss: {
                await dismiss()
            })
        }
    }
#endif
