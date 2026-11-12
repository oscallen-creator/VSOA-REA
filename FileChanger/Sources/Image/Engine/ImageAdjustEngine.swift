import Foundation
import CoreImage
import CoreGraphics

/// IMG-19..22. One table of sliders drives both the UI and the CoreImage chain.
struct ImageAdjustControl: Identifiable, Sendable {
    let id: String
    let label: String
    let section: String
    let range: ClosedRange<Double>
    var isEV: Bool { id == "exposure" }
    func display(_ v: Double) -> String { isEV ? String(format: "%.2f EV", v) : String(format: "%+.0f", v) }
    private static func c(_ id: String, _ label: String, _ section: String, _ r: ClosedRange<Double> = -100...100) -> ImageAdjustControl {
        .init(id: id, label: label, section: section, range: r)
    }
    // Ranges are ours (inventory: unknown). Exposure is in stops; everything else in -100...100 or 0...100.
    static let all: [ImageAdjustControl] = [
        c("exposure", "Exposure", "Light", -3...3), c("brightness", "Brightness", "Light"), c("contrast", "Contrast", "Light"),
        c("highlights", "Highlights", "Light"), c("shadows", "Shadows", "Light"), c("gamma", "Gamma", "Light"),
        c("temperature", "Temperature", "Colour"), c("tint", "Tint", "Colour"), c("saturation", "Saturation", "Colour"),
        c("vibrance", "Vibrance", "Colour"), c("hue", "Hue", "Colour"), c("fade", "Fade", "Colour", 0...100),
        c("clarity", "Clarity", "Detail", 0...100), c("sharpness", "Sharpness", "Detail", 0...100),
        c("noiseReduction", "Noise Reduction", "Detail", 0...100), c("dehaze", "Dehaze", "Detail", 0...100),
        c("blur", "Blur", "Effects", 0...100), c("vignette", "Vignette", "Effects", 0...100), c("grain", "Grain", "Effects", 0...100),
    ]
    static let sections = ["Light", "Colour", "Detail", "Effects"]
}

struct ImageAdjustments: Equatable, Sendable {
    var values: [String: Double] = [:]
    subscript(id: String) -> Double { get { values[id] ?? 0 } set { values[id] = newValue == 0 ? nil : newValue } }
    var isIdentity: Bool { values.isEmpty }
}

enum ImageAdjustEngine {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    private static func filter(_ name: String, _ image: CIImage, _ params: [String: Any]) -> CIImage {
        guard let f = CIFilter(name: name) else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        for (k, v) in params { f.setValue(v, forKey: k) }
        return f.outputImage ?? image
    }

    /// The adjustment chain. Stages whose sliders are at zero are skipped.
    static func apply(_ a: ImageAdjustments, to input: CIImage) -> CIImage {
        guard !a.isIdentity else { return input }
        let extent = input.extent
        let side = max(extent.width, extent.height)
        var img = input
        if a["exposure"] != 0 { img = filter("CIExposureAdjust", img, ["inputEV": a["exposure"]]) }
        if a["gamma"] != 0 { img = filter("CIGammaAdjust", img, ["inputPower": pow(2, -a["gamma"] / 100)]) }
        if a["temperature"] != 0 || a["tint"] != 0 {
            img = filter("CITemperatureAndTint", img, [
                "inputNeutral": CIVector(x: 6500 + a["temperature"] * 20, y: a["tint"] * 1.5),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if a["brightness"] != 0 || a["contrast"] != 0 || a["saturation"] != 0 {
            img = filter("CIColorControls", img, ["inputBrightness": a["brightness"] / 100 * 0.5,
                                                  "inputContrast": 1 + a["contrast"] / 100 * 0.5,
                                                  "inputSaturation": 1 + a["saturation"] / 100])
        }
        if a["highlights"] != 0 || a["shadows"] != 0 {
            let h = a["highlights"]
            img = filter("CIHighlightShadowAdjust", img, ["inputHighlightAmount": h < 0 ? 1 + h / 100 : 1,
                                                          "inputShadowAmount": a["shadows"] / 100])
            if h > 0 {
                let lift = 0.75 + 0.15 * h / 100
                img = filter("CIToneCurve", img, ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                                                  "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: lift),
                                                  "inputPoint4": CIVector(x: 1, y: 1)])
            }
        }
        if a["vibrance"] != 0 { img = filter("CIVibrance", img, ["inputAmount": a["vibrance"] / 100]) }
        if a["hue"] != 0 { img = filter("CIHueAdjust", img, ["inputAngle": a["hue"] / 100 * Double.pi]) }
        if a["fade"] != 0 {
            let k = a["fade"] / 100 * 0.2
            img = filter("CIColorMatrix", img, ["inputRVector": CIVector(x: 1 - k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 - k, z: 0, w: 0),
                                                "inputBVector": CIVector(x: 0, y: 0, z: 1 - k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                "inputBiasVector": CIVector(x: k, y: k, z: k, w: 0)])
        }
        if a["dehaze"] != 0 {
            let d = a["dehaze"] / 100
            img = filter("CIColorControls", img, ["inputContrast": 1 + d * 0.4, "inputSaturation": 1 + d * 0.2, "inputBrightness": -d * 0.05])
        }
        if a["noiseReduction"] != 0 { img = filter("CINoiseReduction", img, ["inputNoiseLevel": a["noiseReduction"] / 100 * 0.08, "inputSharpness": 0.4]) }
        if a["sharpness"] != 0 { img = filter("CISharpenLuminance", img, ["inputSharpness": a["sharpness"] / 100 * 1.5, "inputRadius": max(1.2, side / 1500)]) }
        if a["clarity"] != 0 { img = filter("CIUnsharpMask", img, ["inputRadius": max(4, side / 100), "inputIntensity": a["clarity"] / 100 * 0.9]) }
        if a["blur"] != 0 {
            img = filter("CIGaussianBlur", img.clampedToExtent(), ["inputRadius": a["blur"] / 100 * side / 60]).cropped(to: extent)
        }
        if a["vignette"] != 0 { img = filter("CIVignette", img, ["inputIntensity": a["vignette"] / 100 * 1.6, "inputRadius": side / 400 + 1]) }
        if a["grain"] != 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let g = a["grain"] / 100
            // Add the noise's luminance as a soft-light layer.
            let mono = filter("CIColorControls", noise.cropped(to: extent), ["inputSaturation": 0, "inputContrast": 1 + g * 0.5])
            let faded = filter("CIColorMatrix", mono, ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: g * 0.7)])
            img = filter("CISoftLightBlendMode", faded, ["inputBackgroundImage": img])
        }
        return img.cropped(to: extent)
    }

    static func render(_ a: ImageAdjustments, _ image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let out = apply(a, to: input)
        guard let cg = context.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: ImageFiles.space(for: image)) else {
            throw FileChangerError.failed("Could not render the photo adjustments.")
        }
        return cg
    }

    static func adjust(_ url: URL, _ a: ImageAdjustments, progress: ProgressHandler) async throws -> URL {
        let image = try ImageFiles.load(url)
        progress(0.3)
        let out = try render(a, image)
        progress(0.8)
        return try await ImageFiles.save(out, beside: url, suffix: "-edited")
    }
}
