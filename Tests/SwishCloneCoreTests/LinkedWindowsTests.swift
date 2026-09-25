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

    // MARK: - Taille minimale découverte

    func testARefusedShrinkRevealsTheMinimum() {
        var session = sideBySide
        let requested = session.frames(borderAt: 1000).second // 440 pt demandés
        let actual = CGRect(x: 1000, y: 25, width: 500, height: 805) // TextEdit en garde 500
        XCTAssertTrue(session.learnMinimum(of: .second, requested: requested, actual: actual))
        XCTAssertEqual(session.minimumSecond, 500)
        XCTAssertEqual(session.clampedBorder(1000), 940, "la frontière s'arrête là où la droite garde 500 pt")
        let (first, second) = session.frames(borderAt: 1000)
        XCTAssertEqual(first.maxX, second.minX, "toujours collées")
        XCTAssertEqual(second.width, 500)
    }

    func testAnAcceptedSizeTeachesNothing() {
        var session = sideBySide
        let requested = session.frames(borderAt: 1000).second
        XCTAssertFalse(session.learnMinimum(of: .second, requested: requested, actual: requested))
        XCTAssertFalse(session.learnMinimum(of: .second, requested: requested,
                                            actual: requested.insetBy(dx: -0.5, dy: 0)), "arrondi")
        XCTAssertEqual(session.minimumSecond, LinkedResize.minimumExtent)
    }

    func testTheFirstWindowLearnsToo() {
        var session = sideBySide
        let requested = session.frames(borderAt: 200).first
        XCTAssertTrue(session.learnMinimum(of: .first, requested: requested,
                                           actual: CGRect(x: 0, y: 25, width: 350, height: 805)))
        XCTAssertEqual(session.clampedBorder(200), 350)
    }

    func testAMinimumIsNeverLearnedTwiceSmaller() {
        var session = sideBySide
        let requested = session.frames(borderAt: 1000).second
        session.learnMinimum(of: .second, requested: requested, actual: CGRect(x: 1000, y: 25, width: 500, height: 805))
        XCTAssertFalse(session.learnMinimum(of: .second, requested: requested,
                                            actual: CGRect(x: 1000, y: 25, width: 480, height: 805)))
        XCTAssertEqual(session.minimumSecond, 500)
    }

    func testWhenMinimumsLeaveNoRoomTheBorderDoesNotMove() {
        var session = sideBySide
        let r1 = session.frames(borderAt: 1000).second
        session.learnMinimum(of: .second, requested: r1, actual: CGRect(x: 0, y: 25, width: 900, height: 805))
        let r2 = session.frames(borderAt: 200).first
        session.learnMinimum(of: .first, requested: r2, actual: CGRect(x: 0, y: 25, width: 900, height: 805))
        XCTAssertEqual(session.clampedBorder(1000), 720)
        XCTAssertEqual(session.clampedBorder(100), 720)
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
