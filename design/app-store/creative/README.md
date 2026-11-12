# Play On Con App Store creative

Two en-US static assets, created 2026-10-07 using Play On Con's existing badge, forest/cream palette, and genuine iOS captures.

| Placement | Upload file | Dimensions | Editable source |
| --- | --- | --- | --- |
| Product page Header | [header.png](en-US/header.png) | 3840 × 1646 | [header.svg](sources/header.svg) |
| Search Results | [search-result.png](en-US/search-result.png) | 3840 × 2560 | [search-result.svg](sources/search-result.svg) |

Both exports are opaque, 8-bit RGB sRGB PNGs. Backgrounds fill the canvas; essential copy, badge, and phone screens stay inside the art safe areas measured from Apple's dedicated Photoshop templates. Full and safe-area crop previews are in [previews](previews/). Template-safe crops help check composition; they do not replace App Store Connect's product-page preview.

The header emphasizes the convention's established “Camp. Con. Community.” identity. Search creative presents the actual Schedule and Venue Map screens. Source captures are documented as version 2026.10.6+28 in the existing screenshot manifest; the project currently declares 2026.10.7+29. The captured interface, schedule content, and BETA indicator are preserved. No dates, prices, URLs, accolades, or download calls to action were added to the artwork.

## Sources and verification

- [Apple creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications), checked 2026-10-07.
- [Header Photoshop template](https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-product_page_header_template-static.psd): measured art-safe rectangle x=1097, y=493, width=1646, height=661.
- [Search Results Photoshop template](https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-search_results_template-static.psd): measured art-safe rectangle x=836, y=765, width=2168, height=1030.
- Original badge: `assets/branding/poc-logo.png`.
- Genuine UI: `design/app-store/iphone/01-all-sessions.png` and `04-venue-map.png`.

[manifest.json](manifest.json) records export checks, source hashes, template coordinates, and source-build provenance. Visual QA inspected the full artwork, native artwork crops, and smaller storefront/crop previews. Files have not been uploaded or submitted to Apple.

## Rebuild

Run from the repository root with Node.js and the existing `sharp` package:

```sh
node design/app-store/creative/render-assets.mjs
```

If `sharp` is supplied by a bundled runtime rather than a local Node installation:

```sh
POC_SHARP_MODULE=/absolute/path/to/node_modules/sharp node design/app-store/creative/render-assets.mjs
```

Edit copy and composition in [render-assets.mjs](render-assets.mjs) for repeatable changes. It regenerates both SVGs, PNGs, previews, and the manifest. The SVGs embed the original source images and remain independently editable. Text uses Arial Rounded MT Bold and Arial, available on this Mac; another machine needs those fonts for identical regeneration. Rebuilding resets visual review to pending so new exports are reviewed again.
