# Third-Party Notices

Roomy is proprietary software. The Roomy macOS application binary does not
embed any third-party open-source libraries beyond the Apple SDKs provided
by macOS itself.

The Roomy marketing website references the following third-party assets at runtime via a public CDN.
They are not bundled with the macOS application.

---

## Geist Sans

- **Source:** https://github.com/vercel/geist-font
- **License:** SIL Open Font License, Version 1.1 (OFL-1.1)
- **Copyright:** © Vercel, Inc.
- **Usage in Roomy:** Loaded by the marketing website (`landing/`) via
  `@fontsource/geist-sans` from `cdn.jsdelivr.net`. The font is not
  bundled with or redistributed by the Roomy application.

## Geist Mono

- **Source:** https://github.com/vercel/geist-font
- **License:** SIL Open Font License, Version 1.1 (OFL-1.1)
- **Copyright:** © Vercel, Inc.
- **Usage in Roomy:** Loaded by the marketing website (`landing/`) via
  `@fontsource/geist-mono` from `cdn.jsdelivr.net`. The font is not
  bundled with or redistributed by the Roomy application.

---

### About the SIL Open Font License (OFL-1.1)

The full text of the OFL-1.1 is available at:
https://openfontlicense.org/open-font-license-official-text/

The OFL permits free use, study, modification, and redistribution of the
fonts, provided that any derivative font files are not sold by themselves
and that the reserved font names are not reused without permission.

---

## Apple Platform Frameworks

Roomy is built on Apple's macOS frameworks (SwiftUI, AppKit, Foundation,
etc.), which are provided by Apple under the terms of the Apple SDK
license accepted by developers when installing Xcode. These frameworks
are not redistributed by Roomy; they are linked at runtime against
system-provided binaries on the end user's Mac.

---

If you believe a third-party component is used by Roomy but is not listed
here, please contact support@getroomy.dev so we can update this notice.
