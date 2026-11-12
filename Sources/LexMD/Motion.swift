import AppKit
import SwiftUI

/// Animations that follow the system's Reduce Motion setting. Views read
/// `accessibilityReduceMotion` from the environment; model and AppKit code use these.
enum Motion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `animation`, or none when Reduce Motion is on, so the change happens in place.
    static func animation(_ animation: Animation, reduced: Bool = isReduced) -> Animation? {
        reduced ? nil : animation
    }
}

/// `withAnimation`, without the animation when Reduce Motion is on.
@MainActor
@discardableResult
func withMotion<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.animation(animation), body)
}

extension AnyTransition {
    /// `transition`, or a plain cross-fade when Reduce Motion is on.
    static func motion(_ transition: AnyTransition, reduced: Bool) -> AnyTransition {
        reduced ? .opacity : transition
    }
}
