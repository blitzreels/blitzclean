# BlitzClean identity

The mark combines an open C with a lightning cut in mint `#17FFA6` on graphite.
It replaces the separate bolt and sparkle with one silhouette and no text.
The production artwork is clean SVG geometry; AI-generated concepts informed the direction.

- `BlitzClean.icon/Assets/Mark.svg`: unmasked, transparent foreground at 1024 × 1024.
- `BlitzClean.icon/Assets/Background.svg`: opaque, full-bleed graphite layer.
- `BlitzClean.icon/icon.json`: prepared layered Icon Composer document.
- `app-icon.png`: sRGB 1024px fallback icon for the existing macOS 14+ bundle.

The legacy ICNS uses the familiar macOS inset rounded tile; the layered sources have no baked corner mask.
The foreground has no baked glow, shadow, texture, or bevel. System effects belong in Icon Composer.
The layered document is not yet included in the app: first-use Apple licence acceptance is pending.

Design reference: [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).
Apple recommends simple centered shapes, crisp foreground edges, and unmasked layers for current macOS icons.

Regenerate the fallback PNG from the SVG, then generate every native ICNS size:

```sh
swift scripts/render-icon.swift assets/brand/app-icon.png
./scripts/build-icon.sh
```

## Concept brief

Built-in image generation was used for exploration, then the production mark was authored as vector geometry.
Prompt: A bold mint C-shaped circular sweep with a lightning-shaped opening, one unified cleaning-and-speed emblem.
Centered, simple, thick silhouette, clear at 16px, no text or sparkles, transparent foreground, no baked effects.

The menu bar loads the vector as a template image so it works in light and dark appearances.
The dashboard and tray load the bundled ICNS; brand assets are cached rather than reread on each update.
