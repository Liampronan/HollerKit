# Changelog

## 1.0.0-beta.4

- **iOS:** Let testers attach, paste, and remove photos directly in the bug report sheet, with off-main-actor image downsampling and reliable outbox upload retry handling (#22, #25).
- **iOS:** Reset bug report draft state on re-presentation so a second report does not retain old text or fail to submit, and add a submission progress and confirmation overlay (#23, #24).
- **iOS:** Fix quest speech note dictation lifecycle (speech capture finalization, locale matching, and cancellation), make quest outcome rows tappable across their full width, and add an interactive steps checklist to the quest sheet (#20, #21).
- **iOS:** Fix "Start Quest" button layout inside List rows by replacing `Label` with `HStack` in `QuestCardView`, preventing icon slot distortion and restoring the `play.fill` icon (#26, #27).
- **Server & MCP:** Bumped server and MCP dependencies, pinned `@types/node` to v22, verified MCP lockfiles in CI, and upgraded GitHub Actions workflows (#8, #9, #19).
- **Database:** No new database migrations are required for this release; the existing `001_hollerkit_v1.sql` schema remains current.

## 1.0.0-beta.3

- **iOS:** Quest overlay controls (`Done`, `Mark`, and tap-to-expand) receive taps on iOS 18+ by using `OverlayHitPolicy.capturesTouch` with `interactiveFrame` instead of rejecting touches that hit `UIHostingController`'s root view, while still passing touches outside the bar through to the host app.
- **iOS:** `.hollerKitPresenter()` keeps its content view in a single structural position so runtime `isEnabled` changes do not tear down or reset the host view's `@State`.
- **iOS:** `HollerKit.reconcileEnablement()` configures and refreshes QA quests when `isEnabled()` transitions from `false` to `true` after `HollerKit.configure(...)`.
- **Server:** Removed `fetchTypes: false` from the Supabase Edge Function example and made `postgresStore` serialize/parse `api_keys.scopes` via JSON and Postgres array literals so `hk_` API keys work even when `fetchTypes: false` is configured.
