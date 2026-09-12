//
//  ChatWindowFrameClampingTests.swift
//  osaurusTests
//
//  Pins `ChatWindowManager.constrainedFrame(_:to:)` — the clamp that keeps a
//  chat window's restored (autosaved) frame inside the current screen's
//  visible frame. Regression: a frame autosaved on a larger display (or at a
//  higher resolution) was restored verbatim by `setFrameUsingName`, so on a
//  smaller screen the window's bottom edge sat below the visible area where
//  it could not be dragged back on-screen ("bottom cut off" reports).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatWindowFrameClampingTests {

    // Scott's small-screen case: a 1024×666 display whose visible frame is
    // 1024×639 (menu bar at top, auto-hidden Dock), with a frame previously
    // saved on a larger display at the old 700pt chat height.
    private static let visible = NSRect(x: 0, y: 0, width: 1024, height: 639)
    private static let oldTallFrame = NSRect(x: 0, y: 0, width: 1024, height: 700)

    @Test("frame taller than the visible frame is shrunk and stays on-screen")
    func shrinksTooTallFrame_andKeepsBottomOnScreen() {
        let clamped = ChatWindowManager.constrainedFrame(Self.oldTallFrame, to: Self.visible)
        #expect(clamped.height <= Self.visible.height)
        #expect(clamped.minY >= Self.visible.minY)
        #expect(clamped.maxY <= Self.visible.maxY)
        #expect(clamped.width == Self.oldTallFrame.width)
    }

    @Test("frame wider than the visible frame is shrunk on the x axis")
    func shrinksTooWideFrame() {
        let wide = NSRect(x: 0, y: 0, width: 1200, height: 500)
        let clamped = ChatWindowManager.constrainedFrame(wide, to: Self.visible)
        #expect(clamped.width == Self.visible.width)
        #expect(clamped.minX >= Self.visible.minX)
        #expect(clamped.maxX <= Self.visible.maxX)
    }

    @Test("frame restored below the visible frame is pulled back up on-screen")
    func pullsFrameThatSatBelowVisibleFrameBackUp() {
        // Saved when the Dock was visible: the window's bottom edge sat below
        // the current visible frame's origin.
        let low = NSRect(x: 0, y: -120, width: 1024, height: 700)
        let clamped = ChatWindowManager.constrainedFrame(low, to: Self.visible)
        #expect(clamped.minY >= Self.visible.minY)
        #expect(clamped.maxY <= Self.visible.maxY)
        #expect(clamped.height <= Self.visible.height)
    }

    @Test("already-fitting frame is left untouched")
    func leavesFittingFrameUntouched() {
        let fitting = NSRect(x: 100, y: 40, width: 900, height: 560)
        let clamped = ChatWindowManager.constrainedFrame(fitting, to: Self.visible)
        #expect(clamped == fitting)
    }
}
