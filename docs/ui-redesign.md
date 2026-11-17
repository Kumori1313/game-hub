# UI Redesign Brief

## Placement and goal

Phase 3.5 substantially redesigns the hub and tic-tac-toe entry experience before Phase 4 adds lobbies. Preserve existing roadmap numbering and the verified guest-session behavior. This document defines the direction; it does not change the published interface.

## Reference observations

The supplied CentOS screenshot shows a full-width illustrated navigation strip and a large mission banner using related artwork. Its recognizable mark, repeated visual treatment, and strong opening statement make the top of the page feel like one composition. Adopt that relationship for Game Hub with original artwork and a mark that works at navigation size.

The supplied AI 2027 screenshot shows an ivory background, dark serif editorial text, generous spacing, restrained borders, and a separate column of compact diagrams, labels, and green accents. The [live site](https://ai-2027.com/) is accessible; the user’s screenshot remains the reference for the requested arrangement. A still screenshot establishes the composition, while the requested dynamic behavior is specified below.

Saved references live in `UI-Ideas/`, which is intentionally ignored by Git. Keep the brief and original implementation assets tracked. Do not make deployed pages depend on ignored reference files or reuse the saved site's scripts.

## Proposed visual direction

- **Identity:** explore a Game Hub emblem built from intersecting paths, board cells, and X/O forms. Create coordinated artwork for the navigation and banner rather than using the CentOS mark or artwork.
- **Palette:** make dark mode the default, with deep charcoal surfaces and light text. Provide a light mode using warm ivory surfaces and near-black text. Explore plum artwork for the navigation/banner and muted green accents in both modes. Exact colors are prototype choices.
- **Typography:** use a prominent editorial heading style with readable body text and compact labels for status information. Start with system font stacks; introduce font assets only when their benefit is clear.
- **Composition:** replace the current stack of dark cards with an illustrated opening section, a clear guest-entry/game-choice area, and a supporting visual column in both themes. Keep the primary action easy to find.

## Light and dark modes

Dark mode is the first-visit default, regardless of the operating system’s color preference. Provide an accessible, clearly labeled theme toggle in the top navigation on both sites. A user’s explicit selection overrides the default and persists across reloads and navigation between the hub and game using the same origin-wide storage key, `game-hub-theme` (`dark` or `light`). If storage is unavailable or its value is invalid, use dark mode and keep the toggle functional for the current page.

Apply the stored theme before the page first paints to avoid a flash of the wrong colors. Set the corresponding browser `color-scheme` so native controls match. Define shared semantic color tokens for surfaces, text, borders, actions, focus, errors, and illustrations. Adapt the artwork and side visuals to both palettes; preserve contrast, status meaning, and legibility in each. Theme changes must not reset guest identity, form input, or the current screen.

## Navigation and mission banner

Use the original emblem and a restrained crop of the banner art in the top navigation. Include links only to implemented destinations, such as the hub and game selection. Keep the current guest identity/change-name action easy to reach after entry.

Make the opening banner a substantial visual element. Pair original art with a short mission statement about easy multiplayer games with friends. Draft copy: “Small games. Shared moments.” Supporting copy can explain that guests pick a name and play together without an account. Preserve honest availability messaging while lobbies and matches are still being built.

The art must remain recognizable and the text readable at desktop and phone widths. Do not place detailed imagery directly beneath form fields or critical status messages.

## Dynamic side visuals

Use a sticky desktop panel next to the main content, drawing on AI 2027’s diagram-and-label composition. Build an original illustrated tic-tac-toe board with connecting paths and small annotations. Let scrolling advance a short demonstration, and let confirmed guest-entry state highlight the next relevant step.

Label the board as an illustration or preview. Do not invent player counts, available lobbies, scores, or other live statistics. Until gameplay exists, a preview must not appear to be a playable match.

Prefer lightweight SVG/CSS and browser-native animation. Update scroll effects through a bounded animation loop or observers, pause work when offscreen or hidden, and avoid unnecessary dependencies. Decorative visuals must not intercept pointer input, enter the keyboard order, or produce repeated screen-reader announcements.

For narrow screens, move the panel below the primary content or reduce it to a compact illustration. Respect `prefers-reduced-motion`: provide a stable illustration and meaningful text without parallax, pulsing, or automatic transitions. If any motion runs automatically for more than five seconds, provide a pause control.

## Scope across both repositories

Apply matching design tokens, navigation treatment, forms, buttons, focus states, and connection messages to the hub and game site. Keep their code in their respective repositories. Document the matching styles and assets before future shared-package extraction.

Sketch how the visual language extends to public lobby lists, waiting rooms, and the match board, without implementing Phase 4 or Phase 6 behavior early. Changing the design must preserve the Supabase project, `game-hub-auth` storage key, guest UUID continuity, and safe display-name rendering.

## Acceptance criteria

- [ ] Desktop and mobile previews show original, related artwork in navigation and mission banner.
- [ ] Layout, typography, and side visuals form one coherent design in both light and dark modes.
- [ ] First visits default to dark mode; the labeled toggle works with keyboard and assistive technology.
- [ ] Explicit theme choices persist across reloads and hub/game navigation without a wrong-theme flash.
- [ ] Invalid or unavailable storage falls back to dark mode; switching themes preserves guest identity and unsaved input.
- [ ] Guest entry and game selection remain the primary actions; unfinished features are clearly identified.
- [ ] Side visuals respond to scrolling or guest progress without implying fabricated live data.
- [ ] At 320px, content and controls fit without horizontal scrolling or visual overlap.
- [ ] Keyboard navigation, visible focus, status/error announcements, and readable contrast are preserved.
- [ ] Reduced-motion behavior and any required pause control work without hiding essential information.
- [ ] Existing unit tests and guest-session browser tests pass locally and on both published sites.
- [ ] Visual checks cover entry, returning guest, name editing, offline/error states, desktop, mobile, and both themes.

## Implementation order

1. Create a visual prototype with the original mark, artwork, mission banner, and desktop side panel.
2. Review the composition at desktop and phone widths, including both themes and reduced motion.
3. Apply the chosen treatment to both entry flows and sketch the future lobby/match layouts.
4. Verify accessibility, guest behavior, and asset paths before deployment.
