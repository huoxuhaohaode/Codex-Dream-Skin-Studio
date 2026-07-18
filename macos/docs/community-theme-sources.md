# Community theme source review

The in-app community catalog contains only data-only themes whose source,
license claim, immutable Git commit, and SHA-256 hashes were reviewed. Catalog
downloads are restricted to commit-pinned `raw.githubusercontent.com` URLs.

## Verified catalog entry

- **世事宜梦境** — `xnydl/codex-dream-skin`, commit
  `8508629b3839682d6b51b299c8a1883b7b209eac`, MIT software license. Its preset
  documentation says the background is deterministically generated with Node
  and zlib and contains no photograph, person, or third-party IP. The catalog
  pins both `theme.json` and `background.jpg` by SHA-256.

## Reviewed but not cataloged

- `fantuan-lab/codex-skin-market`: software is MIT, but the artwork license
  limits separate extraction or redistribution.
- `zhenxishuai/Codex-ONE-Dream-Skin`: the portrait is a demonstration asset and
  is not licensed for independent redistribution.
- `cyjg1/codex-Arknights-skin` and other franchise/celebrity themes: software
  licensing does not establish redistribution rights for character artwork or
  likenesses.
- University-branded themes: notices retain logo and photography rights with
  the universities and describe the packages as private previews.

Users can still import a local folder, a standard `.dreamskin` package, or a
legacy `.codexskin` package. Local imports are marked unverified unless their
provenance comes from the built-in catalog. The importer never runs scripts or
copies CSS from a third-party package. Verified catalog imports retain their
source URL and cannot be repackaged by the app.
