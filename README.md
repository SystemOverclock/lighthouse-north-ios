# Lighthouse North SDK for iOS

Add push notifications to your iOS app with built-in LGPD consent evidence, heartbeat, and easy opt-out.

## Features

- 📱 **Push registration** — device token + consent evidence in one call
- 🔔 **Heartbeat** — keeps device alive on the platform (24h, auto-restart)
- 🚪 **Opt-out** — one method, always free, never throws
- 🛡️ **LGPD by design** — collects only `platform`, `token`, `contactRef`, `consent`. Nothing else
- 🔐 **iOS Keychain** — token stored securely, never in UserDefaults
- 🔒 **No secrets in logs** — tokens are always masked
- 📦 **No Firebase bundled** — uses your app's APNs token

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies** → enter:

```
https://github.com/SystemOverclock/lighthouse-north-ios.git
```

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SystemOverclock/lighthouse-north-ios.git", from: "0.2.0")
]
```

## Quick Start

### 1. Get your App Key

In your Lighthouse North dashboard: **Apps → Keys**. The key looks like `ak_...`.

> Keep it in environment config or Keychain, never hardcoded.

### 2. Initialize

```swift
import LighthouseNorthClient

let client = LighthouseNorthClient.shared
client.initialize(
    appKey: "ak_...",
    apiBaseUrl: "https://api.lighthousenorth.com.br"
)
```

### 3. Register for Push

Call this from a user action, after APNs returns a token:

```swift
func didRegisterForRemoteNotifications(withDeviceToken token: Data) {
    let tokenString = token.map { String(format: "%02x", $0) }.joined()
    client.registerForPush(
        token: tokenString,
        contactRef: "user-123",        // your user ID (optional)
        policyVersion: "2026-09"       // consent policy version
    ) { result in
        if case .success = result {
            client.startHeartbeat()
        }
    }
}
```

### 4. Handle Opt-out

Always show an opt-out option in your app settings:

```swift
client.optOut { result in
    // device removed from platform
}
```

## Requirements

- iOS 12+ · Swift 5.9+ · Xcode 15+
- APNs push notification capability enabled in your app

## Privacy

This SDK collects exactly: device platform, APNs token, your contact reference, and consent version. No IP, no user agent, no advertising ID, no app data. Tokens are stored in iOS Keychain. See our [Privacy Policy](https://lighthousenorth.com.br/privacidade).

## License

MIT
