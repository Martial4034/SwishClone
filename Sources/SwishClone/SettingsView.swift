import SwiftUI
import SwishCloneCore
import SwishGestures

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "Général"
    case sensitivity = "Sensibilité"
    case zone = "Zone active"
    case animation = "Animation"
    case about = "À propos"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sensitivity: return "slider.horizontal.3"
        case .zone: return "rectangle.topthird.inset.filled"
        case .animation: return "wand.and.rays"
        case .about: return "info.circle"
        }
    }
}

/// Préférences façon Swish : sidebar + contenu. Chaque contrôle est lié
/// directement à `GestureSettings.shared`, donc tout changement s'applique
/// et se persiste en temps réel, sans bouton "Enregistrer".
struct SettingsView: View {
    @ObservedObject private var settings = GestureSettings.shared
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            Form {
                switch selection ?? .general {
                case .general:
                    Toggle("Swipe (gauche, droite, haut, bas)", isOn: $settings.swipeEnabled)
                    Toggle("Pinch (in, out)", isOn: $settings.pinchEnabled)
                    Toggle("Afficher l'aperçu pendant le geste", isOn: $settings.previewEnabled)
                    Toggle("Retour haptique", isOn: $settings.hapticsEnabled)
                    Toggle("Redimensionner les fenêtres voisines", isOn: $settings.linkedResizeEnabled)
                    Section("Gestes, un par un") {
                        ForEach(GestureCatalog.entries, id: \.action) { entry in
                            Toggle(isOn: Binding(
                                get: { settings.isEnabled(entry.action) },
                                set: { settings.setEnabled(entry.action, $0) }
                            )) {
                                HStack {
                                    Text(entry.action.label())
                                    Spacer()
                                    Text(entry.triggers[0].symbols + (entry.target == .dockApp ? " sur le Dock" : ""))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Deux fenêtres placées en moitiés complémentaires (gauche et droite, haut et bas) se redimensionnent ensemble en glissant leur bord commun.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Le retour haptique marque chaque étape validée — le moment où l'on peut enchaîner une autre direction — et l'annulation. Il demande un trackpad Force Touch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .sensitivity:
                    sliderRow(
                        "Seuil du swipe",
                        value: $settings.swipeThreshold,
                        range: 5...50,
                        display: String(format: "%.0f", settings.swipeThreshold)
                    )
                    sliderRow(
                        "Seuil du pinch",
                        value: $settings.pinchThreshold,
                        range: 0.02...0.3,
                        display: String(format: "%.2f", settings.pinchThreshold)
                    )
                    Text("Plus le seuil est bas, plus le geste se déclenche facilement.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow(
                        "Pause d'étape",
                        value: $settings.stepPause,
                        range: 0.15...0.5,
                        display: String(format: "%.2f s", settings.stepPause)
                    )
                    sliderRow(
                        "Annulation",
                        value: $settings.cancelTimeout,
                        range: 0.6...2,
                        display: String(format: "%.1f s", settings.cancelTimeout)
                    )
                    Text("Sans lever les doigts, une pause valide la direction et permet d'en enchaîner une autre (bas puis droite = quart en bas à droite). Rester immobile plus longtemps annule le geste, comme Échap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .zone:
                    sliderRow(
                        "Hauteur de la zone",
                        value: $settings.gestureZoneHeight,
                        range: 20...100,
                        display: String(format: "%.0f pt", settings.gestureZoneHeight)
                    )
                    Text("Hauteur, depuis le haut de la fenêtre active, où le curseur doit se trouver pour qu'un geste agisse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .animation:
                    sliderRow(
                        "Durée",
                        value: $settings.animationDuration,
                        range: 0.05...0.5,
                        display: String(format: "%.2f s", settings.animationDuration)
                    )

                case .about:
                    LabeledContent("Application", value: "SwishClone")
                    LabeledContent("Version", value: SwishCloneCore.version)
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .general).rawValue)
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(display)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}
