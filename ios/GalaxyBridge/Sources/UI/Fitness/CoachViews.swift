import AVFoundation
import SwiftUI
import Vision

// MARK: - Exercise information

/// How to do an exercise: the two photos alternating so the movement shows,
/// the muscles it works, and the steps.
struct ExerciseInfoView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise
    @State private var frame = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let images = exercise.images, !images.isEmpty {
                    ZStack {
                        ForEach(images.indices, id: \.self) { index in
                            AsyncImage(url: FitnessLibrary.imageURL(images[index])) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFit()
                                case .failure: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                                default: ProgressView()
                                }
                            }
                            .opacity(frame % images.count == index ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1.1))
                            withAnimation(.easeInOut(duration: 0.35)) { frame += 1 }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        tag(exercise.muscle.title, .orange)
                        tag(tr(exercise.equipment), .blue)
                        if let level = exercise.level { tag(tr(level.capitalized), .green) }
                    }
                    if let primary = exercise.primary, !primary.isEmpty {
                        Text("Works: \(primary.map { tr($0.capitalized) }.joined(separator: ", "))")
                            .font(.subheadline)
                    }
                    if let secondary = exercise.secondary, !secondary.isEmpty {
                        Text("Also: \(secondary.map { tr($0.capitalized) }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .cardStyle()

                if let steps = exercise.instructions, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How to do it").font(.headline)
                        ForEach(steps.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor, in: Circle())
                                Text(steps[index]).font(.subheadline)
                            }
                        }
                        if AppLanguage.active.hasPrefix("es") {
                            Text("Instructions from free-exercise-db, in English.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .cardStyle()
                }

                if !fitness.history(for: exercise.id).isEmpty {
                    NavigationLink {
                        ExerciseProgressView(exerciseID: exercise.id)
                    } label: {
                        Label("Your progress", systemImage: "chart.line.uptrend.xyaxis")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .cardStyle()
                }
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle(exercise.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Voice coach

/// Spoken cues for intervals, rest and counted reps, in the app's language.
/// Music keeps playing, ducked under the voice.
final class VoiceCoach: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = VoiceCoach()
    private let synth = AVSpeechSynthesizer()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "voice.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice.enabled") }
    }

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String, interrupt: Bool = true) {
        guard Self.enabled else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        if interrupt && synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AppLanguage.active.hasPrefix("es") ? "es-ES" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        // Let the music come back up.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Rep counter

/// What the camera watches for each movement: the joint whose angle opens
/// and closes on every rep, and the angles that count as the two ends.
enum RepMovement: String, CaseIterable, Identifiable {
    case squat, pushUp, curl, press, pullUp, lunge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squat: return tr("Squat")
        case .pushUp: return tr("Push-up")
        case .curl: return tr("Curl")
        case .press: return tr("Shoulder press")
        case .pullUp: return tr("Pull-up")
        case .lunge: return tr("Lunge")
        }
    }

    /// Knee for leg movements, elbow for arm movements.
    var usesKnee: Bool { self == .squat || self == .lunge }

    /// Angle (degrees) below which the joint is "closed", and above which it
    /// is "open". A rep is open -> closed -> open.
    var closed: Double {
        switch self {
        case .squat: return 100
        case .lunge: return 105
        case .pushUp: return 100
        case .curl: return 65
        case .press: return 95
        case .pullUp: return 85
        }
    }

    var open: Double {
        switch self {
        case .squat, .lunge: return 155
        case .pushUp: return 150
        case .curl: return 140
        case .press: return 155
        case .pullUp: return 145
        }
    }

    /// Where to put the phone, so the joint is visible.
    var placement: String {
        switch self {
        case .squat, .lunge: return tr("Phone on the floor 2-3 m away, side on, whole body in view.")
        case .pushUp: return tr("Phone on the floor to your side, about 1.5 m away.")
        case .curl, .press: return tr("Phone at chest height in front of you, upper body in view.")
        case .pullUp: return tr("Phone on the floor facing the bar, whole body in view.")
        }
    }

    static func guess(from name: String) -> RepMovement {
        let n = name.lowercased()
        if n.contains("lunge") || n.contains("split") { return .lunge }
        if n.contains("squat") || n.contains("leg press") { return .squat }
        if n.contains("push-up") || n.contains("push up") || n.contains("pushup") || n.contains("dip") { return .pushUp }
        if n.contains("curl") { return .curl }
        if n.contains("pull-up") || n.contains("chin") || n.contains("pulldown") { return .pullUp }
        if n.contains("press") { return .press }
        return .squat
    }
}

/// The camera and Vision's body pose detection. Frames are analysed off the
/// main thread; the count and skeleton are published on it.
final class PoseCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published var reps = 0
    @Published var angle: Double?
    @Published var joints: [CGPoint] = []
    @Published var tip: String?
    @Published var available = true
    @Published var front = true

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pose.camera")
    private var movement: RepMovement = .squat
    private var isClosed = false
    private var deepest = 180.0
    private var frameCount = 0

    func configure(movement: RepMovement) {
        queue.async {
            self.movement = movement
            self.isClosed = false
            self.deepest = 180
        }
    }

    func reset() {
        queue.async {
            self.isClosed = false
            self.deepest = 180
        }
        reps = 0
        tip = nil
    }

    func start() {
        queue.async { self.setUp(front: self.front) }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func flip() {
        front.toggle()
        let wantFront = front
        queue.async { self.setUp(front: wantFront) }
    }

    private func setUp(front: Bool) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.available = false }
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let connection = output.connection(with: .video) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = front
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let body = request.results?.first,
              let points = try? body.recognizedPoints(.all) else {
            DispatchQueue.main.async { self.joints = []; self.angle = nil }
            return
        }
        analyse(points)
    }

    private func analyse(_ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) {
        let sides: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] =
            movement.usesKnee
            ? [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
            : [(.leftShoulder, .leftElbow, .leftWrist), (.rightShoulder, .rightElbow, .rightWrist)]
        // The side the camera sees best.
        let best = sides.compactMap { side -> (Double, [CGPoint], Float)? in
            guard let a = points[side.0], let b = points[side.1], let c = points[side.2],
                  a.confidence > 0.3, b.confidence > 0.3, c.confidence > 0.3 else { return nil }
            let angle = Self.angle(a.location, b.location, c.location)
            let flipped = [a, b, c].map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
            return (angle, flipped, a.confidence + b.confidence + c.confidence)
        }.max { $0.2 < $1.2 }

        guard let best else {
            DispatchQueue.main.async {
                self.joints = []
                self.angle = nil
            }
            return
        }
        let angle = best.0
        let joints = best.1

        var counted = false
        var tip: String?
        if !isClosed && angle < movement.closed {
            isClosed = true
            deepest = angle
        } else if isClosed {
            deepest = min(deepest, angle)
            if angle > movement.open {
                isClosed = false
                counted = true
                if movement == .squat && deepest > 90 { tip = tr("Good. Try to go a little lower.") }
            }
        } else if angle < movement.closed + 20 && angle > movement.closed {
            tip = movement.usesKnee ? tr("A bit lower to count it") : tr("Go through the full range")
        }

        DispatchQueue.main.async {
            self.joints = joints
            self.angle = angle
            if counted {
                self.reps += 1
                VoiceCoach.shared.say("\(self.reps)")
            }
            if let tip { self.tip = tip } else if counted { self.tip = nil }
        }
    }

    static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1 = CGVector(dx: a.x - b.x, dy: a.y - b.y)
        let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let mag = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
        guard mag > 0 else { return 180 }
        return acos(max(-1, min(1, dot / mag))) * 180 / .pi
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

/// Counts reps with the camera, out loud, and hands the count back.
struct RepCounterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = PoseCamera()
    @State var movement: RepMovement
    /// Nil when opened on its own: nothing to save to.
    let onSave: ((Int) -> Void)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .overlay {
                        GeometryReader { geo in
                            // The preview fits the 9:16 frame inside the view.
                            let width = min(geo.size.width, geo.size.height * 9 / 16)
                            let height = width * 16 / 9
                            let x0 = (geo.size.width - width) / 2
                            let y0 = (geo.size.height - height) / 2
                            Path { path in
                                let pts = camera.joints.map { CGPoint(x: x0 + $0.x * width, y: y0 + $0.y * height) }
                                if let first = pts.first {
                                    path.move(to: first)
                                    for p in pts.dropFirst() { path.addLine(to: p) }
                                }
                            }
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        }
                    }
            } else {
                Text("The camera is not available. Allow camera access in the iPhone's Settings.")
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }

            VStack {
                HStack {
                    Picker("Movement", selection: $movement) {
                        ForEach(RepMovement.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                    Spacer()
                    Button {
                        camera.flip()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2)
                    }
                    .tint(.white)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal)

                Text(movement.placement)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

                Spacer()

                Text("\(camera.reps)")
                    .font(.system(size: 110, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: camera.reps)
                    .shadow(radius: 8)
                if let tip = camera.tip {
                    Text(tip)
                        .font(.headline)
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                if let angle = camera.angle {
                    Text("\(Int(angle))°").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }

                HStack(spacing: 14) {
                    Button(tr("Close")) { dismiss() }
                        .buttonStyle(.bordered)
                    Button(tr("Reset")) { camera.reset() }
                        .buttonStyle(.bordered)
                    if let onSave {
                        Button {
                            onSave(camera.reps)
                            dismiss()
                        } label: {
                            Text(String(format: tr("Save %ld reps"), camera.reps))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(camera.reps == 0)
                    }
                }
                .controlSize(.large)
                .tint(.white)
                .padding(.bottom)
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.reps)
        .onAppear {
            camera.configure(movement: movement)
            camera.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: movement) { _, value in
            camera.configure(movement: value)
            camera.reset()
        }
    }
}
