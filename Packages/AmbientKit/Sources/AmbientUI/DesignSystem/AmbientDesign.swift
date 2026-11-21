// AMBIENT DESIGN DIRECTION
//
// Material and shape: one piece of dense, warm smoked glass (Liquid Glass tinted graphite on macOS 26, a HUD blur
// on 14 and 15) with a lit rim, always dark so it reads as one crisp object on white pages and dark desktops alike;
// it is a capsule that grows into a rounded card and back, and nothing appears that the capsule did not grow into.
// Motion: critically damped, interruptible springs for every size change; the only bounce is the bar landing after
// a throw, because the hand gave it momentum; Reduce Motion swaps springs for short fades.
// Accent: a single ember orange that means "Ambient is paying attention" (the voice, the thinking ember, the
// pointer) or "the one primary action", never decoration.
// Type: SF Pro at small, confident sizes, tight tracking on titles, tabular figures for anything that counts.

import AppKit
import SwiftUI

public enum AmbientDesign {

    // MARK: Colour

    public enum Palette {
        /// The one accent. Means "Ambient is paying attention" or "this is the primary action".
        public static let ember = Color(red: 1.0, green: 0.584, blue: 0.290)
        /// The hot centre of the ember, for the core of indicators.
        public static let emberCore = Color(red: 1.0, green: 0.83, blue: 0.66)
        /// Ember dark enough to read as text on light surfaces (settings in light appearance).
        public static let emberDeep = Color(red: 0.80, green: 0.36, blue: 0.10)
        /// Text drawn on top of an ember fill.
        public static let emberInk = Color(red: 0.16, green: 0.07, blue: 0.01)
        /// Errors and failed tasks. Desaturated so it never competes with the ember.
        public static let alert = Color(red: 1.0, green: 0.48, blue: 0.46)
        public static let alertDeep = Color(red: 0.78, green: 0.20, blue: 0.20)

        // Text and fills on smoked glass. Always light-on-dark because the glass is always smoked.
        public static let onSmokePrimary = Color.white.opacity(0.95)
        public static let onSmokeSecondary = Color.white.opacity(0.64)
        public static let onSmokeTertiary = Color.white.opacity(0.42)
        public static let onSmokeHairline = Color.white.opacity(0.10)
        public static let onSmokeFill = Color.white.opacity(0.07)
        public static let onSmokeFillHover = Color.white.opacity(0.13)
        public static let onSmokeFillPressed = Color.white.opacity(0.18)
        /// The warm graphite that the glass is tinted toward.
        public static let smoke = Color(red: 0.055, green: 0.050, blue: 0.046)

        // Window surfaces (settings, onboarding). These follow the system appearance.
        public static let windowBackground = adaptive(light: NSColor(srgbRed: 0.965, green: 0.957, blue: 0.945, alpha: 1),
                                                      dark: NSColor(srgbRed: 0.078, green: 0.074, blue: 0.070, alpha: 1))
        public static let sidebarBackground = adaptive(light: NSColor(srgbRed: 0.925, green: 0.914, blue: 0.898, alpha: 1),
                                                       dark: NSColor(srgbRed: 0.105, green: 0.100, blue: 0.094, alpha: 1))
        public static let cardBackground = adaptive(light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                                    dark: NSColor(srgbRed: 0.133, green: 0.127, blue: 0.120, alpha: 1))
        public static let cardHairline = adaptive(light: NSColor(white: 0, alpha: 0.075),
                                                  dark: NSColor(white: 1, alpha: 0.075))
        public static let rowHover = adaptive(light: NSColor(white: 0, alpha: 0.035),
                                              dark: NSColor(white: 1, alpha: 0.045))
        public static let selectedRow = adaptive(light: NSColor(white: 0, alpha: 0.07),
                                                 dark: NSColor(white: 1, alpha: 0.085))
        public static let quietFill = adaptive(light: NSColor(white: 0, alpha: 0.05),
                                               dark: NSColor(white: 1, alpha: 0.07))
        public static let primaryText = adaptive(light: NSColor(white: 0.08, alpha: 1),
                                                 dark: NSColor(white: 0.96, alpha: 1))
        public static let secondaryText = adaptive(light: NSColor(white: 0.08, alpha: 0.60),
                                                   dark: NSColor(white: 0.96, alpha: 0.58))
        public static let tertiaryText = adaptive(light: NSColor(white: 0.08, alpha: 0.40),
                                                  dark: NSColor(white: 0.96, alpha: 0.38))
        /// The accent as text or an icon on a window surface: deeper in light appearance so it passes contrast.
        public static let accentText = adaptive(light: NSColor(srgbRed: 0.80, green: 0.36, blue: 0.10, alpha: 1),
                                                dark: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.36, alpha: 1))

        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }

    // MARK: Motion

    /// Every spring in Ambient. Response is in seconds; damping 1 means no overshoot.
    public enum Motion {
        /// The capsule growing into a card and back. Nearly critically damped: alive, never wobbly.
        public static func surfaceMorph(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.88)
        }
        /// Content of one state handing over to the next inside the capsule.
        public static func contentSwap(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 1.0)
        }
        /// Text streaming in and the card growing with it. Quick and without overshoot so lines never bounce.
        public static func streamingGrowth(reduceMotion: Bool) -> Animation {
            reduceMotion ? .linear(duration: 0.08) : .spring(response: 0.28, dampingFraction: 1.0)
        }
        /// The bar landing on an edge after being thrown. The only bounce in the product, because the person's
        /// hand gave it momentum.
        public static func dockLanding(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.76)
        }
        /// Hover fills and small affordances.
        public static let hoverFeedback = Animation.easeOut(duration: 0.12)
        /// Press feedback on anything clickable.
        public static let pressFeedback = Animation.easeOut(duration: 0.1)
    }

    // MARK: Geometry

    public enum Metrics {
        /// Gap between the bar and the edge of the usable screen area.
        public static let insetFromScreenEdge: CGFloat = 8
        /// The resting capsule: present, small, out of the way.
        public static let restingLength: CGFloat = 38
        public static let restingThickness: CGFloat = 8
        /// The resting capsule when background tasks are running and it carries their dots.
        public static let restingWithTasksThickness: CGFloat = 16
        /// Height of every single-line pill (hover, listening, thinking, working, typing).
        public static let pillThickness: CGFloat = 36
        public static let cardMaximumWidth: CGFloat = 384
        public static let cardMaximumTextHeight: CGFloat = 340
        public static let cardCornerRadius: CGFloat = 22
        public static let cardPadding: CGFloat = 16
        /// Radius of things nested inside a card: concentric with the card at its padding.
        public static let nestedCornerRadius: CGFloat = 10
    }

    // MARK: Type

    public enum Typeface {
        public static let pillLabel = Font.system(size: 12.5, weight: .medium)
        public static let replyBody = Font.system(size: 13.5, weight: .regular)
        public static let replyBodyLineSpacing: CGFloat = 3.5
        public static let rowTitle = Font.system(size: 13, weight: .medium)
        public static let rowDetail = Font.system(size: 12, weight: .regular)
        public static let caption = Font.system(size: 11, weight: .medium)
        public static let monospacedDetail = Font.system(size: 12, weight: .regular, design: .monospaced)
        public static let windowTitle = Font.system(size: 22, weight: .semibold)
        public static let windowTitleTracking: CGFloat = -0.45
        public static let sectionLabel = Font.system(size: 12, weight: .semibold)
        public static let body = Font.system(size: 13, weight: .regular)
    }
}
