import CoreGraphics
import XCTest
@testable import SwishCloneCore

final class LinkedPairTests: XCTestCase {

    // Zone utile de l'écran principal : 1 440 × 805 à partir de y = 25.
    private let left = CGRect(x: 0, y: 25, width: 720, height: 805)
    private let right = CGRect(x: 720, y: 25, width: 720, height: 805)
    private let top = CGRect(x: 0, y: 25, width: 1440, height: 400)
    private let bottom = CGRect(x: 0, y: 425, width: 1440, height: 405)

    func testSideBySideHalvesShareAVerticalBorder() {
        let border = LinkedPair.border(between: left, and: right, axis: .vertical)
        XCTAssertEqual(border, LinkedBorder(axis: .vertical, position: 720, spanStart: 25, spanEnd: 830))
    }

    func testTheHandleIsEightPointsCenteredOnTheBorder() {
        let border = LinkedPair.border(between: left, and: right, axis: .vertical)!
        XCTAssertEqual(border.handleRect, CGRect(x: 716, y: 25, width: 8, height: 805))
    }

    func testTopAndBottomShareAHorizontalBorder() {
        let border = LinkedPair.border(between: top, and: bottom, axis: .horizontal)!
        XCTAssertEqual(border.position, 425)
        XCTAssertEqual(border.handleRect, CGRect(x: 0, y: 421, width: 1440, height: 8))
    }

    func testTwoPointsOfGapOrOverlapStillTouch() {
        let gap = right.offsetBy(dx: 2, dy: 0)
        XCTAssertEqual(LinkedPair.border(between: left, and: gap, axis: .vertical)?.position, 721, "au milieu du vide")
        let overlap = right.offsetBy(dx: -2, dy: 0)
        XCTAssertEqual(LinkedPair.border(between: left, and: overlap, axis: .vertical)?.position, 719)
    }

    func testThreePointsApartIsNoLongerLinked() {
        XCTAssertNil(LinkedPair.border(between: left, and: right.offsetBy(dx: 3, dy: 0), axis: .vertical))
        XCTAssertNil(LinkedPair.border(between: left, and: right.offsetBy(dx: -3, dy: 0), axis: .vertical))
    }

    func testTheHandleOnlyCoversTheSharedPartOfTheBorder() {
        let shorter = CGRect(x: 720, y: 200, width: 720, height: 300)
        let border = LinkedPair.border(between: left, and: shorter, axis: .vertical)!
        XCTAssertEqual(border.spanStart, 200)
        XCTAssertEqual(border.spanEnd, 500)
    }

    func testWindowsThatBarelyFaceEachOtherAreNotLinked() {
        let offset = CGRect(x: 720, y: 830 - 39, width: 720, height: 400)
        XCTAssertNil(LinkedPair.border(between: left, and: offset, axis: .vertical), "39 pt face à face")
        let enough = CGRect(x: 720, y: 830 - 40, width: 720, height: 400)
        XCTAssertNotNil(LinkedPair.border(between: left, and: enough, axis: .vertical), "40 pt")
    }

    func testTheAxisMatters() {
        XCTAssertNil(LinkedPair.border(between: left, and: right, axis: .horizontal))
        XCTAssertNil(LinkedPair.border(between: top, and: bottom, axis: .vertical))
    }

    func testAWindowStillHoldsItsHalfNearItsOuterEdge() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 805)
        XCTAssertTrue(LinkedPair.isAnchored(left, in: .left, of: visible))
        XCTAssertTrue(LinkedPair.isAnchored(right, in: .right, of: visible))
        // Terminal en moitié basse : 12 pt de vide au-dessus du Dock.
        let terminal = CGRect(x: 0, y: 427, width: 1440, height: 391)
        XCTAssertTrue(LinkedPair.isAnchored(terminal, in: .bottom, of: visible))
        XCTAssertTrue(LinkedPair.isAnchored(top, in: .top, of: visible))
    }

    func testAWindowMovedAwayNoLongerHoldsItsHalf() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 805)
        XCTAssertFalse(LinkedPair.isAnchored(left.offsetBy(dx: 25, dy: 0), in: .left, of: visible))
        XCTAssertTrue(LinkedPair.isAnchored(left.offsetBy(dx: 24, dy: 0), in: .left, of: visible))
        XCTAssertFalse(LinkedPair.isAnchored(right.offsetBy(dx: -25, dy: 0), in: .right, of: visible))
        XCTAssertFalse(LinkedPair.isAnchored(top.offsetBy(dx: 0, dy: 25), in: .top, of: visible))
        XCTAssertFalse(LinkedPair.isAnchored(bottom.offsetBy(dx: 0, dy: -25), in: .bottom, of: visible))
        XCTAssertFalse(LinkedPair.isAnchored(right, in: .left, of: visible), "la moitié compte")
    }

    func testSecondaryScreenAboveThePrimary() {
        let a = CGRect(x: 0, y: -1080, width: 800, height: 1055)
        let b = CGRect(x: 800, y: -1080, width: 1120, height: 1055)
        let border = LinkedPair.border(between: a, and: b, axis: .vertical)!
        XCTAssertEqual(border.handleRect, CGRect(x: 796, y: -1080, width: 8, height: 1055))
    }
}

final class LinkedResizeTests: XCTestCase {

    private let left = CGRect(x: 0, y: 25, width: 720, height: 805)
    private let right = CGRect(x: 720, y: 25, width: 720, height: 805)

    private var sideBySide: LinkedResize { LinkedResize(axis: .vertical, first: left, second: right) }

    // MARK: - Les deux cadres

    func testMovingTheBorderResizesBothAndKeepsThemTouching() {
        let (first, second) = sideBySide.frames(borderAt: 900)
        XCTAssertEqual(first, CGRect(x: 0, y: 25, width: 900, height: 805))
        XCTAssertEqual(second, CGRect(x: 900, y: 25, width: 540, height: 805))
        XCTAssertEqual(first.maxX, second.minX, "collées")
        XCTAssertEqual(second.maxX, right.maxX, "bord extérieur inchangé")
    }

    func testVerticalStack() {
        let top = CGRect(x: 0, y: 25, width: 1440, height: 400)
        let bottom = CGRect(x: 0, y: 425, width: 1440, height: 405)
        let (first, second) = LinkedResize(axis: .horizontal, first: top, second: bottom).frames(borderAt: 300)
        XCTAssertEqual(first, CGRect(x: 0, y: 25, width: 1440, height: 275))
        XCTAssertEqual(second, CGRect(x: 0, y: 300, width: 1440, height: 530))
    }

    func testAGapAtTheStartIsClosedOnTheFirstMove() {
        let session = LinkedResize(axis: .vertical, first: left, second: CGRect(x: 722, y: 25, width: 718, height: 805))
        XCTAssertEqual(session.startBorder, 721)
        let (first, second) = session.frames(borderAt: session.startBorder)
        XCTAssertEqual(first.maxX, second.minX)
    }

    // MARK: - Bornes

    func testTheBorderStopsAtTheFloorOfEachWindow() {
        XCTAssertEqual(sideBySide.clampedBorder(10), 120, "gauche : 120 pt au moins")
        XCTAssertEqual(sideBySide.clampedBorder(1430), 1320, "droite : 120 pt au moins")
        XCTAssertEqual(sideBySide.clampedBorder(500), 500)
    }

    func testReleasingOffScreenKeepsTheLastValidBorder() {
        // La souris sort de l'écran : la frontière reste au bord de sa plage.
        let (first, second) = sideBySide.frames(borderAt: 5000)
        XCTAssertEqual(first.width, 1320)
        XCTAssertEqual(second, CGRect(x: 1320, y: 25, width: 120, height: 805))
        XCTAssertEqual(sideBySide.frames(borderAt: -5000).first.width, 120)
    }

    func testAWindowAlreadyNarrowerThanTheFloorKeepsItsSize() {
        let narrow = CGRect(x: 1340, y: 25, width: 100, height: 805)
        let session = LinkedResize(axis: .vertical, first: CGRect(x: 0, y: 25, width: 1340, height: 805), second: narrow)
        XCTAssertEqual(session.clampedBorder(1400), 1340, "ne rétrécit pas davantage")
        XCTAssertEqual(session.clampedBorder(1000), 1000, "mais peut grandir")
    }

    // MARK: - Taille réellement prise

    func testBothSizesTakenLeavesTheBorderWhereItIs() {
        let requested = sideBySide.frames(borderAt: 900)
        XCTAssertNil(sideBySide.settledBorder(requested: requested, actualFirst: requested.first, actualSecond: requested.second))
        let rounded = requested.second.insetBy(dx: -0.5, dy: 0)
        XCTAssertNil(sideBySide.settledBorder(requested: requested, actualFirst: requested.first, actualSecond: rounded), "arrondi")
    }

    func testAMinimumSizeStopsTheBorderAndTheOtherWindowFollows() {
        // TextEdit à droite garde 500 pt quand on lui en demande 440 : il
        // déborde de l'écran, calé à x = 1000.
        let requested = sideBySide.frames(borderAt: 1000)
        let textEdit = CGRect(x: 1000, y: 25, width: 500, height: 805)
        let border = sideBySide.settledBorder(requested: requested, actualFirst: requested.first, actualSecond: textEdit)
        XCTAssertEqual(border, 940)
        let (first, second) = sideBySide.frames(borderAt: border!)
        XCTAssertEqual(second, CGRect(x: 940, y: 25, width: 500, height: 805), "ramené dans son étendue, à sa taille")
        XCTAssertEqual(first.maxX, second.minX, "toujours collées")
    }

    func testAWindowThatRoundsUpToItsGridSetsTheBorder() {
        // Terminal à gauche, par crans de 7 pt : 713 demandés, 717 reçus.
        let requested = sideBySide.frames(borderAt: 713)
        let terminal = CGRect(x: 0, y: 25, width: 717, height: 805)
        XCTAssertEqual(sideBySide.settledBorder(requested: requested, actualFirst: terminal, actualSecond: requested.second), 717)
    }

    func testAWindowThatRoundsDownClosesTheGap() {
        let requested = sideBySide.frames(borderAt: 900)
        let terminal = CGRect(x: 0, y: 25, width: 896, height: 805)
        XCTAssertEqual(sideBySide.settledBorder(requested: requested, actualFirst: terminal, actualSecond: requested.second), 896)
    }

    func testTheWindowThatStayedBiggerWins() {
        let requested = sideBySide.frames(borderAt: 1000)
        let roundedDown = CGRect(x: 0, y: 25, width: 996, height: 805)
        let refused = CGRect(x: 1000, y: 25, width: 500, height: 805)
        XCTAssertEqual(sideBySide.settledBorder(requested: requested, actualFirst: roundedDown, actualSecond: refused), 940)
    }

    func testARoundedSizeDoesNotBlockTheNextMove() {
        // Le bug constaté : Terminal arrondit vers le haut, et la frontière ne
        // repartait plus vers lui. Le mouvement suivant, plus loin, doit
        // toujours demander une taille plus petite.
        let session = sideBySide
        let first = session.frames(borderAt: 713)
        _ = session.settledBorder(requested: first, actualFirst: CGRect(x: 0, y: 25, width: 717, height: 805),
                                  actualSecond: first.second)
        XCTAssertEqual(session.frames(borderAt: 700).first.width, 700)
    }

    func testTopAndBottomSettleToo() {
        let top = CGRect(x: 0, y: 25, width: 1440, height: 400)
        let bottom = CGRect(x: 0, y: 425, width: 1440, height: 405)
        let session = LinkedResize(axis: .horizontal, first: top, second: bottom)
        let requested = session.frames(borderAt: 600)
        let tall = CGRect(x: 0, y: 600, width: 1440, height: 300)
        XCTAssertEqual(session.settledBorder(requested: requested, actualFirst: requested.first, actualSecond: tall), 530)

        // Seules les hauteurs comptent : la fenêtre du bas a pris la sienne,
        // celle du haut s'est arrêtée 4 pt plus haut.
        let shorterTop = CGRect(x: 0, y: 25, width: 1440, height: 571)
        XCTAssertEqual(session.settledBorder(requested: requested, actualFirst: shorterTop, actualSecond: requested.second), 596)
    }

    // MARK: - Annulation

    func testTheStartBorderGivesBackTheOriginalFrames() {
        let (first, second) = sideBySide.frames(borderAt: sideBySide.startBorder)
        XCTAssertEqual(first, left)
        XCTAssertEqual(second, right)
    }

    // MARK: - Ordre des écritures

    func testTheShrinkingWindowIsWrittenFirst() {
        XCTAssertEqual(LinkedResize.writeOrder(from: 720, to: 900), [.second, .first], "vers la droite : la droite rétrécit")
        XCTAssertEqual(LinkedResize.writeOrder(from: 720, to: 500), [.first, .second], "vers la gauche : la gauche rétrécit")
    }

    func testAShrinkingWindowResizesBeforeMoving() {
        let (_, smaller) = sideBySide.frames(borderAt: 900)
        XCTAssertTrue(LinkedResize.resizesBeforeMoving(from: right, to: smaller))
        XCTAssertFalse(LinkedResize.resizesBeforeMoving(from: smaller, to: right))
    }
}
