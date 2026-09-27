import CoreGraphics
import XCTest
@testable import SwishCloneCore

/// La garde qui empêche le test de cible d'interroger l'hôte lui-même (voir
/// `WindowStack`) : sur une fenêtre de l'hôte, jamais d'appel AX.
final class WindowStackTests: XCTestCase {

    private let own: Int32 = 100
    private let other: Int32 = 200

    private let dock: Int32 = 300

    private func window(_ pid: Int32, _ rect: CGRect, alpha: Double = 1, layer: Int = 0) -> WindowStack.Window {
        WindowStack.Window(pid: pid, bounds: rect, alpha: alpha, layer: layer)
    }

    /// Le cas réel du 27/09/2026 : la fenêtre plein écran du Dock (niveau 20)
    /// passe devant tout dans la pile, mais l'Accessibilité la traverse.
    private var dockOverlay: WindowStack.Window {
        window(dock, CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 20)
    }

    func testOwnWindowOnTopIsDetected() {
        let stack = [
            window(own, CGRect(x: 100, y: 100, width: 400, height: 300)),
            window(other, CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ]
        XCTAssertTrue(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 200, y: 200), in: stack, ownPID: own))
    }

    func testOtherWindowInFrontOfOursWins() {
        // Une fenêtre de l'hôte en arrière-plan, recouverte : le geste vise
        // celle de devant, qu'on peut interroger.
        let stack = [
            window(other, CGRect(x: 150, y: 150, width: 200, height: 200)),
            window(own, CGRect(x: 100, y: 100, width: 400, height: 300)),
        ]
        XCTAssertFalse(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 200, y: 200), in: stack, ownPID: own))
    }

    func testOwnWindowElsewhereDoesNotBlock() {
        let stack = [
            window(own, CGRect(x: 100, y: 100, width: 400, height: 300)),
            window(other, CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ]
        XCTAssertFalse(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 700, y: 600), in: stack, ownPID: own))
    }

    func testFullyTransparentWindowIsSeenThrough() {
        let stack = [
            window(own, CGRect(x: 0, y: 0, width: 1000, height: 800), alpha: 0),
            window(other, CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ]
        XCTAssertFalse(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 10, y: 10), in: stack, ownPID: own))
    }

    func testTheDockOverlayDoesNotHideOurWindow() {
        let stack = [
            dockOverlay,
            window(own, CGRect(x: 460, y: 135, width: 520, height: 696)),
            window(other, CGRect(x: 0, y: 30, width: 1440, height: 805)),
        ]
        XCTAssertTrue(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 720, y: 483), in: stack, ownPID: own))
    }

    func testTheDockOverlayDoesNotHideOtherWindowsEither() {
        let stack = [dockOverlay, window(other, CGRect(x: 0, y: 30, width: 1440, height: 805))]
        XCTAssertFalse(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 720, y: 483), in: stack, ownPID: own))
    }

    func testOurHighLevelPanelCounts() {
        // Un panneau de l'hôte au-dessus des fenêtres (bandeau, menu) :
        // l'interroger serait aussi le faire répondre sur le thread du tap.
        let stack = [
            window(own, CGRect(x: 0, y: 0, width: 685, height: 30), layer: 1000),
            window(other, CGRect(x: 0, y: 0, width: 1440, height: 900)),
        ]
        XCTAssertTrue(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 100, y: 10), in: stack, ownPID: own))
    }

    func testNothingUnderThePoint() {
        XCTAssertFalse(WindowStack.isOwnWindowOnTop(at: CGPoint(x: 10, y: 10), in: [], ownPID: own))
    }

    // MARK: - Portée du test AX quand une fenêtre de l'hôte est dessous

    func testHiddenOwnWindowIsStillUnderThePoint() {
        let stack = [
            window(other, CGRect(x: 0, y: 0, width: 1000, height: 800)),
            window(own, CGRect(x: 100, y: 100, width: 400, height: 300)),
        ]
        XCTAssertTrue(WindowStack.hasOwnWindow(at: CGPoint(x: 200, y: 200), in: stack, ownPID: own))
        XCTAssertFalse(WindowStack.hasOwnWindow(at: CGPoint(x: 700, y: 600), in: stack, ownPID: own))
    }

    func testTransparentOwnWindowDoesNotCount() {
        let stack = [window(own, CGRect(x: 0, y: 0, width: 1000, height: 800), alpha: 0)]
        XCTAssertFalse(WindowStack.hasOwnWindow(at: CGPoint(x: 10, y: 10), in: stack, ownPID: own))
    }

    func testFrontmostOtherOwnerSkipsTheDockOverlayAndOurs() {
        let stack = [
            dockOverlay,
            window(own, CGRect(x: 0, y: 0, width: 1440, height: 30), layer: 1000),
            window(other, CGRect(x: 0, y: 0, width: 1440, height: 805)),
            window(own, CGRect(x: 0, y: 0, width: 1440, height: 805)),
        ]
        XCTAssertEqual(WindowStack.frontmostOtherOwner(at: CGPoint(x: 720, y: 10), in: stack, ownPID: own), other)
    }

    func testFrontmostOtherOwnerIsNilWithoutAnOrdinaryWindow() {
        let stack = [dockOverlay, window(own, CGRect(x: 0, y: 0, width: 1440, height: 900))]
        XCTAssertNil(WindowStack.frontmostOtherOwner(at: CGPoint(x: 720, y: 483), in: stack, ownPID: own))
    }
}
