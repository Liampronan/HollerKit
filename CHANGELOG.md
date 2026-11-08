# Changelog

## 1.0.0-beta.3

- **iOS:** Quest overlay controls (`Done`, `Mark`, and tap-to-expand) receive taps on iOS 18+ by using `OverlayHitPolicy.capturesTouch` with `interactiveFrame` instead of rejecting touches that hit `UIHostingController`'s root view, while still passing touches outside the bar through to the host app.
- **iOS:** `.hollerKitPresenter()` keeps its content view in a single structural position so runtime `isEnabled` changes do not tear down or reset the host view's `@State`.
- **iOS:** `HollerKit.reconcileEnablement()` configures and refreshes QA quests when `isEnabled()` transitions from `false` to `true` after `HollerKit.configure(...)`.
- **Server:** Removed `fetchTypes: false` from the Supabase Edge Function example and made `postgresStore` serialize/parse `api_keys.scopes` via JSON and Postgres array literals so `hk_` API keys work even when `fetchTypes: false` is configured.
