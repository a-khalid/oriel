# Contributing to Nafitha

Thank you for helping. Issues, fixes, docs and translations are all welcome.

## Getting started

```bash
make test   # must pass
make run    # builds build/Nafitha.app and opens it
```

You can open `Package.swift` in Xcode to edit code. Machines can only start from the signed app bundle, because Virtualization.framework requires the `com.apple.security.virtualization` entitlement. So run the app with `make run`, not from the Xcode Run button.

## Guidelines

- Keep `NafithaCore` free of UI code; the app target only renders state.
- Call Virtualization.framework from the main actor only (see `Sources/NafithaCore/Runtime/VZMainQueue.swift`).
- Never write the EFI variable store or machine identifier anywhere except bundle creation. Recreating them erases boot entries and changes the guest's hardware identity.
- Code, comments and pull requests are in English.
- Add tests for new logic in `NafithaCore` (`swift-testing`).

## Translations

UI strings are written in English in code and translated in `Resources/<language>.lproj/Localizable.strings`.

1. Copy `Resources/ar.lproj/Localizable.strings` to `Resources/<code>.lproj/Localizable.strings` and translate the values. Leave the keys unchanged.
2. Add the language code to `CFBundleLocalizations` in `Support/Info.plist`.
3. Run `make lint-strings`. It lists any missing keys.
