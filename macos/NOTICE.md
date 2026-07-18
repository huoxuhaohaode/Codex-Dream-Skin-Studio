# Notices

Codex Dream Skin Studio is an **unofficial** customization project and is **not affiliated with, endorsed by, or sponsored by OpenAI**.

## Software license

The MIT License in `LICENSE` applies to the **software source code** in this repository (scripts, CSS, injectors, docs that describe the software, and the abstract demo asset generated for this repo).

It does **not** grant rights to:

- OpenAI or Codex trademarks, product names, logos, or trade dress
- Official Codex / ChatGPT application binaries, `.app` bundles, or `app.asar`
- Any user-supplied images or third-party artwork you drop into a theme
- Character likenesses, franchise art, or celebrity imagery

## Demo artwork

`assets/portal-hero.png` is original abstract geometric art generated for this open-source repository (no characters). Replace it with your own image before shipping a branded theme to customers.

The following original project assets were generated with OpenAI's built-in
image generation tool on 2026-07-18 from prompts written specifically for this
repository. They contain no imported third-party artwork, named characters, or
recognizable people:

- `theme-switcher/Assets/AppIcon-1024.png`
- `presets/preset-lunar-harbor/background.png`
- `presets/preset-paper-garden/background.png`
- `presets/preset-solar-foundry/background.png`
- `presets/preset-glass-coast/background.png`
- `presets/preset-orbit-library/background.png`
- `presets/preset-porcelain-tide/background.png`
- `presets/preset-verdant-atrium/background.png`
- `presets/preset-ink-mountain/background.png`
- `presets/preset-crystal-canyon/background.png`
- `presets/preset-cloud-workshop/background.png`

They are bundled as Dream Skin application/demo artwork. As with any generated
asset, downstream distributors remain responsible for their own rights review.

## Verified community catalog

The application does not bundle community artwork. Its catalog may download a
theme only from an immutable GitHub commit after separate SHA-256 checks for
the theme configuration and image. The first entry, **世事宜梦境**, comes from
`xnydl/codex-dream-skin` commit
`8508629b3839682d6b51b299c8a1883b7b209eac`. That repository applies MIT to
its software and states that this preset is deterministically generated
abstract artwork with no photograph, person, or third-party IP. The original
repository remains the authoritative source for its license and provenance.
See `docs/community-theme-sources.md` for the review record and exclusions.

## Arina Hashimoto reference material

The following user/maintainer-supplied files are excluded from the MIT software license:

- `presets/preset-romantic-rose/background.jpg`
- `../windows/assets/dream-reference.jpg`
- `../docs/images/presets/romantic-rose-source.png`
- `../docs/images/presets/romantic-rose-light.jpg`
- `../docs/images/presets/romantic-rose-dark.jpg`

They are included at the maintainer's direction as a local theme preset, source archive, and real runtime previews. They are not official OpenAI/Codex artwork. Their inclusion does not certify or grant third-party likeness, model-output, or redistribution rights. Downstream redistribution and commercial use require an independent rights review; the two runtime screenshots are documentation previews and must never be imported as wallpapers.

## Runtime

This project does not redistribute Node.js. At runtime it validates and uses the Node.js executable already signed and bundled inside the user's official Codex desktop application.

## Security model

Themes are applied through Chromium DevTools Protocol on **loopback only**. While a themed session is running, treat the local debugging port as sensitive: do not run untrusted local software that could attach to it. Use the Restore launcher to tear down the themed session and debugging port.
