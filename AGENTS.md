# FreshBrew Agent Guidelines

## Project Scope

FreshBrew is an independent macOS menu bar application for checking and updating Homebrew formulae and casks.

- Use `FreshBrew` for all product, type, file, folder, target, and identifier naming.
- Do not introduce names from projects that inspired FreshBrew into source code or code comments.
- Attribution belongs in `README.md`, not in source files.
- The bundle identifier is currently `net.siann.freshbrew`.
- The current deployment target is Apple Silicon macOS 14 or later.
- Use the provided FreshBrew artwork for the application and idle menu bar states. Use built-in SF Symbols for transient operation states where appropriate.

## Architecture

- Use AppKit for the status item and menu behavior.
- Use SwiftUI for About, Update History, and Skipped Packages window content.
- Keep AppKit-to-SwiftUI interop narrow and owned by dedicated presenter or controller types.
- Keep `MenuBarModel` as the source of truth for menu state and Homebrew workflows.
- Keep Homebrew execution, notifications, persistence, and launch-at-login behavior behind focused services.
- Prefer dependency injection so workflow logic remains unit-testable.

## Behavior Rules

- Every Homebrew check and update must follow the current Greedy Mode setting.
- Changing Greedy Mode must invalidate package results produced under the previous mode.
- After-unlock checks use a 60-second delay and a four-hour minimum-check threshold.
- Periodic and after-unlock automatic checks are mutually exclusive.
- Automatic cleanup runs only after a failure-free update with completed packages.
- Preserve detailed Homebrew failures for seven days without logging passwords.
- Keep partial update successes in history while leaving failed packages available.
- Do not automatically update or reinstall unrelated packages outside the selected update candidates.

## UI Guidelines

- Keep the menu compact and avoid redundant status text.
- Keep menu labels and behavior consistent with Greedy Mode.
- Menu state must refresh safely while the menu is open.
- Update History and Skipped Packages should share the same initial and minimum window dimensions and remain freely resizable.
- About is a fixed-size utility window.
- Use locale-aware date and time formatting.

## Development Workflow

- Put temporary plans and development notes in `temp_file/`; that directory is intentionally ignored.
- Do not add Codex-specific workspace configuration to the repository.
- Use `script/build_and_run.sh` for a repeatable local build-and-run workflow when appropriate.
- Preserve unrelated working-tree changes.
- Do not commit or push unless the user explicitly asks.
- Before committing, review the complete diff and stage only intended files.

## Validation

Run the most relevant focused tests while developing. Before a requested checkpoint commit, run:

```bash
xcodebuild test \
  -project FreshBrew.xcodeproj \
  -scheme FreshBrew \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/freshbrew-derived-data \
  CODE_SIGNING_ALLOWED=NO
```

Also validate the release build and diff:

```bash
xcodebuild build \
  -project FreshBrew.xcodeproj \
  -scheme FreshBrew \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/freshbrew-release-derived-data \
  CODE_SIGNING_ALLOWED=NO

git diff --check
```

macOS XCTest may require running outside a restricted sandbox so Xcode can communicate with `testmanagerd`.
