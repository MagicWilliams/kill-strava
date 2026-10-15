import SwiftUI
import PhotosUI
import UIKit

/// Edit a run's journal after the fact (#124): title, effort, feel, notes, photo, shoes —
/// the save screen's questions (`SaveRunView`, frame 7a), asked again from Run Detail.
///
/// What it writes is decided in `RunDetailJournal.plan`; how each write landed, and what the
/// page shows afterwards, in `RunDetailJournal.applied`. The writes go through `RunJournal`,
/// the same path the save screen uses. Unlike that screen, nothing here is ever defaulted:
/// a cleared title is no title, and the shoe is exactly what the picker shows.
struct RunJournalEditSheet: View {
    let runID: UUID
    /// The heading the page falls back to with no title — the title field's placeholder.
    let fallbackHeading: String
    /// The photo already showing on the page, if it loaded.
    let initialPhoto: UIImage?
    @ObservedObject var shoes: ShoeStore
    /// What landed, and the image that goes with its `photoPath`. Called after every Save
    /// that wrote anything, including a partly failed one.
    let onSaved: (RunJournalEntry, UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// What the database holds. Moves forward after a partly failed Save, so the retry
    /// only redoes what didn't land.
    @State private var original: RunJournalEntry
    @State private var shownPhoto: UIImage?
    @State private var draft: PostRun.Draft
    @State private var photoChange: RunDetailJournal.PhotoChange = .keep
    @State private var newPhoto: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var editing: Field?

    private enum Field { case title, notes }

    init(runID: UUID, journal: RunJournalEntry, fallbackHeading: String, initialPhoto: UIImage?,
         shoes: ShoeStore, onSaved: @escaping (RunJournalEntry, UIImage?) -> Void) {
        self.runID = runID
        self.fallbackHeading = fallbackHeading
        self.initialPhoto = initialPhoto
        self.shoes = shoes
        self.onSaved = onSaved
        _original = State(initialValue: journal)
        _shownPhoto = State(initialValue: initialPhoto)
        _draft = State(initialValue: RunDetailJournal.draft(from: journal))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.lg) {
                    titleCard
                    effortCard
                    feelCard
                    photoCard
                    shoesCard
                }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.top, Tokens.Space.md)
                .padding(.bottom, Tokens.Space.xl2)
                .disabled(saving)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Palette.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
            .navigationTitle("Edit run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let image { pick(image) }
                takingPhoto = false
            }
            .ignoresSafeArea()
        }
        .task { if shoes.phase == .idle { await shoes.load() } }
    }

    // MARK: - The questions

    private var titleCard: some View {
        Card {
            SectionLabel("Title")
            TextField("", text: $draft.title,
                      prompt: Text(fallbackHeading).foregroundStyle(Tokens.Palette.textTertiary))
                .font(Tokens.Font.display(24))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .submitLabel(.done)
                .focused($editing, equals: .title)
                .accessibilityLabel("Title")
        }
    }

    private var effortCard: some View {
        Card {
            SectionLabel("Effort")
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
                ForEach(RunDetailJournal.feelOptions(current: original.feelTags), id: \.self) { tag in
                    JournalChip(title: PostRun.tagLabel(tag), selected: draft.feelTags.contains(tag)) {
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
            let image = photoChange == .replace ? newPhoto : shownPhoto
            let hasPhoto = photoChange == .replace || (photoChange == .keep && original.photoPath != nil)
            if hasPhoto {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        // Stored, but it didn't load on the page. It can still be removed
                        // or replaced.
                        ZStack {
                            Tokens.Palette.inset
                            Image(systemName: "photo").font(.system(size: 22))
                                .foregroundStyle(Tokens.Palette.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: removePhoto) {
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
        let current = PostRun.shoeID(draft.shoe, defaultID: original.shoeID)
        let options = RunDetailJournal.shoeOptions(shoes.shoes, current: original.shoeID,
                                                   defaultID: shoes.defaultShoeID)
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
                        JournalChip(title: shoe.isRetired ? shoe.name + " (retired)" : shoe.name,
                                    selected: current == shoe.id) {
                            Haptics.select()
                            draft.shoe = .chosen(shoe.id)
                        }
                    }
                    JournalChip(title: "None", selected: current == nil) {
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
            // Couldn't load them: the run keeps whatever pair it has. No picker beats a
            // picker whose "None" would quietly untag it.
            EmptyView()
        }
    }

    private var saveBar: some View {
        VStack(spacing: Tokens.Space.xs) {
            if let failure {
                HStack(alignment: .top, spacing: Tokens.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                    Text(failure)
                        .font(Tokens.Font.ui(13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tokens.Palette.warning)
                .padding(.vertical, 10).padding(.horizontal, Tokens.Space.md)
                .background(Tokens.Well.warning.fill,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            }
            PrimaryButton(title: saving ? "Saving\u{2026}" : failure == nil ? "Save" : "Try again",
                          loading: saving,
                          icon: failure == nil ? "checkmark" : "arrow.clockwise",
                          action: save)
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.md)
        .padding(.bottom, Tokens.Space.sm)
        .background(Tokens.Palette.canvas.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
        }
    }

    // MARK: - Actions

    private func pick(_ image: UIImage) {
        newPhoto = image
        photoChange = .replace
    }

    private func removePhoto() {
        newPhoto = nil
        photoItem = nil
        photoChange = original.photoPath == nil ? .keep : .remove
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            pick(image)
        }
    }

    private func save() {
        editing = nil
        let plan = RunDetailJournal.plan(draft, original: original, photo: photoChange)
        guard !plan.isNoop else {
            dismiss()
            return
        }
        Haptics.commit()
        saving = true
        failure = nil
        let upload = newPhoto
        Task {
            var fieldsSaved = true
            var photo: RunDetailJournal.PhotoResult = .untouched
            switch plan.photo {
            case .replace:
                // One call does both, fields first — the save screen's own path.
                let outcome = await RunJournal.record(plan.entry, photo: upload, forRun: runID).value
                fieldsSaved = outcome.fieldsSaved
                switch outcome.photo {
                case .attached(let path): photo = .attached(path)
                case .failed, .none: photo = .failed
                }
            case .remove:
                if plan.writesFields {
                    fieldsSaved = await RunJournal.record(plan.entry, photo: nil, forRun: runID).value.fieldsSaved
                }
                photo = await RunJournal.detachPhoto(fromRun: runID) ? .removed : .failed
            case .keep:
                fieldsSaved = await RunJournal.record(plan.entry, photo: nil, forRun: runID).value.fieldsSaved
            }

            let landed = RunDetailJournal.applied(plan, to: original, fieldsSaved: fieldsSaved, photo: photo)
            switch photo {
            case .attached:
                shownPhoto = upload
                photoChange = .keep
                newPhoto = nil
            case .removed:
                shownPhoto = nil
                photoChange = .keep
            case .untouched, .failed:
                break
            }
            original = landed
            onSaved(landed, shownPhoto)
            saving = false

            if let message = RunDetailJournal.failureMessage(plan, fieldsSaved: fieldsSaved, photo: photo) {
                failure = message
            } else {
                dismiss()
            }
        }
    }
}

/// A pickable capsule, drawn exactly as the save screen's (frame 7a): volt marks the choice,
/// `onVolt` on top. Its own copy because that one is private to `SaveRunView` and
/// `TrainingIntakeView` already owns the name `Chip`.
private struct JournalChip: View {
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
