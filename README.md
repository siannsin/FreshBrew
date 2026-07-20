# FreshBrew

FreshBrew is a focused macOS menu bar utility for checking and updating Homebrew formulae and casks.

It currently supports Apple Silicon Macs running macOS 14 or later.

## Features

- Check and update Homebrew formulae and casks from the menu bar.
- Optional Greedy Mode for casks that auto-update or use version markers such as `latest`.
- Check automatically after unlock or on a configurable periodic interval.
- Receive update notifications with an **Update All** action.
- Update, temporarily skip, or always skip individual packages.
- Keep completed packages in update history, including partial batch successes.
- Run optional automatic cleanup after successful updates, plus manual and deep cleanup.
- Launch at login and retain detailed Homebrew failure logs for seven days.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- [Homebrew](https://brew.sh/) installed

## Install

1. Download the latest `FreshBrew-<version>-arm64.dmg` from [GitHub Releases](https://github.com/siannsin/FreshBrew/releases/latest).
2. Open the DMG and drag **FreshBrew** into **Applications**.
3. Open FreshBrew from the Applications folder.

FreshBrew releases are currently ad-hoc signed and are not Apple-notarized. On first launch, macOS may block the app because the developer cannot be verified. After attempting to open it:

1. Open **System Settings → Privacy & Security**.
2. Scroll to **Security** and click **Open Anyway** for FreshBrew.
3. Confirm **Open**.

See [Apple's instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

The matching `.sha256` release asset can be used to verify that the downloaded DMG has not changed:

```bash
shasum -a 256 -c FreshBrew-<version>-arm64.dmg.sha256
```

## Use FreshBrew

FreshBrew runs in the menu bar and does not open a normal app window.

1. Click the FreshBrew menu bar icon.
2. Select **Check Updates**.
3. Review available packages or select **Update All**.
4. Use **Update History** to review completed updates.

FreshBrew may request:

- **Notifications**, to report available updates and update results.
- **App Management**, when Homebrew replaces applications in `/Applications`.
- Your administrator password, when a Homebrew installer requires elevated access.

FreshBrew does not store administrator passwords.

## Settings

- **Greedy Mode** includes casks that auto-update or otherwise require Homebrew's `--greedy` behavior. It is off by default.
- **Check Mode** can run after unlock or periodically. After-unlock mode checks the four-hour threshold first and, when eligible, waits one minute before checking.
- **Auto Cleanup** runs Homebrew cleanup only after a failure-free update that completed at least one package. It is off by default.
- **Launch at Login** starts FreshBrew when you sign in.

Changing Greedy Mode clears the current update results so the next check uses the newly selected mode consistently.

## Attribution

FreshBrew is an independently implemented project inspired by [TopOff](https://github.com/ihazgithub/TopOff) by Thomas Haslam.

## License

FreshBrew is available under the [MIT License](LICENSE).
