# HollerKit iOS SDK (`ios/`)

The HollerKit Swift package provides in-app bug reporting and guided QA test quests for **iOS 18+** with zero third-party dependencies.

---

## 1. Add the Package to Xcode

1. In Xcode, open **File > Add Package Dependencies...** and enter `https://github.com/Liampronan/HollerKit` (or click **Add Local...** and select the `HollerKit` repository root).
2. Add the `HollerKit` library product to your app target.
3. If you use QA Quests, add your `hollerkit-quests.json` file to your app target's **Copy Bundle Resources** build phase so quests are available immediately at launch (and synced with your server when online).

---

## 2. Configure at Launch

Call `HollerKit.configure(...)` on startup and attach `.hollerKitPresenter()` to your root view:

```swift
import HollerKit
import SwiftUI

@main
struct MyApp: App {
    init() {
        HollerKit.configure(
            server: URL(string: "https://your-project.supabase.co/functions/v1/hollerkit")!,
            auth: {
                // Return the signed-in tester's JWT, or nil when signed out.
                try? await supabase.auth.session.accessToken
            },
            isEnabled: {
                // Active in Debug and TestFlight; inert in App Store builds.
                HollerKitEnvironment.isDebugOrTestFlight
            },
            invocation: [.shake, .screenshot],
            inputMode: .textAndAudio,
            captureBreadcrumbs: true,
            quests: .bundled("hollerkit-quests") { route in
                // Optional: navigate when a tester taps "Start Quest"
                AppRouter.shared.navigate(to: route)
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .hollerKitPresenter()
        }
    }
}
```

---

## 3. Why Runtime Gating (`isEnabled`) Instead of `#if DEBUG`?

Xcode compiles **TestFlight** archives using the **Release** build configuration. If you wrap HollerKit in `#if DEBUG`, it is stripped out of TestFlight builds and beta testers can't use it.

Instead, keep HollerKit linked and pass `isEnabled: { HollerKitEnvironment.isDebugOrTestFlight }`:
- **In Debug & TestFlight:** Shake/screenshot gestures, breadcrumbs, and the QA Quests board are active.
- **In App Store builds (`isEnabled() == false`):** HollerKit installs no gesture observers, records no breadcrumbs, starts no new network requests, and turns `.hollerKitPresenter()`, `presentBugReport()`, and `presentQuests()` into no-ops. (If you embed `HollerKit.presentationView()` or `HollerKit.questBoardView()` directly in your own view hierarchy, gate those views with `isEnabled` as well.)

### Required `Info.plist` Keys for Voice Dictation

Because TestFlight builds are Release archives, include these keys in `Info.plist` whenever voice dictation (`.textAndAudio`) is enabled:
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

---

## 4. Offline & Signed-Out Queueing

Testers can file bug reports or finish quests even while offline or signed out:
- Submissions and screenshots are queued on disk (without storing auth tokens).
- The outbox flushes automatically on launch, when the app enters the foreground, when connectivity returns, and when a new report is submitted.
- If a tester signs in while the app is already open on a single-user device, you can call `await HollerKit.flushOutbox()` (and optionally `await HollerKit.quests.refresh()`) after login completes. Note that queued reports are not bound to a specific user ID on disk, so flushing after sign-in submits any pending items under the newly signed-in account—avoid calling `flushOutbox()` across account switches on shared devices.

---

## 5. Optional: App-Side Protocol Wrapper

If you prefer not to import `HollerKit` across your feature views, wrap it behind a tiny protocol in your app:

```swift
import HollerKit

@MainActor
protocol QAFeedbackService {
    func configure()
    func breadcrumb(_ message: String, category: String?)
    func presentBugReport()
    func presentQuests()
}

struct LiveQAFeedbackService: QAFeedbackService {
    func configure() {
        HollerKit.configure(
            server: URL(string: "https://your-project.supabase.co/functions/v1/hollerkit")!,
            auth: { try? await AuthManager.shared.currentAccessToken() },
            isEnabled: { HollerKitEnvironment.isDebugOrTestFlight },
            invocation: [.shake, .screenshot],
            quests: .bundled("hollerkit-quests") { route in
                AppRouter.shared.navigate(to: route)
            }
        )
    }

    func breadcrumb(_ message: String, category: String? = nil) {
        HollerKit.breadcrumb(message, category: category)
    }

    func presentBugReport() { HollerKit.presentBugReport() }
    func presentQuests() { HollerKit.presentQuests() }
}

struct NoOpQAFeedbackService: QAFeedbackService {
    func configure() {}
    func breadcrumb(_ message: String, category: String? = nil) {}
    func presentBugReport() {}
    func presentQuests() {}
}
```
