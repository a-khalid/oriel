## What does this change?

<!-- A short description of the change and why it is needed. Link related issues with "Fixes #123". -->

## How was it tested?

<!-- Guests and macOS versions you tried, and the commands you ran. -->

## Checklist

- [ ] `make test` passes
- [ ] `make lint-strings` passes (new UI strings are translated in every `Resources/<lang>.lproj`)
- [ ] `OrielCore` stays free of UI code; Virtualization.framework is only called from the main actor
- [ ] New logic in `OrielCore` has tests
- [ ] Code, comments and the PR description are in English
