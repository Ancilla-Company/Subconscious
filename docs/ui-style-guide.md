# Subconscious UI Style Guide

## Purpose and authority
This guide makes the existing Windows desktop application the visual authority for the Flutter desktop, web, mobile, and browser-extension clients. The shared `apps/shared_ui_kit` package is the implementation source of truth. Platform shell details may differ, but hierarchy, semantic color use, interaction behavior, labels, and core components must remain consistent.

## Design principles

1. **Focused work surface.** Chat, context, and main work areas are distinct, resizable desktop panels. Mobile and extension variants present the same information one task at a time.
2. **Quiet, structured interface.** Use Material 3 surfaces, fine `outlineVariant` dividers, compact controls, and minimal elevation. Do not introduce heavy card shadows, gradients, or rounded dashboard chrome.
3. **System-like precision.** Desktop forms use compact density, 3 px field/button radii, 32 px small action controls, and clear text labels. Icons supplement, never replace, essential labels.
4. **Explicit engine state.** Show connected, connecting, and disconnected status; disable dependent actions rather than allowing ambiguous failures.
5. **Accessible by construction.** Every icon button requires a tooltip and semantic label; support keyboard navigation, visible focus, text scaling, dark mode, and sufficient color contrast.

## Tokens

Implement semantic tokens in `apps/shared_ui_kit`, rather than hard-coding values in features.

| Token | Existing authority | Use |
|---|---|---|
| `AppColors.seed` | `#7C6FE0` | Default accent / Material seed |
| `AppColors.surface` | `#F8F7FC` | Preferred light application surface |
| `AppColors.onSurface` | `#211F2B` | Preferred light foreground |
| `ColorScheme.surface` | Generated Material 3 scheme | Base panel and scaffold surface |
| `ColorScheme.surfaceContainerLowest` | Generated Material 3 scheme | Compact field and toolbar-button fill |
| `ColorScheme.outlineVariant` | Generated Material 3 scheme | 1 px separators and resting field borders |
| `ColorScheme.secondaryContainer` | Generated Material 3 scheme | Selected navigation item |
| `ColorScheme.onSecondaryContainer` | Generated Material 3 scheme | Selected navigation icon and text |

Accent choices are Device/default, neutral, blue, purple, green, orange, and red. The neutral choice uses a monochrome scheme. Accent colors affect emphasis only; they must not be the sole indicator of selected, error, or connection state.

### Geometry and density

| Element | Standard |
|---|---|
| Desktop icon rail | 40 px wide; 40 px square actions; 20 px icons |
| Compact toolbar action | 32 px square with 1 px outline |
| Desktop form fields | Dense, filled, 10 px horizontal and 8 px vertical padding, 3 px radius |
| Main settings content | 24/28/24/32 px outer inset; 750 px maximum readable width |
| Standard divider | 1 px `outlineVariant` |
| Desktop resize divider | 5 px hit area with a centered 1 px `outlineVariant` line |
| Wide breakpoint | 720 logical px |
| Desktop side panels | Chat 140–600 px; context 180–600 px; main panel at least 300 px |

### Typography and icons

Use the Material 3 text theme for all body, title, label, and error styles. Use `titleMedium` for section/flyout headers and `labelMedium` for compact status text. Use Fluent UI System Icons from `fluentui_system_icons`; ordinary state is regular and selected state is filled. Do not hard-code font families or manually recreate the type scale.

## Desktop and wide-web composition

The desktop layout contains, from top to bottom:

1. A native/window composition bar where applicable.
2. A 1 px top rule above the workspace.
3. A 40 px icon rail placed on the configured left or right edge.
4. A row of context, chat, and main panels in user-selected order.
5. 5 px drag separators between panels.

The main panel expands. Chat and context panels retain user-adjustable widths. When all panels are hidden, center the monochrome Subconscious mark at 88 px; do not present a blank page.

## Mobile and browser extension composition

Below 720 px, use a compact app bar with the menu trigger, `Subconscious` title, and connection status. The flyout is the authoritative narrow navigation model and is also the required browser-extension model:

- A 40 px icon rail on the left: Subconscious mark, Workspaces, Threads, Files, Settings, Account.
- A 1 px divider.
- A contextual navigation pane headed `Subconscious`.
- Selecting an item closes the flyout and shows a single focused destination.

The extension popup should be 400 px wide by default, adapt down to 320 px, and use this flyout rather than an independent tab bar. When room is insufficient, the contextual pane is replaced by the focused destination after selection. Extension options use the existing mobile settings screen. The extension must never expose a desktop multi-panel layout in the popup.

## Components and states

- **Navigation:** selected state uses `secondaryContainer`; no rounded selection pills in the icon rail.
- **Forms:** use dense, filled outline fields and compact controls. Invalid data receives an inline message and programmatic error semantics.
- **Panels:** panel backgrounds are `surface`; boundaries are separators, not elevated cards.
- **Connection:** show a status dot plus text (`connected`, `connecting`, `disconnected`). Use green, amber, and red respectively, with text and semantics.
- **Loading:** use centered circular progress where a panel is unavailable, and linear progress for in-place settings loading.
- **Errors:** retain the surface, show a concise actionable message with appropriate retry/reconnect action.
- **Empty states:** use direct guidance and the logo only for the fully hidden desktop-panel state.
- **Destructive actions:** require explicit confirmation and show progress while requests are in flight.

## Responsive and platform rules

All clients share models, API behavior, feature availability, terminology, themes, and settings. Windows retains native title-bar composition and desktop density. Web follows wide or narrow layout based on viewport. Android follows narrow layout. TUI is intentionally text-first but shares command names, status labels, validation, and information hierarchy; its color palette maps to the semantic state colors above.

## Implementation rules

- Move reusable color, spacing, radius, and component defaults to `shared_ui_kit` before introducing new feature-level values.
- Prefer `Theme.of(context).colorScheme` and `textTheme` to raw `Color` and `TextStyle` values.
- Add stable `ValueKey` identifiers for Selenium-visible controls and test states; do not use visible copy as the primary E2E selector.
- Do not add a browser-extension-only visual language. Reuse the mobile flyout and shared component styles.
- Every new state needs light, dark, and narrow-layout coverage.
