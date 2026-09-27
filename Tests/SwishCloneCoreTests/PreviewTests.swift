import CoreGraphics
import XCTest
@testable import SwishCloneCore

final class PreviewContentTests: XCTestCase {

    private func content(_ action: GestureAction) -> PreviewContent {
        PreviewContent(.action(action))
    }

    func testZonesAreTheRealLayoutOnAUnitScreen() {
        XCTAssertEqual(content(.leftHalf), .zone(CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(content(.bottomRightQuarter), .zone(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        XCTAssertEqual(content(.topHalf), .zone(CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        XCTAssertEqual(content(.maximize), .zone(CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testEveryZoneMatchesWindowLayout() {
        // L'aperçu ne doit jamais montrer autre chose que ce que fera le lever.
        // Même écran de référence que `PreviewContent`, ramené à l'unité.
        let reference = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let actions: [GestureAction] = [
            .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
            .maximize, .centerReduced,
        ]
        for action in actions {
            let frame = WindowLayout.frame(for: action, in: reference)!
            let unit = CGRect(x: frame.minX / 1000, y: frame.minY / 1000, width: frame.width / 1000, height: frame.height / 1000)
            XCTAssertEqual(content(action), .zone(unit), "\(action)")
        }
    }

    func testWindowButtonsAreTrafficLights() {
        XCTAssertEqual(content(.close), .light(.close), "fermer : feu rouge")
        XCTAssertEqual(content(.minimize), .light(.minimize), "réduire : feu jaune")
        XCTAssertEqual(content(.toggleFullScreen), .light(.fullScreen), "plein écran : feu vert")
    }

    func testQuittingIsNotDrawnLikeClosing() {
        // Même feu rouge, mais « quitter » porte l'icône de l'app : les deux
        // ne doivent jamais se confondre.
        XCTAssertNotEqual(content(.quitApp), content(.close))
    }

    func testQuitAndUnrecognized() {
        XCTAssertEqual(content(.quitApp), .quitApp)
        XCTAssertEqual(PreviewContent(.unrecognized), .unrecognized)
    }

    func testLabels() {
        XCTAssertEqual(GestureStateMachine.Preview.action(.bottomRightQuarter).label(), "Quart en bas à droite")
        XCTAssertEqual(GestureStateMachine.Preview.action(.close).label(), "Fermer la fenêtre")
        XCTAssertEqual(GestureStateMachine.Preview.action(.quitApp).label(appName: "TextEdit"), "Quitter TextEdit")
        XCTAssertEqual(GestureStateMachine.Preview.action(.quitApp).label(), "Quitter l'app")
        XCTAssertEqual(GestureStateMachine.Preview.unrecognized.label(), "Aucune action")
    }
}

final class PreviewPlacementTests: XCTestCase {

    /// Deux écrans en coordonnées AX : le principal (barre de menus 25 pt,
    /// Dock 74 pt) et un second à droite.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    ]
    private let size = CGSize(width: 160, height: 160)

    // MARK: - Centrage

    func testCenteredInTheUsableArea() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 801)
        let panel = PreviewPlacement.frame(size: size, centeredIn: visible)
        XCTAssertEqual(panel, CGRect(x: 640, y: 345.5, width: 160, height: 160))
        XCTAssertEqual(panel.midY, visible.midY, "centré entre la barre de menus et le Dock, pas sur l'écran entier")
    }

    func testCenteredOnASecondaryScreenAboveThePrimary() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let panel = PreviewPlacement.frame(size: size, centeredIn: above)
        XCTAssertEqual(panel.midX, 960)
        XCTAssertEqual(panel.midY, -540)
    }

    // MARK: - Quel écran

    func testWindowTargetUsesTheWindowsScreenNotTheCursors() {
        // Fenêtre surtout sur le second écran, geste commencé sur sa barre de
        // titre encore au-dessus du premier.
        let window = CGRect(x: 1200, y: 100, width: 1000, height: 600)
        let cursor = CGPoint(x: 1300, y: 110)
        XCTAssertEqual(PreviewPlacement.screenIndex(targetFrame: window, cursor: cursor, screens: screens), 1)
    }

    func testDockTargetUsesTheCursorsScreen() {
        XCTAssertEqual(PreviewPlacement.screenIndex(targetFrame: nil, cursor: CGPoint(x: 600, y: 880), screens: screens), 0)
        XCTAssertEqual(PreviewPlacement.screenIndex(targetFrame: nil, cursor: CGPoint(x: 2000, y: 1060), screens: screens), 1)
    }

    func testOffScreenWindowFallsBackOnTheCursorsScreen() {
        let lost = CGRect(x: 9000, y: 9000, width: 400, height: 300)
        XCTAssertEqual(PreviewPlacement.screenIndex(targetFrame: lost, cursor: CGPoint(x: 100, y: 10), screens: screens), 0)
    }

    func testNoScreenAtAll() {
        XCTAssertNil(PreviewPlacement.screenIndex(targetFrame: nil, cursor: CGPoint(x: 9000, y: 9000), screens: screens))
    }

    // MARK: - Conversion

    func testCocoaConversionIsTheInverseOfAX() {
        let ax = CGRect(x: 100, y: 60, width: 64, height: 48)
        let cocoa = ScreenGeometry.cocoaRect(fromAX: ax, primaryScreenHeight: 900)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 792, width: 64, height: 48))
        XCTAssertEqual(ScreenGeometry.axRect(fromCocoa: cocoa, primaryScreenHeight: 900), ax)
    }
}
