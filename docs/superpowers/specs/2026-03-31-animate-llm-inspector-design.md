# Animate LLM Inspector — Design Spec

**Date:** 2026-03-31
**Status:** Draft

## Overview

Add an LLM chat tab to the Animate page's right-hand inspector pane, giving full natural language control over character asset generation, prompt editing, and workflow management. The LLM uses the same providers and chat infrastructure as the Write page's existing LLM feature.

## Architecture

### Module Structure

Extract shared LLM infrastructure from WriteUI into ProjectKit so both WriteUI and AnimateUI can use it without cross-importing:

**Move to ProjectKit:**
- `LLMProviderConfig` — singleton managing provider/model selection, API keys, UserDefaults persistence
- `MiniMaxClient` — multi-provider chat client with streaming (MiniMax, OpenCode, Claude CLI)
- `MiniMaxMessage` — chat message model
- `LLMChatSession` — session persistence model (id, title, messages, timestamps)
- `AgentProcessManager` — Claude CLI process spawning
- Chat session file I/O (save/load JSON from project directory)

**Keep in WriteUI:**
- `LLMInspectorView` — Write-specific chat UI with suggestion parsing and libretto integration
- `LLMSuggestion`, `LLMUndoEntry` — Write-specific suggestion/undo models
- Write-specific system prompt construction

**New in AnimateUI:**
- `AnimateLLMInspectorView` — Animate-specific chat UI tab
- `AnimateLLMAgent` — action parsing, system prompt construction, store integration
- `AnimateLLMAction` — parsed action model

### Inspector Layout Change

The Animate inspector pane changes from a flat view to a tabbed layout:

- **LLM tab** — full-height chat interface (input at bottom, messages scrolling above)
- **Properties tab** — existing inspector content (rig settings, timeline cues, canvas render options)

Tab selection persisted via `@AppStorage("animate.inspector.selectedTab")`.

The LLM tab label and styling match the Write page's LLM tab exactly.

## Chat Scoping

Two modes, toggled via a segmented control at the top of the LLM tab:

- **Character mode** — conversation scoped to the currently selected character. System prompt includes that character's full context. Switching characters switches conversations.
- **Show mode** — conversation spans all characters. System prompt includes summary status for all characters. Useful for cross-character operations.

### Session Persistence

Chat sessions saved to the OWP project directory:

```
Project.owp/
  Animate/
    ChatHistory/
      {character-slug}.json        # Character-mode sessions
      __show__.json                # Show-mode session
      {slug}__{timestamp}.json     # Archived sessions
```

One `MiniMaxClient` instance per active session key (character slug or "__show__").

## System Prompt Construction

### Character Mode

Dynamic system prompt built from AnimateStore state:

```
You are an assistant for character asset generation in an animation production tool.
You are currently working on: {character.name} ({character.genderType}, age {character.age}).
Wardrobe type: {character.defaultWardrobeType}.

Current workflow status:
- Inspiration images: {count} total, {curatedCount} curated
- Inspiration reference image: {set or not set}
- Master reference sheet: {approved/not approved, N variants}
- Head turnaround sheet: {approved/not approved}
- Head poses: {N}/6 approved
- Costumes: {list each costume set with approval status}

Current prompts:
- Master sheet prompt: {full text}
- Head sheet prompt: {full text}
- {For each costume}: {costume name} sheet prompt: {full text}

You can take actions by including [ACTION] blocks in your response.
Free actions (execute immediately):
  [ACTION type="edit_prompt" target="{target}"] new prompt text [/ACTION]
  [ACTION type="toggle_curated" file="{filename}"] [/ACTION]
  [ACTION type="set_reference" file="{filename}"] [/ACTION]
  [ACTION type="approve_variant" target="{target}" index="{N}"] [/ACTION]
  [ACTION type="update_character" field="{field}" value="{value}"] [/ACTION]

Paid actions (require user confirmation via preflight):
  [ACTION type="generate" target="{target}" count="{N}"] [/ACTION]
  [ACTION type="batch_submit" wardrobe="{soldier|civilian}" count="{N}"] [/ACTION]

Targets: master_sheet, head_sheet, head_slot:{pose}, costume_sheet:{name}, costume_slot:{costume}:{pose}, accessory:{costume}:{name}, inspiration

When editing prompts, output the COMPLETE replacement prompt text inside the ACTION block.
When the user asks to generate something, determine the correct target and count.
For questions about status, respond conversationally without action blocks.

Keep responses concise — this is an inspector panel, not a full-page chat.
```

### Show Mode

System prompt includes a summary table of all characters and their workflow completion status, plus the ability to loop actions across characters.

## Action Parsing

After streaming completes, the app scans the full response for `[ACTION]...[/ACTION]` blocks using regex.

### AnimateLLMAction Model

```swift
struct AnimateLLMAction {
    enum ActionType {
        case editPrompt(target: PromptTarget, newPrompt: String)
        case generate(target: GenerationTarget, count: Int)
        case batchSubmit(wardrobe: CharacterWardrobeType, count: Int)
        case toggleCurated(filename: String)
        case setReference(filename: String)
        case approveVariant(target: String, index: Int)
        case updateCharacter(field: String, value: String)
    }

    var type: ActionType
    var characterID: UUID  // resolved from current selection or show-mode context
}
```

### Prompt Targets

```swift
enum PromptTarget {
    case masterSheet
    case headSheet
    case headSlot(CharacterReferencePose)
    case costumeSheet(costumeName: String)
    case costumeSlot(costumeName: String, pose: CharacterReferencePose)
    case accessory(costumeName: String, accessoryName: String)
}
```

### Generation Targets

```swift
enum GenerationTarget {
    case masterSheet
    case headSheet
    case headPoses       // all 6
    case costumeSheet(costumeName: String)
    case costumePoses(costumeName: String)  // all 6
    case accessory(costumeName: String, accessoryName: String)
    case inspiration
}
```

## Action Execution

### Free Actions (immediate)

1. Parse action block
2. Execute against AnimateStore (e.g., `store.updateMasterReferenceSheetPrompt(newText, for: characterID)`)
3. Append a system message to the chat: "Updated master sheet prompt"
4. Store previous value for undo capability

### Paid Actions (preflight)

1. Parse action block
2. Build `[GeminiGenerationDraft]` array from the target/count
3. Present `GeminiGenerationPreflightSheet` with the drafts pre-populated
4. User confirms or cancels
5. On confirm: execute generation, results appear in character workflow as usual
6. Append system message: "Generated 3 master sheet variants" or "Cancelled"

### Undo

Each free action records an `AnimateLLMUndoEntry` with:
- Action description
- Previous value (prompt text, curated state, etc.)
- Timestamp

User can say "undo that" or "revert the last change" and the LLM emits an undo action, or the app provides an undo button on action confirmation messages.

## Chat UI

### AnimateLLMInspectorView

Matches Write page's `LLMInspectorView` layout:

- **Top bar:** Character/Show mode segmented control, session management (new/archive)
- **Message list:** Scrolling conversation with:
  - User messages (right-aligned, accent color bubble)
  - LLM responses (left-aligned, secondary bubble)
  - Action confirmations (inline system messages with icon: checkmark for executed, xmark for cancelled)
  - Streaming indicator during generation
- **Input area:** Text field at bottom with send button, model indicator

### Provider & Model Selection

Uses the shared `LLMProviderConfig` singleton — same provider/model picker as the Write page. Changing the provider on either page changes it everywhere.

## Comprehensive Action Coverage

The LLM handles every Animate store operation through natural language:

### Character Data
- Create/rename characters
- Update gender, age, wardrobe type
- Edit backstory, personality, notes

### Inspiration Images
- Toggle curation on images (by filename or description like "the third one")
- Set inspiration reference image
- Remove images from the gallery
- Describe what kind of inspiration images to generate

### Master Sheet
- Edit prompt (full replacement or targeted modifications like "add more emphasis on X")
- Generate N variants
- Approve a specific variant

### Head Turnarounds
- Edit head sheet prompt
- Edit individual head pose prompts
- Generate head sheet or individual poses
- Approve variants

### Costumes
- Edit costume sheet prompt
- Edit individual full-body pose prompts
- Edit accessory prompts
- Generate costume sheets, full-body poses, accessories
- Approve variants
- Modify costume notes/descriptions

### Batch Operations
- Submit inspiration batches (soldier/civilian)
- Cross-character operations in show mode (generate for all, status queries)

### Workflow Queries
- "What's the status of Luke's workflow?"
- "Which characters need master sheets?"
- "How many curated images does Yasmin have?"
- "Show me the current military costume prompt for Johnny"

## Files to Create/Modify

### New Files
- `Packages/ProjectKit/Sources/ProjectKit/LLM/LLMProviderConfig.swift`
- `Packages/ProjectKit/Sources/ProjectKit/LLM/LLMClient.swift` (renamed from MiniMaxClient)
- `Packages/ProjectKit/Sources/ProjectKit/LLM/LLMChatSession.swift`
- `Packages/ProjectKit/Sources/ProjectKit/LLM/LLMMessage.swift`
- `Packages/ProjectKit/Sources/ProjectKit/LLM/AgentProcessManager.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimateLLMAgent.swift`
- `Packages/Animate/Sources/AnimateUI/Views/AnimateLLMInspectorView.swift`

### Modified Files
- `Packages/ProjectKit/Package.swift` — no new dependencies needed (URLSession + Process)
- `Packages/Animate/Package.swift` — already depends on ProjectKit
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift` — add tab layout, LLM tab
- `Sources/WriteUI/Views/LLMInspectorView.swift` — update imports from local to ProjectKit
- `Sources/WriteUI/Services/` — remove moved files, update imports
- `Package.swift` (root) — WriteUI dependency on ProjectKit already exists

### Not Modified
- Write page LLM behavior — zero functional changes, only import path updates
- AnimateStore — LLM agent calls existing public methods, no new store APIs needed
- GeminiImageService — generation pipeline unchanged
- GeminiGenerationPreflightSheet — reused as-is for paid action confirmation

## Success Criteria

1. Natural language commands produce correct prompt edits and generation requests
2. Every generation request goes through the preflight sheet before spending credits
3. Chat history persists across app restarts
4. Character-scoped and show-wide modes work independently
5. Write page LLM continues to work identically after the refactor
6. Streaming responses feel responsive in the inspector panel
7. Action confirmations are clearly visible in the chat history
