# Haloscope Unsigned Preview

Unsigned Preview is an optional distribution channel for technical testers who
do not want to build Haloscope with Xcode. The recommended no-cost path remains
the Personal Team source build in the main README; Preview is deliberately
degraded because it cannot use a trusted Apple signing team.

## Support boundary

| Capability | Unsigned Preview |
| --- | --- |
| Collapsed and expanded notch panel | Supported |
| Seven-day quota and reset-time display | Supported |
| Current activity, recent conversations, and token statistics | Supported |
| Codex CLI auto-detection and manual executable selection | Supported |
| English and Simplified Chinese | Supported |
| Appearance, placement, animation, opacity, and text color | Supported |
| Universal arm64 and x86_64 execution | Supported |
| Desktop Widget or `HaloscopeWidget.appex` | Not included |
| App Group or shared Keychain access | Not included |
| Apple Developer ID trust or notarization | Not provided |
| Gatekeeper acceptance without user approval | Not promised |
| Sparkle or other automatic updates | Not included |
| Automatic launch at login | Disabled in the first Preview release |
| Official Homebrew Cask | Not provided |

The app identifies itself as `Unsigned Preview` in its first-launch disclosure
and Settings. Ad-hoc signing protects bundle structure and architecture
compatibility only; it is not equivalent to Developer ID signing.

## Verify the download first

Download the ZIP or DMG and the matching `SHA256SUMS.txt` file from the latest
**Haloscope Unsigned Preview** pre-release on the [GitHub Releases page](https://github.com/HaochengLuo/Haloscope/releases).
In Terminal, from the directory containing those files, run:

```bash
shasum -a 256 -c Haloscope-<version>-SHA256SUMS.txt
```

Do not open an artifact until the checksum reports `OK`. The manifest covers the
ZIP, DMG, and dSYM archive when one is present.

## Install from the DMG

1. Open the DMG in Finder.
2. Drag `Haloscope Preview.app` to `Applications`.
3. Eject the DMG and open the copied app from Finder. If macOS asks for
   confirmation, choose **Open**.
4. If the first-open dialog does not offer **Open**, open **System Settings →
   Privacy & Security**, find the blocked app notice, and choose **Open Anyway**.
5. Read the in-app Unsigned Preview disclosure. The desktop Widget will not
   appear because it is not part of this channel.

Do not disable Gatekeeper, System Integrity Protection, or other global macOS
security settings. This project does not automate quarantine removal. An
advanced shell fallback, after checksum verification, is to run the exact app
path with `open "/Applications/Haloscope Preview.app"`; Finder and System
Settings approval remain the preferred flow.

## Manual upgrades

Download the next official Preview release, verify its checksum, quit Haloscope
Preview, and replace `/Applications/Haloscope Preview.app` with the new copy.
Preview preferences are isolated under `com.lamluo.haloscope.preview` and should
survive normal replacement. Updates are manual; the app does not claim to
discover or install updates automatically.

## Uninstall

Quit the app, move `/Applications/Haloscope Preview.app` to the Trash, and empty
the Trash when ready. To remove Preview preferences, delete
`~/Library/Preferences/com.lamluo.haloscope.preview.plist` if it exists. Do not
delete the regular `com.lamluo.haloscope` preferences when removing Preview.

## Why the Widget is absent

The Widget relies on signed App Group and shared Keychain capabilities. An
unsigned Preview app cannot honestly promise those capabilities, so it has no
embedded extension, no Widget onboarding, and no Widget URL schemes. The notch
panel reads Codex data directly and remains usable without shared storage.

Homebrew can download and checksum a file, but a Homebrew Cask cannot create an
Apple Developer ID identity or notarization. An official Cask is therefore out
of scope for the initial Preview channel.

## Preview versus a Personal Team source build

The Personal Team source build is recommended when Xcode is available. It keeps
the regular Haloscope target and Widget behavior, uses your own Apple account
for local signing, and is the path to test the complete feature set. Unsigned
Preview is easier to install but has no Widget, no App Group/shared Keychain,
no automatic login item, no automatic updates, and still requires explicit
macOS approval.

Preview preferences remain isolated from regular Haloscope preferences and URL
schemes. A future signed build may selectively import only non-sensitive
preferences: Codex executable path, language, appearance, animation preference,
collapsed status placement, opacity, and text color. It must not import login
item registration, Keychain items, App Group data, Widget state, or security
approvals.

## Reporting an installation problem

Include the exact Preview version, macOS version, CPU architecture (`arm64` or
`x86_64`), whether the app came from the ZIP or DMG, the checksum result, and
the wording of any Finder or System Settings approval message. Do not attach
Codex credentials, message content, file contents, or private authentication
responses.

## Manual release QA matrix

Before treating a Preview release as ready, test on macOS 14 Intel, macOS 14
Apple Silicon, macOS 15 Apple Silicon, and macOS 26 Apple Silicon. Repeat on a
clean user account with no prior Haloscope install and on an account that
previously installed a Personal Team build.

For each environment verify that the DMG mounts, the app copies to
`/Applications`, the documented system-UI approval flow works, `codex app-server`
can launch, quota/activity/conversations/token statistics render, Settings
persist, no Widget onboarding appears, no incomplete Widget appears in the
Widget gallery, relaunch works, and replacing one Preview version with another
preserves Preview preferences. Also verify that Preview and a Personal Team
build can coexist without sharing preferences or URL schemes. A release is
blocked if any supported macOS version requires disabling global security
protections.
