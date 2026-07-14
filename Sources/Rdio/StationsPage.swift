import MapKit
import SwiftUI

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
                                    .fill(.green.opacity(0.85))
                                    .frame(width: place.dotDiameter, height: place.dotDiameter)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("\(place.title), \(place.country)")
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
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
            Text(model.panelTitle)
                .font(.headline)
                .lineLimit(1)
                .padding([.top, .horizontal], 10)

            if model.panelChannels.isEmpty {
                Spacer()
                Text("Click a dot on the map,\nor search above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.panelChannels, id: \.channelID) { channel in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(channel.title).lineLimit(1)
                            if !channel.subtitle.isEmpty {
                                Text(channel.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button {
                            model.play(channel)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Play now")
                        Button {
                            model.addFavorite(channel)
                        } label: {
                            Image(systemName: model.isFavorite(channel) ? "heart.fill" : "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .help(model.isFavorite(channel) ? "Already in your stations" : "Add to my stations")
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
                    HStack(spacing: 8) {
                        TextField("Name", text: $station.name)
                            .frame(width: 200)
                        TextField("Stream URL", text: $station.urlString)
                            .foregroundStyle(station.url == nil ? Color.red : Color.primary)
                        Button {
                            model.playRow(station)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(station.url == nil)
                        .help("Play now")
                        Button {
                            model.remove(station)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
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
                Spacer()
                Text("Drag to reorder · changes save automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .onChange(of: model.stations) { _, _ in
            model.scheduleSave()
        }
    }
}
