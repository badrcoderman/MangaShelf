# Native iPhone UI capture

Run **Capture native iPhone UI** in GitHub Actions on the commit being reviewed.
The job uses Xcode with an iOS 26 simulator SDK and creates a fresh iPhone
simulator with an installed iOS 26 runtime. It builds and installs the production
MangaShelf target, then launches it through XCTest. No preview app, reference
binary, sample manga, or rendered web substitute participates in the capture.

The two UI tests select all five real tabs in English and Arabic with the
simulator set to dark appearance. Each capture requires the localized tab labels,
the selected tab, five visible touch targets of at least 44 × 44 points, the
physical Library → More order, and no blocking alert. The phone remains in
English to verify that explicit `app.language = ar` overrides the phone language.

Download the `MangaShelf-UI-<run>-<attempt>` artifact:

| File | Evidence |
| --- | --- |
| `screenshots/msl-{en,ar}-dark-0{1…5}-{tab}.png` | Ten full native simulator screenshots, copied without image edits |
| `capture-report.json` | Capture completeness, dimensions, byte hashes, originating test names |
| `provenance.json` | Commit, working tree, Xcode/SDK, simulator type/runtime/UDID, locales, appearance |
| `built-app.json` | Installed app version/build/bundle identifier and executable hash |
| `Tabs.xcresult` | Original test results and lifetime-preserved screenshot/state/accessibility attachments |
| `attachments/manifest.json` | Original `xcresulttool` mapping from attachment filenames to test names |
| `build.log`, `test.log`, `capture.log`, `run-status.json` | Build, installation, execution and final exit status |

The completeness gate fails if a named screenshot is missing, duplicated,
malformed, has an unexpected viewport, or repeats the exact bytes of another
tab/locale. Test/build failures remain failures even when partial screenshots
can be exported. The workflow uploads available evidence on failure too.

Successful capture is **not a visual parity pass**. Review the PNGs alongside
the supplied Tachimanga screenshots and record mismatches in geometry, colors,
glyphs, empty states and text. The initial pass uses a real empty store; it does
not prove populated-library geometry, reader parity, source execution, light
appearance, accessibility modes, a smaller phone, or behavior on physical iPhone.

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
