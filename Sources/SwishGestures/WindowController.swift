import AppKit
// `AXUIElement` n'est pas annoté `Sendable` par Apple ; il est capturé
// par le timer d'animation, qui ne quitte jamais le thread principal.
@preconcurrency import ApplicationServices
import SwishCloneCore

/// Contrôle de fenêtres externes via l'Accessibility API (AXUIElement),
/// et mapping des gestes détectés vers des actions sur la fenêtre au
/// premier plan.
///
/// `@MainActor` : le timer d'animation et le cooldown sont un état
/// partagé sans verrou, et tout ce qui appelle ce type (moniteurs,
/// `TouchGestureView`, interface) est déjà sur le thread principal. Seules
/// les fonctions sans état — permission, lecture de position et de taille —
/// restent `nonisolated`, pour `GestureTarget` et le futur thread du tap.
@MainActor
public enum WindowController {

    // MARK: - Permission Accessibility

    nonisolated public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Déclenche le prompt système qui envoie l'utilisateur vers
    /// Réglages Système > Confidentialité et sécurité > Accessibilité.
    @discardableResult
    nonisolated public static func requestAccessibilityPermission() -> Bool {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Fenêtre au premier plan

    /// Fenêtre actuellement focalisée de l'application frontmost,
    /// quelle qu'elle soit (jamais la nôtre en particulier).
    public static func getFrontmostWindow() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard result == .success, let window = focusedWindow else { return nil }
        return (window as! AXUIElement)
    }

    // MARK: - Lecture position/taille

    nonisolated public static func position(of window: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated public static func size(of window: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    nonisolated public static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = position(of: window), let size = size(of: window) else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: - Déplacement/redimensionnement

    @discardableResult
    public static func moveAndResize(
        window: AXUIElement,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        var position = CGPoint(x: x, y: y)
        var size = CGSize(width: width, height: height)

        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        return positionResult == .success && sizeResult == .success
    }

    // MARK: - Déplacement/redimensionnement animé

    /// Une animation au plus par fenêtre. Les gestes visent la fenêtre sous
    /// le curseur, pas seulement celle au premier plan : deux fenêtres
    /// peuvent s'animer en même temps (le placement complémentaire de l'une
    /// pendant la glissade correctrice de l'autre).
    private static var animationTimers: [(window: WindowRef, timer: Timer)] = []

    /// Intervalle entre deux étapes (~75 fps). L'interpolation se base sur
    /// le temps écoulé réel et non sur un nombre d'étapes fixe : chaque
    /// écriture AX est un appel synchrone vers l'app cible, dont la durée
    /// varie, donc un compte d'étapes ferait dériver la durée totale.
    private static let animationTickInterval: TimeInterval = 0.013

    /// Comme `moveAndResize`, mais interpolé en ease-out sur `duration`
    /// secondes (l'Accessibility API n'a pas d'animation native : on
    /// simule en écrivant position/taille à intervalles rapprochés).
    ///
    /// Une animation déjà en cours **sur cette fenêtre** est annulée avant
    /// d'en démarrer une nouvelle, qui part de la position RÉELLE actuelle
    /// (relue ici), pas du point de départ de l'ancienne. Les animations des
    /// autres fenêtres continuent.
    public static func animatedMoveAndResize(
        window: AXUIElement,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        duration: TimeInterval? = nil
    ) {
        // Défaut lu ici et non dans la signature : un argument par défaut
        // est évalué hors de l'acteur principal.
        let duration = duration ?? GestureSettings.shared.animationDuration

        let ref = WindowRef(window)
        animationTimers.removeAll { entry in
            guard entry.window == ref else { return false }
            entry.timer.invalidate()
            return true
        }

        guard let startPosition = position(of: window), let startSize = size(of: window) else {
            // Impossible de lire l'état de départ : pas d'interpolation
            // possible, on applique directement.
            moveAndResize(window: window, x: x, y: y, width: width, height: height)
            return
        }

        let startTime = Date()
        let timer = Timer(timeInterval: animationTickInterval, repeats: true) { timer in
            // Timer ajouté à `RunLoop.main` ci-dessous : le bloc y tourne,
            // mais son type (`@Sendable`) ne le dit pas au compilateur.
            MainActor.assumeIsolated {
                let t = min(1, Date().timeIntervalSince(startTime) / duration)

                if t >= 1 {
                    // Dernière étape : valeurs exactes de la cible, sans
                    // erreur d'arrondi cumulée.
                    moveAndResize(window: window, x: x, y: y, width: width, height: height)
                    timer.invalidate()
                    animationTimers.removeAll { $0.timer === timer }
                    return
                }

                // ease-out cubique : grands pas au début, petits à la fin.
                let eased = CGFloat(1 - pow(1 - t, 3))
                moveAndResize(
                    window: window,
                    x: startPosition.x + (x - startPosition.x) * eased,
                    y: startPosition.y + (y - startPosition.y) * eased,
                    width: startSize.width + (width - startSize.width) * eased,
                    height: startSize.height + (height - startSize.height) * eased
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimers.append((ref, timer))
    }

    // MARK: - Plein écran natif

    /// Attribut Accessibility non documenté officiellement par Apple,
    /// mais largement utilisé par les outils d'automatisation existants
    /// (équivalent de `kAXFullScreenAttribute`) : bascule le vrai plein
    /// écran natif macOS (bouton vert), qui donne son propre bureau/Space
    /// à la fenêtre — différent de `moveAndResize` qui redimensionne
    /// juste la fenêtre pour remplir l'écran sans changer de bureau.
    private static let fullScreenAttributeName = "AXFullScreen" as CFString

    /// Lit l'état actuel de `AXFullScreen` et le bascule (true -> false,
    /// false -> true) — un pinch out répété fait donc entrer ET sortir du
    /// plein écran natif, comme recliquer sur le bouton vert. Ne plante
    /// jamais : certaines apps ne supportent ni la lecture ni l'écriture
    /// de cet attribut, auquel cas on logge et on ne fait rien.
    @discardableResult
    public static func toggleNativeFullScreen(window: AXUIElement) -> Bool {
        var value: AnyObject?
        let readResult = AXUIElementCopyAttributeValue(window, fullScreenAttributeName, &value)

        guard readResult == .success, let currentValue = (value as? NSNumber)?.boolValue else {
            debugLog("AXFullScreen illisible sur cette fenêtre (result=\(readResult.rawValue)) — "
                + "app probablement non compatible, pas de bascule.")
            return false
        }

        let newValue: CFBoolean = currentValue ? kCFBooleanFalse : kCFBooleanTrue
        let setResult = AXUIElementSetAttributeValue(window, fullScreenAttributeName, newValue)

        guard setResult == .success else {
            debugLog("AXFullScreen non modifiable sur cette fenêtre (result=\(setResult.rawValue)) — "
                + "app probablement non compatible, pas de bascule.")
            return false
        }

        return true
    }

    // MARK: - Actions

    /// Délai minimum entre deux actions de fenêtre déclenchées par geste,
    /// pour éviter qu'une même intention ne se ré-applique en double si le
    /// classifieur ré-émet un geste très rapidement après le précédent.
    private static let actionCooldown: TimeInterval = 0.3
    private static var lastActionDate: Date?

    private static func debugLog(_ message: @autoclosure () -> String) {
        if GestureClassifier.debugLoggingEnabled {
            print("[WindowController] \(message())")
        }
    }

    /// Applique `action` à `window` — la fenêtre visée par le geste, pas
    /// forcément celle au premier plan. Ne fait rien (sans planter) si la
    /// permission Accessibility manque ou pendant le cooldown.
    ///
    /// **L'écran de référence est celui de la fenêtre**, et sa zone utile
    /// (`visibleFrame` : sans la barre de menus ni le Dock). Avant, c'était
    /// `NSScreen.main` — l'écran de la fenêtre *active* — et son cadre entier
    /// posé en (0, 0) : faux dès qu'on vise une fenêtre sur un autre écran.
    public static func perform(_ action: GestureAction, on window: AXUIElement) {
        guard isAccessibilityTrusted() else { return }

        if let lastActionDate, Date().timeIntervalSince(lastActionDate) < actionCooldown {
            debugLog("action ignorée : cooldown actif (\(Date().timeIntervalSince(lastActionDate))s < \(actionCooldown)s)")
            return
        }
        lastActionDate = Date()
        // Une nouvelle action sur CETTE fenêtre rend caduques ses relectures
        // en attente — pas celles d'une autre fenêtre (placer la fenêtre
        // complémentaire juste après ne doit pas annuler celles de la
        // première).
        pendingOverflowChecks.removeAll { $0.window == WindowRef(window) }

        // Hors des moitiés, la fenêtre quitte sa zone mémorisée (elle y est
        // réenregistrée plus bas si l'action est une moitié).
        if HalfZone(action) == nil { placements.forget(WindowRef(window)) }

        switch action {
        case .minimize:
            // Repose sur AXMinimizedAttribute : fonctionne pour la grande
            // majorité des apps AppKit, mais certaines fenêtres (panneaux
            // système, certaines apps non standard) peuvent l'ignorer
            // silencieusement — l'API ne donne aucun moyen fiable de le
            // détecter à l'avance.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)

        case .toggleFullScreen:
            toggleNativeFullScreen(window: window)

        case .close:
            pressCloseButton(of: window)

        case .quitApp:
            // Une action d'app, pas de fenêtre : `AppController.quit`.
            debugLog("quitApp reçu par WindowController — ignoré")

        default:
            guard let current = frame(of: window),
                  let screen = screen(forWindowAt: current),
                  let theoretical = WindowLayout.frame(for: action, in: screen.visible) else {
                debugLog("action \(action) impossible : cadre ou écran introuvable")
                return
            }
            let visible = screen.visible
            var target = theoretical
            let zone = HalfZone(action)
            if let zone {
                // Placement complémentaire : se caler sur le bord réel de la
                // fenêtre qui occupe la moitié d'en face, si elle est valide.
                let occupant = validOccupant(of: zone.complement, on: screen.id, excluding: window)
                target = ComplementaryLayout.frame(for: zone, in: visible, occupant: occupant)
                if target != theoretical {
                    debugLog("moitié \(zone) calée sur la fenêtre d'en face : \(target) au lieu de \(theoretical)")
                }
                placements.record(WindowRef(window), in: zone, on: screen.id, frame: target)
            }
            animatedMoveAndResize(
                window: window,
                x: target.minX,
                y: target.minY,
                width: target.width,
                height: target.height
            )
            scheduleOverflowCheck(of: window, in: visible)
        }
    }

    // MARK: - Fenêtres qui refusent la taille demandée

    private static var overflowCheckGeneration = 0
    /// La dernière action de chaque fenêtre dont des relectures sont en
    /// attente. Courte : une entrée s'en va à la dernière relecture.
    private static var pendingOverflowChecks: [(window: WindowRef, generation: Int)] = []

    private static func isLatestAction(_ generation: Int, on window: AXUIElement) -> Bool {
        pendingOverflowChecks.contains { $0.window == WindowRef(window) && $0.generation == generation }
    }

    /// Relectures après l'animation : la première juste après, la seconde
    /// plus tard pour les apps qui se réajustent en différé.
    private static let overflowCheckDelays: [TimeInterval] = [0.1, 0.6]

    /// **Relit le cadre réel une fois l'animation finie et ramène la
    /// fenêtre dans la zone utile si elle en déborde** — sans toucher à sa
    /// taille. Voir `WindowLayout.correctedFrame(for:in:)`.
    ///
    /// Deux relectures, parce qu'une app peut se réajuster tout de suite ou
    /// un peu plus tard. La correction est idempotente : une fenêtre déjà
    /// remise en place ne bouge plus. Une nouvelle action entre-temps annule
    /// les relectures en attente de cette fenêtre-là (`pendingOverflowChecks`).
    private static func scheduleOverflowCheck(of window: AXUIElement, in visible: CGRect) {
        overflowCheckGeneration &+= 1
        let generation = overflowCheckGeneration
        pendingOverflowChecks.append((WindowRef(window), generation))
        let lastDelay = overflowCheckDelays.last
        let animation = GestureSettings.shared.animationDuration
        for delay in overflowCheckDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + animation + delay) {
                MainActor.assumeIsolated {
                    guard isLatestAction(generation, on: window) else { return }
                    if delay == lastDelay {
                        pendingOverflowChecks.removeAll { $0.window == WindowRef(window) && $0.generation == generation }
                    }
                    guard let actual = frame(of: window) else { return }
                    guard let corrected = WindowLayout.correctedFrame(for: actual, in: visible) else {
                        // Le cadre constaté devient la référence du placement
                        // complémentaire (sans effet hors des moitiés).
                        placements.updateFrame(of: WindowRef(window), to: actual)
                        restickComplement(of: window, to: actual, in: visible)
                        return
                    }
                    placements.updateFrame(of: WindowRef(window), to: corrected)
                    restickComplement(of: window, to: corrected, in: visible)
                    debugLog("fenêtre hors de l'écran après l'action (\(actual)) — ramenée en \(corrected), taille inchangée")
                    animatedMoveAndResize(
                        window: window,
                        x: corrected.minX,
                        y: corrected.minY,
                        width: corrected.width,
                        height: corrected.height
                    )
                }
            }
        }
    }

    /// **Recolle la moitié d'en face** sur le cadre que la fenêtre a
    /// finalement pris (voir `ComplementaryLayout.restuckFrame`) : sans ça,
    /// les deux ne se touchaient plus, et n'étaient donc plus liées.
    ///
    /// Une seule fois par relecture, sans relecture en retour : pas de
    /// va-et-vient entre deux apps qui arrondiraient chacune.
    private static func restickComplement(of window: AXUIElement, to final: CGRect, in visible: CGRect) {
        guard let placement = placements.placement(of: WindowRef(window)) else { return }
        let otherZone = placement.zone.complement
        guard let other = placements.occupant(of: otherZone, on: placement.screen, excluding: WindowRef(window)),
              let otherFrame = validOccupant(of: otherZone, on: placement.screen, excluding: window) else { return }
        guard let target = ComplementaryLayout.restuckFrame(for: otherZone, in: visible,
                                                            current: otherFrame, neighbor: final) else { return }

        debugLog("moitié \(otherZone) recollée sur sa voisine : \(target) au lieu de \(otherFrame)")
        placements.record(other.window, in: otherZone, on: placement.screen, frame: target)
        animatedMoveAndResize(window: other.window.element, x: target.minX, y: target.minY,
                              width: target.width, height: target.height)
        let element = other.window.element
        DispatchQueue.main.asyncAfter(deadline: .now() + GestureSettings.shared.animationDuration + 0.15) {
            MainActor.assumeIsolated {
                if let actual = frame(of: element) { placements.updateFrame(of: WindowRef(element), to: actual) }
            }
        }
    }

    /// Presse le bouton de fermeture par AX, plutôt que de fermer la fenêtre
    /// d'autorité : c'est le même chemin qu'un clic, donc l'app décide —
    /// feuille « Enregistrer ? » comprise. Une fenêtre sans bouton de
    /// fermeture (certains panneaux) n'est pas touchée.
    private static func pressCloseButton(of window: AXUIElement) {
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            debugLog("fermeture impossible : pas de bouton de fermeture exposé par AX")
            return
        }
        let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        if result != .success {
            debugLog("fermeture refusée par l'app (erreur AX \(result.rawValue))")
        }
    }

    /// L'écran qui porte la fenêtre : son numéro d'affichage (stable quand
    /// un autre écran est branché ou débranché) et sa zone utile, en
    /// coordonnées AX.
    static func screen(forWindowAt windowFrame: CGRect) -> (id: CGDirectDisplayID, visible: CGRect)? {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return nil }
        let frames = screens.map { ScreenGeometry.axRect(fromCocoa: $0.frame, primaryScreenHeight: primaryHeight) }
        guard let index = ScreenGeometry.screenIndex(for: windowFrame, among: frames) else { return nil }
        return (
            displayID(of: screens[index]),
            ScreenGeometry.axRect(fromCocoa: screens[index].visibleFrame, primaryScreenHeight: primaryHeight)
        )
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    // MARK: - Placement complémentaire

    /// Un `AXUIElement` comparé par `CFEqual` : deux références vers la même
    /// fenêtre sont égales même si ce ne sont pas les mêmes objets.
    struct WindowRef: Equatable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (a: WindowRef, b: WindowRef) -> Bool { CFEqual(a.element, b.element) }
    }

    /// Quelle fenêtre occupe quelle moitié, par écran. En mémoire, pour la
    /// durée du processus ; vidée par `resetPlacements()`.
    private static var placements = PlacementMemory<WindowRef, CGDirectDisplayID>()

    /// Oublie tous les placements : à l'arrêt de la détection et quand la
    /// configuration des écrans change (les zones utiles ne sont plus les
    /// mêmes).
    public static func resetPlacements() {
        placements.removeAll()
    }

    /// Le cadre réel actuel de l'occupant de `zone`, s'il l'occupe toujours
    /// (voir `PlacementValidation`). Un occupant qui ne compte plus est
    /// oublié au passage.
    private static func validOccupant(of zone: HalfZone, on screen: CGDirectDisplayID, excluding window: AXUIElement) -> CGRect? {
        guard let entry = placements.occupant(of: zone, on: screen, excluding: WindowRef(window)) else { return nil }
        guard let actual = currentFrameIfStillPlaced(entry) else {
            debugLog("occupant de la moitié \(zone) oublié : déplacé, fermé, réduit ou en plein écran")
            placements.forget(entry.window)
            return nil
        }
        return actual
    }

    /// Le cadre réel de la fenêtre mémorisée, si elle occupe toujours sa
    /// zone. N'oublie rien : l'appelant décide.
    private static func currentFrameIfStillPlaced(_ entry: PlacementMemory<WindowRef, CGDirectDisplayID>.Entry) -> CGRect? {
        let element = entry.window.element
        // Le cadre d'abord : une fenêtre déplacée (le cas courant) évite les
        // deux autres lectures.
        guard let actual = frame(of: element),
              PlacementValidation.isStillPlaced(recorded: entry.frame, actual: actual,
                                                isMinimized: false, isFullScreen: false),
              boolAttribute(element, kAXMinimizedAttribute as CFString) == false,
              boolAttribute(element, fullScreenAttributeName) == false else { return nil }
        return actual
    }

    // MARK: - Fenêtres liées

    /// Deux moitiés complémentaires d'un même écran, valides, redimensionnables
    /// et qui se touchent : leur bord commun se saisit (`LinkedResizeController`).
    struct LinkedWindowPair {
        /// La fenêtre de gauche (ou du haut), puis celle de droite (ou du bas).
        let first: AXUIElement
        let second: AXUIElement
        let firstFrame: CGRect
        let secondFrame: CGRect
        let border: LinkedBorder
    }

    /// Les paires liées de tous les écrans, lues maintenant. Aucune lecture
    /// AX tant que rien n'est placé en moitié.
    static func linkedPairs() -> [LinkedWindowPair] {
        guard !placements.isEmpty, let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let halves: [(HalfZone, HalfZone, LinkAxis)] = [(.left, .right, .vertical), (.top, .bottom, .horizontal)]
        var pairs: [LinkedWindowPair] = []
        for screen in NSScreen.screens {
            let id = displayID(of: screen)
            let visible = ScreenGeometry.axRect(fromCocoa: screen.visibleFrame, primaryScreenHeight: primaryHeight)
            for (firstZone, secondZone, axis) in halves {
                guard let a = placements.occupant(of: firstZone, on: id),
                      let b = placements.occupant(of: secondZone, on: id),
                      let frameA = currentFrameIfHolding(a.window.element, firstZone, of: visible),
                      let frameB = currentFrameIfHolding(b.window.element, secondZone, of: visible),
                      let border = LinkedPair.border(between: frameA, and: frameB, axis: axis),
                      isResizable(a.window.element), isResizable(b.window.element) else { continue }
                pairs.append(LinkedWindowPair(first: a.window.element, second: b.window.element,
                                          firstFrame: frameA, secondFrame: frameB, border: border))
            }
        }
        return pairs
    }

    /// Le cadre réel d'une fenêtre qui tient encore sa moitié (voir
    /// `LinkedPair.isAnchored`), ni réduite ni en plein écran.
    private static func currentFrameIfHolding(_ window: AXUIElement, _ zone: HalfZone, of visible: CGRect) -> CGRect? {
        guard let actual = frame(of: window),
              LinkedPair.isAnchored(actual, in: zone, of: visible),
              boolAttribute(window, kAXMinimizedAttribute as CFString) == false,
              boolAttribute(window, fullScreenAttributeName) == false else { return nil }
        return actual
    }

    /// Après un glissé de frontière : les nouveaux cadres deviennent la
    /// référence, la paire reste liée.
    static func recordLinkedFrames(_ frames: [(AXUIElement, CGRect)]) {
        for (window, frame) in frames { placements.updateFrame(of: WindowRef(window), to: frame) }
    }

    /// Une fenêtre fermée ou devenue illisible pendant un glissé.
    static func forgetPlacement(of window: AXUIElement) {
        placements.forget(WindowRef(window))
    }

    nonisolated static func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// Écrit la taille seule : la fenêtre garde son origine.
    static func setSize(_ size: CGSize, of window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    /// Écrit un cadre sans animation. Pour une fenêtre qui rétrécit, la
    /// taille avant la position (voir `LinkedResize.resizesBeforeMoving`).
    /// `false` si l'app a répondu par une erreur — fenêtre fermée, le plus
    /// souvent.
    static func setFrame(_ frame: CGRect, of window: AXUIElement, sizeFirst: Bool) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let writes: [(CFString, AXValue)] = sizeFirst
            ? [(kAXSizeAttribute as CFString, sizeValue), (kAXPositionAttribute as CFString, positionValue)]
            : [(kAXPositionAttribute as CFString, positionValue), (kAXSizeAttribute as CFString, sizeValue)]
        for (attribute, value) in writes where AXUIElementSetAttributeValue(window, attribute, value) != .success {
            return false
        }
        return true
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// Chemin de la fenêtre de test locale (`TouchGestureView`) : agit sur
    /// la fenêtre au premier plan, et jamais sur la nôtre.
    public static func handleGesture(_ gesture: Gesture) {
        guard isAccessibilityTrusted() else {
            requestAccessibilityPermission()
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            debugLog("geste ignoré : notre propre fenêtre de test est au premier plan")
            return
        }

        let action: GestureAction?
        switch gesture {
        case let .swipe(direction, _): action = GestureSequence.resolve(swipes: [direction])
        case let .pinch(direction, _): action = GestureSequence.resolve(pinches: [direction])
        case .tap: action = nil
        }

        guard let action, let window = getFrontmostWindow() else { return }
        perform(action, on: window)
    }
}
