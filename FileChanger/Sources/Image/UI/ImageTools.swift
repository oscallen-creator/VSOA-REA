import Foundation
import SwiftUI

/// Image tools on the wheel (IMG-*, META-* in docs/inventory/image.md). Owned by the image builder.
enum ImageTools {
    private static let imageOnly: Set<FileKind> = [.image]

    @MainActor static var all: [FileToolSpec] {
        [
            FileToolSpec(id: "resizeImage", wheelLabel: "RESIZE", title: "Resize Images", symbol: "arrow.up.left.and.arrow.down.right",
                         kinds: imageOnly, minFiles: 1, maxFiles: .max, action: .panel { AnyView(ResizeEditor(files: $0)) }),
            FileToolSpec(id: "compress", wheelLabel: "COMPRESS", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                         kinds: [.image, .pdf], minFiles: 1, maxFiles: .max, action: .panel { AnyView(CompressEditor(files: $0)) }),
            FileToolSpec(id: "cropImage", wheelLabel: "CROP", title: "Crop Image", symbol: "crop",
                         kinds: imageOnly, minFiles: 1, maxFiles: .max, action: .panel { AnyView(CropEditor(files: $0)) }),
            FileToolSpec(id: "editImage", wheelLabel: "EDIT", title: "Edit Photo", symbol: "slider.horizontal.3",
                         kinds: imageOnly, minFiles: 1, maxFiles: .max, action: .panel { AnyView(AdjustEditor(files: $0)) }),
            FileToolSpec(id: "annotateImage", wheelLabel: "ANNOTATE", title: "Annotate Photo", symbol: "pencil.and.outline",
                         kinds: imageOnly, minFiles: 1, maxFiles: 1, action: .panel { AnyView(AnnotateEditor(files: $0)) }),
            FileToolSpec(id: "createCollage", wheelLabel: "COLLAGE", title: "Create Collage", symbol: "square.grid.2x2",
                         kinds: imageOnly, minFiles: 2, maxFiles: .max, action: .panel { AnyView(CollageEditor(files: $0)) }),
            FileToolSpec(id: "frameImage", wheelLabel: "ADD BG", title: "Add Background", symbol: "photo.artframe",
                         kinds: imageOnly, minFiles: 1, maxFiles: .max, action: .panel { AnyView(FrameEditor(files: $0)) }),
            FileToolSpec(id: "redactImage", wheelLabel: "REDACT", title: "Redact Photo", symbol: "eye.slash",
                         kinds: imageOnly, minFiles: 1, maxFiles: .max, action: .panel { AnyView(RedactEditor(files: $0)) }),
            FileToolSpec(id: "readQRCode", wheelLabel: "READ QR", title: "Read QR Codes", symbol: "qrcode.viewfinder",
                         kinds: imageOnly, minFiles: 1, maxFiles: .max, action: .run { QRResultsWindow.show($0) }),
            FileToolSpec(id: "removeMetadata", wheelLabel: "METADATA", title: "Metadata", symbol: "doc.text.magnifyingglass",
                         kinds: [.image, .pdf], minFiles: 1, maxFiles: .max, action: .panel { AnyView(MetadataEditor(files: $0)) }),
        ]
    }
}
