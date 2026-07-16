# FreshBrew

FreshBrew is a focused macOS menu bar utility for checking and updating Homebrew formulae and casks.

The project is in early development and currently targets Apple Silicon Macs running macOS 14 or later.

## Features

- Check and update Homebrew formulae and casks from the menu bar.
- Optional Greedy Mode for casks that auto-update or use version markers such as `latest`.
- Check automatically after unlock or on a configurable periodic interval.
- Receive update notifications with an **Update All** action.
- Update, temporarily skip, or always skip individual packages.
- Preserve completed packages in update history, including partial batch successes.
- Run optional automatic cleanup after successful updates, plus manual and deep cleanup.
- Launch at login and retain detailed Homebrew failure logs for seven days.

FreshBrew defaults to Greedy Mode off, Auto Cleanup off, and **After Unlock** check mode. After unlocking, it checks the four-hour threshold first and, when eligible, waits one minute before checking Homebrew.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- [Homebrew](https://brew.sh/) installed

## Development

1. Open `FreshBrew.xcodeproj` in Xcode.
2. Select the `FreshBrew` scheme and `My Mac` destination.
3. Build and run with `Command-R`.

The project also includes a repeatable terminal workflow:

```bash
./script/build_and_run.sh
```

Run the macOS test suite with:

```bash
xcodebuild test \
  -project FreshBrew.xcodeproj \
  -scheme FreshBrew \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/freshbrew-derived-data \
  CODE_SIGNING_ALLOWED=NO
```

The project includes dedicated FreshBrew application and menu bar artwork. Built-in SF Symbols are used for transient operation states such as checking and updating.

## Attribution

FreshBrew is an independently implemented project inspired by [TopOff](https://github.com/ihazgithub/TopOff) by Thomas Haslam.
