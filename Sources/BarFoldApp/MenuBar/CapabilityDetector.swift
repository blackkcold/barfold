import Foundation

struct CapabilityReport: Sendable {
    let osVersion: String
    let kind: EngineKind
    let detail: String
    let isExperimental: Bool
}

enum CapabilityDetector {
    static func detect(override: String = "auto") -> CapabilityReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        if override == "unsupported" {
            return CapabilityReport(
                osVersion: os,
                kind: .unsupported,
                detail: "Unsupported engine forced by settings.",
                isExperimental: false
            )
        }

        // macOS 27 renders the whole menu bar as one MenuBarAgent window. The
        // length trick is not verified there, so v1.0 must stay expanded and
        // explain the situation instead of risking a broken menu bar.
        if version.majorVersion >= 27 {
            return CapabilityReport(
                osVersion: os,
                kind: .unsupported,
                detail: "macOS \(os) uses the single-window menu bar model. BarFold 1.0 does not ship an unverified macOS 27 engine; the arrow stays reachable and folding is disabled.",
                isExperimental: false
            )
        }

        return CapabilityReport(
            osVersion: os,
            kind: .lengthSpacer,
            detail: "Length spacer engine (verified on macOS 26).",
            isExperimental: false
        )
    }

    static func availableEngines() -> [[String: String]] {
        [
            ["name": EngineKind.lengthSpacer.rawValue, "available": "true", "detail": "Separator length expansion"],
            ["name": EngineKind.unsupported.rawValue, "available": "true", "detail": "Diagnostic only; keeps the bar expanded"],
        ]
    }
}
