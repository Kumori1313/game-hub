# Repository Guidelines

## Project Structure & Module Organization

This repository is currently in the planning stage. `multiplayer_game_hub_roadmap.md` defines the proposed architecture, phased work, and release milestones; `LICENSE` contains the MIT license. No application source, test suite, or asset directories exist yet.

The planned hub runs on GitHub Pages, with individual games maintained in separate repositories. Firebase anonymous authentication and Realtime Database provide guest identity, lobbies, and synchronization. Keep hub work here and game-specific implementations in their respective repositories. Document new directories when introducing the initial scaffold.

## Build, Test, and Development Commands

There is currently no package manifest, build tool, development server, or automated test command. Do not assume `npm test` or `npm run build` works.

- Use `git status --short` to review pending changes.
- Use `git diff --check` to check tracked changes for whitespace errors.
- Use `git diff` to review changes before committing.

When adding application tooling, document exact installation, local development, build, and test commands in a README. Include Firebase Emulator Suite setup before introducing database integration.

## Coding Style & Naming Conventions

For Markdown, use descriptive headings, short paragraphs, fenced code blocks for commands, and relative links to repository files. Preserve the roadmap's phase headings and checkbox format when updating progress.

No language-specific style, formatter, or linter has been established. Define indentation, file naming, and formatting scripts alongside the first implementation; follow those choices consistently afterward.

## Testing Guidelines

No testing framework or coverage threshold is configured. Review documentation for accurate paths, commands, and milestone status.

The roadmap calls for emulator tests covering permitted and denied database operations, concurrent joins, invalid moves, and unauthorized host actions. Add these with backend integration. Before release, verify the full guest-to-game flow with two independent browser sessions, including disconnects and GitHub Pages asset paths.

## Commit & Pull Request Guidelines

Git history contains only `Initial commit`, so no established commit convention exists. Use short, imperative subjects describing a focused change, such as `Document lobby membership rules`.

Pull requests should describe the change, link relevant issues or roadmap phases, and record validation performed. Include screenshots for interface changes and explain configuration or deployment changes.

## Security & Configuration

Keep service-account credentials and server secrets out of commits and browser code. Use emulators for development and deny-by-default database rules. Treat display names as untrusted text and use Firebase IDs for identity.
