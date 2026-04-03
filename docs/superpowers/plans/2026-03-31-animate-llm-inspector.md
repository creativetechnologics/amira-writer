# Animate LLM Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-height LLM chat tab to the Animate inspector, giving natural language control over all character asset generation, prompt editing, and workflow management.

**Architecture:** Extract shared LLM infrastructure (provider config, chat client, persistence) from WriteUI into ProjectKit. Build an Animate-specific agent layer that translates natural language to AnimateStore actions via [ACTION] block parsing. Integrate as a new tab in a tabbed inspector layout.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26), URLSession streaming, Process (Claude CLI), ProjectKit shared module

---

### Task 1: Extract LLM types into ProjectKit

**Files:**
- Create: `Packages/ProjectKit/Sources/ProjectKit/LLMProviderConfig.swift`
- Create: `Packages/ProjectKit/Sources/ProjectKit/LLMMessage.swift`
- Create: `Packages/ProjectKit/Sources/ProjectKit/LLMClient.swift`
- Create: `Packages/ProjectKit/Sources/ProjectKit/LLMChatPersistence.swift`
- Create: `Packages/ProjectKit/Sources/ProjectKit/AgentProcessManager.swift`

Move the following from WriteUI into ProjectKit with these changes:
- `LLMProviderConfig.swift` — copy as-is from `Sources/WriteUI/Services/LLMProviderConfig.swift`
- `LLMMessage.swift` — extract `MiniMaxMessage` (rename to `LLMMessage`) and `LLMChatSession` (remove the `suggestions: [LLMSuggestion]?` field since that's Write-specific; make it `Any`-typed metadata or just drop it)
- `LLMClient.swift` — copy `MiniMaxClient` class, rename to `LLMClient`, remove Write-specific suggestion parsing. Keep streaming, provider switching, Claude CLI support.
- `LLMChatPersistence.swift` — extract the `LLMChatPersistence` enum
- `AgentProcessManager.swift` — copy as-is

Key decisions for the extraction:
- `LLMChatSession.suggestions` is Write-specific (`[LLMSuggestion]`). In ProjectKit, make it `additionalData: Data?` (opaque JSON blob) so Write can still persist suggestions and Animate can persist action history.
- `MiniMaxClient` rename to `LLMClient`. The class name is misleading since it supports 3 providers.
- Keep `LLMSuggestion` in WriteUI — it's libretto-specific.

- [ ] **Step 1:** Create `Packages/ProjectKit/Sources/ProjectKit/LLMProviderConfig.swift` — copy from WriteUI, add `@available(macOS 26.0, *)`, add `import Foundation` only (no AppKit/SwiftUI)
- [ ] **Step 2:** Create `Packages/ProjectKit/Sources/ProjectKit/LLMMessage.swift` — extract `MiniMaxMessage` renamed to `LLMMessage`, `LLMChatSession` with `additionalData: Data?` instead of `suggestions`
- [ ] **Step 3:** Create `Packages/ProjectKit/Sources/ProjectKit/LLMChatPersistence.swift` — extract persistence enum using new `LLMChatSession` type
- [ ] **Step 4:** Create `Packages/ProjectKit/Sources/ProjectKit/AgentProcessManager.swift` — copy as-is
- [ ] **Step 5:** Create `Packages/ProjectKit/Sources/ProjectKit/LLMClient.swift` — copy MiniMaxClient, rename to LLMClient, use `LLMMessage` instead of `MiniMaxMessage`, remove `parseSuggestions()` method (keep it in WriteUI as an extension or local helper)
- [ ] **Step 6:** Verify ProjectKit builds: `swift build --package-path Packages/ProjectKit`
- [ ] **Step 7:** Commit: "feat: extract shared LLM infrastructure into ProjectKit"

### Task 2: Update WriteUI to use ProjectKit LLM types

**Files:**
- Modify: `Sources/WriteUI/Services/LLMProviderConfig.swift` — replace with `@_exported import` or typealias
- Modify: `Sources/WriteUI/Services/MiniMaxClient.swift` — replace with typealias to `LLMClient`, keep suggestion parsing as local extension
- Modify: `Sources/WriteUI/Views/LLMInspectorView.swift` — update type references
- Modify: `Sources/WriteUI/ScriptStore.swift` — update any LLM type references

- [ ] **Step 1:** In WriteUI's `LLMProviderConfig.swift`, replace the full file with: `import ProjectKit` + `public typealias LLMProviderConfig = ProjectKit.LLMProviderConfig` (and similar for each type) — OR just delete the file and let WriteUI import from ProjectKit
- [ ] **Step 2:** In WriteUI's `MiniMaxClient.swift`, keep `LLMSuggestion`, suggestion parsing, and undo types. Replace `MiniMaxMessage` references with `LLMMessage`. Add `typealias MiniMaxMessage = LLMMessage` for backward compat if needed. Replace `MiniMaxClient` with import from ProjectKit + extension for suggestion parsing.
- [ ] **Step 3:** Update `LLMInspectorView.swift` imports
- [ ] **Step 4:** Verify full app builds: `swift build --product Opera`
- [ ] **Step 5:** Verify Write page LLM still works (manual test)
- [ ] **Step 6:** Commit: "refactor: WriteUI uses shared LLM types from ProjectKit"

### Task 3: Build AnimateLLMAgent

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/AnimateLLMAgent.swift`

This is the "brain" that builds system prompts and parses action blocks.

- [ ] **Step 1:** Create `AnimateLLMAgent.swift` with:
  - `AnimateLLMAction` enum (editPrompt, generate, batchSubmit, toggleCurated, setReference, approveVariant, updateCharacter)
  - `AnimateLLMPromptTarget` enum
  - `AnimateLLMGenerationTarget` enum
  - `buildSystemPrompt(character:store:mode:)` function
  - `buildShowSystemPrompt(store:)` function
  - `parseActions(from response:characterID:)` function using regex for `[ACTION]...[/ACTION]` blocks
  - `executeAction(_:on store:)` function for free actions
  - `buildPreflightDrafts(for action:store:)` function for paid actions

- [ ] **Step 2:** Implement `buildSystemPrompt` — includes character name, gender, age, wardrobe, workflow status, current prompts, action format instructions
- [ ] **Step 3:** Implement `parseActions` — regex scan for `[ACTION type="..." ...]...[/ACTION]` blocks, parse attributes, return `[AnimateLLMAction]`
- [ ] **Step 4:** Implement `executeAction` for free actions — switch on type, call appropriate AnimateStore methods
- [ ] **Step 5:** Implement `buildPreflightDrafts` for paid actions — construct `[GeminiGenerationDraft]` arrays from generation targets
- [ ] **Step 6:** Verify Animate package builds
- [ ] **Step 7:** Commit: "feat: add AnimateLLMAgent for natural language action parsing"

### Task 4: Build AnimateLLMInspectorView

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/AnimateLLMInspectorView.swift`

- [ ] **Step 1:** Create the view struct matching LLMInspectorView pattern:
  - `@Bindable var store: AnimateStore`
  - `@State private var clients: [String: LLMClient]`
  - `@State private var inputText: String`
  - `@AppStorage("animate.llm.chatScope")` for character/show toggle
  - Session key: character's `assetFolderSlug` or `"__show__"`
  - Client creation with session loading from `{project}/Animate/ChatHistory/`

- [ ] **Step 2:** Build the body layout:
  - Top: segmented control (Character / Show)
  - Middle: ScrollView with message list (ScrollViewReader for auto-scroll)
  - Bottom: text input + send button + model indicator

- [ ] **Step 3:** Implement `sendMessage()`:
  - Build system prompt via AnimateLLMAgent
  - Call `client.send()` with streaming
  - After streaming completes, parse actions
  - Execute free actions immediately, show confirmations inline
  - For paid actions, set preflight state

- [ ] **Step 4:** Add message bubble views (user right-aligned, assistant left-aligned, system messages centered)
- [ ] **Step 5:** Add action confirmation messages (checkmark icon for executed, cost icon for preflight-pending)
- [ ] **Step 6:** Add session management (new session, archive)
- [ ] **Step 7:** Add preflight sheet presentation for paid actions
- [ ] **Step 8:** Verify Animate package builds
- [ ] **Step 9:** Commit: "feat: add AnimateLLMInspectorView chat interface"

### Task 5: Update Animate InspectorView with tabs

**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

- [ ] **Step 1:** Add tab enum and @AppStorage for selected tab:
  ```swift
  enum InspectorTab: String { case llm, properties }
  @AppStorage("animate.inspector.selectedTab") private var selectedTab = InspectorTab.llm.rawValue
  ```

- [ ] **Step 2:** Wrap existing inspector body in a tab container:
  - Tab bar at top with "LLM" and "Properties" labels
  - LLM tab: `AnimateLLMInspectorView(store: store)`
  - Properties tab: existing inspector content

- [ ] **Step 3:** Verify Animate package builds
- [ ] **Step 4:** Full app build and deploy
- [ ] **Step 5:** Commit: "feat: tabbed Animate inspector with LLM chat"

### Task 6: Integration testing and polish

- [ ] **Step 1:** Test character-scoped chat (select character, send message, verify context)
- [ ] **Step 2:** Test show-wide chat (verify all characters listed in context)
- [ ] **Step 3:** Test prompt editing via natural language (verify prompt updates in workflow)
- [ ] **Step 4:** Test generation request (verify preflight sheet appears)
- [ ] **Step 5:** Test session persistence (restart app, verify chat history loads)
- [ ] **Step 6:** Test Write page LLM still works after refactor
- [ ] **Step 7:** Build and deploy to laptop
- [ ] **Step 8:** Commit: "feat: Animate LLM inspector integration complete"
