// swift-tools-version: 6.0
// Ganttpath - single-user project scheduling for engineering projects (MS Project style logic), in Swift.
//
//   GanttpathCore  scheduling engine, data model, calendars, import/export, PDF/SVG drawing. Pure Swift + Foundation,
//                  builds and is tested on macOS and Linux.
//   Ganttpath      the SwiftUI Mac app (macOS only).
//   gpcli          a small command-line tool around GanttpathCore (used by the cross-check tests against the JavaScript app).

import PackageDescription

var products: [Product] = [
    .library(name: "GanttpathCore", targets: ["GanttpathCore"]),
    .executable(name: "gpcli", targets: ["gpcli"]),
]
var targets: [Target] = [
    .target(name: "GanttpathCore", path: "Sources/GanttpathCore"),
    .executableTarget(name: "gpcli", dependencies: ["GanttpathCore"], path: "Sources/gpcli"),
    .testTarget(name: "GanttpathCoreTests", dependencies: ["GanttpathCore"], path: "Tests/GanttpathCoreTests",
                resources: [.copy("Fixtures")]),
]

#if os(macOS)
products.append(.executable(name: "Ganttpath", targets: ["Ganttpath"]))
targets.append(.executableTarget(name: "Ganttpath", dependencies: ["GanttpathCore"], path: "Sources/Ganttpath"))
#endif

let package = Package(
    name: "Ganttpath",
    platforms: [.macOS("27.0")],
    products: products,
    targets: targets
)
