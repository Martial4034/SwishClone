import CoreGraphics

/// **Quelle fenêtre a été placée en dernier dans quelle moitié, par écran**,
/// avec le cadre réel constaté ensuite.
///
/// Générique sur l'identité des fenêtres et des écrans pour se tester sans
/// AX : des entiers dans les tests, un `AXUIElement` (comparé par
/// `CFEqual`) et un numéro d'affichage dans l'app.
///
/// En mémoire seulement, pour la durée du processus : une fenêtre ne survit
/// pas de façon fiable à un redémarrage, et l'hôte vide la mémoire quand la
/// détection s'arrête ou que les écrans changent.
///
/// **Une fenêtre n'occupe qu'une zone à la fois** : l'enregistrer quelque
/// part la retire d'ailleurs.
public struct PlacementMemory<Window: Equatable, Screen: Hashable> {

    public struct Entry {
        public var window: Window
        /// Le cadre réel constaté après le placement (anti-débordement
        /// compris), en coordonnées AX.
        public var frame: CGRect
    }

    private struct Key: Hashable {
        var screen: Screen
        var zone: HalfZone
    }

    private var entries: [Key: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ window: Window, in zone: HalfZone, on screen: Screen, frame: CGRect) {
        forget(window)
        entries[Key(screen: screen, zone: zone)] = Entry(window: window, frame: frame)
    }

    /// Met à jour le cadre constaté d'une fenêtre déjà enregistrée (relecture
    /// après l'animation ou après une correction). Sans effet sinon.
    public mutating func updateFrame(of window: Window, to frame: CGRect) {
        for (key, entry) in entries where entry.window == window {
            entries[key]?.frame = frame
        }
    }

    /// L'occupant de `zone` sur `screen`, sauf s'il s'agit de `excluded` —
    /// la fenêtre qu'on est justement en train de placer.
    public func occupant(of zone: HalfZone, on screen: Screen, excluding excluded: Window? = nil) -> Entry? {
        guard let entry = entries[Key(screen: screen, zone: zone)] else { return nil }
        if let excluded, entry.window == excluded { return nil }
        return entry
    }

    /// La moitié et l'écran où la fenêtre est enregistrée, s'il y en a une.
    public func placement(of window: Window) -> (zone: HalfZone, screen: Screen)? {
        entries.first { $0.value.window == window }.map { ($0.key.zone, $0.key.screen) }
    }

    public mutating func forget(_ window: Window) {
        entries = entries.filter { $0.value.window != window }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
