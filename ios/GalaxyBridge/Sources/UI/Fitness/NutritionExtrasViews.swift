import SwiftUI
import VisionKit

// MARK: - Barcode lookup

/// Open Food Facts, the free product database: a barcode in, nutrition per
/// 100 g out. Only the barcode is sent, nothing about the user.
enum OpenFoodFacts {
    enum LookupError: LocalizedError {
        case notFound
        case noNutrition

        var errorDescription: String? {
            switch self {
            case .notFound: return tr("This product is not in Open Food Facts yet.")
            case .noNutrition: return tr("The product has no nutrition facts. Create it from the label instead.")
            }
        }
    }

    private struct Response: Decodable {
        let status: Int?
        let product: Product?
    }

    private struct Product: Decodable {
        let product_name: String?
        let product_name_es: String?
        let product_name_en: String?
        let brands: String?
        let serving_quantity: Flexible?
        let nutriments: [String: Flexible]?
    }

    /// Open Food Facts sends numbers as numbers or as strings.
    private struct Flexible: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Double(text.replacingOccurrences(of: ",", with: "."))
            } else {
                value = nil
            }
        }
    }

    static func lookup(_ code: String) async throws -> Food {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty,
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=product_name,product_name_es,product_name_en,brands,serving_quantity,nutriments")
        else { throw LookupError.notFound }
        var request = URLRequest(url: url)
        request.setValue("GalaxyBridge/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == 1, let product = response.product else { throw LookupError.notFound }
        let n = product.nutriments ?? [:]
        let kcal = n["energy-kcal_100g"]?.value ?? n["energy_100g"]?.value.map { $0 / 4.184 }
        guard let kcal else { throw LookupError.noNutrition }
        let spanish = AppLanguage.active.hasPrefix("es")
        let baseName = (spanish ? product.product_name_es : product.product_name_en)
            ?? product.product_name ?? product.product_name_es ?? digits
        let brand = product.brands?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let name = brand.map { "\(baseName) (\($0))" } ?? baseName
        return Food(
            id: "off." + digits,
            name: name,
            kcal: kcal,
            protein: n["proteins_100g"]?.value ?? 0,
            carbs: n["carbohydrates_100g"]?.value ?? 0,
            fat: n["fat_100g"]?.value ?? 0,
            serving: product.serving_quantity?.value ?? 100,
            custom: true
        )
    }
}

/// The camera, looking for a barcode. Hands the first one it reads back.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onCode(code)
                    return
                }
            }
        }
    }
}

/// Scan, look up, and hand back a food ready to log.
struct BarcodeLookupView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    let onFood: (Food) -> Void

    @State private var code: String?
    @State private var error: String?
    @State private var manual = ""

    var body: some View {
        VStack(spacing: 16) {
            if let code {
                if let error {
                    ContentUnavailableView {
                        Label("Not found", systemImage: "barcode.viewfinder")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Scan again") {
                            self.code = nil
                            self.error = nil
                        }
                    }
                } else {
                    ProgressView("Looking up \(code)…")
                }
            } else if BarcodeScannerView.isAvailable {
                BarcodeScannerView { found in code = found }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
                Text("Point the camera at the barcode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    Section {
                        TextField("Barcode number", text: $manual)
                            .keyboardType(.numberPad)
                        Button("Look up") { code = manual }
                            .disabled(manual.count < 8)
                    } footer: {
                        Text("The camera scanner needs camera access and an iPhone XS or newer.")
                    }
                }
            }
        }
        .navigationTitle("Scan a barcode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
        }
        .task(id: code) {
            guard let code else { return }
            if let known = fitness.allFoods.first(where: { $0.id == "off." + code.filter(\.isNumber) }) {
                onFood(known)
                return
            }
            do {
                let food = try await OpenFoodFacts.lookup(code)
                fitness.addCustomFood(food)
                onFood(food)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Fasting

/// Intermittent fasting: a timer against a goal, and the history of fasts.
struct FastingView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var goal: Double = 16
    @State private var confirmEnd = false

    private let goals: [Double] = [12, 14, 16, 18, 20, 24, 36]

    var body: some View {
        List {
            Section {
                if let fast = fitness.activeFast {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(fast.start)
                        let target = fast.goalHours * 3600
                        VStack(spacing: 14) {
                            ZStack {
                                ActivityRing(progress: elapsed / target, colour: elapsed >= target ? .green : .purple, lineWidth: 18)
                                VStack(spacing: 4) {
                                    Text(ActiveSessionView.clock(elapsed))
                                        .font(.system(.title, design: .rounded, weight: .bold))
                                        .monospacedDigit()
                                    Text(elapsed >= target
                                        ? tr("Goal reached")
                                        : String(format: tr("%@ to go"), ActiveSessionView.clock(target - elapsed)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 210, height: 210)
                            Text(phase(hours: elapsed / 3600))
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                            HStack {
                                Text("Started \(fast.start.formatted(date: .omitted, time: .shortened))")
                                Spacer()
                                Text("Goal \(Int(fast.goalHours)) h")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    Button("End fast", role: .destructive) { confirmEnd = true }
                } else {
                    Picker("Goal", selection: $goal) {
                        ForEach(goals, id: \.self) { hours in
                            Text("\(Int(hours)) h").tag(hours)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button {
                        fitness.startFast(goalHours: goal)
                        Reminders.fastChanged(fitness.activeFast)
                    } label: {
                        Label("Start fasting now", systemImage: "play.fill").font(.headline)
                    }
                    Button {
                        // A fast that started after last night's dinner.
                        let calendar = Calendar.current
                        let dinner = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
                        let start = dinner > Date() ? dinner.addingTimeInterval(-86_400) : dinner
                        fitness.startFast(goalHours: goal, at: start)
                        Reminders.fastChanged(fitness.activeFast)
                    } label: {
                        Label("I started at 21:00", systemImage: "clock.arrow.circlepath")
                    }
                }
            } footer: {
                Text("Fasting is not for everyone. If you are pregnant, diabetic, underweight or have had an eating disorder, talk to a doctor first.")
            }

            Section("History") {
                let done = fitness.data.fasts.filter { $0.end != nil }
                if done.isEmpty {
                    Text("No fasts yet.").foregroundStyle(.secondary)
                }
                ForEach(done) { fast in
                    HStack {
                        Image(systemName: fast.reachedGoal ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(fast.reachedGoal ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(fast.start.formatted(date: .abbreviated, time: .shortened))
                            Text("Goal \(Int(fast.goalHours)) h").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(fast.duration.hoursMinutes).monospacedDigit()
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { fitness.deleteFast(fast.id) }
                    }
                }
            }
        }
        .navigationTitle("Fasting")
        .confirmationDialog("End this fast?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End fast", role: .destructive) {
                fitness.endFast()
                Reminders.fastChanged(nil)
            }
        }
    }

    /// What the hours mean, kept to what is well established.
    private func phase(hours: Double) -> String {
        switch hours {
        case ..<4: return tr("Digesting your last meal.")
        case ..<12: return tr("Blood sugar and insulin settle; the body draws on stored glycogen.")
        case ..<18: return tr("Glycogen runs low and the body burns more fat for energy.")
        default: return tr("Long fast: drink water and stop if you feel unwell.")
        }
    }
}
