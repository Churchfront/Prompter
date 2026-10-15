import Foundation

/// The web pages the remote server hands out, read from the app bundle.
/// Only the files listed here are served, so a request can never reach anything else.
enum WebAssets {
    private static let files: [String: (resource: String, ext: String, type: String)] = [
        "remote.html": ("remote", "html", "text/html; charset=utf-8"),
        "display.html": ("display", "html", "text/html; charset=utf-8"),
        "embed.html": ("embed", "html", "text/html; charset=utf-8"),
        "prompter.js": ("prompter", "js", "text/javascript; charset=utf-8"),
        "prompter.css": ("prompter", "css", "text/css; charset=utf-8"),
        "figtree.ttf": ("Figtree-VariableFont_wght", "ttf", "font/ttf")
    ]

    static func response(for name: String) -> RemoteResponse {
        guard let file = files[name], let data = data(resource: file.resource, ext: file.ext) else {
            return .notFound
        }
        return RemoteResponse(contentType: file.type, body: data)
    }

    private static func data(resource: String, ext: String) -> Data? {
        // Synchronized folders copy resources flat into the bundle; "Web" covers a folder reference.
        let url = Bundle.main.url(forResource: resource, withExtension: ext)
            ?? Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "Web")
        return url.flatMap { try? Data(contentsOf: $0) }
    }
}
