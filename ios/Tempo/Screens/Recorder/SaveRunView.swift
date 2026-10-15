import SwiftUI
import PhotosUI
import UIKit

/// The post-run save screen (#129): frames 7a (dark) and 7b (light) of the signed-off
/// "04 · Post-run" page. The run as recorded — map, distance, time, pace, splits — then the
/// journal: effort, feel and notes, title, photo, shoes. All of it optional; Save is pinned
/// below and always one tap.
///
/// Shown by `runRecorder(...)` whenever `PreRun.screen(for:)` says `.save`. What it shows
/// inside that is `PostRun.stage`, read off the recorder, so a save in flight, a failed save
/// with its Retry, a race saving itself and the moment after a save are all the recorder's
/// call, not this view's. It writes nothing itself: Save is `confirmSave(journal:photo:)`,
/// Discard is `.discard(.liveScreen)` behind a second confirmation, and the cover closes
/// when the recorder is reset.
struct SaveRunView: View {
    @Environment(WorkoutRecorder.self) private var recorder
    @StateObject private var shoes = ShoeStore()

    @State private var draft = PostRun.Draft()
    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var confirmingDiscard = false
    /// Both final once the clock has stopped, so worked out once rather than every second.
    @State private var route = RunDetail()
    @State private var splitRows: [PostRun.SplitRow] = []
    @FocusState private var editing: Field?

    private enum Field { case title, notes }

    var body: some View {
        let stage = PostRun.stage(phase: recorder.state.phase, kind: recorder.state.kind, landing: landing)
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            switch stage {
            case .review(let saving, let failure):
                review(saving: saving, failure: failure)
            case .race(let saving, let failure):
                race(saving: saving, failure: failure)
            case .saved(let note):
                saved(note: note)
            case .close:
                EmptyView()
            }
        }
        .onAppear(perform: prepare)
        .task { await shoes.load() }
        // Saved onto Today, or discarded: back to idle, and the cover goes with it.
        .onChange(of: stage == .close, initial: true) { _, closing in
            if closing { recorder.reset() }
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let image { photo = image }
                takingPhoto = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Discard this run?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard run", role: .destructive) { recorder.send(.discard(.liveScreen)) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(PostRun.discardMessage(alreadyInHealth: recorder.saveOutcome == .dropped))
        }
    }

    // MARK: - Frame 7a / 7b

    private func review(saving: Bool, failure: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.lg) {
                header
                if route.hasRoute {
                    RunRouteMap(detail: route)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
                        .accessibilityLabel("Route map")
                }
                summary
                if !splitRows.isEmpty { splitsCard }
                effortCard
                feelCard
                photoCard
                shoesCard
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, Tokens.Space.lg)
            .padding(.bottom, Tokens.Space.xl2)
            .disabled(saving)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar(saving: saving, failure: failure)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel("Run complete", color: Tokens.Palette.accentText)
            // Prefilled with the default; cleared, it saves as the default anyway
            // (`PostRun.journal`), which is what the prompt says.
            TextField("", text: $draft.title, prompt: Text(defaultTitle).foregroundStyle(Tokens.Palette.textTertiary))
                .font(Tokens.Font.display(28))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .submitLabel(.done)
                .focused($editing, equals: .title)
                .accessibilityLabel("Title")
            Text(dateLine).font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private var summary: some View {
        let s = summaryNumbers
        return VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            HStack(spacing: Tokens.Space.sm) {
                Metric(value: s.distance, unit: s.distanceUnit, label: "Distance")
                Metric(value: s.time, unit: nil, label: "Moving time")
                Metric(value: s.pace, unit: s.paceUnit, label: "Avg pace")
            }
            if let elapsed = s.elapsed {
                Text("Elapsed \(elapsed), with pauses")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }

    private var splitsCard: some View {
        Card {
            SectionLabel("Splits")
            VStack(spacing: Tokens.Space.xs) {
                ForEach(splitRows) { row in
                    HStack(spacing: Tokens.Space.md) {
                        Text(row.label).mono(12, Tokens.Palette.textSecondary)
                            .frame(width: 30, alignment: .leading)
                        Text(row.pace).mono(12)
                            .frame(width: 48, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Tokens.Palette.voltMark.opacity(0.75))
                                .frame(width: max(6, geo.size.width * row.barFraction), height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                    }
                    .frame(height: 22)
                }
            }
        }
    }

    private var effortCard: some View {
        Card {
            SectionLabel("Effort")
            Text("How hard was it?").font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
            HStack(spacing: Tokens.Space.xs) {
                ForEach(Array(PostRun.rpeScale), id: \.self) { n in
                    let picked = draft.rpe == n
                    Button {
                        Haptics.select()
                        draft.rpe = PostRun.tappedRPE(n, current: draft.rpe)
                    } label: {
                        Text("\(n)")
                            .font(Tokens.Font.mono(15))
                            .foregroundStyle(picked ? Tokens.Palette.onVolt : Tokens.Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(picked ? Tokens.Palette.volt : Tokens.Palette.inset,
                                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable(haptic: false))
                    .accessibilityLabel("Effort \(n) of 10")
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            Text(PostRun.rpeWord(draft.rpe))
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private var feelCard: some View {
        Card {
            SectionLabel("Feel")
            FlowLayout(spacing: Tokens.Space.sm) {
                ForEach(PostRun.feelTags, id: \.self) { tag in
                    Chip(title: PostRun.tagLabel(tag), selected: draft.feelTags.contains(tag)) {
                        Haptics.select()
                        draft.feelTags = PostRun.toggled(tag, in: draft.feelTags)
                    }
                }
            }
            TextField("", text: $draft.notes,
                      prompt: Text("Notes for you and the coach").foregroundStyle(Tokens.Palette.textTertiary),
                      axis: .vertical)
                .lineLimit(3...8)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .focused($editing, equals: .notes)
                .padding(Tokens.Space.md)
                .background(Tokens.Well.neutral.insetFill,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .accessibilityLabel("Notes")
        }
    }

    private var photoCard: some View {
        Card {
            SectionLabel("Photo")
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            self.photo = nil
                            photoItem = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(Pressable())
                        .padding(Tokens.Space.sm)
                        .accessibilityLabel("Remove photo")
                    }
            } else {
                HStack(spacing: Tokens.Space.sm) {
                    SecondaryButton(title: "Library", icon: "photo.on.rectangle") { choosingPhoto = true }
                    if CameraPicker.isAvailable {
                        SecondaryButton(title: "Camera", icon: "camera.fill") { takingPhoto = true }
                    }
                }
            }
        }
    }

    @ViewBuilder private var shoesCard: some View {
        let options = PostRun.shoeOptions(shoes.shoes, defaultID: shoes.defaultShoeID)
        let picked = PostRun.shoeID(draft.shoe, defaultID: shoes.defaultShoeID)
        switch shoes.phase {
        case .idle, .loading:
            Card {
                SectionLabel("Shoes")
                ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
            }
        case .ready where !options.isEmpty:
            Card {
                SectionLabel("Shoes")
                FlowLayout(spacing: Tokens.Space.sm) {
                    ForEach(options) { shoe in
                        Chip(title: shoe.name, selected: picked == shoe.id) {
                            Haptics.select()
                            draft.shoe = .chosen(shoe.id)
                        }
                    }
                    Chip(title: "None", selected: picked == nil) {
                        Haptics.select()
                        draft.shoe = .chosen(nil)
                    }
                }
            }
        case .ready:
            Card {
                SectionLabel("Shoes")
                Text("Add your shoes on the You tab and Tempo will keep their mileage.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        case .unavailable:
            // Couldn't reach them: no picker beats a picker that says "None" and means it.
            EmptyView()
        }
    }

    private func saveBar(saving: Bool, failure: String?) -> some View {
        VStack(spacing: Tokens.Space.xs) {
            if let failure { failureNote(failure) }
            PrimaryButton(
                title: saving ? "Saving\u{2026}" : failure == nil ? "Save run" : "Try again",
                loading: saving,
                icon: failure == nil ? "checkmark" : "arrow.clockwise",
                action: save
            )
            QuietButton(title: "Discard") { confirmingDiscard = true }
                .disabled(saving)
                .opacity(saving ? 0.4 : 1)
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.md)
        .background(Tokens.Palette.canvas.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
        }
    }

    private func failureNote(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
            Text("\(reason). Everything you wrote is still here.")
                .font(Tokens.Font.ui(13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Tokens.Palette.warning)
        .padding(.vertical, 10).padding(.horizontal, Tokens.Space.md)
        .background(Tokens.Well.warning.fill, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }

    // MARK: - A race (no form)

    private func race(saving: Bool, failure: String?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            SectionLabel("Race", color: Tokens.Palette.accentText)
            Text(saving ? "Saving your race\u{2026}" : "Your race isn't saved yet").display(28)
            summary
            Spacer(minLength: 0)
            if let failure {
                failureNote(failure)
                PrimaryButton(title: "Try again", icon: "arrow.clockwise") { recorder.confirmSave() }
                QuietButton(title: "Discard") { confirmingDiscard = true }
            } else {
                PrimaryButton(title: "Saving\u{2026}", loading: true)
            }
        }
        .padding(Tokens.Space.xl)
        .padding(.top, Tokens.Space.xl2)
    }

    // MARK: - Saved, somewhere other than Today

    private func saved(note: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Palette.success)
            Text("Saved").display(30)
            Text(note)
                .font(Tokens.Font.ui(15)).foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            PrimaryButton(title: "Done") { recorder.reset() }
        }
        .padding(Tokens.Space.xl)
    }

    // MARK: - Reading the recorder

    private var units: Units { recorder.snapshot.units }

    private var startedAt: Date { recorder.state.startedAt ?? recorder.state.endedAt ?? .now }

    private var defaultTitle: String {
        PostRun.defaultTitle(startedAt: startedAt, kind: recorder.state.kind, target: recorder.state.target)
    }

    /// "Tue 14 Oct, 6:42 AM · Outdoor".
    private var dateLine: String {
        let when = startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        let kind = switch recorder.state.kind {
        case .outdoor: "Outdoor"
        case .treadmill: "Treadmill"
        case .race: "Race"
        }
        return when + " \u{00B7} " + kind
    }

    private var summaryNumbers: PostRun.Summary {
        let s = recorder.snapshot
        return PostRun.summary(distanceM: s.distanceM, movingS: s.movingS, elapsedS: s.elapsedS, units: units)
    }

    private var landing: PostRun.Landing? {
        switch recorder.saveOutcome {
        case .saved: .inTempo
        case .tooShort: .tooShort
        case .queued: .queued
        case .dropped, nil: nil
        }
    }

    // MARK: - Actions

    private func prepare() {
        if draft.title.isEmpty { draft.title = defaultTitle }
        route.routeSegments = RunDetailLoader.routeSegments(recorder.route)
        splitRows = PostRun.splitRows(recorder.splits, splitMeters: units.splitMeters)
    }

    private func save() {
        editing = nil
        let journal = PostRun.journal(draft, defaultTitle: defaultTitle, defaultShoeID: shoes.defaultShoeID)
        Haptics.commit()
        recorder.confirmSave(journal: journal, photo: photo)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            photo = image
        }
    }
}

// MARK: - Parts

/// One of the three numbers under the map: value in Roboto Mono, its unit beside it.
private struct Metric: View {
    let value: String
    let unit: String?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Tokens.Font.mono(22))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).font(Tokens.Font.ui(12, .medium)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            SectionLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Tokens.Well.neutral.fill)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A pickable capsule: feel tags and shoes. Volt marks the choice, `onVolt` on top.
private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Font.ui(13, .semibold))
                .foregroundStyle(selected ? Tokens.Palette.onVolt : Tokens.Palette.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? Tokens.Palette.volt : Tokens.Palette.inset, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The system camera, for a photo taken there and then. `PhotosPicker` covers the library
/// but has no camera.
private struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
