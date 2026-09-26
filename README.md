# Ganttpath (Swift)

Ganttpath 1.3.6, rebuilt in Swift as a native macOS app (SwiftUI and AppKit, macOS 27). It is single-user project
scheduling for engineering projects, using MS Project style logic. The JavaScript/Electron version is the reference: its source is in
`Ganttpath-1.3.6-source.zip` and is not part of this repository.

## Layout

| Folder | What it is | Builds on |
|---|---|---|
| `Sources/GanttpathCore` | Scheduling engine, data model, calendars and holidays, durations and lags, MS Project XML / Excel / CSV / `.gpath` import and export, templates, reports, S-curve, network layout, compare, and the drawings of the Gantt chart, table, other views and PDF pages (with an SVG writer) | macOS and Linux |
| `Sources/GanttpathModel` | The app's state and commands without UI: selection, table cursor, editing, keyboard, clipboard, row and bar dragging, files, autosave, versions, preferences | macOS and Linux |
| `Sources/Ganttpath` | The Mac app: window, Gantt pane, other views, dialogs, menus, CoreGraphics/CoreText painting for screen, PDF and PNG | macOS only |
| `Sources/gpcli` | Command-line tool used to cross-check against the JavaScript app, and to render every view as SVG | macOS and Linux |
| `Tests/` | swift-testing suites (see below) | macOS and Linux |
| `Packaging/build-app.sh` | Builds `dist/Ganttpath.app` and a zip on a Mac | macOS |

## Build and run (Mac)

```
swift build                      # everything
swift test                       # all tests
Packaging/build-app.sh           # dist/Ganttpath.app  (add --mpxj <path to mpxj-convert> to read .mpp files directly)
```

Without the MPXJ reader, open MS Project files after saving them as XML in MS Project (File > Save As > XML).
Holiday downloads use date.nager.at, as the JavaScript app does. The built-in holiday data is used when the Mac is offline.

## Tests

- **Golden tests against JavaScript 1.3.6.** The fixtures `Tests/GanttpathCoreTests/Fixtures/js136-*.json.z` hold input and output that
  the JavaScript app produced. They cover schedules of 150 random projects, 100 scripts of 40 editing commands, 60 MS Project XML exports,
  112 imports, and table cells, chart geometry, critical-path rows and timeline data for 86 projects. The Swift code must match them value for value.
- Ports of the JavaScript unit tests (engine, calendar, hours, model, MSPDI, tabular, templates, reports, views, WBS, task info, chart label reach).
- Ports of the JavaScript browser tests to the model (clipboard, editing, keyboard, row drag, bar drag, files, preferences).
- Print layout on every paper size: no text runs off the page, page numbers are filled in, header and footer fields are filled in.
- Tests that use the private CTCI fixtures run only when `GP_PRIVATE_FIXTURES` points to them. Those files are not in the repository.

## Continuous build on macOS

`.github/workflows/macos.yml` runs on every push. On a GitHub macOS runner it:
1. builds everything;
2. runs all tests;
3. assembles `Ganttpath.app`;
4. starts the app in a smoke-test mode.

In that mode (`GP_SMOKE_DIR`, see `Sources/Ganttpath/App/SmokeTest.swift`) the app opens the sample project and shows every
view and two dialogs, saving a picture of each. It also exports and reads back a PDF, exports a PNG, makes an edit and undoes it, then quits.
The app zip, the pictures and the report are attached to the run as the `ganttpath-mac` artifact. If the runner has no macOS 27 SDK,
the workflow builds with `GP_MACOS_MIN` set to the runner's SDK version.

## Known differences from the JavaScript app

- JavaScript 1.3.6 wrote `[object Object]` for the project start and status date in the "# Project Settings" block of the CSV export.
  The Swift version writes the dates.
- JavaScript adds an empty undo step when a command sets a field that is missing from an old file to null. Swift does not add that step.
- PDFs are drawn with CoreGraphics instead of Chromium's print-to-PDF. The layout is the same (same paper sizes, scale, margins, columns,
  header and footer), but text is placed with CoreText metrics, so line breaks and ellipses can differ by a character.
- View > Text Size scales the table, chart, diagrams and the app's text. The JavaScript app zoomed the whole web page.
