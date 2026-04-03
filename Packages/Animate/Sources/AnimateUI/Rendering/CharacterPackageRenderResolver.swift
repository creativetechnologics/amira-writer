import Foundation

@available(macOS 26.0, *)
struct CharacterPackageRenderResolver: Sendable {
    private let library = CharacterPackageLibrary()
    private let assembler = CharacterPackageRigAssembler()
    private let selectionStore = CharacterPackageSelectionStore()

    func resolveRenderPlan(
        for character: AnimationCharacter,
        animateURL: URL?,
        selection: CharacterRenderSelectionContext? = nil
    ) -> CharacterPackageResolvedRenderPlan? {
        guard let animateURL else { return nil }

        let explicitActivePackageID = selectionStore.activePackageID(for: character.owpSlug, in: animateURL)
        let packages = library.installedPackages(
            for: character.owpSlug,
            in: animateURL,
            preferredActivePackageID: explicitActivePackageID
        )

        if let explicitActivePackageID,
           let activePackage = packages.first(where: { $0.id == explicitActivePackageID }) {
            return assembler.assemble(character: character, package: activePackage, selection: selection)
        }

        for package in packages {
            if let renderPlan = assembler.assemble(character: character, package: package, selection: selection) {
                return renderPlan
            }
        }

        return nil
    }
}
