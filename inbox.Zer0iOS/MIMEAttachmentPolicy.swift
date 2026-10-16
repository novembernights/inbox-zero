import Foundation

enum MIMEAttachmentPolicy {
    static func shouldHideAsInlineBodyAsset(
        mimeType: String,
        disposition: String?,
        contentIdentifiers: [String],
        html: String
    ) -> Bool {
        guard mimeType.lowercased().hasPrefix("image/") else { return false }

        let normalizedDisposition = disposition?.lowercased() ?? ""
        guard normalizedDisposition.contains("inline") || normalizedDisposition.isEmpty else { return false }

        let lowerHTML = html.lowercased()
        return contentIdentifiers.contains { rawIdentifier in
            let identifier = rawIdentifier
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \"'"))
                .lowercased()
            guard !identifier.isEmpty else { return false }
            return lowerHTML.contains("cid:\(identifier)")
        }
    }
}
