# RoomyCore package

The platform-independent part of Roomy. See the repository [README](../README.md) and [docs/architecture.md](../docs/architecture.md).

| Target | Kind | Depends on | Notes |
|---|---|---|---|
| `RoomyCore` | library | Foundation | Scanner, rule catalog, probes, disposal, reports. Builds on macOS and Linux. |
| `RoomyFleet` | library | RoomyCore, swift-crypto | Policy, evaluator, audit log, metrics, metrics server, license, runner. |
| `roomy` | executable | both, swift-argument-parser | The CLI. |

```sh
swift build && swift test
swift build -c release --product roomy --static-swift-stdlib    # Linux single binary
```

Rules live in `Sources/RoomyCore/Rules/builtin-rules.json` and are embedded into the binary with SwiftPM's `embedInCode` resource, so a release is one file on Linux.
