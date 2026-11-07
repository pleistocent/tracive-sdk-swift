import ImageIO
import PhotosUI
import SwiftUI
import TraciveSDK
import TraciveSDKExtended
import UIKit
import UniformTypeIdentifiers

struct EvidenceFile: @unchecked Sendable {
  let name: String?
  let data: Data
  let mimeType: String
  let thumbnail: UIImage?
}

/// One picked file, read only when its row starts.
struct EvidenceInput: Sendable {
  let read: @Sendable () async throws -> EvidenceFile

  static func attachment(_ attachment: ReportAttachment) -> EvidenceInput {
    EvidenceInput {
      EvidenceFile(
        name: nil,
        data: attachment.bytes,
        mimeType: attachment.mimeType,
        thumbnail: thumbnail(of: attachment.bytes, mimeType: attachment.mimeType)
      )
    }
  }

  static func document(at url: URL, maxBytes: Int) -> EvidenceInput {
    EvidenceInput {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      // Asked before reading, so a huge file is refused without loading it into memory.
      guard size <= maxBytes else {
        throw TraciveReportError(code: .fileTooLarge, message: "A PDF must be smaller than 1 MiB.")
      }
      return EvidenceFile(
        name: url.lastPathComponent,
        data: try Data(contentsOf: url),
        mimeType: "application/pdf",
        thumbnail: nil
      )
    }
  }

  static func photo(_ result: PHPickerResult) -> EvidenceInput {
    let provider = PickedProvider(provider: result.itemProvider)
    return EvidenceInput {
      let (data, mimeType) = try await provider.loadImage()
      return EvidenceFile(
        name: provider.provider.suggestedName,
        data: data,
        mimeType: mimeType,
        thumbnail: thumbnail(of: data, mimeType: mimeType)
      )
    }
  }

  private static func thumbnail(of data: Data, mimeType: String) -> UIImage? {
    guard mimeType.hasPrefix("image/"),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 144,
        ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: image)
  }
}

/// NSItemProvider is not Sendable, and this one is only touched once, from its own read.
private struct PickedProvider: @unchecked Sendable {
  let provider: NSItemProvider

  func loadImage() async throws -> (Data, String) {
    let type =
      provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .image) }
      ?? .image
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let data {
          continuation.resume(returning: (data, type.preferredMIMEType ?? "image/jpeg"))
        } else {
          continuation.resume(
            throwing: error
              ?? TraciveReportError(code: .imageUnreadable, message: "The photo could not be read.")
          )
        }
      }
    }
  }
}

struct PhotoPicker: UIViewControllerRepresentable {
  let limit: Int
  let onPick: ([EvidenceInput]) -> Void
  @Environment(\.presentationMode) private var presentationMode

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = limit
    // Avoids a slow transcode: the core recompresses whatever it gets.
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    private let parent: PhotoPicker

    init(_ parent: PhotoPicker) { self.parent = parent }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      parent.presentationMode.wrappedValue.dismiss()
      if !results.isEmpty { parent.onPick(results.map(EvidenceInput.photo)) }
    }
  }
}

struct DocumentPicker: UIViewControllerRepresentable {
  let limit: Int
  let maxBytes: Int
  let onPick: ([EvidenceInput]) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
    picker.allowsMultipleSelection = limit > 1
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let parent: DocumentPicker

    init(_ parent: DocumentPicker) { self.parent = parent }

    func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      parent.onPick(urls.map { EvidenceInput.document(at: $0, maxBytes: parent.maxBytes) })
    }
  }
}
