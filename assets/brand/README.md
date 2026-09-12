# BlitzClean identity

BlitzClean is a native Mac utility by BlitzReels.
A near-black tile, a mint-green lightning bolt, and a small clean glint form its mark.

The native UI shares BlitzRecorder’s palette: mint `#17FFA6`, canvas `#09090B`,
subtle white borders, 8px controls, and 12px cards.
`Sources/FreeSpace/BlitzDesign.swift` keeps these tokens and button styles in one place.

The artwork is original vector geometry, rendered locally with AppKit.
Regenerate the 1024px PNG with:

```sh
swift scripts/render-icon.swift assets/brand/app-icon.png
```

`./scripts/build-icon.sh` creates the macOS iconset and ICNS from that PNG.
