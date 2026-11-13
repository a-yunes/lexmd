import Foundation

/// The document shell for pages LexMD shows or writes without its script: Quick Look previews
/// and exported HTML. The in-app preview builds its own page around the script.
package enum StandalonePage {
    /// A complete page: the reader's language, the policy, each stylesheet in order, and the
    /// rendered document in `#content`. `styles` must already be safe inside `<style>`.
    package static func html(title: String, policy: String, styles: [String], body: String) -> String {
        """
        <!doctype html>
        <html lang="\(MarkdownHTML.languageTag())">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="LexMD">
        <title>\(MarkdownHTML.escape(title))</title>
        \(styles.map { "<style>\n\($0)\n</style>" }.joined(separator: "\n"))
        </head>
        <body>
        <article id="content">\(body)</article>
        </body>
        </html>

        """
    }
}
