# 34 — Adapter Interface Pseudocode

Date: 2026-03-31

## Purpose
Express the future adapter layer in code-like terms without touching the live app.

## PackageManifestAdapter
```swift
protocol PackageManifestAdapter {
    func loadManifest(at url: URL) throws -> VNextCharacterPackage
    func resolveDefaultCostume(for package: VNextCharacterPackage) -> CostumePack?
    func resolveMouthProfile(id: String, in package: VNextCharacterPackage) -> MouthProfile?
}
```

## MotionPlanAdapter
```swift
protocol MotionPlanAdapter {
    func decodePlan(at url: URL) throws -> MotionPlan
    func validate(plan: MotionPlan, against package: VNextCharacterPackage) -> [MotionPlanIssue]
    func emitRuntimeInstructions(plan: MotionPlan) -> [RuntimeInstruction]
}
```

## MouthOverlayAdapter
```swift
protocol MouthOverlayAdapter {
    func decodeProfile(at url: URL) throws -> MouthProfile
    func buildOverlayEvents(from lyricPlan: LyricMouthPlan, profile: MouthProfile) -> [MouthOverlayEvent]
    func resolveAnchor(for angleFamily: String, profile: MouthProfile) -> MouthAnchor
}
```

## AssetReviewAdapter
```swift
protocol AssetReviewAdapter {
    func decodeReview(at url: URL) throws -> AssetReviewResult
    func nextAction(for review: AssetReviewResult) -> ReviewAction
    func isPromotionEligible(_ review: AssetReviewResult) -> Bool
}
```

## ReadinessAdapter
```swift
protocol ReadinessAdapter {
    func score(package: VNextCharacterPackage) -> ReadinessScore
    func status(from score: ReadinessScore) -> PackageReadinessStatus
}
```

## Principle
The adapters should hide schema complexity from the rest of the future runtime.
