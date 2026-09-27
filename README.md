# Ganttpath (Swift)

Ganttpath, rebuilt in Swift as a native macOS app (SwiftUI and AppKit, macOS 27), starting from the JavaScript app 1.3.6. It is single-user project
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
Packaging/fetch-mpxj.sh mpxj     # the .mpp reader (checked against its checksum)
Packaging/build-app.sh --mpxj mpxj/package/bin/mpxj-convert   # dist/Ganttpath.app and dist/Ganttpath-<version>-build<n>-mac.zip
```

## Versions

The version is `APP_VERSION` in `Sources/GanttpathCore/Files.swift`. It goes up with every change handed over: 1.4.0 is the first
Swift version with direct `.mpp` opening; 1.5.0 adds elapsed durations, scheduling from the finish date, eleven baselines with
baseline comparison, and custom columns in the MS Project XML export. Every build also gets its own build number (the CI run number, or the date and time for a
local build). The number is shown in Ganttpath > About Ganttpath and is part of the zip name.

## MS Project files

- `.mpp` files are read by MPXJ (LGPL-2.1-or-later), the same reader the JavaScript app used: the native build in npm
  `@byteink/mppjs-darwin-arm64` 0.1.8, for Apple-silicon Macs. It is bundled inside the app as `Contents/Resources/bin/mpxj-convert`,
  with its licence and notices (`mpxj-LICENSE.txt`, `mpxj-NOTICE.txt`). It converts the file to MS Project XML, which Ganttpath imports.
- What comes in: tasks and outline, durations (elapsed ones too), dates, links and lags, constraints, deadlines, % complete and actual
  dates, manual and automatic scheduling, milestones, notes, calendars with their holidays (recurring ones too, as one exception per
  day), Baseline and Baseline 1 to 10, status date, scheduling from the start or the finish date, and custom fields (Text, Number,
  Flag, Date, Cost, Duration, Start, Finish, Outline Code) as custom columns. Resources, assignments and costs are left out; the
  import report says what was left out.
- What goes out to MS Project XML: the same, with custom columns as custom fields (Text1-30, Number1-20, Flag1-20, Date1-10, named by
  the column as the field alias; fields that came from MS Project go back to the same field). Tags, custom bar colours and S-curve
  weights have no place in MS Project XML and are not written.

## MS Project scheduling rules added in 1.5

- **Elapsed durations** (3ed, 12eh, 2ew, 1emo, 45em): the task runs round the clock, weekends and holidays included. An elapsed day
  is 24 hours, a week 7 days, a month 30 days. Checked against MS Project with MPXJ's test file DurationTest9.mpp (all 15 tasks
  get MS Project's dates). An elapsed task linked after another starts the moment its predecessor allows, even at 17:00 on a Friday,
  and its slack counts round the clock too - MS Project's documented rule; no MS Project file with a linked elapsed task was
  available to check this against.
- **Schedule from the finish date** (Project > Project Settings > Schedule from): tasks are placed back from the finish date, new
  automatic tasks are As Late As Possible, the start date is calculated, and As Soon As Possible tasks start with the project. MS
  Project's test files only have finish-scheduled projects without tasks, so this follows Microsoft's description of the feature.
- **Baselines**: Baseline and Baseline 1 to 10. Compare two of them from the toolbar's baseline menu (Compare with) or Project >
  Baselines: a second (teal) bar, the columns Compared Baseline Start / Finish and Baseline Start / Finish Shift, and the Baseline
  Changes report.
- Known limit of that reader build: it cannot convert files that use custom-field lookup tables, value lists or graphical
  indicators (MPXJ's own test files: 105 of 116 convert). Ganttpath then says so; save such a file as XML in MS Project and open the XML.
- Without the reader (a build without `--mpxj`), open MS Project files after saving them as XML in MS Project (File > Save As > XML).
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
- Errors, conflicts and messages work as they do in Microsoft Project, not as they did in the JavaScript app:
  - An error opens a message box that stays until OK is pressed. The JavaScript app showed it for a few seconds at the bottom of the window.
  - Every message of the session goes to a **Message Log**, a tab of the pane at the bottom of the window (next to **Scheduling
    Conflicts**). Open it from View > Show Message Log (⌥⌘L), from the ⚠ toolbar button (then
    the Message Log tab), or with the box's "Show Message Log" button. The log
    can be copied or cleared.
  - Rest the pointer on a task row or bar that has a ⚠ scheduling conflict to see what is wrong. On a summary row, the tooltip lists the
    conflicts of the tasks below it.
- The toolbar has no project title (the name is in the window's title bar). The conflicts, Project, task panel and light/dark buttons
  sit at the right end of the first row; search, filter, sort, group and columns are on the second row. In a narrow window the
  right-hand buttons move to the end of the second row.
