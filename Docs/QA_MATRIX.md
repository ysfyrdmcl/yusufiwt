# QA Matrix

| Gate | Mac Local V1 | V2/full product |
| --- | --- | --- |
| macOS app/helper/hook build | Required | Required |
| Local Swift/domain/IPC/UI tests | Required | Required |
| Fake-agent socket/persistence/decision smoke | Required | Required |
| Live Codex hook approve/deny/ack | Required or explicit blocker | Required |
| Offline/no outbound runtime | Required | Optional by mode |
| iOS/watchOS/APNs/relay | Deferred | Required |
| Developer ID/notarization/Sparkle | Deferred | Required |

The detailed release checklist is `MAC_LOCAL_V1_RELEASE_CHECKLIST.md`; fixture evidence is never reported as a live provider or OS-notification pass.
