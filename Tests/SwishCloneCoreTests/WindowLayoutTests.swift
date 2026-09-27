import CoreGraphics
import XCTest
@testable import SwishCloneCore

final class ScreenGeometryTests: XCTestCase {

    /// Écran principal 1440 × 900 : barre de menus de 25 pt en haut, Dock de
    /// 70 pt en bas. En AppKit (origine en bas), la zone utile commence à
    /// y = 70.
    private let primaryHeight: CGFloat = 900

    func testVisibleFrameOfThePrimaryScreen() {
        let cocoa = CGRect(x: 0, y: 70, width: 1440, height: 805)
        XCTAssertEqual(
            ScreenGeometry.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight),
            CGRect(x: 0, y: 25, width: 1440, height: 805)
        )
    }

    func testScreenAboveThePrimaryHasNegativeY() {
        let cocoa = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        XCTAssertEqual(
            ScreenGeometry.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        )
    }

    func testScreenToTheRightAlignedAtTheBottom() {
        let cocoa = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        XCTAssertEqual(
            ScreenGeometry.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
    }

    // MARK: - L'écran de la fenêtre

    private let screens = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    ]

    func testWindowBelongsToTheScreenHoldingItsCenter() {
        let window = CGRect(x: 1600, y: 100, width: 800, height: 600)
        XCTAssertEqual(ScreenGeometry.screenIndex(for: window, among: screens), 1)
    }

    func testStraddlingWindowGoesToTheScreenHoldingItsCenter() {
        let window = CGRect(x: 1000, y: 100, width: 600, height: 400) // centre en x = 1300
        XCTAssertEqual(ScreenGeometry.screenIndex(for: window, among: screens), 0)
    }

    func testCenterOffScreenFallsBackOnTheLargestOverlap() {
        // Centre sous le bas du premier écran, là où le second continue.
        let window = CGRect(x: 1300, y: 700, width: 400, height: 400) // centre (1500, 900)
        XCTAssertEqual(ScreenGeometry.screenIndex(for: window, among: screens), 1)
    }

    func testWindowEntirelyOffScreenHasNoScreen() {
        let window = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertNil(ScreenGeometry.screenIndex(for: window, among: screens))
    }
}

final class WindowLayoutTests: XCTestCase {

    /// La zone utile de l'écran principal ci-dessus, en coordonnées AX.
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 805)

    private func frame(_ action: GestureAction, in rect: CGRect? = nil) -> CGRect? {
        WindowLayout.frame(for: action, in: rect ?? visible)
    }

    func testHalves() {
        XCTAssertEqual(frame(.leftHalf), CGRect(x: 0, y: 25, width: 720, height: 805))
        XCTAssertEqual(frame(.rightHalf), CGRect(x: 720, y: 25, width: 720, height: 805))
        XCTAssertEqual(frame(.topHalf), CGRect(x: 0, y: 25, width: 1440, height: 402))
        XCTAssertEqual(frame(.bottomHalf), CGRect(x: 0, y: 427, width: 1440, height: 403))
    }

    func testHalvesSplitOnAWholePointAndTouchExactly() {
        // 805 pt de haut : pas de 402,5 que chaque app arrondirait à sa façon.
        let top = frame(.topHalf)!, bottom = frame(.bottomHalf)!
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(bottom.maxY, visible.maxY)
        let odd = CGRect(x: 0, y: 25, width: 1441, height: 805)
        let left = frame(.leftHalf, in: odd)!, right = frame(.rightHalf, in: odd)!
        XCTAssertEqual(left.width, 720)
        XCTAssertEqual(right, CGRect(x: 720, y: 25, width: 721, height: 805))
    }

    func testQuarters() {
        XCTAssertEqual(frame(.topLeftQuarter), CGRect(x: 0, y: 25, width: 720, height: 402))
        XCTAssertEqual(frame(.topRightQuarter), CGRect(x: 720, y: 25, width: 720, height: 402))
        XCTAssertEqual(frame(.bottomLeftQuarter), CGRect(x: 0, y: 427, width: 720, height: 403))
        XCTAssertEqual(frame(.bottomRightQuarter), CGRect(x: 720, y: 427, width: 720, height: 403))
    }

    func testMaximizeFillsTheUsableAreaNotTheWholeScreen() {
        XCTAssertEqual(frame(.maximize), visible)
    }

    func testCenterReducedIsSixtyPercentCentered() {
        XCTAssertEqual(frame(.centerReduced), CGRect(x: 288, y: 186, width: 864, height: 483))
    }

    func testNonGeometricActionsHaveNoFrame() {
        XCTAssertNil(frame(.minimize))
        XCTAssertNil(frame(.toggleFullScreen))
        XCTAssertNil(frame(.close))
    }

    func testSecondaryScreenAboveKeepsItsOrigin() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        XCTAssertEqual(frame(.leftHalf, in: above), CGRect(x: 0, y: -1080, width: 960, height: 1055))
        XCTAssertEqual(frame(.bottomRightQuarter, in: above), CGRect(x: 960, y: -553, width: 960, height: 528))
    }

    func testEveryFrameStaysInsideTheUsableArea() {
        let actions: [GestureAction] = [
            .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
            .maximize, .centerReduced,
        ]
        for action in actions {
            let result = frame(action)
            XCTAssertNotNil(result, "\(action)")
            XCTAssertTrue(visible.contains(result!), "\(action) déborde : \(result!)")
        }
    }
}

final class OverflowCorrectionTests: XCTestCase {

    /// Zone utile de l'écran principal : 1 440 × 805 à partir de y = 25
    /// (coordonnées AX, barre de menus au-dessus, Dock en dessous).
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 805)

    private func corrected(_ actual: CGRect, in rect: CGRect? = nil) -> CGRect? {
        WindowLayout.correctedFrame(for: actual, in: rect ?? visible)
    }

    // MARK: - Rien à corriger

    func testWindowThatFitsIsLeftAlone() {
        XCTAssertNil(corrected(CGRect(x: 720, y: 25, width: 720, height: 805)), "moitié droite exacte")
        XCTAssertNil(corrected(CGRect(x: 300, y: 200, width: 500, height: 400)), "fenêtre quelconque à l'intérieur")
    }

    func testRoundingIsNotAnOverflow() {
        // Quart bas-droite demandé à y = 427,5 × 402,5 ; l'app pose 428 × 403.
        XCTAssertNil(corrected(CGRect(x: 720, y: 428, width: 720, height: 403)))
    }

    // MARK: - Un côté

    func testRightOverflowIsAnchoredOnTheRightEdge() {
        // Moitié droite demandée (720 de large), l'app impose 900.
        XCTAssertEqual(
            corrected(CGRect(x: 720, y: 25, width: 900, height: 805)),
            CGRect(x: 540, y: 25, width: 900, height: 805)
        )
    }

    func testBottomOverflowIsAnchoredOnTheBottomEdge() {
        // Moitié basse demandée (402,5 de haut), l'app impose 500.
        XCTAssertEqual(
            corrected(CGRect(x: 0, y: 427.5, width: 1440, height: 500)),
            CGRect(x: 0, y: 330, width: 1440, height: 500)
        )
    }

    func testLeftAndTopOverflowAreAnchoredToo() {
        XCTAssertEqual(
            corrected(CGRect(x: -50, y: 10, width: 600, height: 400)),
            CGRect(x: 0, y: 25, width: 600, height: 400)
        )
    }

    // MARK: - Deux côtés

    func testQuarterOverflowingRightAndBottom() {
        XCTAssertEqual(
            corrected(CGRect(x: 720, y: 427.5, width: 900, height: 500)),
            CGRect(x: 540, y: 330, width: 900, height: 500)
        )
    }

    // MARK: - Plus grande que l'écran

    func testWiderThanTheScreenKeepsItsLeftEdgeVisible() {
        // Les feux tricolores sont à gauche : c'est ce bord-là qu'on garde.
        XCTAssertEqual(
            corrected(CGRect(x: 720, y: 25, width: 1600, height: 805)),
            CGRect(x: 0, y: 25, width: 1600, height: 805)
        )
        XCTAssertNil(corrected(CGRect(x: 0, y: 25, width: 1600, height: 805)), "déjà calée à gauche")
    }

    func testTallerThanTheScreenKeepsItsTitlebarVisible() {
        XCTAssertEqual(
            corrected(CGRect(x: 100, y: 300, width: 600, height: 900)),
            CGRect(x: 100, y: 25, width: 600, height: 900)
        )
    }

    // MARK: - Invariants

    func testSizeIsNeverChanged() {
        let frames = [
            CGRect(x: 720, y: 25, width: 900, height: 805),
            CGRect(x: 720, y: 427.5, width: 900, height: 500),
            CGRect(x: -50, y: 10, width: 600, height: 400),
            CGRect(x: 720, y: 25, width: 1600, height: 805),
        ]
        for frame in frames {
            XCTAssertEqual(corrected(frame)?.size, frame.size, "\(frame)")
        }
    }

    func testCorrectedFrameFitsWheneverItCan() {
        let frames = [
            CGRect(x: 720, y: 25, width: 900, height: 805),
            CGRect(x: 720, y: 427.5, width: 900, height: 500),
            CGRect(x: -50, y: 10, width: 600, height: 400),
            CGRect(x: 1300, y: 800, width: 400, height: 300),
        ]
        for frame in frames {
            let result = corrected(frame)!
            XCTAssertTrue(visible.contains(result), "\(frame) → \(result)")
            XCTAssertNil(corrected(result), "une seconde correction ne doit rien changer")
        }
    }

    func testSecondaryScreenAboveThePrimary() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        XCTAssertEqual(
            corrected(CGRect(x: 960, y: -1080, width: 1100, height: 1055), in: above),
            CGRect(x: 820, y: -1080, width: 1100, height: 1055)
        )
    }
}
