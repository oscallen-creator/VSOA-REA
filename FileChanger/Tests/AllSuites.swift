// Each area owns one `<area>Suites` list in its own test file; this file only joins them.
enum TestSuites {
    static var all: [Suite] { coreSuites + conversionSuites + imageSuites + mediaSuites + shellSuites }
}
