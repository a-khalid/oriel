# Contributing to Oriel

Thank you for helping. Issues, fixes, docs and translations are all welcome.

Please open an issue (bug report or feature request) before starting on a large change, so we can agree on the approach. Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Getting started

```bash
make test   # must pass
make run    # builds build/Oriel.app and opens it
```

You can open `Package.swift` in Xcode to edit code. Machines can only start from the signed app bundle, because Virtualization.framework requires the `com.apple.security.virtualization` entitlement. So run the app with `make run`, not from the Xcode Run button.

## Guidelines

- Keep `OrielCore` free of UI code; the app target only renders state.
- Call Virtualization.framework from the main actor only (see `Sources/OrielCore/Runtime/VZMainQueue.swift`).
- Never write the EFI variable store or machine identifier anywhere except bundle creation. Recreating them erases boot entries and changes the guest's hardware identity.
- Code, comments and pull requests are in English.
- Add tests for new logic in `OrielCore` (`swift-testing`).
- CI runs `swift build`, `swift test`, `scripts/check-localizations.sh` and a release app build on every pull request.

## Translations

UI strings are written in English in code and translated in `Resources/<language>.lproj/Localizable.strings`.

1. Copy `Resources/ar.lproj/Localizable.strings` to `Resources/<code>.lproj/Localizable.strings` and translate the values. Leave the keys unchanged.
2. Add the language code to `CFBundleLocalizations` in `Support/Info.plist`.
3. Run `make lint-strings`. It lists any missing keys.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE), copyright "The Oriel Authors".
