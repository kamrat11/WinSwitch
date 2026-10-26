// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinSwitch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "WinSwitch",
            path: "Sources/WinSwitch",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        // Notepad
        .executableTarget(
            name: "WinPad",
            dependencies: ["WinDialogs"],
            path: "Sources/WinPad",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Notepad++, on Scintilla like the original
        .executableTarget(
            name: "WinCode",
            dependencies: ["Scintilla", "WinDialogs"],
            path: "Sources/WinCode",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // MS Paint
        .executableTarget(
            name: "WinPaint",
            dependencies: ["WinDialogs"],
            path: "Sources/WinPaint",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Windows-style dialogs shared by the apps above (Save As).
        .target(
            name: "WinDialogs",
            path: "Sources/WinDialogs",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "Scintilla",
            path: "Vendor/Scintilla",
            exclude: ["License.txt", "README.md", "VERSION", "lexilla/include/LexicalStyles.iface"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("scintilla/include"),
                .headerSearchPath("scintilla/src"),
                .headerSearchPath("scintilla/cocoa"),
                .headerSearchPath("lexilla/include"),
                .headerSearchPath("lexilla/lexlib"),
                .define("NDEBUG"),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("QuartzCore")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
