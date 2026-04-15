import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct GeminiGenerationReferenceDraft: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
    var path: String
    var isIncluded: Bool = true
}

@available(macOS 26.0, *)
struct GeminiGenerationDraftOverrideTelemetry: Hashable, Sendable {
    var effectiveProviderHint: String? = nil
    var promptAppendix: String? = nil
    var isLocked = false

    var hasProviderOverride: Bool {
        !(effectiveProviderHint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasPromptAppendix: Bool {
        !(promptAppendix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasVisibleChanges: Bool {
        hasProviderOverride || hasPromptAppendix || isLocked
    }

    var badgeLabels: [String] {
        var labels: [String] = []
        if hasProviderOverride {
            labels.append("Provider")
        }
        if hasPromptAppendix {
            labels.append("Appendix")
        }
        if isLocked {
            labels.append("Locked")
        }
        return labels
    }
}

@available(macOS 26.0, *)
struct GeminiGenerationDraft: Identifiable, Hashable, Sendable {
    enum PricingMode: Hashable, Sendable {
        case standard
        case batch
    }

    var id: UUID = UUID()
    var title: String
    var destinationDescription: String
    var prompt: String
    var recommendedLORACaption: String? = nil
    var contextNote: String? = nil
    var model: GeminiModel
    var aspectRatio: String
    var imageSize: String
    var referenceItems: [GeminiGenerationReferenceDraft]
    var linkedPlaceID: UUID? = nil
    var routeID: UUID? = nil
    var worldNodeID: UUID? = nil
    var cameraPose: WorldCameraPose? = nil
    var mapPoint: WorldMapPoint? = nil
    var mapViewPreset: MapViewPreset? = nil
    var pricingMode: PricingMode = .standard
    var isSelected: Bool = true
    var overrideTelemetry: GeminiGenerationDraftOverrideTelemetry? = nil

    var estimatedCost: Double {
        switch pricingMode {
        case .standard:
            model.estimatedCost(for: imageSize)
        case .batch:
            model.estimatedBatchCost(for: imageSize)
        }
    }

    var includedReferenceItems: [GeminiGenerationReferenceDraft] {
        referenceItems.filter(\.isIncluded)
    }
}

@available(macOS 26.0, *)
struct GeminiGenerationPreflightSheet: View {
    let store: AnimateStore
    @Binding var drafts: [GeminiGenerationDraft]
    let title: String
    let confirmTitle: String
    let onConfirm: ([GeminiGenerationDraft], GeminiGenerationDraft.PricingMode) -> Void
    let onCancel: () -> Void

    @State private var selectedMode: GeminiGenerationDraft.PricingMode = .standard

    private let aspectRatioOptions = ["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"]
    private let imageSizeOptions = ["1K", "2K", "4K"]

    private var usesSharedConfiguration: Bool {
        drafts.count > 1
    }

    private var selectedDrafts: [GeminiGenerationDraft] {
        drafts.filter(\.isSelected)
    }

    private var totalCost: Double {
        selectedDrafts.reduce(0) { $0 + $1.estimatedCost }
    }

    private var selectedOverrideCount: Int {
        selectedDrafts.filter { $0.overrideTelemetry?.hasVisibleChanges == true }.count
    }

    private var overriddenDrafts: [GeminiGenerationDraft] {
        drafts.filter { $0.overrideTelemetry?.hasVisibleChanges == true }
    }

    private var selectedOverriddenDrafts: [GeminiGenerationDraft] {
        selectedDrafts.filter { $0.overrideTelemetry?.hasVisibleChanges == true }
    }

    private var selectedLockedOverrideCount: Int {
        selectedDrafts.filter { $0.overrideTelemetry?.isLocked == true }.count
    }

    private var selectedProviderOverrideCount: Int {
        selectedDrafts.filter { $0.overrideTelemetry?.hasProviderOverride == true }.count
    }

    private var selectedAppendixOverrideCount: Int {
        selectedDrafts.filter { $0.overrideTelemetry?.hasPromptAppendix == true }.count
    }

    private var lockedOverrideDrafts: [GeminiGenerationDraft] {
        drafts.filter { $0.overrideTelemetry?.isLocked == true }
    }

    private var providerOverrideDrafts: [GeminiGenerationDraft] {
        drafts.filter { $0.overrideTelemetry?.hasProviderOverride == true }
    }

    private var appendixOverrideDrafts: [GeminiGenerationDraft] {
        drafts.filter { $0.overrideTelemetry?.hasPromptAppendix == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard

                    if usesSharedConfiguration {
                        sharedConfigurationCard
                    }

                    ForEach($drafts) { $draft in
                        if usesSharedConfiguration {
                            promptOnlyRequestCard($draft)
                        } else {
                            requestCard($draft)
                        }
                    }
                }
                .padding()
            }

            Divider()

            footer
        }
        .frame(minWidth: 960, minHeight: 720)
        .onAppear {
            if let first = drafts.first {
                selectedMode = first.pricingMode
            }
        }
        .onChange(of: selectedMode) { _, newMode in
            for index in drafts.indices {
                drafts[index].pricingMode = newMode
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(
                    usesSharedConfiguration
                        ? "Preview the shared Nano Banana configuration once at the top, then review each prompt and cost below."
                        : "Preview every Nano Banana request before it is sent. You can override prompts, reference images, model, aspect ratio, and size here."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("\(selectedDrafts.count)/\(drafts.count) selected", systemImage: "sparkles.rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.22), in: Capsule())
        }
        .padding()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                preflightMetric(title: "Selected Cost", value: "$\(String(format: "%.3f", totalCost))", icon: "creditcard.fill", tint: .orange)
                preflightMetric(title: "Models", value: selectedDrafts.map(\.model.displayName).joined(separator: ", "), icon: "cpu", tint: .purple)
                preflightMetric(title: "Sizes", value: Set(selectedDrafts.map(\.imageSize)).sorted().joined(separator: ", "), icon: "arrow.up.left.and.arrow.down.right", tint: .blue)
                preflightMetric(title: "Overrides", value: selectedOverrideCount == 0 ? "None" : "\(selectedOverrideCount) selected", icon: "slider.horizontal.3", tint: .pink)
            }

            if usesSharedConfiguration {
                HStack(spacing: 8) {
                    Button("Select All") {
                        setSelectionState(true, for: drafts.indices)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Select None") {
                        setSelectionState(false, for: drafts.indices)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Only Overrides") {
                        selectOnlyOverrides()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(overriddenDrafts.isEmpty)

                    Button("Only Locked") {
                        selectOnlyLockedOverrides()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(lockedOverrideDrafts.isEmpty)

                    Button("Only Provider") {
                        selectOnlyProviderOverrides()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(providerOverrideDrafts.isEmpty)

                    Button("Only Appendix") {
                        selectOnlyAppendixOverrides()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appendixOverrideDrafts.isEmpty)
                }
            }

            if !selectedOverriddenDrafts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected Override Drafts")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(selectedOverriddenDrafts, id: \.id) { draft in
                        HStack(alignment: .top, spacing: 8) {
                            Text(draft.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let telemetry = draft.overrideTelemetry {
                                ForEach(telemetry.badgeLabels, id: \.self) { badge in
                                    Text(badge)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.pink.opacity(0.14)))
                                        .foregroundStyle(.pink)
                                }
                            }
                        }
                    }

                    Text("Breakdown • Provider \(selectedProviderOverrideCount) • Appendix \(selectedAppendixOverrideCount) • Locked \(selectedLockedOverrideCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sharedConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shared Configuration")
                .font(.headline)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: sharedModelBinding) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aspect Ratio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Aspect Ratio", selection: sharedAspectRatioBinding) {
                        ForEach(aspectRatioOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 150)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Image Size", selection: sharedImageSizeBinding) {
                        ForEach(imageSizeOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reference Images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        setSharedReferencesIncluded(true)
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sharedReferenceItems.isEmpty)
                    Button {
                        setSharedReferencesIncluded(false)
                    } label: {
                        Label("Select None", systemImage: "circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sharedReferenceItems.isEmpty)
                    Button {
                        addSharedReferenceImages()
                    } label: {
                        Label("Add Image", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if sharedReferenceItems.isEmpty {
                    Text("No references selected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(sharedReferenceItems.indices, id: \.self) { index in
                                sharedReferenceCard(reference: sharedReferenceBinding(at: index))
                                    .frame(width: 140)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func setSharedReferencesIncluded(_ included: Bool) {
        for draftIndex in drafts.indices {
            for refIndex in drafts[draftIndex].referenceItems.indices {
                drafts[draftIndex].referenceItems[refIndex].isIncluded = included
            }
        }
    }

    private func setDraftReferencesIncluded(draftID: UUID, included: Bool) {
        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        for refIndex in drafts[draftIndex].referenceItems.indices {
            drafts[draftIndex].referenceItems[refIndex].isIncluded = included
        }
    }

    private func preflightMetric(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overrideTelemetryView(_ telemetry: GeminiGenerationDraftOverrideTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Overrides Applied", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.pink)
                ForEach(telemetry.badgeLabels, id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.pink.opacity(0.16)))
                        .foregroundStyle(.pink)
                }
            }

            if let provider = telemetry.effectiveProviderHint?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
                Text("Provider override → \(provider)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.pink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let appendix = telemetry.promptAppendix?.trimmingCharacters(in: .whitespacesAndNewlines), !appendix.isEmpty {
                Text("Prompt appendix → \(appendix)")
                    .font(.caption2)
                    .foregroundStyle(.pink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if telemetry.isLocked {
                Text("Locked override will preserve this draft’s authored override context.")
                    .font(.caption2)
                    .foregroundStyle(.pink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.pink.opacity(0.18))
        }
    }

    private func setSelectionState(_ isSelected: Bool, for indices: some Sequence<Int>) {
        for index in indices {
            guard drafts.indices.contains(index) else { continue }
            drafts[index].isSelected = isSelected
        }
    }

    private func selectOnlyOverrides() {
        for index in drafts.indices {
            drafts[index].isSelected = drafts[index].overrideTelemetry?.hasVisibleChanges == true
        }
    }

    private func selectOnlyLockedOverrides() {
        for index in drafts.indices {
            drafts[index].isSelected = drafts[index].overrideTelemetry?.isLocked == true
        }
    }

    private func selectOnlyProviderOverrides() {
        for index in drafts.indices {
            drafts[index].isSelected = drafts[index].overrideTelemetry?.hasProviderOverride == true
        }
    }

    private func selectOnlyAppendixOverrides() {
        for index in drafts.indices {
            drafts[index].isSelected = drafts[index].overrideTelemetry?.hasPromptAppendix == true
        }
    }

    private func requestCard(_ draft: Binding<GeminiGenerationDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle(isOn: draft.isSelected) {
                            Text(draft.wrappedValue.title)
                                .font(.headline)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(draft.wrappedValue.destinationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let contextNote = draft.wrappedValue.contextNote, !contextNote.isEmpty {
                        Text(contextNote)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let overrideTelemetry = draft.wrappedValue.overrideTelemetry, overrideTelemetry.hasVisibleChanges {
                        overrideTelemetryView(overrideTelemetry)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("$\(String(format: "%.3f", draft.wrappedValue.estimatedCost))")
                        .font(.headline)
                    Text("\(draft.wrappedValue.imageSize) • \(draft.wrappedValue.aspectRatio)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: draft.prompt)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary.opacity(0.4))
                    }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: draft.model) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aspect Ratio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Aspect Ratio", selection: draft.aspectRatio) {
                        ForEach(aspectRatioOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 150)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Image Size", selection: draft.imageSize) {
                        ForEach(imageSizeOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reference Images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        setDraftReferencesIncluded(draftID: draft.wrappedValue.id, included: true)
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(draft.wrappedValue.referenceItems.isEmpty)
                    Button {
                        setDraftReferencesIncluded(draftID: draft.wrappedValue.id, included: false)
                    } label: {
                        Label("Select None", systemImage: "circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(draft.wrappedValue.referenceItems.isEmpty)
                    Button {
                        addReferenceImages(to: draft.wrappedValue.id)
                    } label: {
                        Label("Add Image", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if draft.wrappedValue.referenceItems.isEmpty {
                    Text("No references selected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(draft.referenceItems.indices, id: \.self) { index in
                                referenceCard(reference: draft.referenceItems[index], draftID: draft.wrappedValue.id)
                                    .frame(width: 140)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func promptOnlyRequestCard(_ draft: Binding<GeminiGenerationDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle(isOn: draft.isSelected) {
                            Text(draft.wrappedValue.title)
                                .font(.headline)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(draft.wrappedValue.destinationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let contextNote = draft.wrappedValue.contextNote, !contextNote.isEmpty {
                        Text(contextNote)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let overrideTelemetry = draft.wrappedValue.overrideTelemetry, overrideTelemetry.hasVisibleChanges {
                        overrideTelemetryView(overrideTelemetry)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("$\(String(format: "%.3f", draft.wrappedValue.estimatedCost))")
                        .font(.headline)
                    Text("\(drafts.first?.imageSize ?? draft.wrappedValue.imageSize) • \(drafts.first?.aspectRatio ?? draft.wrappedValue.aspectRatio)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: draft.prompt)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary.opacity(0.4))
                    }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func referenceCard(
        reference: Binding<GeminiGenerationReferenceDraft>,
        draftID: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            referenceThumbnail(path: reference.wrappedValue.path)
                .overlay(alignment: .topTrailing) {
                    Button {
                        removeReference(reference.wrappedValue.id, from: draftID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary, .thinMaterial)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

            Toggle(isOn: reference.isIncluded) {
                Text(reference.wrappedValue.label)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(reference.wrappedValue.isIncluded ? Color.accentColor : Color.secondary, lineWidth: 1)
        }
    }

    private func sharedReferenceCard(
        reference: Binding<GeminiGenerationReferenceDraft>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            referenceThumbnail(path: reference.wrappedValue.path)
                .overlay(alignment: .topTrailing) {
                    Button {
                        removeSharedReference(reference.wrappedValue.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary, .thinMaterial)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

            Toggle(isOn: reference.isIncluded) {
                Text(reference.wrappedValue.label)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(reference.wrappedValue.isIncluded ? Color.accentColor : Color.secondary, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func referenceThumbnail(path: String) -> some View {
        if let image = store.thumbnailImage(for: path, maxSize: 120) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let absURL = resolvedAbsoluteURL(for: path),
                  let image = store.thumbnailImage(for: absURL.path, maxSize: 120) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.25))
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var footer: some View {
        HStack {
            if store.geminiAPIKey.isEmpty {
                Label("Set a Gemini API key before generating.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if !selectedDrafts.isEmpty {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Mode", selection: $selectedMode) {
                Label("Generate Now", systemImage: "bolt.fill")
                    .tag(GeminiGenerationDraft.PricingMode.standard)
                Label("Add to Batch", systemImage: "tray.and.arrow.down.fill")
                    .tag(GeminiGenerationDraft.PricingMode.batch)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .help(selectedMode == .standard
                  ? "Send requests immediately at standard pricing"
                  : "Add requests to the batch queue for submission from the inspector")

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button(confirmButtonTitle) {
                onConfirm(selectedDrafts, selectedMode)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.geminiAPIKey.isEmpty || selectedDrafts.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var selectionSummary: String {
        var parts = ["\(selectedDrafts.count) selected"]
        if selectedOverrideCount > 0 {
            parts.append("\(selectedOverrideCount) overridden")
        }
        if selectedLockedOverrideCount > 0 {
            parts.append("\(selectedLockedOverrideCount) locked")
        }
        return parts.joined(separator: " • ")
    }

    private var confirmButtonTitle: String {
        let count = selectedDrafts.count
        let base = selectedMode == .standard ? confirmTitle : "Add to Queue"
        guard count > 0 else { return base }
        return "\(base) (\(count))"
    }

    private var sharedModelBinding: Binding<GeminiModel> {
        Binding(
            get: { drafts.first?.model ?? .flash },
            set: { newValue in
                for index in drafts.indices {
                    drafts[index].model = newValue
                }
            }
        )
    }

    private var sharedAspectRatioBinding: Binding<String> {
        Binding(
            get: { drafts.first?.aspectRatio ?? aspectRatioOptions.first ?? "1:1" },
            set: { newValue in
                for index in drafts.indices {
                    drafts[index].aspectRatio = newValue
                }
            }
        )
    }

    private var sharedImageSizeBinding: Binding<String> {
        Binding(
            get: { drafts.first?.imageSize ?? imageSizeOptions.first ?? "1K" },
            set: { newValue in
                for index in drafts.indices {
                    drafts[index].imageSize = newValue
                }
            }
        )
    }

    private var sharedReferenceItems: [GeminiGenerationReferenceDraft] {
        drafts.first?.referenceItems ?? []
    }

    private func sharedReferenceBinding(at index: Int) -> Binding<GeminiGenerationReferenceDraft> {
        Binding(
            get: { sharedReferenceItems[index] },
            set: { newValue in
                for draftIndex in drafts.indices where drafts[draftIndex].referenceItems.indices.contains(index) {
                    drafts[draftIndex].referenceItems[index] = newValue
                }
            }
        )
    }

    private func addReferenceImages(to draftID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add Reference Images"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        for url in panel.urls {
            let item = GeminiGenerationReferenceDraft(
                label: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isIncluded: true
            )
            drafts[draftIndex].referenceItems.append(item)
        }
    }

    private func addSharedReferenceImages() {
        let panel = NSOpenPanel()
        panel.title = "Add Reference Images"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let item = GeminiGenerationReferenceDraft(
                label: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isIncluded: true
            )
            for draftIndex in drafts.indices {
                drafts[draftIndex].referenceItems.append(item)
            }
        }
    }

    private func removeReference(_ referenceID: UUID, from draftID: UUID) {
        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[draftIndex].referenceItems.removeAll { $0.id == referenceID }
    }

    private func removeSharedReference(_ referenceID: UUID) {
        for draftIndex in drafts.indices {
            drafts[draftIndex].referenceItems.removeAll { $0.id == referenceID }
        }
    }

    private func resolvedAbsoluteURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
