# Lumen

A native macOS 14+ coding agent built with Swift 6 and SwiftUI. Provider credentials stay in Keychain; the app uses your own provider accounts or a local OpenAI-compatible server.

## Build

Install full Xcode and its command-line components, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
swift test
./scripts/build.sh
open build/Build/Products/Debug/Lumen.app
```

The build script uses `/Applications/Xcode.app` when `DEVELOPER_DIR` is not set. Set that environment variable to use another Xcode installation. `project.yml` is the source of truth; the generated Xcode project is ignored by Git.

`LumenCore` contains the testable logic. `LumenApp` contains the native UI. Tests run offline. There are no runtime package dependencies.
