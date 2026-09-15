# UI reference integration

Imported 52 PNG resources and three icon fonts from the supplied static extraction. ReferenceUI preserves source directories; ReferenceUI-manifest.json records each source and SHA-256. Images are bundled resources, not a claim that each is shown in the app. The app identity is unchanged. No native libraries, JARs, CAR containers or extracted localization catalogs were installed. Existing English and Arabic catalogs remain authoritative.

Material glyphs now render the library icon instead of hand-drawn rectangles. The visually identified IcoMoon filter, pencil, external-share, incognito and crop glyphs are used when the corresponding symbols are requested. Other extracted icons remain available in the bundled fonts. The sample does not establish redistribution licenses for every reference asset; review licenses before public distribution.

Overflow panels use measured content height bounded by available viewport height, with a 296-point maximum width. Glass is applied to that bounded panel, not an expanding max-height frame. Long menus scroll; Dynamic Type causes content to be remeasured.

Validation: resource integrity checks. Native compilation and iPhone screenshot verification still required; no Xcode/Swift runtime is available in this execution environment.
