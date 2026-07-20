# Changelog

## [0.1.0] - July 2026

### Added

- Apple Silicon menu bar app for checking and updating Homebrew formulae and casks on macOS 14 or later.
- Normal and Greedy update modes, with the selected mode applied consistently to checks and updates.
- Manual, after-unlock, and configurable periodic update checks.
- Notifications for available updates, completed updates, partial failures, cleanup results, and check failures.
- Notification action for starting an Update All operation.
- Individual package updates, temporary skips, and persistent skips.
- Update history with partial batch successes preserved.
- Optional automatic cleanup after failure-free updates, plus manual and deep cleanup actions.
- Administrator-password retry support for Homebrew operations that require elevated access.
- Automatic forced-reinstall fallback when Homebrew refuses to upgrade a selected self-updating cask in place.
- Seven-day diagnostic retention for Homebrew failures without storing administrator passwords.
- Launch-at-login support.

[0.1.0]: https://github.com/siannsin/FreshBrew/releases/tag/v0.1.0
