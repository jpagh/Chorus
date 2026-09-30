import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Window-drag plumbing and the reorder maths the rail depends on.
///
/// All of it moved here verbatim when `ServiceSidebarView` and `SpaceStripView`
/// were replaced by `UnifiedRailView` (build step 5 of concept C). It is the
/// part the UX audit rated severity 0 — tested, and working — so it was moved
/// rather than rewritten, and it lives in its own file so the next rail rebuild
/// cannot take it down with the view it happened to sit in.

enum ServiceReorderPlacement {
    case before
    case after
}

/// Sets whether the user can move the window by dragging its background.
///
/// With `.windowStyle(.hiddenTitleBar)` the top of the window stays a title-bar
/// drag band, 52 points tall since `TrafficLightsPositioner` grew it. In the bar layout the rail sits in that band, so a click-drag on a tab
/// was grabbed by the window move before SwiftUI's `.draggable` reorder could
/// start — the window slid instead of the tab reordering. A view nested in a
/// SwiftUI `ScrollView` can't opt out of that drag (the scroll view
/// short-circuits AppKit hit-testing, so a `mouseDownCanMoveWindow == false`
/// nested view is never consulted).
///
/// So we turn the OS window drag off for that layout and hand dragging to
/// explicit `WindowDragHandle`s instead (Chrome's model). The sidebar layout,
/// whose rail doesn't hold draggable tabs in the band, keeps the normal drag.
struct WindowMovableConfigurator: NSViewRepresentable {
    let isMovable: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        applyWhenAttached(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyWhenAttached(to: nsView)
    }

    private func applyWhenAttached(to view: NSView) {
        let isMovable = isMovable
        DispatchQueue.main.async {
            view.window?.isMovable = isMovable
        }
    }
}

/// A transparent strip that moves the window on click-drag, the way Chrome lets
/// you drag the empty part of its tab strip. Used to fill the reserved gap in
/// the top bar, where the OS window drag is off (see
/// `WindowMovableConfigurator`). A double-click zooms, matching a title bar.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

enum SpaceMove {
    /// The spaces a service can be moved into: every space except the ones it
    /// already belongs to. Moving into a space it's already in would just
    /// double-link it, and the current space is one of those memberships, so
    /// this naturally leaves it out too. Order follows `allSpaceIDs` (the
    /// sorted space list).
    static func eligibleSpaceIDs(allSpaceIDs: [UUID], memberSpaceIDs: Set<UUID>) -> [UUID] {
        allSpaceIDs.filter { !memberSpaceIDs.contains($0) }
    }
}

enum ServiceReorder {
    static func reorderedIDs(
        _ ids: [UUID],
        moving droppedID: UUID,
        relativeTo targetID: UUID,
        placement: ServiceReorderPlacement
    ) -> [UUID]? {
        guard droppedID != targetID,
              let fromIndex = ids.firstIndex(of: droppedID),
              let targetIndex = ids.firstIndex(of: targetID) else {
            return nil
        }

        var reordered = ids
        let moved = reordered.remove(at: fromIndex)

        var toIndex = targetIndex
        if placement == .after {
            toIndex += 1
        }
        if fromIndex < toIndex {
            toIndex -= 1
        }
        guard fromIndex != toIndex else {
            return nil
        }

        reordered.insert(moved, at: toIndex)
        return reordered
    }
}

/// Places a service membership in an ordered target group. Unlike
/// `ServiceReorder`, the moving id may come from another group and therefore
/// may not be present in `targetIDs` yet.
enum ServicePlacement {
    static func orderedIDs(
        _ targetIDs: [UUID],
        moving droppedID: UUID,
        relativeTo targetID: UUID?,
        placement: ServiceReorderPlacement
    ) -> [UUID]? {
        guard targetID != droppedID else { return nil }

        var reordered = targetIDs.filter { $0 != droppedID }
        let insertionIndex: Int
        if let targetID {
            guard let targetIndex = reordered.firstIndex(of: targetID) else { return nil }
            insertionIndex = placement == .after ? targetIndex + 1 : targetIndex
        } else {
            insertionIndex = 0
        }

        reordered.insert(droppedID, at: insertionIndex)
        return reordered == targetIDs ? nil : reordered
    }
}

/// Whether the rail draws service names, and where that answer is kept.
///
/// This is chrome visibility rather than user data, so it lives in defaults
/// instead of `AppPreferences`: a stored property there is a new schema version
/// and a migration (see CLAUDE.md), which a cosmetic toggle does not earn.
enum ServiceNameVisibility {
    static let defaultsKey = "showServiceNames"
}

/// The width of the space strip in the hybrid layout, and what that width
/// means.
///
/// The strip has two widths rather than a dragged range. A drag handle was
/// tried first and felt bad: the strip is 40-odd points of chrome, the useful
/// range is short, and the two widths that matter are the two ends of it.
/// A toggle says the same thing and lands on the right width every time.
enum SpaceStripMetrics {
    static let defaultsKey = "showSpaceNames"

    /// Wide enough to read a name beside the emoji.
    static let namedWidth: CGFloat = 180
    /// The emoji on their own.
    static let compactWidth: CGFloat = 52

    static func width(showingNames: Bool) -> CGFloat {
        showingNames ? namedWidth : compactWidth
    }

    /// How far the window's traffic lights reach in from the leading edge,
    /// with room after them. Centred in the 52 point band, they end at x 73.
    static let trafficLightsWidth: CGFloat = 82

    /// Leading inset the service bar needs so the window's traffic lights,
    /// which sit over the strip, do not land on the first tab. The lights are
    /// 82 points wide; the named strip swallows them whole and the bar starts
    /// flush, while the compact one leaves 30 points of them overhanging.
    static func barLeadingInset(stripWidth: CGFloat, lightsWidth: CGFloat) -> CGFloat {
        Swift.max(0, lightsWidth - stripWidth)
    }
}

/// Whether keyboard focus should be drawn, the way browsers answer
/// `:focus-visible`. A key press turns the marks on and a click turns them
/// off, so the ring that SwiftUI's first-responder pass put on the first rail
/// row at launch no longer shows until the keyboard is in use.
@MainActor
@Observable
final class FocusVisibility {
    static let shared = FocusVisibility()

    private(set) var isVisible = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            let visible = FocusVisibility.visibility(after: event.type)
            MainActor.assumeIsolated {
                if let visible, FocusVisibility.shared.isVisible != visible {
                    FocusVisibility.shared.isVisible = visible
                }
            }
            return event
        }
    }

    /// What an event means for the marks: on after a key, off after a click,
    /// and no change for anything else.
    nonisolated static func visibility(after type: NSEvent.EventType) -> Bool? {
        switch type {
        case .keyDown: return true
        case .leftMouseDown, .rightMouseDown: return false
        default: return nil
        }
    }
}

/// Spaces reorder live while you drag one: as the pointer enters another
/// space's slot, the dragged space moves into it, and the order is saved as
/// it goes. The old drop-to-place version decided before or after from where
/// the drop landed, and a drag downward never reached its drop handler.
///
/// The drag carries a type of Chorus's own, visible only inside the app, so a
/// service tab or a link dragged over the space list can never move a space.
enum LiveReorder {
    static let spaceType = UTType(exportedAs: "com.nicojan.chorus.space-id")

    /// The order after `dragged` takes the slot of `target`: it lands after
    /// the target when it came from above, and before it when it came from
    /// below. Nil when nothing would move.
    static func moving(_ dragged: UUID, over target: UUID, in ids: [UUID]) -> [UUID]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target)
        else { return nil }
        var moved = ids
        moved.remove(at: from)
        moved.insert(dragged, at: to)
        return moved
    }

    /// What a space drag carries: its id, under the Chorus-only type.
    static func itemProvider(forSpace id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: spaceType.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// The drop side of `LiveReorder`, put on each space's row. `onOtherDrop`
/// takes anything that is not a space, such as a service dropped on a
/// heading in the all-services rail; leave it nil where only spaces belong.
struct LiveSpaceDropDelegate: DropDelegate {
    let targetID: UUID
    /// The space being dragged, set by the row that started the drag.
    let draggingID: UUID?
    let move: (_ dragged: UUID, _ target: UUID) -> Void
    var onOtherDrop: ((DropInfo) -> Bool)? = nil

    private func carriesSpace(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [LiveReorder.spaceType])
    }

    func validateDrop(info: DropInfo) -> Bool {
        carriesSpace(info) || onOtherDrop != nil
    }

    func dropEntered(info: DropInfo) {
        guard carriesSpace(info), let draggingID, draggingID != targetID else { return }
        move(draggingID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // The order was saved as the drag went, so a space drop has nothing
        // left to do.
        if carriesSpace(info) { return true }
        return onOtherDrop?(info) ?? false
    }
}
