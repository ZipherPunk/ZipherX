// PrintSilencer.swift
// ZipherX
//
// Silences all print() calls in Release builds.
// Debug builds retain full logging for development.

#if !DEBUG
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    // Silenced in Release builds
}
#endif
