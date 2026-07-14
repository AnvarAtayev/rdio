import MapKit
import SwiftUI

/// Name or URL cell: a borderless field that reads as plain text and edits on a
/// single click, the caret landing where you clicked. Swapping a Text for a
/// TextField on click was the fragile part — the field could lose focus the
/// moment it appeared, and the click looked like it did nothing.
private struct EditableCell: View {
    @Binding var text: String
    let placeholder: String
    var tint: Color = .primary
    var monospaced = false
    @State private var hovered = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .onHover { hovered = $0 }
    }
}

/// One row in the My Stations list. Name and URL are both click-to-edit cells.
private struct StationRow: View {
    @Binding var station: SettingsModel.EditableStation
    let onPlay: () -> Void
    let onRemove: () -> Void
    @State private var rowHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                EditableCell(text: $station.name, placeholder: "Name")
                    .frame(width: 200)
                if let location = station.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                }
            }
            EditableCell(
                text: $station.urlString, placeholder: "Stream URL",
                tint: station.url == nil ? .red : .primary, monospaced: true)
            if let original = station.resettableName {
                HoverButton(symbol: "arrow.uturn.backward", help: "Reset name to “\(original)”") {
                    station.name = original
                }
            }
            HoverButton(symbol: "play.circle", help: "Play now", disabled: station.url == nil) {
                onPlay()
            }
            HoverButton(symbol: "trash", help: "Remove") {
                onRemove()
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { rowHovered = $0 }
    }
}

/// Plain symbol button with a subtle hover tint, used throughout the
/// Stations page for play/favorite/remove actions.
struct HoverButton: View {
    let symbol: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 24, height: 22)
                .foregroundStyle(hovered && !disabled ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered && !disabled ? Color.primary.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Text-pill variant of HoverButton, used for the "Popular" discovery action.
/// Same hover mechanism: brightens text and darkens the background on hover.
struct PopularButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text("Popular")
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(hovered ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? Color.primary.opacity(0.1) : Color.secondary.opacity(0.15))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Browse popular stations")
    }
}

extension RadioGarden.Place {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Bigger cities get bigger dots (sizes run 1…~700).
    var dotDiameter: CGFloat {
        6 + min(8, CGFloat(size) / 40)
    }
}

/// Everything station-related on one page: Radio Garden search + world map
/// on top, the favourites editor below (drag the divider to resize).
struct StationsPage: View {
    @ObservedObject var model: SettingsModel

    // A FIXED starting region, never `.automatic`: an automatic camera reframes
    // itself to fit the annotations, and our camera-change handler mutates the
    // annotations — that feedback loop pegs the main thread and leaks tiles.
    private static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 110, longitudeDelta: 300))
    @State private var camera: MapCameraPosition = .region(StationsPage.worldRegion)

    var body: some View {
        SettingsPage(title: "Stations") {
            VSplitView {
                searchAndMap
                    .frame(minHeight: 260)
                favorites
                    .frame(minHeight: 160)
            }
        }
        .task { await model.loadPlacesIfNeeded() }
        .onChange(of: model.focusCounter) { _, _ in
            if let region = model.focusRegion {
                withAnimation { camera = .region(region) }
            }
        }
    }

    // MARK: Search + map + results

    private var searchAndMap: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search stations, cities, or genres…", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.runSearch() } }
                HoverButton(symbol: "shuffle", help: "Surprise me — play a random station") {
                    Task { await model.surpriseMe() }
                }
                PopularButton {
                    Task { await model.loadPopular() }
                }
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding([.top, .horizontal], 10)

            HStack(spacing: 0) {
                Map(position: $camera) {
                    ForEach(model.visiblePlaces) { place in
                        Annotation("", coordinate: place.coordinate) {
                            Button {
                                Task { await model.selectPlace(place) }
                            } label: {
                                Circle()
                                    .fill(Color(red: 0.0, green: 0.42, blue: 0.95))
                                    .frame(width: place.dotDiameter, height: place.dotDiameter)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                            }
                            .buttonStyle(.plain)
                            .help("\(place.title), \(place.country)")
                        }
                    }
                }
                // Muted terrain: green dots on green land were the problem, so the
                // map recedes and the dots carry the colour.
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .onMapCameraChange(frequency: .onEnd) { context in
                    model.updateVisiblePlaces(for: context.region)
                }

                Divider()

                resultsPanel
                    .frame(width: 270)
            }
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.panelTitle.isEmpty {
                Text(model.panelTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .padding([.top, .horizontal], 10)
            }

            if model.panelStations.isEmpty {
                Spacer()
                Text("Click a dot on the map,\nsearch above, or try Popular.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.panelStations) { station in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(station.title).lineLimit(1)
                            if !station.subtitle.isEmpty {
                                Text(station.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        HoverButton(symbol: "play.circle", help: "Play now") {
                            model.play(station)
                        }
                        HoverButton(
                            symbol: model.isFavorite(station) ? "heart.fill" : "plus.circle",
                            help: model.isFavorite(station)
                                ? "Remove from my stations" : "Add to my stations"
                        ) {
                            model.toggleFavorite(station)
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding([.horizontal, .bottom], 8)
            }
        }
    }

    // MARK: Favourites

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My Stations")
                .font(.headline)
                .padding([.top, .horizontal], 10)
                .padding(.bottom, 4)
            List {
                ForEach($model.stations) { $station in
                    StationRow(
                        station: $station,
                        onPlay: { model.playRow(station) },
                        onRemove: { model.remove(station) })
                }
                .onMove { source, destination in
                    model.moveStations(from: source, to: destination)
                }
            }
            Divider()
            HStack {
                Button {
                    model.addStation()
                } label: {
                    Label("Add Station", systemImage: "plus")
                }
                Button("Open JSON…") {
                    NSWorkspace.shared.open(Stations.fileURL)
                }
            }
            .padding(8)
        }
        .onChange(of: model.stations) { _, _ in
            model.scheduleSave()
        }
    }
}
