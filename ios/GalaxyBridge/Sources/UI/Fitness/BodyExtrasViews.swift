import Charts
import PhotosUI
import SwiftUI

// MARK: - Tape measurements

private struct MeasurePoint: Identifiable {
    let date: Date
    let cm: Double
    var id: Date { date }
}

struct MeasurementsView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var adding = false
    @State private var part = 3

    private var sorted: [BodyMeasurement] { fitness.data.measurements.sorted { $0.date < $1.date } }

    var body: some View {
        let parts = BodyMeasurement.parts
        let key = parts[part].key
        let points = sorted.compactMap { entry in entry[keyPath: key].map { MeasurePoint(date: entry.date, cm: $0) } }
        List {
            Section {
                Picker("Measurement", selection: $part) {
                    ForEach(parts.indices, id: \.self) { index in
                        Text(tr(parts[index].name)).tag(index)
                    }
                }
                if points.count >= 2 {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("cm", point.cm))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.purple)
                        PointMark(x: .value("Date", point.date), y: .value("cm", point.cm))
                            .foregroundStyle(Color.purple)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 180)
                    if let first = points.first, let last = points.last {
                        let delta = last.cm - first.cm
                        let sign = delta > 0 ? "+" : ""
                        Text("\(sign)\(delta.oneDecimal) cm since \(first.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Log this measurement twice to see a trend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    adding = true
                } label: {
                    Label("Log measurements", systemImage: "plus")
                }
            } footer: {
                Text("Measure relaxed, in the morning, at the widest point, with the tape level. Waist at the navel.")
            }
            Section("History") {
                ForEach(sorted.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
                        Text(
                            parts.compactMap { part in
                                entry[keyPath: part.key].map { tr(part.name) + " " + $0.oneDecimal }
                            }.joined(separator: " · ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { fitness.deleteMeasurement(entry.id) }
                    }
                }
            }
        }
        .navigationTitle("Measurements")
        .sheet(isPresented: $adding) {
            NavigationStack {
                MeasurementEntryView { entry in
                    fitness.addMeasurement(entry)
                    adding = false
                }
            }
        }
    }
}

struct MeasurementEntryView: View {
    let onSave: (BodyMeasurement) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entry = BodyMeasurement(date: Date())

    var body: some View {
        Form {
            DatePicker("Date", selection: $entry.date, in: ...Date(), displayedComponents: .date)
            Section("Centimetres") {
                ForEach(BodyMeasurement.parts.indices, id: \.self) { index in
                    let part = BodyMeasurement.parts[index]
                    HStack {
                        Text(tr(part.name))
                        Spacer()
                        NumberField(placeholder: "--", value: Binding(
                            get: { entry[keyPath: part.key] ?? 0 },
                            set: { entry[keyPath: part.key] = $0 > 0 ? $0 : nil }
                        ))
                        .frame(width: 90)
                    }
                }
            }
        }
        .navigationTitle("Log measurements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave(entry) }
                    .disabled(BodyMeasurement.parts.allSatisfy { entry[keyPath: $0.key] == nil })
            }
        }
    }
}

// MARK: - Progress photos

struct ProgressPhotosView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: ProgressPhoto?
    @State private var comparing = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PhotosPicker(selection: $picked, maxSelectionCount: 5, matching: .images) {
                        Label("Add photos", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    if fitness.data.photos.count >= 2 {
                        Button {
                            comparing = true
                        } label: {
                            Label("Compare", systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("Photos stay inside this app on your iPhone. Same place, light and pose each time makes changes easy to see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(fitness.data.photos) { photo in
                        Button {
                            viewing = photo
                        } label: {
                            StoredPhoto(url: fitness.photoURL(photo))
                                .aspectRatio(3 / 4, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text(photo.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2.weight(.semibold))
                                        .padding(4)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(4)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Progress photos")
        .onChange(of: picked) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.8) {
                        fitness.addPhoto(jpeg)
                    }
                }
                picked = []
            }
        }
        .sheet(item: $viewing) { photo in
            NavigationStack {
                StoredPhoto(url: fitness.photoURL(photo))
                    .aspectRatio(contentMode: .fit)
                    .navigationTitle(photo.date.formatted(date: .abbreviated, time: .omitted))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Close") { viewing = nil } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) {
                                fitness.deletePhoto(photo)
                                viewing = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $comparing) {
            NavigationStack { PhotoCompareView() }
        }
    }
}

/// First and latest photo side by side, or any two picked.
struct PhotoCompareView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @State private var left = 0
    @State private var right = 0

    var body: some View {
        let photos = fitness.data.photos.sorted { $0.date < $1.date }
        VStack {
            HStack(spacing: 4) {
                side(photos, $left)
                side(photos, $right)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .onAppear {
            left = 0
            right = max(0, photos.count - 1)
        }
    }

    private func side(_ photos: [ProgressPhoto], _ index: Binding<Int>) -> some View {
        VStack(spacing: 6) {
            if photos.indices.contains(index.wrappedValue) {
                StoredPhoto(url: fitness.photoURL(photos[index.wrappedValue]))
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Picker("Photo", selection: index) {
                ForEach(photos.indices, id: \.self) { i in
                    Text(photos[i].date.formatted(date: .abbreviated, time: .omitted)).tag(i)
                }
            }
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A photo from the app's own folder.
struct StoredPhoto: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable()
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}
