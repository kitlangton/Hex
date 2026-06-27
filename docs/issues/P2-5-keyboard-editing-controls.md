# [P2-5] Keyboard in-place editing controls (control surface)

- **Phase:** 2 — Keyboard + IPC
- **Depends on:** P2-2 (basic dictate keyboard)
- **Blocks:** —
- **Size:** M
- **Status:** TODO (design captured here; not yet built)

> Split out of [P2-2](P2-2-keyboard-ui.md) so it can be designed/built independently of the
> locked screens spec ([ios-ui-design-v1.md](../ios-ui-design-v1.md)). This issue owns
> everything about **editing text from inside the Hex keyboard** without switching keyboards.

## Problem

A single big mic button is poor for *small* fixes (a stray word, a missing comma). But
forcing a switch to the system keyboard for those edits is exactly the friction that kills
keyboard apps.

## Core principle (LOCKED)

**Never show a letter layout that differs from the native keyboard.** Even subtle QWERTY
differences wreck typing muscle memory. Hex builds **no** alternate typing keyboard.
Everything Hex adds is either dictation or a **letter-free control surface** built from
patterns users already know. The **globe** key always hands off to the real system keyboard
for genuine free-typing.

## Design (proposed)

Two **letter-free** panels, **swiped horizontally** (page-dot indicator):

- **Panel 1 — Dictate:** the basic dictate keyboard (owned by P2-2).
- **Panel 2 — Controls:** a caret **trackpad** (mirrors the native hold-and-drag-spacebar
  gesture — zero new learning), **delete-word**, **undo/redo**, and a **punctuation/symbols**
  cluster (conceptually the familiar native "123" layer). No letters.

## Tasks

- [ ] Add a swipeable second panel ("Controls") to the keyboard with a page-dot indicator.
- [ ] Caret **trackpad** via `adjustTextPosition(byCharacterOffset:)` — tune drag
      sensitivity/acceleration against a real text field (this is the highest-value, most
      feel-sensitive control).
- [ ] Delete-word (repeat `deleteBackward` back to the previous boundary); undo/redo.
- [ ] Punctuation + symbols cluster via `insertText`.
- [ ] Keep memory minimal (no ML model in the extension).

## Nice-to-have (not required for V1)

- [ ] **Replace-by-voice:** when the user has selected a word **in their own app**, read
      `selectedText` and let dictation replace it. (The keyboard cannot create selections —
      selection is user-driven.) Keep it simple for now; only build if it proves useful.

## Acceptance criteria

- [ ] Swipe toggles Dictate ⇄ Controls; caret trackpad, delete-word, and punctuation all work
      in a real text field **without switching keyboards**.
- [ ] No letter layout is ever shown (globe hands off to the native keyboard for typing).
- [ ] Renders clearly in light and dark mode; stays under the extension memory budget.

## Files
- `HexIOSKeyboard/` — second panel view + control handlers.
