import AppKit
import Combine
// `AXUIElement` n'est pas annoté `Sendable` par Apple ; il ne quitte jamais
// le thread principal ici.
@preconcurrency import ApplicationServices
import SwishCloneCore

/// **Fenêtres liées** : quand deux moitiés complémentaires se touchent, leur
/// bord commun se saisit à la souris et redimensionne les deux fenêtres en
/// direct (« Resize Adjacent Windows » de Swish).
///
/// Une **poignée** par paire : un panneau invisible de 8 pt posé sur le bord
/// commun (`LinkedResizeHandle`). Il reçoit lui-même le clic, que l'app en
/// dessous ne voit pas : ni tap souris actif, ni combat avec la poignée native
/// de redimensionnement. Choisi et vérifié par le prototype du 25/09/2026.
///
/// Les paires viennent de la mémoire du placement complémentaire, relue toutes
/// les `refreshInterval` secondes (et à chaque changement d'app au premier
/// plan) : aucune lecture AX tant que rien n'est placé en moitié.
///
/// **⌘ délie les deux fenêtres** : glisser la frontière avec ⌘ enfoncé (au
/// clic ou en cours de route) ne redimensionne que la fenêtre au premier plan
/// des deux, l'autre ne bouge pas.
@MainActor
enum LinkedResizeController {

    /// Assez court pour que la poignée suive une fenêtre déplacée sans
    /// décalage visible, et revienne vite au-dessus d'une app qui vient de
    /// remonter ses fenêtres (mesuré par le prototype : 0,2 s passait).
    static let refreshInterval: TimeInterval = 0.1

    private static var handles: [LinkedResizeHandle] = []
    private static var timer: Timer?
    private static var settingObserver: AnyCancellable?
    private static var activationObserver: (any NSObjectProtocol)?

    /// Avec la détection (`GestureMonitor.start`) : suit ensuite le réglage.
    static func start() {
        settingObserver = GestureSettings.shared.$linkedResizeEnabled.sink { enabled in
            MainActor.assumeIsolated { enabled ? activate() : deactivate() }
        }
    }

    static func stop() {
        settingObserver = nil
        deactivate()
    }

    private static func activate() {
        guard timer == nil else { return }
        BackgroundCursor.setEnabled(true)
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                refresh()
                // L'app qui passe au premier plan remonte ses fenêtres
                // par-dessus la poignée un instant *après* la notification :
                // on repasse juste derrière, pour qu'un clic sur la
                // frontière dans la foulée arrive bien à la poignée.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    MainActor.assumeIsolated { refresh() }
                }
            }
        }
        refresh()
    }

    private static func deactivate() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for handle in handles {
            if handle.isDragging { handle.finishDrag() }
            handle.orderOut(nil)
        }
        handles = []
        BackgroundCursor.setEnabled(false)
    }

    static func refresh() {
        if let dragging = handles.first(where: \.isDragging) {
            // Relâchement jamais reçu (⌘Tab pendant le glissé…) : le bouton
            // n'est plus enfoncé, le glissé se termine là où il en est.
            if NSEvent.pressedMouseButtons & 1 == 0 { dragging.finishDrag() }
            return
        }
        let pairs = WindowController.linkedPairs()
        while handles.count < pairs.count { handles.append(LinkedResizeHandle()) }
        let windows = pairs.isEmpty ? [] : OnScreenWindow.frontToBack()
        for (index, handle) in handles.enumerated() {
            if index < pairs.count {
                handle.show(pairs[index], among: windows)
            } else {
                handle.hide()
            }
        }
    }
}

/// Une fenêtre à l'écran telle que la voit le serveur de fenêtres.
struct OnScreenWindow {
    let number: Int
    let pid: pid_t
    /// En coordonnées AX (celles de `CGWindowList` aussi).
    let bounds: CGRect
    let layer: Int

    /// Les fenêtres visibles du bureau actuel, de l'avant vers l'arrière.
    static func frontToBack() -> [OnScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return OnScreenWindow(number: number, pid: pid, bounds: bounds,
                                  layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    /// La fenêtre du serveur qui correspond à une fenêtre AX : même app, même
    /// cadre (sans API privée pour passer de l'une à l'autre).
    func matches(pid other: pid_t, frame: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return pid == other && layer == 0
            && abs(bounds.minX - frame.minX) <= tolerance && abs(bounds.minY - frame.minY) <= tolerance
            && abs(bounds.width - frame.width) <= tolerance && abs(bounds.height - frame.height) <= tolerance
    }
}

/// La poignée d'une paire : un panneau non activant, sans fond, posé sur le
/// bord commun et **juste au-dessus de la plus avancée des deux fenêtres** —
/// pas au-dessus de tout : une troisième fenêtre qui recouvre le bord garde
/// ses clics.
@MainActor
final class LinkedResizeHandle: NSPanel {

    private(set) var pair: WindowController.LinkedWindowPair?

    private var session: LinkedResize?
    private var dragStartMouse: CGFloat = 0
    private var appliedBorder: CGFloat = 0
    /// ⌘ enfoncé pendant le glissé : seule `frontSide` suit la souris.
    private var unlinked = false
    private var frontSide: LinkedResize.Side = .first
    private var escapeMonitor: Any?

    var isDragging: Bool { session != nil }

    var cursor: NSCursor {
        pair?.border.axis == .horizontal ? .resizeUpDown : .resizeLeftRight
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle]
        // Une fenêtre transparente laisse passer les clics là où rien n'est
        // dessiné : le curseur changeait (le suivi de la souris ne dépend que
        // de la géométrie), mais le clic arrivait à l'app en dessous, qui se
        // redimensionnait seule. Le dire explicitement force la réception.
        ignoresMouseEvents = false
        contentView = LinkedResizeHandleView(handle: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Position et ordre

    func show(_ pair: WindowController.LinkedWindowPair, among windows: [OnScreenWindow]) {
        self.pair = pair
        // Sur un autre bureau, ou cachées : pas de poignée.
        guard let first = windows.firstIndex(where: { $0.matches(pid: pid(of: pair.first), frame: pair.firstFrame) }),
              let second = windows.firstIndex(where: { $0.matches(pid: pid(of: pair.second), frame: pair.secondFrame) })
        else { hide(); return }

        let strip = pair.border.handleRect
        place(strip)

        // Juste au-dessus de la plus avancée des deux : aucune autre fenêtre
        // qui touche la bande ne doit se trouver entre elle et la poignée,
        // sinon la poignée lui volerait ses clics. Cliquer dans l'une des
        // deux apps remonte ses fenêtres par-dessus la poignée : on la replace.
        let front = min(first, second)
        let pairNumbers = [windows[first].number, windows[second].number]
        let misplaced: Bool
        let me = windows.firstIndex(where: { $0.number == windowNumber })
        if let me, me < front {
            misplaced = windows[(me + 1)..<front].contains {
                $0.layer == 0 && !pairNumbers.contains($0.number) && $0.bounds.intersects(strip)
            }
        } else {
            misplaced = true
        }
        if misplaced { order(.above, relativeTo: windows[front].number) }
    }

    func hide() {
        pair = nil
        orderOut(nil)
    }

    private func place(_ axRect: CGRect) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let rect = ScreenGeometry.cocoaRect(fromAX: axRect, primaryScreenHeight: primaryHeight)
        if frame != rect { setFrame(rect, display: false) }
    }

    private func pid(of window: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return pid
    }

    // MARK: - Glissé

    /// La souris, sur l'axe de déplacement de la frontière, en coordonnées AX.
    private func mouseAlongAxis() -> CGFloat {
        let mouse = NSEvent.mouseLocation
        guard pair?.border.axis == .horizontal else { return mouse.x }
        return (NSScreen.screens.first?.frame.height ?? 0) - mouse.y
    }

    func beginDrag() {
        guard let pair,
              let first = WindowController.frame(of: pair.first),
              let second = WindowController.frame(of: pair.second) else { return }
        let session = LinkedResize(axis: pair.border.axis, first: first, second: second)
        self.session = session
        debugLog("glissé commencé : \(first) | \(second)")
        dragStartMouse = mouseAlongAxis()
        appliedBorder = session.startBorder
        unlinked = false
        frontSide = Self.frontSide(of: pair, first: first, second: second)
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Échap
            MainActor.assumeIsolated { self?.cancelDrag() }
        }
    }

    func drag() {
        guard let session, let pair else { return }
        if !unlinked && NSEvent.modifierFlags.contains(.command) {
            unlinked = true
            debugLog("⌘ : fenêtres déliées, seule la fenêtre \(frontSide == .first ? "de gauche/du haut" : "de droite/du bas") suit")
        }
        let proposed = session.startBorder + (mouseAlongAxis() - dragStartMouse)
        let border = session.clampedBorder(proposed)
        guard border != appliedBorder else { return }
        if unlinked {
            // Seule la fenêtre au premier plan : l'autre reste où elle est.
            let frames = session.frames(borderAt: border)
            guard writeFrames(frames, of: pair, order: [frontSide]) else { return }
            appliedBorder = border
        } else {
            guard let settled = move(to: border, pair: pair, session: session) else { return }
            appliedBorder = settled
        }
        let settled = appliedBorder

        // La poignée suit la frontière, pour rester sous le curseur.
        var moved = pair.border
        moved.position = settled
        place(moved.handleRect)
    }

    /// La fenêtre de la paire la plus en avant à l'écran : celle que ⌘
    /// redimensionne seule. Celle de gauche (ou du haut) si l'ordre est
    /// illisible.
    private static func frontSide(of pair: WindowController.LinkedWindowPair, first: CGRect, second: CGRect) -> LinkedResize.Side {
        let windows = OnScreenWindow.frontToBack()
        var firstPID: pid_t = 0, secondPID: pid_t = 0
        AXUIElementGetPid(pair.first, &firstPID)
        AXUIElementGetPid(pair.second, &secondPID)
        let firstIndex = windows.firstIndex { $0.matches(pid: firstPID, frame: first) } ?? .max
        let secondIndex = windows.firstIndex { $0.matches(pid: secondPID, frame: second) } ?? .max
        return secondIndex < firstIndex ? .second : .first
    }

    /// **Pose la frontière**, en laissant d'abord parler la fenêtre qui
    /// rétrécit :
    ///
    /// 1. sa taille seule, relue aussitôt : si l'app refuse (taille minimale
    ///    de TextEdit) ou arrondit (grille de Terminal), la frontière se recale
    ///    sur ce qu'elle a pris ;
    /// 2. puis sa position, et l'autre fenêtre, **directement à la frontière
    ///    recalée** ;
    /// 3. la fenêtre qui grandit peut arrondir à son tour : on recolle
    ///    l'autre une dernière fois.
    ///
    /// Aucune fenêtre n'est jamais écrite à une frontière qu'on va refuser :
    /// avant, l'autre fenêtre suivait le curseur par-dessus TextEdit bloqué,
    /// puis revenait — elle tremblait à chaque mouvement.
    ///
    /// Renvoie la frontière posée, ou `nil` si une fenêtre ne répond plus
    /// (glissé arrêté).
    private func move(to border: CGFloat, pair: WindowController.LinkedWindowPair, session: LinkedResize) -> CGFloat? {
        let order = LinkedResize.writeOrder(from: appliedBorder, to: border)
        let (shrinking, growing) = (order[0], order[1])
        let window = { (side: LinkedResize.Side) in side == .first ? pair.first : pair.second }
        let pick = { (frames: (first: CGRect, second: CGRect), side: LinkedResize.Side) in
            side == .first ? frames.first : frames.second
        }

        // 1. La taille de celle qui rétrécit.
        let requested = session.frames(borderAt: border)
        guard WindowController.setSize(pick(requested, shrinking).size, of: window(shrinking)),
              let taken = WindowController.frame(of: window(shrinking)) else {
            abort(closing: window(shrinking))
            return nil
        }
        var settled = session.settledBorder(
            requested: requested,
            actualFirst: shrinking == .first ? taken : requested.first,
            actualSecond: shrinking == .second ? taken : requested.second
        ) ?? border

        // 2. Les deux cadres complets, à la frontière recalée.
        var target = session.frames(borderAt: settled)
        guard writeFrames(target, of: pair, order: [shrinking, growing]) else { return nil }

        // 3. Celle qui grandit a-t-elle arrondi ?
        guard let grown = WindowController.frame(of: window(growing)) else {
            abort(closing: window(growing))
            return nil
        }
        if let resettled = session.settledBorder(
            requested: target,
            actualFirst: growing == .first ? grown : target.first,
            actualSecond: growing == .second ? grown : target.second
        ) {
            settled = resettled
            target = session.frames(borderAt: settled)
            guard writeFrames(target, of: pair, order: [shrinking, growing]) else { return nil }
        }
        return settled
    }

    /// Écrit des cadres complets, dans l'ordre donné, la taille avant la
    /// position pour une fenêtre qui rétrécit. `false` (et glissé arrêté) si
    /// une fenêtre ne répond plus.
    private func writeFrames(_ frames: (first: CGRect, second: CGRect), of pair: WindowController.LinkedWindowPair,
                             order: [LinkedResize.Side]) -> Bool {
        for side in order {
            let (window, after) = side == .first ? (pair.first, frames.first) : (pair.second, frames.second)
            let before = WindowController.frame(of: window) ?? after
            let sizeFirst = LinkedResize.resizesBeforeMoving(from: before, to: after)
            guard WindowController.setFrame(after, of: window, sizeFirst: sizeFirst) else {
                debugLog("écriture refusée : \(after)")
                abort(closing: window)
                return false
            }
        }
        return true
    }

    /// Relâché : les cadres constatés deviennent la référence de la paire.
    func finishDrag() {
        guard session != nil, let pair else { return }
        drag()
        guard isDragging else { return } // arrêté pendant la dernière écriture
        let first = WindowController.frame(of: pair.first)
        let second = WindowController.frame(of: pair.second)
        debugLog("glissé terminé : \(first.map { "\($0)" } ?? "?") | \(second.map { "\($0)" } ?? "?")")
        if let first, let second {
            WindowController.recordLinkedFrames([(pair.first, first), (pair.second, second)])
        } else {
            if first == nil { WindowController.forgetPlacement(of: pair.first) }
            if second == nil { WindowController.forgetPlacement(of: pair.second) }
        }
        endDrag()
    }

    /// Échap : les deux fenêtres reviennent à leurs cadres d'avant le glissé.
    func cancelDrag() {
        guard let session, let pair else { return }
        let original = (first: session.originalFirst, second: session.originalSecond)
        _ = writeFrames(original, of: pair, order: LinkedResize.writeOrder(from: appliedBorder, to: session.startBorder))
        debugLog("glissé annulé (Échap)")
        endDrag()
    }

    /// Une fenêtre fermée (ou qui ne répond plus) pendant le glissé : on
    /// s'arrête, l'autre reste où elle est, la paire est dissoute.
    private func abort(closing window: AXUIElement) {
        debugLog("glissé arrêté : une fenêtre ne répond plus (fermée ?)")
        WindowController.forgetPlacement(of: window)
        endDrag()
        hide()
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        if GestureClassifier.debugLoggingEnabled { print("[LinkedResize] \(message())") }
    }

    private func endDrag() {
        session = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if !frame.contains(NSEvent.mouseLocation) { NSCursor.arrow.set() }
    }
}

/// Le contenu de la poignée : rien à dessiner, seulement la souris et le
/// curseur.
@MainActor
final class LinkedResizeHandleView: NSView {

    private weak var handle: LinkedResizeHandle?

    init(handle: LinkedResizeHandle) {
        self.handle = handle
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    /// La fenêtre n'est jamais active : sans ça, le premier clic ne
    /// servirait qu'à l'activer.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    private func showCursor() { handle?.cursor.set() }

    override func cursorUpdate(with event: NSEvent) { showCursor() }
    override func mouseEntered(with event: NSEvent) { showCursor() }
    override func mouseMoved(with event: NSEvent) { showCursor() }
    override func mouseExited(with event: NSEvent) {
        // Pendant le glissé, la souris devance la poignée : on garde ↔.
        if handle?.isDragging != true { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘ se lit au premier mouvement (`drag`), qu'il soit enfoncé dès le
        // clic ou en cours de route.
        showCursor()
        handle?.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        showCursor()
        handle?.drag()
    }

    override func mouseUp(with event: NSEvent) {
        handle?.finishDrag()
    }
}
