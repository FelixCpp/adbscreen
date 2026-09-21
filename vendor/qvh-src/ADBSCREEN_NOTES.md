# ADBScreen vendoring notes for quicktime_video_hack (QVH)

Upstream: https://github.com/danielpaulus/quicktime_video_hack
License: MIT (see `LICENSE` in this directory)
Pinned commit: `d81396e2e7758d98c2a594853b64f98b54a8a871`

## Why a plain copy instead of a git submodule

Every other vendored dependency in this repo (`vendor/uxplay-src`) is a git
submodule pointing at a `FelixCpp`-owned fork on GitHub, so patches are
tracked with normal git history on a custom branch. That wasn't possible
here: creating the vendored copy required only SSH push access to
*existing* `FelixCpp` repos, with no GitHub API/token access available to
create a brand-new `FelixCpp/quicktime_video_hack` fork. So this directory
is a plain source copy (git history stripped) instead. If a fork ever gets
created, this should be converted to a submodule to match the `uxplay-src`
convention.

## ADBScreen-specific patches on top of upstream

- `screencapture/adbscreen_shared_context.go` (new file): adds
  `FindIosDeviceWithContext`/`EnableQTConfigWithContext`, which are copies
  of the upstream `FindIosDevice`/`EnableQTConfig` but reuse a single
  caller-provided `gousb.Context` instead of creating/closing a fresh one
  per call. Repeatedly creating/closing `gousb.Context()` in quick
  succession was observed to reliably trigger intermittent
  `libusb: unknown error [code -99]` **panics** from `gousb.NewContext()`
  on macOS (likely IOKit master-port churn) — sharing one context for the
  whole find → activate → stream flow avoids most of that.
- `screencapture/usbadapter.go` (modified): `UsbAdapter.StartReading` now
  takes a `*gousb.Context` parameter instead of creating its own internal
  context. Also added a best-effort `usbDevice.SetAutoDetach(true)` call
  after opening the device to try to release any conflicting
  kernel/system driver claim (e.g. macOS's `usbmuxd`).
  **This is a breaking change to the upstream API**: the original,
  unmodified root `main.go` (the standalone `qvh` CLI) no longer builds
  because of this signature change. That's fine for our purposes — only
  `./cmd/adbscreen-usbmirror-helper` is built and shipped — but is worth
  knowing if you pull a fresh upstream copy and try to reconcile changes.
- `cmd/adbscreen-usbmirror-helper/main.go` (new, ADBScreen-authored): the
  actual helper binary ADBScreen spawns. Finds a USB iOS device, activates
  the private "QuickTime X" USB config, and streams H.264 frames to
  ADBScreen over a Unix socket using the same wire format as
  `adbscreen-airplay-helper` (1-byte type tag + 4-byte BE length + payload;
  type 0x00 = video frame, 0x01 = device name UTF-8 string). Wraps each
  attempt in `defer recover()` (some `gousb` failure paths panic instead of
  returning an `error`) and retries up to 5 times with backoff.

## Building the bundled binary

```sh
cd vendor/qvh-src
go build -o /tmp/adbscreen-usbmirror-helper ./cmd/adbscreen-usbmirror-helper/
# Rewrite the libusb dependency to a bundled, relocatable copy instead of
# the build machine's Homebrew path, since end users won't have Homebrew:
LIBUSB=$(otool -L /tmp/adbscreen-usbmirror-helper | awk '/libusb/{print $1}')
cp "$LIBUSB" /tmp/libusb-1.0.0.dylib
install_name_tool -id "@executable_path/libusb-1.0.0.dylib" /tmp/libusb-1.0.0.dylib
install_name_tool -change "$LIBUSB" "@executable_path/libusb-1.0.0.dylib" /tmp/adbscreen-usbmirror-helper
codesign --force --sign - /tmp/adbscreen-usbmirror-helper /tmp/libusb-1.0.0.dylib
cp /tmp/adbscreen-usbmirror-helper /tmp/libusb-1.0.0.dylib ../../Sources/ADBScreen/Resources/
```

Both files are bundled as app resources side by side (see `project.yml`),
so `@executable_path/libusb-1.0.0.dylib` resolves correctly at runtime
without requiring libusb to be installed on the end user's Mac.

## Known limitation (unresolved as of this writing)

On at least one tested Mac, the helper reliably gets through device
discovery and starts activating the QuickTime X USB config, but the final
USB interface claim can fail with `Could not retrieve config` or
`libusb: unknown error [code -99]`. This is most likely macOS's own
`usbmuxd`/`AMPDeviceDiscoveryAgent` system daemons holding an exclusive
claim on the interface. `SetAutoDetach(true)` was added as a best-effort
mitigation but doesn't fully resolve it on every machine. A more complete
fix would likely require deeper coordination with (or temporarily
suspending) those system daemons — not attempted here since that's an
invasive, machine-specific action that needs explicit user sign-off,
especially on managed/corporate Macs.
