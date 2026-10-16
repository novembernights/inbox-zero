import Foundation

private struct Case {
    let name: String
    let mimeType: String
    let disposition: String?
    let ids: [String]
    let html: String
    let expected: Bool
}

private let cases = [
    Case(name: "referenced inline signature logo", mimeType: "image/png", disposition: "inline; filename=logo.png", ids: ["<signature-logo>"], html: "<img src='cid:signature-logo'>", expected: true),
    Case(name: "normal image attachment", mimeType: "image/png", disposition: "attachment; filename=photo.png", ids: ["photo"], html: "<img src='cid:photo'>", expected: false),
    Case(name: "unreferenced inline image", mimeType: "image/jpeg", disposition: "inline", ids: ["headshot"], html: "<p>Hello</p>", expected: false),
    Case(name: "inline PDF remains visible", mimeType: "application/pdf", disposition: "inline", ids: ["document"], html: "<a href='cid:document'>PDF</a>", expected: false),
    Case(name: "missing disposition with referenced content ID", mimeType: "image/gif", disposition: nil, ids: ["badge"], html: "<img src=\"cid:badge\">", expected: true)
]

var failures = 0
for test in cases {
    let actual = MIMEAttachmentPolicy.shouldHideAsInlineBodyAsset(
        mimeType: test.mimeType,
        disposition: test.disposition,
        contentIdentifiers: test.ids,
        html: test.html
    )
    print("\(actual == test.expected ? "PASS" : "FAIL"): \(test.name)")
    if actual != test.expected { failures += 1 }
}
guard failures == 0 else { exit(1) }
