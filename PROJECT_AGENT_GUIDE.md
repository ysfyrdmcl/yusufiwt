# yusufiwt — Agent Proje Rehberi

> Son kaynak taraması: 2026-07-19  
> Amaç: Bu dosya, projeye yeni giren bir agent'in bütün depoyu baştan taramadan ürün kapsamını, mimariyi, kritik sözleşmeleri ve doğru değişiklik noktalarını anlaması için hazırlanmıştır.  
> Kaynak önceliği: Çalışan kaynak kod ve testler > `Docs/MAC_LOCAL_V1_SCOPE.md` > ADR'ler > bu rehber > uzun vadeli `yusufiwt_PROJECT_PLAN.md`.

## 1. Bir dakikalık özet

`yusufiwt`, AI kodlama agent'lerini izleyen ve onların onay, soru ve plan taleplerini güvenli biçimde yöneten native Swift bir operasyon merkezidir.

Güncel dağıtılabilir ürün **Mac Local V1**'dir:

- Hesap ve internet gerektirmeyen native macOS menu bar uygulaması.
- Agent olaylarını alan ayrı, aynı kullanıcı yetkisinde çalışan LaunchAgent helper.
- Hook → Unix socket → helper → SQLite → XPC → UI veri hattı.
- Codex, Claude Code, Gemini CLI ve Cursor için yönetilen hook entegrasyonları.
- Onay/soru/plan yanıtları; provider onayı gelmeden “uygulandı” saymama garantisi.
- Launch'ta büyük pencere açmayan notch-first kabuk; explicit Kontrol Merkezi, Ayarlar, inbox, history, analytics, rules, diagnostics, local notifications ve terminal/IDE'ye geri dönme.

Depoda iOS, watchOS, widget, Live Activity, APNs, Vapor relay, Sparkle ve companion kriptografisi de bulunur; bunlar korunmuş **V2 kodudur ve Mac Local V1 çalışma/release kapsamına dahil değildir**.

## 2. Ürünün değişmez sınırları

Bir değişiklik yapmadan önce şu kuralları varsayılan gerçek kabul et:

1. **Local-first:** Mac Local V1 çevrimdışı ve hesapsız çalışır.
2. **Tek Mac:** Agent yürütme otoritesi yalnızca yerel Mac helper'dır. iPhone/Watch execution node değildir.
3. **Helper otoritesi:** UI doğrudan provider veya veritabanı otoritesi değildir; kalıcı karar ve durum helper üzerinden ilerler.
4. **Provider acknowledgment:** UI/relay kabulü başarı değildir. Karar ancak provider acknowledgment sonrasında applied olabilir.
5. **Fail-neutral:** Helper yoksa veya timeout olursa hook hiçbir zaman otomatik allow üretmez; provider'ın native akışına nötr döner.
6. **Structured integration first:** Ekran kazıma veya Screen Recording yoktur. Provider hook/app-server sözleşmeleri kullanılır.
7. **Append-only events + snapshots:** Ham normalize olaylar eklemeli saklanır, session snapshot transaction içinde güncellenir.
8. **Deterministik policy:** Risk ve automation kuralları platformdan bağımsız, test edilebilir domain kodundadır.
9. **Gizlilik:** Prompt/kod/secret varsayılan olarak kalıcılaştırılmaz; diagnostik export yazılmadan önce redakte edilir.
10. **Kullanıcı config'ini koru:** Provider config dosyası bütünüyle değiştirilmez. Managed patch, receipt, hash ve scoped uninstall kullanılır.
11. **Strict concurrency:** Swift concurrency kontrolü `complete`; disk sahibi `DatabaseActor`, UI sahibi `@MainActor`'dır.
12. **Capability-driven UI:** Algılanmayan veya desteklenmeyen provider kabiliyeti çalışan özellik gibi gösterilmez.

## 3. Güncel durum

- Ana geliştirme dalı: `main`.
- Güncel ürün kapsamı: `mac-local-v1`.
- Toolchain: README/CI'ye göre Xcode 26.6 ve Swift 6.3; manifestler `swift-tools-version: 6.2`, Swift language mode 6 kullanır.
- Minimum platformlar: macOS 14, iOS 17, watchOS 10.
- Swift kaynak envanteri: yaklaşık 173 dosya / 31.6K satır.
- Test envanteri: 41 Swift test dosyası ve 21 shell contract testi.
- Son implementation raporu Mac Local V1'i **CONDITIONAL** olarak işaretler: otomatik release suite geçmiştir; gerçek hesap-backed Codex oturumu, gerçek reboot ve bazı UI/performance gözlemleri kullanıcı kontrollü doğrulama bekler.
- Depoda paketlenmiş `dist/yusufiwt.app` ve `dist/yusufiwt-macOS-local-v1.zip` bulunur. Bunlar kaynak değildir; yeniden üretilebilir build çıktılarıdır.

## 4. Kullanılan teknolojiler

| Alan | Teknoloji |
| --- | --- |
| Ana dil | Swift 6, strict concurrency |
| Apple UI | SwiftUI; macOS özel davranışlarda AppKit |
| Arka plan servisi | Aynı kullanıcı LaunchAgent helper, `ServiceManagement` |
| App ↔ helper IPC | Authenticated XPC, `NSSecureCoding`, version negotiation |
| Hook ↔ helper IPC | Unix domain socket, özel `ACIP` binary frame |
| Yerel veri | Doğrudan SQLite3, WAL, actor-owned transactions |
| Yerel güvenlik | Security/Keychain, AES-GCM alan şifreleme, dosya sahipliği/mod kontrolleri |
| Companion kripto (V2) | X25519, HKDF, ChaChaPoly, Ed25519, Keychain |
| Relay backend (V2) | Vapor 4, Fluent, PostgreSQL, Redis, JWTKit, Swift Crypto |
| Push (V2) | APNs HTTP/2/JWT; Notification Service Extension |
| IDE entegrasyonu | TypeScript VS Code/Cursor extension, URI commands |
| Proje üretimi | XcodeGen (`project.yml`) |
| Paket yönetimi | Swift Package Manager; relay ayrı Swift package; extension npm |
| Güncelleme (V2) | Sparkle 2.9.2 |
| Format/lint | SwiftFormat, SwiftLint |
| CI | GitHub Actions, macOS 26 runner |
| Dağıtım | Xcode build/archive, ad-hoc veya Apple signing, ZIP/checksum/release manifest |

## 5. Üst düzey mimari

```text
Codex / Claude / Gemini / Cursor
        │ provider hook JSON
        ▼
agentcontrol-hook (CLI)
        │ normalize + bounded input
        ▼
Unix socket / ACIP frame ──► spool (helper yoksa; audit/replay, asla allow değil)
        │
        ▼
AgentControlHelper (tek yerel otorite)
        ├── SessionRegistryActor / HookDecisionBroker
        ├── DatabaseActor ──► SQLite + WAL
        ├── OperationsRuleEngine / diagnostics / retention
        └── authenticated XPC + registry notifications
                         │
                         ▼
                macOS SwiftUI/AppKit UI
                menu bar / notch / Control Center / Settings
```

V2 companion hattı ayrıdır:

```text
Mac helper authority ⇄ E2E opaque envelopes ⇄ Vapor relay ⇄ iOS/Watch companion
```

Relay plaintext agent içeriğini görmemelidir. PostgreSQL ciphertext ve routing state tutar; Redis yalnızca kısa ömürlü presence/queue hint'idir. Disconnect sonrası PostgreSQL pending fetch otoritatiftir.

## 6. Modül bağımlılık yönü

Bağımlılıklar içeriye, platformdan bağımsız domain'e doğru akar:

```text
Apps / Tools / Services
    ↓
AgentMacUI / AgentHookKit / AgentCodexAdapter / AgentCompanion
    ↓
AgentLocalIPC / AgentPersistence / AgentProtocol
    ↓
AgentDomain
```

Temel yasaklar:

- `AgentDomain` UI, IPC, SQLite veya platform framework'lerine bağlanmaz.
- `AgentProtocol`, wire format dışında iş otoritesi olmaz.
- `AgentPersistence` raw SQLite handle/row dışarı çıkarmaz; küçük `Sendable` read model döndürür.
- Mac Local hedefi companion, relay veya Sparkle runtime koduna ulaşmamalıdır.

## 7. Klasör haritası

### Kök dosyalar

| Yol | Görev |
| --- | --- |
| `README.md` | Kısa ürün ve geliştirme girişi |
| `PROJECT_AGENT_GUIDE.md` | Bu hızlı onboarding ve sorun yönlendirme rehberi |
| `yusufiwt_PROJECT_PLAN.md` | Uzun vadeli ürün vizyonu, fazlar ve ayrıntılı tasarım; güncel release override değildir |
| `Package.swift` | Kök SPM graph'ı; library'ler, CLI tool'lar ve test target'ları |
| `project.yml` | XcodeGen kaynağı; Apple app/extension/helper target'larının otoritatif tanımı |
| `Makefile` | Bootstrap, generate, test, lint ve release komutlarının tek giriş noktası |
| `.swiftformat`, `.swiftlint.yml` | Kod biçimi ve lint politikası |
| `.env.example` | Yalnız local geliştirme örneği; native production client shell secret okumaz |

### `Apps/`

- `Apps/macOS/`: Mac uygulama entry point'i, Info plist'ler ve Sparkle controller. `AgentControlMacApp.swift` helper/menu bar/panel/hotkey/notification başlangıcını kurar; full Kontrol Merkezi ve native Settings yalnız explicit kullanıcı eylemiyle açılır.
- `Apps/iOS/`: V2 companion app, pairing/snapshot/outbox ve companion view'ları.
- `Apps/watchOS/`: V2 Watch companion yüzeyi.
- `Apps/Extensions/NotificationService/`: V2 push decrypt/render sınırı; karar uygulayamaz.
- `Apps/Extensions/AgentLiveActivity/`: V2 Live Activity widget.
- `Apps/Extensions/AgentWidgets/`: V2 widget snapshot'ları.
- `Apps/Shared/`: Paylaşılan marka asset'leri ve `YusufiwtBrandMark`.

### `Packages/AgentControlKit/Sources/`

Bu dizin işin çekirdeğidir. Kök `Package.swift` aynı source path'lerini doğrudan target'lara bağlar; nested `Packages/AgentControlKit/Package.swift` ise XcodeGen local package çözümüdür.

#### `AgentDomain`

Foundation'a yakın, platformdan bağımsız iş modeli:

- Strong ID'ler: `NodeID`, `ProjectID`, `SessionID`, `TurnID`, `ToolRunID`, `ApprovalRequestID`, `QuestionID`, `DeviceID`, `EnvelopeID`, `EventID`, `AdapterID`.
- Ana modeller: `AgentSession`, `AgentTurn`, `ToolRun`, `AgentQuestion`, `ApprovalRequest`, `TerminalContext`, `ProjectReference`.
- State machine'ler: `SessionStateMachine`, `ApprovalStateMachine`, `SessionAggregate`.
- Risk: `AgentAction`, `RiskInput`, `RiskClassifier`, `RiskLevel`, `RiskSignal`.
- Operasyon policy: `OperationsRuleEngine`, alert ve düşük risk automation modelleri.
- Capability: `AgentCapability`, `CapabilityMatrix`.
- Typed error ailesi: configuration, integration, protocol, persistence, security, relay, notification, navigation ve policy.

Önemli session durumları state machine ile kontrol edilir. Approval/question event'leri attention state'lerini yönetir. Duplicate event ID ve aynı source için non-increasing sequence state'i tekrar uygulamaz. Unknown event kaydedilir fakat state değiştirmez.

#### `AgentProtocol`

- `EventEnvelope`: versioned, normalize event zarfı.
- `JSONValue`: bilinmeyen/gelecek payload alanlarını güvenli taşıyan Codable JSON ağacı.
- `WireProtocol`: protocol sürümü ve kontrat yardımcıları.
- `JSONSchema/event-envelope-v1.schema.json`: protocol v1 şeması.

Envelope; global event ID, source, session ID, provider sequence, occurred/received timestamps, privacy class, correlation ID ve schema hash taşır. Maksimum encoded boyut 1 MiB'dır. Bilinmeyen top-level alanlar ignore edilir; bilinmeyen event type korunur.

#### `AgentPersistence`

- `DatabaseActor`: SQLite connection ve tüm transaction sınırlarının sahibi.
- `DatabaseActor+Migrations/Reads/Writes/Operations`: sorumluluklara ayrılmış persistence kodu.
- `SQLiteConnection`: düşük seviye sqlite3 wrapper; module dışına çıkmamalı.
- `Migrations`: checksum'lı, sıralı ve gap kabul etmeyen migration listesi.
- `SensitiveFieldCipher`, `KeychainFieldKeyProvider` kullanımı: hassas alan encryption.
- `EventPayloadPrivacyFilter`: kalıcılaştırma öncesi privacy filtreleme.
- `DiagnosticExport`: export öncesi redaction ve açık consent.

SQLite tabloları:

- `schema_migrations`
- `nodes`, `projects`, `terminal_contexts`
- `agent_sessions`, `session_events`
- `turns`, `tool_runs`
- `approval_requests`, `approval_decisions`, `questions`
- `integration_installations`, `rules`, `notification_deliveries`
- `paired_devices`, `sync_outbox`, `replay_nonces`
- `audit_log`, `settings`, `diagnostic_incidents`

`session_events` append-only event store'dur; `agent_sessions` materialized snapshot'tır. Migration öncesi otomatik backup vardır. Proje path'i canonical kabul edilir; farklı provider'ların aynı repo için çakışan project ID üretmesi path üzerinden birleştirilir.

#### `AgentLocalIPC`

- `AgentControlPaths`: kullanıcı runtime path'lerini hesaplar ve mode/ownership doğrular.
- `UnixSocketServer/Client`, `SocketFrameCodec`: hook trafiği.
- `XPCProtocol/Service/Client/Security`: UI trafiği ve same-user/bundle authorization.
- `HelperHost`: DB, registry, spool, Unix socket ve XPC listener'ı compose eder.
- `HelperRuntime`: `HelperRequest` case'lerini otoritatif olarak işler.
- `SessionRegistryActor`: aktif snapshot'ları restore eder ve notification üretir.
- `HookDecisionBroker`: bekleyen synchronous decision'ları revision/expiry ile yönetir.
- `HookSpool`: helper yokken status/audit event'lerini owner-only dosyalara yazar.
- `LaunchAgentManager`: helper register/repair/unregister ve ad-hoc fallback.

Default runtime kökü, App Group path'i socket uzunluğuna uygunsa group container; değilse:

```text
~/Library/Application Support/AgentControl/
├── agent-control.sqlite
├── ipc/helper.sock
├── spool/
└── update-handoff.json
```

Unix frame biçimi:

```text
ACIP magic (4) + version UInt16 BE + message type UInt16 BE
+ payload length UInt32 BE + SHA-256 checksum (32) + payload
```

Maksimum frame 1 MiB. Invalid magic/version/type, oversize, truncation, trailing bytes ve checksum mismatch decode öncesi reddedilir.

Başlıca `HelperRequest` grupları:

- Sağlık: negotiate, health, heartbeat.
- Olay/karar: submitEvent, requestDecision, pendingDecisions, decisionLifecycles, resolveDecision.
- Session: listSessions, sessionSnapshot, sessionEvents.
- Operasyon: history, analytics, rules, alerts, privacy, diagnostics, repair, deletion.
- Release: prepareForUpdate.

#### `AgentHookKit`

- `ProviderHookMapper`: Codex/Claude/Gemini/Cursor/generic JSON event'lerini normalize envelope, usage update, decision request ve provider status event'lerine dönüştürür.
- `ProviderIntegrations`: binary/version detection ve capability matrix.
- `ManagedConfigPatchEngine`: JSON/JSONC/TOML yapısını kayıpsız ve işaretli bloklarla değiştirir.
- `IntegrationManagement`: preview, atomic install, repair, receipt/backup restore ve scoped uninstall.
- `AgentControlHookClient`: socket gönderimi, timeout, neutral fallback ve spool davranışı.
- `BoundedJSON`: maksimum byte/nesting koruması.
- `TerminalContextCapture`: provider sınırında terminal/project bağlamı yakalama.
- `FakeAgentScenarios`: test ve demo senaryoları.

User-level config hedefleri:

| Provider | Config | Normal capability |
| --- | --- | --- |
| Codex | `~/.codex/hooks.json` | monitor + approve/deny + structured question answer; bilinmeyen major monitor-only |
| Claude | `~/.claude/settings.json` | monitor + approve/deny + answer + plan review; bilinmeyen major monitor-only |
| Gemini | `~/.gemini/settings.json` | monitor + approve/deny + plan review; bilinmeyen major monitor-only |
| Cursor | `~/.cursor/hooks.json` | session + scoped write/delete/task + shell/MCP approve/deny + compaction usage; question/plan resmi event olmadığı için unsupported |
| Generic | Harici contract | monitor-only |

Hook komutu her provider'ın beklediği stdout JSON şemasını üretir; diagnostic yalnız stderr'e gider.

#### `AgentCodexAdapter`

Hook'tan ayrı, korunmuş managed Codex app-server entegrasyonu:

- Codex binary/version/schema detection.
- JSONL RPC codec ve contract negotiation.
- Process manager, reconnect ve diagnostics.
- Managed session/turn control.
- Approval coordinator; provider ack gelmeden applied üretmez.

Mac Local release profile'da `FEATURE_CODEX_MANAGED_SESSION = NO`; release-blocking yol Codex hook modudur.

#### `AgentMacUI`

- `AgentControlStore`: `@MainActor` UI state, reconnect ve registry notification tüketimi.
- `XPCAgentControlTransport`: UI'nin helper'a typed XPC erişimi.
- `DashboardViews`: Entegrasyonlar, Otomasyon/Kurallar, Geçmiş/Analiz ve Gizlilik/Tanılama alanlarından oluşan Kontrol Merkezi.
- `DecisionExperience/DecisionViews`: approval, question ve plan review.
- `FloatingPanel`, `NotchPanelView/Geometry`: çok ekranlı kompakt panel.
- `MacNotificationCoordinator/NotificationPolicy`: privacy-aware local notification ve action policy.
- `GlobalHotKey`: varsayılan Control-Option-Space; alternatif Command-Shift-A.
- `TerminalNavigation`: capability planner ve güvenli navigation execution.
- `Phase10Experience/Views`: onboarding/integration/navigation.

UI snapshot alırken health, sessions ve pending decisions çağrılarını paralel yapar. Registry notifications hızlı refresh tetikler; 10 saniyelik polling yalnız recovery fallback'tir.

Navigation önceliği genel olarak: VS Code/Cursor extension URI → WezTerm CLI → Warp resmi workspace URI → açık kullanıcı eylemiyle permission-gated AppleScript → opt-in Accessibility → uygulamayı aktive et → proje klasörü fallback. Shell command interpolation yapılmaz; Automation/Accessibility izni kullanıcı onboarding kontrolüne basmadan istenmez.

#### `AgentCompanion` ve `AgentCompanionAuthority` — V2

- Pairing ve endpoint kriptografisi.
- Relay API/client modelleri.
- Replay protection, local outbox ve companion UX state'i.
- Widget/Watch/Live Activity için bounded snapshot'lar.
- `HelperCompanionAuthority`: companion kararını provider'a uygulayan tek köprü.

iOS Notification Service kısa ömürlü envelope'u yalnız privacy-filtered göstermek için decrypt edebilir; durably consume veya karar apply edemez. High risk in-app Face ID + hold ister. Critical approval ve secret answer companion'da kapalıdır.

#### `BuildSupport`

Build environment, product feature ve release profile kurallarını fail-closed doğrular. Mac Local profile remote/SSH/watch/LAN/telemetry/iOS/relay/APNs/Sparkle/managed Codex'i kapatır; local hook, persistence ve macOS notification açık kalır.

### `Services/`

- `Services/AgentControlHelper/main.swift`: helper process entry point. Path/cipher/auth policy kurar, `HelperHost` başlatır, SIGTERM/SIGINT'te graceful shutdown yapar.
- `Services/AgentControlRelay/`: ayrı deploy edilen V2 Vapor servisi.

Relay bağımlılıkları: Vapor, Fluent, PostgreSQL driver, SQLite test driver, Redis, JWTKit ve Swift Crypto.

Relay endpoint özeti:

- Public: `GET /v1/health`, `GET /v1/ready`, `POST /auth/apple`, `POST /auth/refresh`.
- Authenticated pairing/device: register Mac, list/revoke device, delete account, create/complete pairing.
- Envelope: submit, pending fetch, ack.
- Push: token register/delete, Live Activity token/update.
- WebSocket: `/v1/ws?access_token=...`.
- Internal: bearer-protected operational metrics.

Production persistence PostgreSQL'dir; test veya `RELAY_USE_IN_MEMORY_DB=1` durumunda in-memory SQLite kullanılır. Redis optional ephemeral provider'dır. Relay startup migration çalıştırır ve retention lifecycle kurar.

### `Tools/`

- `AgentControlHook`: production CLI entry point. Komutlar: `emit`, `notify`, `request-decision`, `doctor`, `provider-hook`, `managed-preview/install/repair/uninstall`, `version`.
- `FakeAgentSimulator`: running/progress/approval/question/plan/subagent/completion/failure/duplicate/out-of-order/malformed senaryoları.
- `ProtocolInspector`: health, pending decision ve resolution gibi düşük seviyeli yerel inceleme.

### `Extensions/agentcontrol-navigation/`

VS Code/Cursor extension. TypeScript 5.5, VS Code API `^1.90.0`; `agentcontrol.captureTerminalContext` ve `agentcontrol.registerTerminal` komutlarını, ayrıca URI activation'ı sağlar. `src/extension.ts` kaynaktır; `dist/extension.js`, `.vsix` ve `node_modules` generated/vendor çıktıdır.

### `Config/`

- `Base.xcconfig`: bundle ID'ler, app/keychain groups, version ve default feature değerleri.
- `Debug/Staging/Release.xcconfig`: environment profilleri.
- `MacLocalRelease.xcconfig`: V2 feature'larını açıkça kapatan güncel local release profili.
- `Local.example.xcconfig`: developer-local override şablonu; gerçek `Local.xcconfig` secret içerebilir ve belgede kopyalanmamalı.
- `Entitlements/`: app/helper/extensions yetkileri.
- `LaunchAgents/`: helper plist.
- `Privacy/`: PrivacyInfo manifest ve data-usage metni.
- `ExportOptions/`: App Store/TestFlight/Developer ID export profilleri.
- `Operations/`, `Updates/`, `SBOM/`: release/operations policy, channel ve CycloneDX SBOM verileri.

### `Docs/`

- `MAC_LOCAL_V1_SCOPE.md`: güncel release kapsamı.
- `ARCHITECTURE.md`, `PROTOCOL.md`: kısa teknik sözleşmeler.
- `ADR/0001...0022`: neden bu mimari kararların alındığı.
- `MAC_LOCAL_V1_RELEASE_CHECKLIST.md`: güncel otomatik ve manuel release kanıt listesi.
- `MAC_LOCAL_V1_IMPLEMENTATION_REPORT.md`: son fiziksel build/runtime kanıtı ve kalan manuel işler.
- `THREAT_MODEL.md`, `PRIVACY.md`, `DATA_DELETION.md`: güvenlik/veri sınırları.
- `RELEASE_*`, `INCIDENT/RECOVERY/ROLLBACK_RUNBOOK`: operasyon prosedürleri.
- `Evidence/`: ekran görüntüsü ve doğrulama artefact'ları; source of truth değildir.

### `Scripts/`, `Tests/`, `Brand/`, `dist/`

- `Scripts/`: bootstrap, generate, test, lint, package/install/verify/release script'leri.
- `Tests/Contracts/`: repository ve faz sözleşmelerini shell üzerinden doğrular.
- `Tests/Fixtures/`: process crash/recovery ve fixture yardımcıları.
- `Brand/`: SVG marka kaynağı ve preview.
- `dist/`: yerel paketleme çıktıları. Kaynak değişikliği bu klasörde yapılmaz.

## 8. Xcode target'ları ve release graph'ları

`project.yml` otoritatif kaynaktır; `.xcodeproj` generated çıktıdır. Proje target'ları:

- `AgentControlMacLocal`: güncel Mac Local app; Sparkle/companion hariç.
- `AgentControlMac`: tam/V2 macOS target; Sparkle ve companion dependency'leri korunur.
- `AgentControliOS`, `AgentControlWatch`.
- `NotificationService`, `AgentLiveActivity`, `AgentWidgets`.
- `AgentControlHelper`, `AgentControlHook`.
- `FakeAgentSimulator`, `ProtocolInspector`.

Mac Local paket build'i app içine helper, hook, LaunchAgent plist ve SHA-256 içeren `release-manifest.json` gömer. Fiziksel local graph yalnız app + helper + hook + gerekli local package target'larını içermelidir.

## 9. Temel çalışma akışları

### 9.1 Olay izleme

1. Provider hook JSON gönderir.
2. `ProviderHookMapper` provider/event type'ı normalize eder, stable ID/sequence/project/terminal context üretir.
3. `agentcontrol-hook` bounded JSON doğrular ve Unix socket üzerinden helper'a gönderir.
4. `HelperRuntime` envelope'u doğrular.
5. `DatabaseActor` event'i append eder ve snapshot'ı transaction içinde state machine ile günceller.
6. `SessionRegistryActor` registry notification yayınlar.
7. `AgentControlStore` XPC read model'i yeniler; UI ve notification policy güncellenir.

Structured usage varsa mapper bunu `quotaRemaining`, `contextRemaining` veya `tokenCounts` olarak normalize eder. Session snapshot ve SQLite migration üzerinden XPC read model'e taşınır. Kotalar, context yüzdesi ve token sayaçları birbirine dönüştürülmez; veri yoksa UI `—` gösterir.

### 9.2 Yerel karar

1. Approval/question/plan hook event'i `HookDecisionRequest` olur.
2. Helper önce audit event'ini kalıcılaştırır, sonra request'i `HookDecisionBroker`'da bekletir.
3. UI pending request'i XPC üzerinden gösterir.
4. Kullanıcı request ID + monotonic revision ile resolve eder.
5. Helper expiry, revision, answer IDs/length ve risk/policy kontrollerini yapar.
6. Hook provider'a yalnız provider şemasına uygun sonucu stdout'tan verir.
7. Provider acknowledgment ayrı event olarak lifecycle'ı applied/deniedApplied durumuna ilerletir.

Helper timeout/down durumunda synchronous karar neutral'dır. Spool'a audit yazılmış olması approval anlamına gelmez.

### 9.3 Managed provider kurulumu

1. Binary/version algılanır; bilinmeyen major monitor-only olur.
2. Mevcut config parse edilir.
3. `managed-preview` diff üretir, yazmaz.
4. Atomic install tüm provider diff'lerini önce hazırlar.
5. Managed block, receipt, pre/post hash ve backup ile yazılır.
6. Çoklu kurulumun sonraki adımı fail olursa önceki yazımlar rollback edilir.
7. Repair yalnız sahip olunan bölgeyi düzeltir.
8. Uninstall marker'lı yusufiwt alanlarını güncel dosyadan kaldırır; kullanıcı değişikliklerini korur. External edit sonrası backup restore fail-closed'dur.

## 10. Domain ve güvenlik sözleşmeleri

### Session/event

- Duplicate `EventID`: idempotent no-op.
- Aynı `sourceKey` için `sequence <= lastSequence`: out-of-order, state gerilemez.
- Unknown event: saklanır, snapshot değiştirmez.
- Terminal state sonrası uygunsuz eski event state'i diriltmez; yalnız açık `providerResumed` kontrollü dönüş yapar.
- Waiting approval varken thinking/running/executing event'i attention durumunu gizlememelidir.

### Approval/question

- Revision mismatch, expiry, missing request veya invalid choice hiçbir zaman approval olmaz.
- Stable question answer ID'leri label'dan bağımsızdır.
- Secret yanıt notification yüzeyinde inline sunulmaz.
- High/Critical otomasyon fail-closed'dur.
- Remote/companion `serverAccepted` state'i başarı değildir.

### IPC/filesystem

- Socket ve runtime dizinleri current user'a ait, group/other erişimsiz olmalıdır.
- XPC client same-user ve beklenen signing/bundle policy'den geçmelidir.
- Ad-hoc signature toleransı yalnız Debug veya `AGENTCONTROL_MAC_LOCAL` compile koşulundadır.
- Input boyutu ve JSON nesting bounded olmalıdır.
- User-controlled değer shell command içine interpolate edilmez.

### Privacy

- Privacy sınıfları domain modelinde taşınır.
- Secret/prompt/code varsayılan persistence ve notification metninde maskelenir.
- Diagnostic export consent ister ve yazmadan önce redakte eder.
- Delete/retention helper + persistence seviyesinde uygulanır.

## 11. Environment ve feature flag'ler

### Hook runtime

- `AGENTCONTROL_SOCKET`: socket override.
- `AGENTCONTROL_SPOOL_DIR`: spool override.
- `AGENTCONTROL_HOOK_TIMEOUT_MS`: karar timeout; default 65000 ms.
- `AGENTCONTROL_STATUS_TIMEOUT_MS`: status timeout; default 250 ms.
- `AGENTCONTROL_MAX_INPUT_BYTES`: üst sınır; global frame limitini aşamaz.
- `AGENTCONTROL_NATIVE_FALLBACK`: `0` dışında native fallback açık.
- `AGENTCONTROL_PROVIDER_VERSION`: managed hook komutunun provider version aktarımı.

### Mac Local release

Kapalı: remote mode, SSH, watch, direct LAN, telemetry, iOS companion, relay, APNs, Sparkle, Codex managed session. Açık: local hook, helper persistence, macOS local notifications.

### Relay V2

`Services/AgentControlRelay/.env.example` tam listedir. Kritik gruplar: host/port/public URL; PostgreSQL/Redis; JWT/pepper ve TTL; Apple audience; APNs key/team/topic; envelope/rate/retention limitleri; metrics token; emergency-disable switch'leri. Gerçek değerleri belgeye veya git'e yazma.

## 12. Geliştirme komutları

İlk kurulum:

```sh
make bootstrap
make generate
make test
```

`bootstrap`, Xcode/Swift/Homebrew kontrol eder; eksik `xcodegen`, `swiftformat`, `swiftlint` araçlarını kurar ve SPM resolve çalıştırır. `generate`, `project.yml` üzerinden `.xcodeproj` üretir.

Günlük doğrulama:

```sh
make swift-test       # root package coverage + relay tests
make contract-test    # repository ve phase contract'ları
make xcode-test       # Apple target build/test akışı
make lint             # SwiftFormat lint + strict SwiftLint
make test             # contract + swift + xcode
```

Mac Local:

```sh
make build-mac-local
make package-mac-local
make install-mac-local
make test-mac-local
make verify-mac-local-v1
make uninstall-mac-local
```

Araçlar:

```sh
swift run agentcontrol-hook doctor
swift run agentcontrol-hook provider-hook codex < input.json
swift run agentcontrol-hook managed-preview codex
swift run fake-agent-simulator approval --auto-decision approve
swift run protocol-inspector pending
```

Relay V2:

```sh
make relay-test
# veya
swift test --package-path Services/AgentControlRelay --scratch-path .build/relay
```

Opt-in performans fixture'ı:

```sh
make persistence-performance
```

`make clean` `.build` ve generated Xcode project'lerini siler; destructive olduğundan kullanıcı değişikliklerini ve local durumunu kontrol etmeden çalıştırma.

## 13. Test stratejisi

| Katman | Yer | Ne doğrular |
| --- | --- | --- |
| Domain unit | `AgentDomainTests` | state/approval/risk/rules/strong ID |
| Protocol contract | `AgentProtocolTests` | envelope, unknown fields/events, size/version |
| Persistence | `AgentPersistenceTests` | migration, privacy, recovery, query, performance |
| IPC/integration | `AgentLocalIPCTests` | socket codec/server, XPC auth, registry/runtime, fuzz |
| Provider | `AgentHookKitTests`, `AgentCodexAdapterTests` | fixture mapping, config patch, RPC/ack/fallback |
| UI logic | `AgentMacUITests` | navigation, decision policy, panel geometry, store behavior |
| Companion V2 | `AgentCompanionTests` | crypto, replay, companion policy/surfaces |
| Relay V2 | `AgentControlRelayTests` | auth, ownership, replay, expiry, operations/security |
| Repository contract | `Tests/Contracts` | phase deliverables, secret hygiene, release graph |

Önemli fixture türleri: Codex/Claude/Gemini hook JSON'ları, risk cases, protocol future-schema envelope, managed Codex JSONL ve crash/recovery subprocess fixture'ları.

Unix socket testleri bazı filesystem sandbox'larında `EPERM` verebilir. Bu durum kaynak hatasıyla karıştırılmamalı; izinli gerçek ortamda tekrar doğrulanmalıdır.

## 14. Bir sorun geldiğinde ilk bakılacak yer

| Belirti / istek | Önce bak |
| --- | --- |
| Session state yanlış/geriliyor | `AgentDomain/StateMachine`, sonra `SessionRegistryActor`, persistence writes |
| Event kayboluyor/duplicate | `EventEnvelope`, `ProviderHookMapper`, `DatabaseActor+Writes`, sequence/source key |
| Hook timeout/helper offline | `AgentControlHookClient`, `HookConfiguration`, Unix socket, `HookSpool`, helper doctor |
| Approval yanlış uygulanıyor | `HookDecisionBroker`, approval state machine, provider output mapper, ack correlation |
| Question choice/text sorunu | `AgentQuestion`, stable choice IDs, `DecisionExperience`, provider mapper |
| Dashboard güncellenmiyor | `AgentControlStore`, `XPCAgentControlTransport`, registry notifications, XPC listener |
| SQLite/migration/recovery | `Migrations`, `DatabaseActor+Migrations`, `SQLiteConnection`, recovery scripts |
| Config dosyası bozuluyor | `ManagedConfigPatchEngine`, `IntegrationManagement`, provider fixture testleri |
| Provider görünmüyor | `ProviderBinaryDetector`, compatibility policy, managed hook config/path |
| Terminal/IDE jump | `TerminalContextCapture`, `TerminalNavigation`, VS Code extension |
| Notification/privacy | `MacNotificationCoordinator`, `NotificationPolicy`, privacy settings/filter |
| Helper register olmuyor | `LaunchAgentManager`, bundled plist, signing mode, install script |
| Mac Local'a V2 dependency sızıyor | `project.yml`, `MacLocalRelease.xcconfig`, `FeatureFlagPolicy`, Mac Local contract |
| iOS/Watch pairing/decision | `AgentCompanion`, app model/coordinator, companion ADR'leri |
| Relay auth/envelope/push | ilgili relay controller, `SecurityServices`, `DeliveryServices`, `Models/Migrations` |
| Release/package checksum | Mac Local scripts, `release-manifest.json`, release verifier/runbook |

## 15. Değişiklik yaparken dosya seçimi

- Domain kuralı değişiyorsa önce `AgentDomain` ve unit test.
- Wire alanı değişiyorsa schema/version/backward compatibility ve protocol fixtures birlikte.
- DB şeması değişiyorsa yeni immutable migration; eski migration checksum'ını değiştirme.
- Helper request ekleniyorsa `HelperRequest`, `HelperResponse`, runtime routing, XPC/socket tests ve UI transport birlikte.
- Yeni provider event'i ekleniyorsa fixture → mapper → normalized envelope → provider output test zinciri.
- UI yalnız local read model tüketmeli; authority/persistence kuralını view içine koyma.
- Xcode target/dependency değişikliği `project.yml` üzerinden yapılmalı; sonra `make generate`.
- Feature ekleniyorsa Mac Local ve V2 profile'larında açık/kapalı durumu explicit olmalı.
- User config değişikliği preview-first, atomic, receipt-backed ve scoped uninstall olmalı.
- Security/privacy davranışı değişiyorsa threat model/ADR ve negative/fuzz testleri güncellenmeli.
- Ürün sınırı değişiyorsa `MAC_LOCAL_V1_SCOPE.md`, ilgili ADR, contract ve bu rehber birlikte güncellenmeli.

## 16. Kod stili ve katkı kuralları

- Üretim değişikliğinden önce ilgili test/contract ve gerekirse ADR güncellenir.
- `Sendable` sınırlarına, actor isolation'a ve `@MainActor` UI sahipliğine uy.
- Raw SQLite veya mutable shared state katmanlar arasında taşınmaz.
- Error'lar kullanıcıya safe message, log'a redacted typed detail sunar.
- Secret, token, private key veya kullanıcı config içeriği commit edilmez.
- Unsupported capability UI'da enable edilmez.
- Provider acknowledgment olmadan approval success raporlanmaz.
- `.build/`, nested `.build/`, `node_modules/`, generated `.xcodeproj`, `dist/` ve compiled extension dosyaları kaynak düzenleme noktası değildir.
- Format/lint sonucu temiz olmalı; test kapsamı düşürülmemeli.

## 17. Bilinen sınırlar ve kalan manuel doğrulamalar

- Bilinmeyen provider major sürümleri bilinçli biçimde monitor-only olur.
- Cursor'ın resmi hook contract'ı Agent question ve plan-review bekleme event'i yayınlamadığından bu iki capability disabled ve gerekçeli görünür; shell/MCP kararları ile session/compaction event'leri desteklenir.
- Exact terminal pane navigation tek seferlik Automation/Accessibility izni isteyebilir; Screen Recording gerekmez.
- Native desktop yalnız macOS'tur; Linux yalnız relay host olabilir.
- Mac Local V1 için canlı account-backed Codex event/approve/deny/provider-ack/completion zinciri henüz kanıtlanmamıştır.
- Gerçek reboot sonrası helper/menu/session restore manuel doğrulama bekler.
- Gerçek OS notification action click ve bazı Instruments/UI performance ölçümleri manuel doğrulama bekler.
- Developer ID notarization, production Sparkle, TestFlight, fiziksel iPhone/Watch ve production APNs V2/stable-candidate evidence kapsamındadır.

## 18. Hızlı agent çalışma protokolü

Yeni bir görevde bütün depoyu taramak yerine:

1. Bu dosyada ilgili “sorun → ilk bakılacak yer” satırını bul.
2. Güncel kapsamı etkiliyorsa `Docs/MAC_LOCAL_V1_SCOPE.md` ve ADR 0022'yi oku.
3. Yalnız ilgili source dosyaları ile onların test/fixture'larını aç.
4. Değişiklik öncesi bağımlılık yönü ve acknowledgment/fail-neutral/privacy kurallarını kontrol et.
5. En küçük ilgili test grubunu çalıştır; risk yüksekse `make test` ve `make lint` ile tamamla.
6. Mimari veya kapsam değiştiyse bu rehberi güncelle.

Bu rehber bir index ve yoğunlaştırılmış sistem modelidir. Kodla çelişirse çalışan kod/test otoritatiftir; çelişkiyi düzeltirken rehberi de aynı commit'te güncelle.
