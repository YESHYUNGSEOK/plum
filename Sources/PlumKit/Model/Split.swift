import CoreGraphics
import Foundation

/// Terminals shown together in one tab: side by side or one above the
/// other, split again as often as wanted. Each pane is an ordinary tab of
/// the workspace (its own shell, agent and state); the split only says how
/// they share the space.
public indirect enum SplitNode: Codable, Equatable, Sendable {
    public enum Axis: String, Codable, Sendable {
        /// Side by side, divided by an up-and-down line.
        case horizontal
        /// One above the other.
        case vertical
    }

    case pane(UUID)
    /// `ratio` is the first one's share of the space, 0…1.
    case split(Axis, ratio: Double, SplitNode, SplitNode)

    /// The panes, left to right and top to bottom.
    public var panes: [UUID] {
        switch self {
        case let .pane(id): [id]
        case let .split(_, _, first, second): first.panes + second.panes
        }
    }

    /// `node` where pane `id` was.
    func replacing(_ id: UUID, with node: SplitNode) -> SplitNode {
        switch self {
        case let .pane(pane): pane == id ? node : self
        case let .split(axis, ratio, first, second):
            .split(axis, ratio: ratio, first.replacing(id, with: node), second.replacing(id, with: node))
        }
    }

    /// Without pane `id`: its sibling takes its parent's place. Nil when
    /// nothing is left.
    func removing(_ id: UUID) -> SplitNode? {
        switch self {
        case let .pane(pane): return pane == id ? nil : self
        case let .split(axis, ratio, first, second):
            switch (first.removing(id), second.removing(id)) {
            case let (first?, second?): return .split(axis, ratio: ratio, first, second)
            case let (only?, nil), let (nil, only?): return only
            case (nil, nil): return nil
            }
        }
    }

    /// Keeps only the panes in `alive`.
    func keeping(_ alive: Set<UUID>) -> SplitNode? {
        panes.filter { !alive.contains($0) }.reduce(Optional(self)) { node, gone in node?.removing(gone) }
    }

    /// The split at `path` (false: first, true: second) gets a new ratio.
    func settingRatio(_ ratio: Double, at path: [Bool]) -> SplitNode {
        guard case let .split(axis, current, first, second) = self else { return self }
        guard let step = path.first else { return .split(axis, ratio: min(0.9, max(0.1, ratio)), first, second) }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis, ratio: current, first, second.settingRatio(ratio, at: rest))
            : .split(axis, ratio: current, first.settingRatio(ratio, at: rest), second)
    }

    /// Each pane's frame in a unit square (origin top left).
    public func frames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case let .pane(id): return [id: rect]
        case let .split(axis, ratio, first, second):
            let (a, b) = Self.divide(rect, axis, ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { one, _ in one }
        }
    }

    static func divide(_ rect: CGRect, _ axis: Axis, _ ratio: Double) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let width = rect.width * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        case .vertical:
            let height = rect.height * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                    CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
        }
    }

    /// The pane next to `id` in a direction, by where the panes lie.
    public func neighbor(of id: UUID, dx: Int, dy: Int) -> UUID? {
        let frames = frames()
        guard let from = frames[id] else { return nil }
        let center = CGPoint(x: from.midX, y: from.midY)
        return frames.filter { other, frame in
            guard other != id else { return false }
            if dx < 0 { return frame.maxX <= from.minX + 1e-6 && frame.minY < from.maxY && frame.maxY > from.minY }
            if dx > 0 { return frame.minX >= from.maxX - 1e-6 && frame.minY < from.maxY && frame.maxY > from.minY }
            if dy < 0 { return frame.maxY <= from.minY + 1e-6 && frame.minX < from.maxX && frame.maxX > from.minX }
            return frame.minY >= from.maxY - 1e-6 && frame.minX < from.maxX && frame.maxX > from.minX
        }
        .min { hypot($0.value.midX - center.x, $0.value.midY - center.y) < hypot($1.value.midX - center.x, $1.value.midY - center.y) }?
        .key
    }
}
