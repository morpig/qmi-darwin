// swift-tools-version: 5.9
import PackageDescription

// qmi-darwin: QMI connection manager for Quectel modems on macOS. See PLAN.md.
let package = Package(
    name: "qmi-darwin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "QMIKit", targets: ["QMIKit"]),
        // What other apps import to talk to qmid: XPC protocol, models, client.
        .library(name: "QMIDAPI", targets: ["QMIDAPI"]),
        .executable(name: "qmictl", targets: ["qmictl"]),
        .executable(name: "qmid", targets: ["qmid"]),
        .executable(name: "QMIDarwinApp", targets: ["QMIDarwinApp"])
    ],
    targets: [
        // Codecs and message definitions: pure, no USB, no root.
        .target(name: "QMIKit"),
        // qmid's public API; Foundation only.
        .target(name: "QMIDAPI"),
        // Hot path in C with a thin Objective-C shim for IOUSBHost: USB pipes, QMAP, utun.
        .target(
            name: "QMIDatapath",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation")
            ]
        ),
        // Transport, service clients, PDN sessions, utun configuration. Shared by qmictl and qmid.
        .target(name: "QMIHost", dependencies: ["QMIKit", "QMIDatapath", "QMIDAPI"]),
        .executableTarget(name: "qmictl", dependencies: ["QMIHost", "QMIKit", "QMIDAPI"]),
        .executableTarget(name: "qmid", dependencies: ["QMIHost", "QMIDAPI"]),
        // QMI Darwin.app host: registers qmid with SMAppService (scripts/build-app.sh).
        .executableTarget(name: "QMIDarwinApp", dependencies: ["QMIDAPI"]),
        .testTarget(name: "QMIKitTests", dependencies: ["QMIKit", "QMIDatapath"]),
        .testTarget(name: "QMIHostTests", dependencies: ["QMIHost", "QMIKit", "QMIDAPI"]),
        .testTarget(name: "QMIDAPITests", dependencies: ["QMIDAPI"])
    ]
)
