# iMusic iOS Maintenance Guide

## Product scope
- This repository's active product target is the native iOS IPA in `platforms/ios/`.
- Do not implement or expand desktop or Android features unless the maintainer explicitly reopens that scope.
- Treat this as a long-lived product: preserve user data, backward compatibility, clear ownership, and reproducible releases.

## Product and interface standard
- The reference is Apple Music on iOS 27: native navigation, system Liquid Glass, restrained system typography, consistent spacing, accessible controls, and familiar music-library/player interactions.
- Reuse shared design-system components. Do not introduce one-off colors, radii, row styles, or navigation behaviors without a documented reason.
- Do not copy Apple branding, proprietary assets, or imply affiliation. Reproduce interaction and visual conventions using iMusic identity and lawful assets.
- Every screen must define loading, empty, error/retry, and populated states where applicable.

## Engineering requirements
- Protect existing user data. Any persistence-key, schema, identity, or storage-format change needs a tested migration and rollback/recovery strategy.
- Playback and source operations must be cancellation-safe and reject stale asynchronous results.
- Imported LX source scripts are untrusted input. Keep their capabilities constrained and validate URLs, payload sizes, timeouts, and errors.
- Keep secrets and personal credentials out of logs and source control. Credentials belong in Keychain.
- Prefer small, testable units, explicit state models, structured concurrency, and `Logger` over `print`.
- Add regression tests for every fixed bug. Avoid broad UI or architecture rewrites without characterization tests.

## Validation and delivery
- Before changes: inspect `git status`; never overwrite unrelated user work.
- Run relevant Swift package tests and iOS simulator/UI tests on macOS when available. On other platforms, state the validation limitation explicitly.
- Validate release version, bundle identifier, signing configuration, IPA contents, and update/download links before release.
- Do not claim a build or test passed unless it was actually run and its result observed.
- Keep generated IPA, DerivedData, simulator results, and local build artifacts out of Git.
- Work in small reviewable batches; document risk, migration, and test coverage for each batch.
