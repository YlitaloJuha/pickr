import os

/// Local-only diagnostics for the PhotoKit adapter (blueprint §4.7).
///
/// - The logger records errors only. Photo identifiers are always `privacy: .private`;
///   error domains and codes are not personal and stay public.
/// - The signposter marks the full build, the delta, size batches and cache writes for
///   Instruments. Nothing leaves the device: no telemetry, no MetricKit upload.
nonisolated enum PhotosLog {
    static let logger = Logger(subsystem: "com.juha.Culler", category: "photos")
    static let signposter = OSSignposter(subsystem: "com.juha.Culler", category: "photos")
}
