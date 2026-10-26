# Native iPhone UI capture

Run **Capture native iPhone UI** in GitHub Actions on the commit being reviewed.
The job uses Xcode with an iOS 26 simulator SDK and creates a fresh iPhone
simulator with an installed iOS 26 runtime. It builds and installs the production
MangaShelf target, then launches it through XCTest. No preview app, reference binary, or rendered web substitute participates.
The additional stage 2/3 flows use explicitly synthetic persistent simulator data,
seeded only after reinstalling the production app into a fresh owned simulator container.
No executable package, trust record, or proprietary artwork is seeded.

The tab-flow UI tests select all five real tabs in English and Arabic with the
simulator set to dark appearance. Each capture requires the localized tab labels,
the selected tab, five visible touch targets of at least 44 × 44 points, the
physical Library → More order, and no blocking alert. The phone remains in
English to verify that explicit `app.language = ar` overrides the phone language.

The full gate expects **60 named screenshots across six tests**. The first four tests require 36 shared UI screenshots:

- 28 dark captures: five tabs, eight settings pages, and the Library menu in each locale.
- Six light captures: More, About, and the Library menu in each locale. The test changes the real App theme control, waits for the saved value, and restores System afterwards.
- Two Library-menu captures at accessibility XXXL text size. The test checks that the app actually enlarged its tab targets and that the panel remains inside the viewport.

Two additional tests (English and Arabic) require 24 populated-store captures:
library, category, filters, selection, local/source details, chapter filters,
history, sources, extensions, extension detail, and repositories. Each locale
uses a fresh installation. Tests exercise real persistence, cached page reading,
mixed category preservation, pinning and targeted history removal. Postflight
checks validate both metadata and original media bytes in the app container.

The About and Changelog Back controls have separate identifiers. The test waits for the child Back control to disappear and the parent to become hittable before returning to More.

Download the `MangaShelf-UI-<run>-<attempt>` artifact:

| File | Evidence |
| --- | --- |
| `screenshots/msl-{en,ar}-dark-0{1…5}-{tab}.png` | Ten tab screenshots; copied without image edits |
| `screenshots/msl-{en,ar}-{dark,light}-*.png` | Settings, menus, and the scoped light/accessibility cases above |
| `capture-report.json` | Capture completeness, dimensions, byte hashes, originating test names |
| `provenance.json` | Commit, working tree, Xcode/SDK, simulator type/runtime/UDID, locales, appearance |
| `built-app.json` | Installed app version/build/bundle identifier and executable hash |
| `Tabs.xcresult`, `Stage23-{English,Arabic}.xcresult` | Original test results and lifetime-preserved screenshot/state/accessibility attachments |
| `seed-*.json`, `persistence-*.json` | Explicit synthetic fixture inventory and postflight data preservation checks |
| `attachments/manifest.json` | Original `xcresulttool` mapping from attachment filenames to test names |
| `build.log`, `test.log`, `capture.log`, `run-status.json` | Build, installation, execution and final exit status |

The completeness gate fails if a named screenshot is missing, duplicated,
malformed, has an unexpected viewport, or repeats the exact bytes of another
tab/locale. Test/build failures remain failures even when partial screenshots
can be exported. The workflow uploads available evidence on failure too.

Successful capture is **not a visual parity pass**. Review the PNGs alongside
the supplied Tachimanga screenshots and record mismatches in geometry, colors,
glyphs, empty states and text. The shared UI tests use an empty store; the extra flows use a synthetic populated store.
Neither proves real source execution, complete reader parity, full light
or accessibility coverage, a smaller phone, or behavior on physical iPhone. The
light and large-text cases cover only the components listed above.

On a Mac with Xcode 26 and an installed iOS 26 simulator runtime:

```bash
bash scripts/capture_ui_snapshots.sh
```

The command requires a fresh `build/ui-snapshots` output directory. It creates
and later deletes only its own simulator. `--ui-tests` generates the separate
`iOS/MangaShelfUI.xcodeproj` and the `MangaShelfUI` scheme; the normal app project
is untouched. This generated project is a local build artifact and should not
be committed. The original `generate_xcode_project.py` command still emits the
normal app project without a UI test target.

Linux can run `python3 scripts/test_ui_snapshot_capture.py` to check synthetic
attachment-manifest failures. That is not an Xcode build or simulator capture.
