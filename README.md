# Shade

A menu bar app for macOS that dims everything except the front window.

- **⌃⌘R** turns Shade on and slides the front window to the center of its screen.
- **Esc** (while Shade is on) turns it off and slides the window back to where it was.
- Intensity, "Center Window on Enable" and "Launch at Login" are in the menu bar menu.

Centering needs Accessibility permission (System Settings → Privacy & Security → Accessibility).

## Build

There is no prebuilt download yet; build from source (needs the Xcode command line tools, macOS 13+):

```sh
./build.sh   # builds and ad-hoc signs Shade.app
open Shade.app
```

Ad-hoc signing changes the app's identity on every build, so macOS drops the Accessibility
permission after a rebuild; reset it with `tccutil reset Accessibility local.shade`.

## License

MIT, see [LICENSE](LICENSE).
