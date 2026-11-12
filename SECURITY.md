# Security

Please report vulnerabilities privately through GitHub's private vulnerability reporting for this
repository. Do not post exploit details or private documents in public issues.

LexMD has no server, account, or telemetry. It reads and writes the Markdown files you open.
The preview never runs scripts from documents, opens linked files only when you click them, and
reveals apps and scripts in Finder instead of launching them. Images hosted online load only when
you turn on Load images from the web in Settings.
Settings stay in the app's preferences on your Mac. Update checks contact GitHub only when you
enable them or choose Check for Updates, and updates are verified with LexMD's signing key.
Diagram and math libraries are bundled and run apart from document content, never as page scripts.
In Git repositories LexMD runs the local `git` only: it never fetches, pulls, or pushes, and it
changes Git settings only when you set an author in the Commit sheet. The Quick Look extension is
sandboxed, has no network access, and reads only the previewed file and the images it references.
