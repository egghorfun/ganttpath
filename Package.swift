// swift-tools-version: 6.0
// Ganttpath - single-user project scheduling for engineering projects (MS Project style logic), in Swift.
//
//   GanttpathCore  scheduling engine, data model, calendars, import/export, PDF/SVG drawing. Pure Swift + Foundation,
//                  builds and is tested on macOS and Linux.
//   GanttpathModel the app's state and commands (selection, editing, clipboard, files, preferences) without any UI, so
//                  they are tested on Linux too.
//   Ganttpath      the SwiftUI Mac app (macOS only): draws GanttpathModel and GanttpathCore's drawings.
//   gpcli          a small command-line tool around GanttpathCore (used by the cross-check tests against the JavaScript app).

import PackageDescription

var products: [Product] = [
    .library(name: "GanttpathCore", targets: ["GanttpathCore"]),
    .library(name: "GanttpathModel", targets: ["GanttpathModel"]),
    .executable(name: "gpcli", targets: ["gpcli"]),
]
var targets: [Target] = [
    .target(name: "GanttpathCore", path: "Sources/GanttpathCore"),
    .target(name: "GanttpathModel", dependencies: ["GanttpathCore"], path: "Sources/GanttpathModel"),
    .executableTarget(name: "gpcli", dependencies: ["GanttpathCore"], path: "Sources/gpcli"),
    .testTarget(name: "GanttpathCoreTests", dependencies: ["GanttpathCore"], path: "Tests/GanttpathCoreTests",
                resources: [.copy("Fixtures")]),
    .testTarget(name: "GanttpathModelTests", dependencies: ["GanttpathModel", "GanttpathCore"], path: "Tests/GanttpathModelTests"),
]

#if os(macOS)
products.append(.executable(name: "Ganttpath", targets: ["Ganttpath"]))
targets.append(.executableTarget(name: "Ganttpath", dependencies: ["GanttpathCore", "GanttpathModel"], path: "Sources/Ganttpath",
                                  swiftSettings: [.swiftLanguageMode(.v5)]))
#endif

// The app targets macOS 27. GP_MACOS_MIN lets a build machine without the macOS 27 SDK (for example a CI runner) compile
// and test everything against an earlier macOS; the shipped app is built with the default.
let macMin = Context.environment["GP_MACOS_MIN"] ?? "27.0"

let package = Package(
    name: "Ganttpath",
    platforms: [.macOS(macMin)],
    products: products,
    targets: targets
)
