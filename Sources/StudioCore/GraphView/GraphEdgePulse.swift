import CoreGraphics
import Foundation
import SwiftUI

/// One travelling signal on a relation edge.
struct GraphEdgePulse: Sendable, Equatable {
    /// Bézier parameter of the signal head. `0` sits at the referencing table and `1`
    /// at the referenced table, so travel always follows the declared foreign key.
    let head: CGFloat
    /// Bézier parameter where the trailing wake begins. Never below `0`.
    let tail: CGFloat
    /// `0...1` envelope that fades the signal up as it leaves the source card and back
    /// down as it reaches the target.
    let intensity: Double
}

/// A relation edge prepared for pulse animation, in the screen space of the frame that
/// prepared it.
///
/// `seed` comes from the edge identity rather than from its position in any list, so a
/// relation keeps one firing rhythm across frames, pans and launches. An edge that
/// scrolls out of the visible set and back resumes where it would have been instead of
/// restarting, which is what keeps the graph from twitching while the reader moves.
struct GraphEdgePulseTrack: Sendable, Equatable {
    let edgeID: String
    /// Anchor on the referencing (foreign key) table.
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    /// Anchor on the referenced table.
    let end: CGPoint
    let isHighlighted: Bool
    let seed: UInt64

    init(
        edgeID: String,
        start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        end: CGPoint,
        isHighlighted: Bool
    ) {
        self.edgeID = edgeID
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
        self.isHighlighted = isHighlighted
        self.seed = GraphEdgePulseField.seed(forEdgeID: edgeID)
    }
}

/// Timing and selection for the signals that drift along schema relations.
///
/// Every value here is a pure function of a track's identity and the wall clock, so the
/// animation carries no per-frame state: the canvas asks what a track looks like at a
/// time and draws that. The same property makes the rhythm reproducible in tests.
enum GraphEdgePulseField {
    /// Animating every relation in a large catalog costs far more than the effect is
    /// worth. Sparse firing is also the visual intent — a graph where every edge glows
    /// at once reads as a busy background rather than as traffic between tables.
    static let trackLimit = 110

    /// Edges shorter than this on screen have no room for a head and a wake, so a pulse
    /// on them registers only as a flicker.
    static let minimumTrackLength: CGFloat = 34

    /// Seconds a signal takes to cross an edge, before per-edge jitter.
    static let baseTravel: Double = 2.4

    /// Average quiet gap between two firings on the same edge. Longer than the travel it
    /// follows, which holds roughly a third of the visible relations in motion at once —
    /// enough to read the direction of traffic, short of a graph that shimmers.
    static let baseRest: Double = 2.1

    /// Fraction of the edge spanned by the fading wake behind the head.
    static let tailSpan: CGFloat = 0.17

    /// Below this the signal is no longer distinguishable from the edge ink.
    static let visibilityFloor: Double = 0.02

    /// How long a track's rhythm runs before it repeats.
    struct Rhythm: Sendable, Equatable {
        /// Seconds the head takes to travel the full edge.
        let travel: Double
        /// Travel plus the quiet gap that follows it.
        let cycle: Double
        /// Where in the cycle this track sits at time zero.
        let offset: Double
    }

    /// Stable hash of an edge identity.
    ///
    /// `hashValue` is seeded per process, which would reshuffle every rhythm on relaunch
    /// and leave the timing untestable, so this is a plain FNV-1a over the identity.
    static func seed(forEdgeID id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Spreads a seed into an independent `0..<1` value per `salt`, so one edge can draw
    /// several uncorrelated traits from the same identity.
    static func unitValue(_ seed: UInt64, salt: UInt64) -> Double {
        var mixed = seed &+ salt
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        mixed ^= mixed >> 31
        return Double(mixed >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Travel speed and rest gap vary per edge so neighbouring relations never fire in
    /// lockstep; a synchronised graph reads as a progress indicator rather than as
    /// independent connections.
    static func rhythm(for seed: UInt64) -> Rhythm {
        let travel = baseTravel * (0.74 + 0.62 * unitValue(seed, salt: 0x9e37_79b9_7f4a_7c15))
        let rest = baseRest * (0.9 + 2.6 * unitValue(seed, salt: 0xc2b2_ae3d_27d4_eb4f))
        let cycle = travel + rest
        return Rhythm(
            travel: travel,
            cycle: cycle,
            offset: cycle * unitValue(seed, salt: 0x1656_67b1_9e37_79f9)
        )
    }

    /// The signal on `track` at `time` seconds, or `nil` while the track is resting.
    static func pulse(on track: GraphEdgePulseTrack, at time: Double) -> GraphEdgePulse? {
        guard time.isFinite else { return nil }
        let rhythm = rhythm(for: track.seed)
        let wrapped = (time + rhythm.offset).truncatingRemainder(dividingBy: rhythm.cycle)
        let elapsed = wrapped < 0 ? wrapped + rhythm.cycle : wrapped
        guard elapsed < rhythm.travel else { return nil }

        let head = CGFloat(elapsed / rhythm.travel)
        let intensity = envelope(at: head)
        guard intensity > visibilityFloor else { return nil }
        return GraphEdgePulse(head: head, tail: max(0, head - tailSpan), intensity: intensity)
    }

    /// Fades a signal in as it leaves the referencing table and out as it arrives, so
    /// nothing pops into existence against a card edge.
    static func envelope(at head: CGFloat) -> Double {
        guard head >= 0, head <= 1 else { return 0 }
        let rise = min(1, Double(head) / 0.18)
        let fall = min(1, Double(1 - head) / 0.24)
        return rise * fall
    }

    /// Straight-line span of a track, used to drop edges too short to animate.
    static func length(of track: GraphEdgePulseTrack) -> CGFloat {
        hypot(track.end.x - track.start.x, track.end.y - track.start.y)
    }

    /// Trims the prepared tracks to a bounded per-frame set.
    ///
    /// Highlighted relations are the ones the reader is pointing at and always survive.
    /// The remainder is sampled at an even stride so the surviving pulses stay spread
    /// across the whole graph instead of clumping into whichever edges happen to come
    /// first in graph order.
    /// Dropping the short tracks first is also what makes the effect survive zooming out:
    /// once a catalog is compressed to an overview, only the long-haul relations still
    /// have room to show a signal travelling, and those are the ones worth watching.
    static func select(
        from candidates: [GraphEdgePulseTrack],
        limit: Int = trackLimit
    ) -> [GraphEdgePulseTrack] {
        let usable = candidates.filter { length(of: $0) >= minimumTrackLength }
        return GraphEdgeSampling.evenSample(usable, limit: limit) { $0.isHighlighted }
    }
}

// MARK: - Drawing

/// Paints the travelling relation signals into a canvas.
///
/// Separate from the graph view so the effect can be rendered — and looked at — without
/// a live session, and so the drawing stays a pure function of tracks plus a timestamp.
enum GraphEdgePulseRenderer {
    /// Deliberately low contrast: the motion is ambient context for which way a relation
    /// runs, never a foreground element competing with the table cards.
    static func draw(in context: inout GraphicsContext, tracks: [GraphEdgePulseTrack], time: Double) {
        for track in tracks {
            guard let pulse = GraphEdgePulseField.pulse(on: track, at: time) else { continue }
            let tint = track.isHighlighted ? StudioPalette.edgePulseHighlight : StudioPalette.edgePulse
            // Relations the reader is not pointing at fade back further still.
            let intensity = pulse.intensity * (track.isHighlighted ? 1 : 0.72)

            // Two stacked strokes stand in for a gradient along the wake, which Canvas
            // cannot stroke directly: a wide faint pass, then a narrow brighter one over
            // the half nearest the head.
            context.stroke(
                segment(on: track, from: pulse.tail, to: pulse.head, samples: 7),
                with: .color(tint.opacity(0.16 * intensity)),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                segment(on: track, from: (pulse.tail + pulse.head) / 2, to: pulse.head, samples: 4),
                with: .color(tint.opacity(0.34 * intensity)),
                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            )

            let head = bezierPoint(
                start: track.start, control1: track.control1,
                control2: track.control2, end: track.end, t: pulse.head
            )
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - 3.4, y: head.y - 3.4, width: 6.8, height: 6.8)),
                with: .color(tint.opacity(0.1 * intensity))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - 1.6, y: head.y - 1.6, width: 3.2, height: 3.2)),
                with: .color(tint.opacity(0.52 * intensity))
            )
        }
    }

    /// Polyline approximation of the edge curve between two Bézier parameters.
    ///
    /// Sampling in Bézier space rather than trimming by arc length keeps the wake pinned
    /// to the same parameter the head uses, so the two never drift apart on a curve.
    static func segment(
        on track: GraphEdgePulseTrack,
        from start: CGFloat,
        to end: CGFloat,
        samples: Int
    ) -> Path {
        var path = Path()
        let steps = max(1, samples - 1)
        for index in 0...steps {
            let t = start + (end - start) * CGFloat(index) / CGFloat(steps)
            let point = bezierPoint(
                start: track.start, control1: track.control1,
                control2: track.control2, end: track.end, t: t
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
