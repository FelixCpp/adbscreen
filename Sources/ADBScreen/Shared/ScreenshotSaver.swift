import AppKit
import UniformTypeIdentifiers

/// Asks the user where to save captured media — a save panel right after
/// the shot/recording, rather than a pre-configured folder.
enum ScreenshotSaver {
    static func promptForLocation(suggestedName: String, contentType: UTType, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Speicherort wählen"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    static func promptAndSave(pngData: Data, suggestedName: String) {
        promptForLocation(suggestedName: suggestedName, contentType: .png) { url in
            try? pngData.write(to: url)
        }
    }

    static func promptAndSave(image: NSImage, suggestedName: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }
        promptAndSave(pngData: pngData, suggestedName: suggestedName)
    }

    /// Moves a finished recording (written to a temp file while capturing)
    /// to a location the user picks now that it's done.
    static func promptAndMove(tempURL: URL, suggestedName: String, contentType: UTType) {
        promptForLocation(suggestedName: suggestedName, contentType: contentType) { destURL in
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Aufnahme konnte nicht gespeichert werden"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    static func filename(prefix: String, ext: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(prefix)-\(formatter.string(from: Date())).\(ext)"
    }
}
