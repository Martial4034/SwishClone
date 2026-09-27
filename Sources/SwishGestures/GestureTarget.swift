import AppKit
// `AXUIElement` n'est pas annoté `Sendable` par Apple ; `Target` le
// transporte entre le début et la fin d'un geste.
@preconcurrency import ApplicationServices
import SwishCloneCore

/// **Ce qui est sous le curseur au début d'un geste** : la barre de titre
/// d'une fenêtre, ou l'icône d'une app lancée dans le Dock.
///
/// ```
///   élément AX sous le curseur
///      ├─ appartient au Dock ──▶ icône d'app ? lancée ? pas nous ? ──▶ DockHitTest
///      └─ sinon ──▶ remontée jusqu'à la fenêtre ──▶ TitlebarHitTest
/// ```
///
/// Remplace `GestureZone`, qui regardait la fenêtre *au premier plan* et
/// vérifiait *à la fin* du geste que le curseur était dans sa bande du haut.
/// Ici, on demande à AX l'élément sous le curseur, on remonte jusqu'à sa
/// fenêtre, et `TitlebarHitTest` (Core, testé) décide. L'appel se fait **une
/// fois, au début du geste** : la fenêtre trouvée est celle sur laquelle le
/// geste agira au lever, même si le curseur a bougé entre-temps.
///
/// La fenêtre visée n'est pas activée : elle peut être en arrière-plan, et
/// le reste (comme le réglage « Activate Window » de Swish, éteint par
/// défaut).
public enum GestureTarget {

    public enum Target: @unchecked Sendable {
        /// `frame` en coordonnées AX.
        case window(AXUIElement, frame: CGRect)
        /// L'app d'une icône du Dock. Le nom sert à l'aperçu (« Quitter
        /// TextEdit »).
        case dockApp(pid: pid_t, name: String)

        public var kind: GestureTargetKind {
            switch self {
            case .window: return .titlebar
            case .dockApp: return .dockApp
            }
        }
    }

    static let dockBundleIdentifier = "com.apple.dock"

    /// Délai maximal d'une réponse AX. **Il est global** : AX l'applique à
    /// tous les éléments dès qu'on le pose sur l'élément système. Sans lui,
    /// une app qui ne répond plus bloquerait le test jusqu'à six secondes —
    /// et, une fois le tap actif, tout le défilement du Mac avec lui.
    static let messagingTimeout: Float = 0.1

    /// Profondeur maximale de la remontée vers la fenêtre. Une barre
    /// d'outils est à quelques niveaux ; au-delà, on est dans un contenu.
    static let maxDepth = 25

    /// Le curseur, en coordonnées globales AX (origine en haut à gauche) —
    /// `CGEvent.location` les donne directement, sans conversion.
    @MainActor
    public static func underCursor() -> Target? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        return hitTest(at: point, zoneHeight: GestureSettings.shared.gestureZoneHeight)
    }

    /// `nonisolated` : n'utilise que des appels AX, sûrs depuis n'importe
    /// quel thread — le tap de l'étape 5 l'appellera depuis le sien.
    public static func hitTest(at point: CGPoint, zoneHeight: Double) -> Target? {
        // **Avant tout appel AX.** Sur une fenêtre de l'hôte, la question AX
        // serait traitée par l'hôte lui-même, sur ce thread-ci : ses vues se
        // reconstruiraient hors du thread principal, et l'app s'arrêterait.
        // Vérifier le pid *après* (plus bas) est trop tard. Voir `WindowStack`.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if WindowStack.isOwnWindowOnTop(at: point, in: onScreenWindows(), ownPID: ownPID) {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              pid != ownPID else { return nil }

        // Le pid du Dock est relu à chaque geste plutôt que gardé : il change
        // quand le Dock redémarre, et la lecture ne coûte presque rien.
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == dockBundleIdentifier {
            return dockTarget(from: hit)
        }

        var path: [AXNodeInfo] = []
        var current = hit
        for _ in 0 ..< maxDepth {
            let info = nodeInfo(current)
            if info.role == kAXWindowRole as String {
                guard let frame = WindowController.frame(of: current) else { return nil }
                let verdict = TitlebarHitTest.evaluate(
                    path: path,
                    window: info,
                    windowFrame: frame,
                    point: point,
                    zoneHeight: zoneHeight
                )
                guard verdict == .titlebar else {
                    debugLog("pas de cible : \(verdict) (chemin \(path.compactMap(\.role)))")
                    return nil
                }
                return .window(current, frame: frame)
            }
            path.append(info)
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// La pile des fenêtres visibles, de l'avant vers l'arrière. Sûr depuis
    /// n'importe quel thread : aucune app n'est interrogée.
    static func onScreenWindows() -> [WindowStack.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return WindowStack.Window(
                pid: pid,
                bounds: bounds,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                layer: info[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }

    // MARK: - Dock

    /// L'icône touchée, ou son parent proche : selon la version de macOS,
    /// l'élément renvoyé peut être un enfant de l'icône.
    private static let dockItemSearchDepth = 3

    private static func dockTarget(from hit: AXUIElement) -> Target? {
        var current = hit
        for _ in 0 ..< dockItemSearchDepth {
            let info = nodeInfo(current)
            if info.role == "AXDockItem" {
                return dockTarget(item: current, info: info)
            }
            guard let parent = element(current, kAXParentAttribute) else { break }
            current = parent
        }
        debugLog("Dock : pas d'icône sous le curseur")
        return nil
    }

    private static func dockTarget(item: AXUIElement, info: AXNodeInfo) -> Target? {
        let url = self.url(item, kAXURLAttribute)
        let isRunning = bool(item, "AXIsApplicationRunning") ?? false
        let runningApps = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }

        let verdict = DockHitTest.evaluate(
            item: info,
            isRunning: isRunning,
            itemURL: url,
            itemBundleIdentifier: url.flatMap { Bundle(url: $0)?.bundleIdentifier },
            runningApps: runningApps,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        guard case let .app(app) = verdict else {
            debugLog("Dock : pas de cible : \(verdict) (\(string(item, kAXTitleAttribute) ?? "sans titre"), \(url?.path ?? "sans URL"))")
            return nil
        }
        let name = NSRunningApplication(processIdentifier: app.pid)?.localizedName
            ?? string(item, kAXTitleAttribute)
            ?? "l'app"
        debugLog("Dock : cible \(name) (pid \(app.pid))")
        return .dockApp(pid: app.pid, name: name)
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? URL
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    // MARK: - Attributs

    private static func nodeInfo(_ element: AXUIElement) -> AXNodeInfo {
        AXNodeInfo(
            role: string(element, kAXRoleAttribute),
            subrole: string(element, kAXSubroleAttribute)
        )
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        if GestureClassifier.debugLoggingEnabled {
            print("[GestureTarget] \(message())")
        }
    }
}
