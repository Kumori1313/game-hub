# Visual System and Component Guide

This guide describes the hub and its matching first-party interfaces. Other games may use their own visual design; follow the [game development guide](game-development-guide.md) for routing, identity, and platform integration.

## Identity and layout

Game Hub uses an original board-and-path emblem and `public/art/playfield.svg`, an original SVG illustration created for this project. Both repositories own matching copies. The same artwork is cropped in the navigation strip and enlarged beside a short page title. No reference-site artwork, logos, fonts, or scripts are shipped. `UI-Ideas/` remains a local, ignored research folder.

The content layout pairs guest entry and game selection with a sticky desktop illustration. Below 760px it becomes a single column, with the illustration after the primary content. System sans-serif type supports controls, Georgia supplies editorial headings, and system monospace supplies compact annotations. No font downloads or animation packages are required.

## Shared files

| File | Responsibility |
| --- | --- |
| `index.html` | Apply saved theme synchronously before the first paint; dark fallback. |
| `src/style.css` | Theme tokens, layouts, reusable controls, responsive and reduced-motion rules. |
| `src/theme.js` | Labeled keyboard-accessible toggle, persistence, and cross-tab synchronization. |
| `src/illustration.js` | Preview moves driven by scrolling and verified guest state. |
| `src/main.js` | Site-specific composition, headings, and navigation links. |
| `public/art/playfield.svg` | Original navigation/banner artwork, served under each project base path. |

Keep presentation modules, stylesheet, artwork, and bootstrap behavior aligned across repositories. Site-specific text and destinations belong in each `main.js`.

## Color and theme contract

| Token | Use |
| --- | --- |
| `--page`, `--surface`, `--field` | Main background, raised content, and form inputs. |
| `--text`, `--muted` | Primary and supporting text. |
| `--accent`, `--accent-ink` | Primary actions and their foreground. |
| `--plum`, `--grid` | X marks and illustration grid. |
| `--line`, `--control-line`, `--focus`, `--error` | Separators, higher-contrast control boundaries, keyboard outlines, and validation feedback. |

Use `data-theme="dark"` or `data-theme="light"` on the document element. `game-hub-theme` stores the explicit choice; absent, invalid, or inaccessible storage defaults to dark. Both themes set the appropriate browser `color-scheme`. Navigation/banner retain a coordinated plum artwork treatment in either theme, with a light focus ring for legibility.

Theme changes update the document without rebuilding the guest UI. They must preserve entered text, UUIDs, editing state, and the selected screen. Storage failure affects persistence, not the page-local toggle. The theme has no dependency on the operating system’s color preference.

## Illustration and accessibility

The side board is labeled as an illustration rather than a playable match. Its five-move X win advances with page scrolling; confirmed guest readiness establishes a minimum preview step. The preview has no move counter, progress checklist, or explanatory captions. No live player counts, scores, or lobby statistics are invented.

An IntersectionObserver gates work to visible panels. Scroll/resize events schedule at most one pending animation frame, and hidden documents do not draw. No timer advances the preview automatically. Reduced-motion mode shows the final board without transitions and does not change the diagram as the user scrolls. Its static description remains available to assistive technology.

Use native links, buttons, labels, and inputs; preserve visible focus and the skip-to-entry link. Keep errors and connection updates in the existing alert/status regions. Names remain untrusted text and use `textContent`.

## Future screen sketches

The game site now implements lobby discovery and waiting rooms using this visual language. These sketches describe presentation; playable matches remain future roadmap work.

```text
LOBBY DISCOVERY
[Shared art navigation / theme toggle]
Compact game banner: Tic-Tac-Toe
Main column                         Side column
  Public lobbies                      Illustrated board
  [Create lobby]                      Game rules summary
  Host · 1/2 · Waiting [Join]          Two players · X starts
  Empty/loading/error states

WAITING ROOM
[Shared art navigation / theme toggle]
Lobby title                         Side column
  Host / X · connection state         Two seats diagram
  Guest / O · connection state        Steps to start
  [Start: host only] [Leave]

MATCH
[Shared navigation / theme toggle]
Current turn · your mark             Side column
  Accessible 3 × 3 board              Players and connection
  Result / interruption message       Match summary
  [Leave] / [Return to hub]
```

Use `.section-heading` and `.section-number` for grouping, `.game-card` for bounded content, `.button` for the main action, and `.secondary` for alternatives. Future functional boards must have their own accessible controls; never repurpose the decorative preview as a playable board.

## Verification

The browser suite covers both existing guest behavior and redesign behavior: dark default under a light OS preference, cross-site persistence, keyboard toggling, preserved input and identity, invalid/unavailable storage, reduced motion, scrolling, responsive layouts, artwork URLs, and text/action/error token contrast. Run using the hub README’s local or hosted commands.

Full-page screenshots cover both sites in light/dark at 1440px and 320px. Guest tests also exercise returning guests, editing, failed requests, offline recovery, and cleared sessions. Inspect representative screenshots after changes; contrast-token checks do not replace visual review of artwork, overlays, or controls.

## Interface copy

Keep the interface focused on entering a name, selecting a game, and playing. Use short, literal titles and action labels. Do not add slogans, promotional paragraphs, numbered onboarding summaries, or captions that explain an obvious control or illustration. Keep name constraints, actionable errors, and unavailable-feature notices where needed. Place secondary information, such as guest-identity persistence, in a collapsed disclosure. Banners retain their artwork but use compact page titles so they do not push controls below the first screen.

## Navigation while scrolling

The header stays visible at the top while browsing the hub and game lobbies. Scroll padding keeps anchor targets clear of it. During active game play, `body.match-playing` returns the game header to normal page flow so it scrolls away with the page. Sticky navigation resumes when the match finishes, is interrupted, or the player leaves. The match layout itself remains independent of this navigation state.
