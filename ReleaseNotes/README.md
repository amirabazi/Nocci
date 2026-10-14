# Release notes

One file per marketing version, named after it: `0.2.0.md`, `0.3.0.md`.

`Scripts/release.sh` refuses to build without the file for the version in
`Config/Version.env`, and copies it next to the archive under the archive's own name.
`generate_appcast` pairs the two by matching basename and embeds the text as the update's
description, which is what Sparkle shows in its update window.

So this is the text a user reads when deciding whether to install. Write it for them, not
as a changelog for yourself: what changed, what they need to do differently, anything that
could surprise them. Keep it short. Markdown headings and lists render; keep images out,
since the window is small and offline users see nothing.

Notes are never rewritten after a release goes out. `generate_appcast` adds a signing
warning to the file, and editing a published file invalidates its signature until the tool
is run again.
