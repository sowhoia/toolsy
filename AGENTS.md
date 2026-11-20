# Rules for coding agents

Toolsy is a public repository. These rules hold for every coding agent and assistant that works on it,
whoever asks.

## Authorship

- Never credit an AI assistant. No `Co-Authored-By` trailer naming an assistant or a model, no
  "Generated with …" line, and no mention of an assistant in commit messages, pull requests, tags,
  release notes or files. Commits carry the git identity of the person you work for, and nothing else.

## Commits and releases

- Conventional Commits (`feat(mods): …`, `fix(menu): …`, `docs: …`), one commit per logical change,
  with a body that says why.
- Push, open pull requests, tag and publish releases only when asked. `scripts/release.sh` makes a
  release from a commit tagged `vX.Y.Z`; the README's Development section says how.

## Contracts

The mod format, the `toolsy-mod` command line and the files Toolsy keeps on disk are contracts:
existing mods and saved state must keep working. A change to the format updates
[docs/MOD_FORMAT.md](docs/MOD_FORMAT.md) and [docs/MOD_AUTHORING_FOR_AI.md](docs/MOD_AUTHORING_FOR_AI.md)
in the same commit; the engine's tests check that both stay true.

## Checks

```sh
swift test                                  # the app
(cd Packages/ToolsyShared && swift test)
(cd Packages/ToolsyEngine && swift test)    # also the docs and every mod in Mods/
(cd Packages/ToolsyPrivileged && swift test)
```

The app is in English and Russian: every string a change adds to the app gets a Russian entry in
`Resources/ru.lproj/Localizable.strings`, and every text of a mod in `Mods/` (but `vpn-protector`) a
Russian translation in its `localizations`.

## Safety

- Do not run `Mods/vpn-protector`'s commands or its binary unless the person you work for asks: it
  rewrites the firewall of the Mac it runs on and can cut it off the network.
- Try the app as a debug build on scratch data (`--data-root`, `--simulate-helper`, see
  `Sources/Toolsy/App/LaunchOptions.swift`). A release build always uses the real data and runs the
  installed mods.
- The key that signs releases for Toolsy's updater (`~/.config/toolsy/update-signing.key`) signs real
  releases only, never a test or a dry run.
