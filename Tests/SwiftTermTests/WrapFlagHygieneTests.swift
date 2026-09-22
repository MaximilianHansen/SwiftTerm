//
//  WrapFlagHygieneTests.swift
//
//  A row's `isWrapped` (soft-wrap continuation) flag must be cleared when the
//  application replaces that row with a hard line — otherwise a later reflow
//  re-joins unrelated rows. Mirrors xterm.js semantics:
//    - `InputHandler.eraseInLine`: `CSI 2 K` passes clearWrap=true, `CSI 0 K`
//      passes clearWrap = (x == 0).
//    - `InputHandler.lineFeed`: sets `isWrapped = false` on the row it moves into.
//
//  Symptom this guards (Ink-based TUIs such as Claude Code redraw every frame
//  with `ESC[2K ESC[1A …`): after any widen, a redrawn short row was glued to
//  the end of the row above it ("deeperresearch"), with the row above copied
//  at its full old width so the fragment landed at the far right.
//

import XCTest
@testable import SwiftTerm

final class WrapFlagHygieneTests: XCTestCase {
    final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func make(cols: Int, rows: Int) -> Terminal {
        Terminal(delegate: Delegate(), options: TerminalOptions(cols: cols, rows: rows, scrollback: 1000))
    }

    private func rowText(_ t: Terminal, _ i: Int) -> String {
        let line = t.buffer.lines[i]
        var s = ""
        for c in 0..<line.count {
            let cd = line[c]
            s.append(cd.code == 0 ? " " : t.getCharacter(for: cd))
        }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    func testEraseEntireLineClearsWrapFlag() {
        let t = make(cols: 20, rows: 6)
        t.feed(text: "hello\r\n" + String(repeating: "x", count: 25))
        XCTAssertTrue(t.buffer.lines[2].isWrapped)
        t.feed(text: "\u{1b}[G\u{1b}[2K")
        XCTAssertFalse(t.buffer.lines[2].isWrapped, "CSI 2K must clear isWrapped")
    }

    func testEraseToRightFromColumnZeroClearsWrapFlag() {
        let t = make(cols: 20, rows: 6)
        t.feed(text: "hello\r\n" + String(repeating: "x", count: 25))
        XCTAssertTrue(t.buffer.lines[2].isWrapped)
        t.feed(text: "\u{1b}[G\u{1b}[K")
        XCTAssertFalse(t.buffer.lines[2].isWrapped, "CSI 0K at column 0 must clear isWrapped")
    }

    func testEraseToRightMidRowKeepsWrapFlag() {
        let t = make(cols: 20, rows: 6)
        t.feed(text: "hello\r\n" + String(repeating: "x", count: 25))
        XCTAssertTrue(t.buffer.lines[2].isWrapped)
        t.feed(text: "\u{1b}[3;3H\u{1b}[K") // cursor at col 2 of the continuation row
        XCTAssertTrue(t.buffer.lines[2].isWrapped, "CSI 0K mid-row leaves the continuation intact")
    }

    func testLineFeedIntoExistingRowClearsWrapFlag() {
        let t = make(cols: 20, rows: 6)
        t.feed(text: "hello\r\n" + String(repeating: "x", count: 25))
        XCTAssertTrue(t.buffer.lines[2].isWrapped)
        t.feed(text: "\u{1b}[2;1Hshort\r\n")
        XCTAssertFalse(t.buffer.lines[2].isWrapped, "a hard LF into a row makes it a hard line")
    }

    func testAutowrapStillFlagsTheContinuationRow() {
        let t = make(cols: 20, rows: 6)
        t.feed(text: "hello\r\n" + String(repeating: "x", count: 25))
        XCTAssertFalse(t.buffer.lines[1].isWrapped)
        XCTAssertTrue(t.buffer.lines[2].isWrapped)
        XCTAssertEqual(rowText(t, 2), "xxxxx")
    }

    /// End to end: an Ink-shaped redraw at 40 cols followed by ONE widen keeps
    /// every hard-newlined row on its own line.
    func testWidenAfterInPlaceRedrawKeepsHardLinesIntact() {
        let t = make(cols: 40, rows: 8)
        t.feed(text: "/Users/raress/.claude/projects/-Users-raress-WORKBENCH/tool-results/hook.txt\r\n")
        t.feed(text: "frame A\r\nframe B\r\nframe C")
        t.feed(text: "\u{1b}[2K\u{1b}[1A\u{1b}[2K\u{1b}[1A\u{1b}[2K\u{1b}[1A\u{1b}[2K\u{1b}[G")
        let staticLines = [
            "  - Search history: Use the mem-search",
            "    skill for past decisions, and deeper",
            "    research",
            "  - Trust this index over re-reading",
        ]
        t.feed(text: staticLines.joined(separator: "\r\n") + "\r\n")
        t.feed(text: "frame A\r\nframe B\r\nframe C")
        t.resize(cols: 80, rows: 8)
        let rows = (0..<t.buffer.lines.count).map { rowText(t, $0) }
        for line in staticLines {
            XCTAssertTrue(rows.contains(line), "lost after widen: '\(line)' in \(rows)")
        }
        XCTAssertFalse(rows.contains { $0.contains("deeperresearch") }, "rows glued across a hard newline: \(rows)")
    }

    /// The legitimate case must keep working: a row that really auto-wrapped
    /// and was never replaced re-joins on widen.
    func testWidenStillRejoinsGenuineSoftWraps() {
        let t = make(cols: 20, rows: 6)
        t.feed(text: "hello\r\n" + String(repeating: "x", count: 25) + "\r\n")
        t.resize(cols: 40, rows: 6)
        XCTAssertEqual(rowText(t, 1), String(repeating: "x", count: 25))
        XCTAssertFalse(t.buffer.lines[2].isWrapped)
    }
}
