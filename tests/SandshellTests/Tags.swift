import Testing

/// Tags shared across the suites.
extension Tag {
    /// Boundaries and unusual inputs.
    @Tag static var edgeCase: Self
    /// Tests that work in a temporary folder on disk.
    @Tag static var fileSystem: Self
}
