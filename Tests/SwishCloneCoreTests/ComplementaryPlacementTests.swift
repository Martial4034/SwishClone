import CoreGraphics
import XCTest
@testable import SwishCloneCore

final class ComplementaryLayoutTests: XCTestCase {

    /// Zone utile de l'écran principal : 1 440 × 805 à partir de y = 25.
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 805)

    private func frame(_ zone: HalfZone, occupant: CGRect?, in rect: CGRect? = nil) -> CGRect {
        ComplementaryLayout.frame(for: zone, in: rect ?? visible, occupant: occupant)
    }

    private func theoretical(_ zone: HalfZone) -> CGRect {
        WindowLayout.frame(for: zone.action, in: visible)!
    }

    // MARK: - Pas d'occupant utilisable : théorique

    func testNoOccupantGivesTheTheoreticalHalf() {
        for zone in HalfZone.allCases {
            XCTAssertEqual(frame(zone, occupant: nil), theoretical(zone), "\(zone)")
        }
    }

    func testOccupantExactlyAtHalfChangesNothing() {
        let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 805)
        XCTAssertEqual(frame(.left, occupant: rightHalf), theoretical(.left))
    }

    func testOccupantNoLongerOnTheScreenEdgeIsIgnored() {
        // Décollé du bord droit : il n'occupe plus la moitié droite.
        let drifted = CGRect(x: 540, y: 25, width: 800, height: 805)
        XCTAssertEqual(frame(.left, occupant: drifted), theoretical(.left))
    }

    // MARK: - Le cas d'origine : l'occupant déborde

    func testLeftHalfMeetsAnOverflowingRightOccupant() {
        // TextEdit en moitié droite, largeur minimale 900 : repoussé à x = 540.
        let textEdit = CGRect(x: 540, y: 25, width: 900, height: 805)
        let result = frame(.left, occupant: textEdit)
        XCTAssertEqual(result, CGRect(x: 0, y: 25, width: 540, height: 805))
        XCTAssertEqual(result.maxX, textEdit.minX, "les deux fenêtres se touchent exactement")
    }

    func testRightHalfMeetsAnOverflowingLeftOccupant() {
        let wide = CGRect(x: 0, y: 25, width: 900, height: 805)
        XCTAssertEqual(frame(.right, occupant: wide), CGRect(x: 900, y: 25, width: 540, height: 805))
    }

    // MARK: - Symétrique : l'occupant laisse un vide

    func testLeftHalfFillsTheGapLeftByANarrowRightOccupant() {
        let narrow = CGRect(x: 900, y: 25, width: 540, height: 805)
        let result = frame(.left, occupant: narrow)
        XCTAssertEqual(result, CGRect(x: 0, y: 25, width: 900, height: 805))
        XCTAssertEqual(result.maxX, narrow.minX, "ni chevauchement ni vide")
    }

    // MARK: - Haut et bas

    func testTopAndBottomAreSymmetric() {
        // Moitié basse repoussée vers le haut (hauteur minimale 500) : y = 330.
        let tallBottom = CGRect(x: 0, y: 330, width: 1440, height: 500)
        XCTAssertEqual(frame(.top, occupant: tallBottom), CGRect(x: 0, y: 25, width: 1440, height: 305))

        let tallTop = CGRect(x: 0, y: 25, width: 1440, height: 500)
        XCTAssertEqual(frame(.bottom, occupant: tallTop), CGRect(x: 0, y: 525, width: 1440, height: 305))
    }

    // MARK: - Seuil de 25 %

    func testTooLittleRoomFallsBackOnTheTheoreticalHalf() {
        // L'occupant ne laisse que 300 pt sur 1 440 (21 %) : trop peu.
        let hog = CGRect(x: 300, y: 25, width: 1140, height: 805)
        XCTAssertEqual(frame(.left, occupant: hog), theoretical(.left))
    }

    func testExactlyTwentyFivePercentIsAccepted() {
        let occupant = CGRect(x: 360, y: 25, width: 1080, height: 805) // laisse 360 = 25 %
        XCTAssertEqual(frame(.left, occupant: occupant).width, 360)
    }

    // MARK: - Ailleurs

    func testSecondaryScreenAboveThePrimary() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        let occupant = CGRect(x: 800, y: -1080, width: 1120, height: 1055)
        XCTAssertEqual(frame(.left, occupant: occupant, in: above), CGRect(x: 0, y: -1080, width: 800, height: 1055))
    }

    func testOnlyHalvesHaveAComplement() {
        XCTAssertEqual(HalfZone(.leftHalf), .left)
        XCTAssertEqual(HalfZone(.bottomHalf), .bottom)
        for action: GestureAction in [.topLeftQuarter, .bottomRightQuarter, .maximize, .centerReduced, .minimize, .close] {
            XCTAssertNil(HalfZone(action), "\(action)")
        }
        XCTAssertEqual(HalfZone.left.complement, .right)
        XCTAssertEqual(HalfZone.top.complement, .bottom)
    }

    // MARK: - Recoller la voisine

    func testTheTopHalfFollowsABottomHalfThatRoseAboveTheDock() {
        // Moitié haute placée d'abord ; la basse, plus haute que demandé, a
        // été remontée pour ne pas passer sous le Dock : elle chevauche.
        let top = CGRect(x: 0, y: 25, width: 1440, height: 402)
        let risen = CGRect(x: 0, y: 420, width: 1440, height: 410)
        XCTAssertEqual(ComplementaryLayout.restuckFrame(for: .top, in: visible, current: top, neighbor: risen),
                       CGRect(x: 0, y: 25, width: 1440, height: 395))
    }

    func testAGapIsClosedToo() {
        // Terminal à droite, arrondi à sa grille : il commence à x = 727.
        let left = CGRect(x: 0, y: 25, width: 720, height: 805)
        let terminal = CGRect(x: 727, y: 25, width: 713, height: 805)
        XCTAssertEqual(ComplementaryLayout.restuckFrame(for: .left, in: visible, current: left, neighbor: terminal),
                       CGRect(x: 0, y: 25, width: 727, height: 805))
    }

    func testWindowsThatAlreadyTouchAreLeftAlone() {
        let top = CGRect(x: 0, y: 25, width: 1440, height: 402)
        let bottom = CGRect(x: 0, y: 427, width: 1440, height: 403)
        XCTAssertNil(ComplementaryLayout.restuckFrame(for: .top, in: visible, current: top, neighbor: bottom))
        XCTAssertNil(ComplementaryLayout.restuckFrame(for: .bottom, in: visible, current: bottom, neighbor: top))
        let roundedBottom = CGRect(x: 0, y: 428, width: 1440, height: 402)
        XCTAssertNil(ComplementaryLayout.restuckFrame(for: .top, in: visible, current: top, neighbor: roundedBottom), "1 pt : arrondi")
    }

    func testNoRestickingToTheTheoreticalHalf() {
        // La voisine n'est plus au bord de l'écran, ou ne laisse que 21 % :
        // recoller voudrait dire revenir au théorique, pas coller.
        let left = CGRect(x: 0, y: 25, width: 720, height: 805)
        let drifted = CGRect(x: 540, y: 25, width: 800, height: 805)
        XCTAssertNil(ComplementaryLayout.restuckFrame(for: .left, in: visible, current: left, neighbor: drifted))
        let hog = CGRect(x: 300, y: 25, width: 1140, height: 805)
        XCTAssertNil(ComplementaryLayout.restuckFrame(for: .left, in: visible, current: left, neighbor: hog))
    }

    func testTheRightAndBottomHalvesAreRestuckToo() {
        let wideLeft = CGRect(x: 0, y: 25, width: 760, height: 805)
        let right = CGRect(x: 720, y: 25, width: 720, height: 805)
        XCTAssertEqual(ComplementaryLayout.restuckFrame(for: .right, in: visible, current: right, neighbor: wideLeft),
                       CGRect(x: 760, y: 25, width: 680, height: 805))
        let shortTop = CGRect(x: 0, y: 25, width: 1440, height: 390)
        let bottom = CGRect(x: 0, y: 427, width: 1440, height: 403)
        XCTAssertEqual(ComplementaryLayout.restuckFrame(for: .bottom, in: visible, current: bottom, neighbor: shortTop),
                       CGRect(x: 0, y: 415, width: 1440, height: 415))
    }

    func testResultAlwaysStaysInsideTheUsableArea() {
        let occupants = [
            CGRect(x: 540, y: 25, width: 900, height: 805),
            CGRect(x: 900, y: 25, width: 540, height: 805),
            CGRect(x: 360, y: 25, width: 1080, height: 805),
        ]
        for occupant in occupants {
            XCTAssertTrue(visible.contains(frame(.left, occupant: occupant)), "\(occupant)")
        }
    }
}

final class PlacementValidationTests: XCTestCase {

    private let recorded = CGRect(x: 540, y: 25, width: 900, height: 805)

    private func valid(_ actual: CGRect?, minimized: Bool = false, fullScreen: Bool = false) -> Bool {
        PlacementValidation.isStillPlaced(recorded: recorded, actual: actual, isMinimized: minimized, isFullScreen: fullScreen)
    }

    func testUnchangedFrameIsValid() {
        XCTAssertTrue(valid(recorded))
        XCTAssertTrue(valid(recorded.offsetBy(dx: 2, dy: -2)), "2 pt : arrondi toléré")
    }

    func testMovedOrResizedByHandIsInvalid() {
        XCTAssertFalse(valid(recorded.offsetBy(dx: 3, dy: 0)), "déplacée de 3 pt")
        XCTAssertFalse(valid(CGRect(x: 540, y: 25, width: 850, height: 805)), "redimensionnée")
    }

    func testClosedMinimizedOrFullScreenIsInvalid() {
        XCTAssertFalse(valid(nil), "fermée : cadre illisible")
        XCTAssertFalse(valid(recorded, minimized: true))
        XCTAssertFalse(valid(recorded, fullScreen: true))
    }
}

final class PlacementMemoryTests: XCTestCase {

    private typealias Memory = PlacementMemory<Int, Int>
    private let main = 1, second = 2
    private let rightFrame = CGRect(x: 540, y: 25, width: 900, height: 805)

    func testRecordsPerScreenAndZone() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: rightFrame)
        XCTAssertEqual(memory.occupant(of: .right, on: main)?.window, 10)
        XCTAssertNil(memory.occupant(of: .right, on: second), "chaque écran a ses zones")
        XCTAssertNil(memory.occupant(of: .left, on: main))
    }

    func testAWindowOccupiesOneZoneAtATime() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: rightFrame)
        memory.record(10, in: .left, on: main, frame: .zero)
        XCTAssertNil(memory.occupant(of: .right, on: main), "basculée à gauche, elle n'est plus à droite")
        XCTAssertEqual(memory.occupant(of: .left, on: main)?.window, 10)

        memory.record(10, in: .left, on: second, frame: .zero)
        XCTAssertNil(memory.occupant(of: .left, on: main), "ni sur l'autre écran")
    }

    func testANewWindowReplacesThePreviousOccupant() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: rightFrame)
        memory.record(11, in: .right, on: main, frame: rightFrame)
        XCTAssertEqual(memory.occupant(of: .right, on: main)?.window, 11)
    }

    func testTheWindowBeingPlacedIsNeverItsOwnOccupant() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: rightFrame)
        XCTAssertNil(memory.occupant(of: .right, on: main, excluding: 10))
        XCTAssertEqual(memory.occupant(of: .right, on: main, excluding: 11)?.window, 10)
    }

    func testUpdateFrameAfterReadingBack() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: CGRect(x: 720, y: 25, width: 720, height: 805))
        memory.updateFrame(of: 10, to: rightFrame)
        XCTAssertEqual(memory.occupant(of: .right, on: main)?.frame, rightFrame)
        memory.updateFrame(of: 99, to: .zero) // inconnue : sans effet
        XCTAssertEqual(memory.occupant(of: .right, on: main)?.frame, rightFrame)
    }

    func testWhereAWindowIsRecorded() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: rightFrame)
        memory.record(11, in: .top, on: second, frame: .zero)
        XCTAssertEqual(memory.placement(of: 10)?.zone, .right)
        XCTAssertEqual(memory.placement(of: 10)?.screen, main)
        XCTAssertEqual(memory.placement(of: 11)?.zone, .top)
        XCTAssertEqual(memory.placement(of: 11)?.screen, second)
        XCTAssertNil(memory.placement(of: 99))
    }

    func testForgetAndRemoveAll() {
        var memory = Memory()
        memory.record(10, in: .right, on: main, frame: rightFrame)
        memory.record(11, in: .left, on: main, frame: .zero)
        memory.forget(10)
        XCTAssertNil(memory.occupant(of: .right, on: main))
        XCTAssertEqual(memory.occupant(of: .left, on: main)?.window, 11)
        memory.removeAll()
        XCTAssertTrue(memory.isEmpty)
    }
}
