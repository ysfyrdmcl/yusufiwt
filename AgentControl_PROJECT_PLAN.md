# AgentControl — Native Swift AI Agent Operations Center

**Belge türü:** Baştan sona uygulama ve ürün planı  
**Belge sürümü:** 1.0  
**Karar tarihi:** 17 Temmuz 2026  
**Hedef:** Codex'in ek ürün kararı veya kapsam yorumu yapmadan projeyi sıralı şekilde geliştirebilmesi  
**Çalışma adı:** AgentControl  
**Ana bundle öneki:** `com.yusuf.agentcontrol`

> Bu belge proje için kaynak gerçektir. Codex; burada tanımlanmayan kritik bir davranışı sessizce varsaymamalı, mevcut mimari ilkelerle en güvenli ve en dar uygulamayı seçmeli, mimari sapmaları `Docs/ADR` altında kaydetmelidir. Her faz, testleri ve kabul kriterleri tamamlanmadan bitmiş sayılmaz.

---

# 1 — Proje özeti

## 1.1 Ürün vizyonu

AgentControl; Codex, Claude Code, Gemini CLI, OpenCode ve gelecekte eklenecek diğer yazılım agent'larını tek bir native macOS kontrol merkezinden izleyen, onay taleplerini yöneten, sorularını yanıtlayan, tamamlanma/başarısızlık durumlarını bildiren ve isteğe bağlı olarak iPhone ile Apple Watch üzerinden güvenli uzaktan işlem yapılmasını sağlayan bir **AI Agent Operations Center** olacaktır.

Ürün yalnızca bir durum göstergesi olmayacaktır. Üç temel işi birlikte yapacaktır:

1. **Gözlemlenebilirlik:** Hangi agent'ın hangi projede ne yaptığını, ne kadar süredir çalıştığını ve ne beklediğini gösterir.
2. **İnsan onayı:** Dosya değişikliği, komut çalıştırma, ağ erişimi, hassas yol erişimi veya agent sorusu gibi bekleyen kararları doğru bağlamla sunar.
3. **Güvenli uzaktan kontrol:** Kullanıcı Mac'in başında değilken iPhone bildirimi, uygulama içi Face ID doğrulaması ve gerektiğinde Apple Watch üzerinden sınırlı karar vermeyi sağlar.

## 1.2 Çözülen problemler

- Birden fazla terminal, IDE, proje ve agent oturumunda bekleyen izinlerin gözden kaçması.
- Agent'ın sessizce uzun süre çalışması, takılması, rate limit'e girmesi veya kullanıcı girdisi beklemesi.
- Bildirimden doğru terminal sekmesine/panesine dönmenin zor olması.
- Agent'ın yaptığı iş bittikten sonra sonucu, süreyi ve değişen kapsamı merkezi bir geçmişte görememek.
- Masadan uzaktayken düşük riskli izinleri güvenli şekilde yanıtlayamamak.
- Farklı agent ürünlerinin farklı hook/event biçimlerini tek bir arayüzde birleştirememe.
- Terminal çıktısı taramaya dayalı kırılgan araçların yanlış durum üretmesi.

## 1.3 Ürün kapsamı

### macOS ana uygulaması

- Menu bar uygulaması.
- Ekranın üst merkezinde isteğe bağlı kompakt “pill/notch” paneli.
- Tam dashboard penceresi.
- Aktif oturumlar, bekleyen onaylar, sorular, plan incelemeleri ve tamamlanan işler.
- Kural motoru, bildirimler, geçmiş, analiz, entegrasyon yönetimi ve tanılama.
- Agent oturumunu başlatma, terminale dönme, durdurma veya iptal etme; yalnızca ilgili adapter destekliyorsa.

### macOS arka plan bileşenleri

- Kullanıcı seviyesinde çalışan `LaunchAgent` helper.
- Hook ve agent adaptörlerinden gelen event'leri alan Unix domain socket.
- Ana uygulama ile helper arasında XPC.
- Yerel SQLite event deposu.
- Ana uygulama kapalıyken dahi oturum izleme, bildirim üretme ve bekleyen onay akışını sürdürme.

### iPhone companion

- Mac/node durumlarını gösterme.
- Actionable push notification ile düşük riskli onay/red.
- Seçenekli veya serbest metin agent sorularına yanıt verme.
- Yüksek riskli işlemler için uygulamayı açma, tam ayrıntı gösterme, Face ID ve basılı tutarak onaylama.
- Seçili oturum için Live Activity.
- Eşlenmiş cihazları görme ve yetkilerini iptal etme.

### Apple Watch companion

- Tamamlandı, başarısız, uzun sürüyor ve soru bekliyor bildirimleri.
- Yalnızca düşük riskli, kısa ve açık eylemler için onay/red.
- Yüksek ve kritik riskli işlemlerde “iPhone'da incele” veya “Mac'i aç” akışı.

### İsteğe bağlı relay sunucusu

- Swift/Vapor tabanlı hafif bağlantı ve push relay'i.
- Mac ile iPhone arasında uçtan uca şifrelenmiş event zarfı taşır.
- İçeriği okuyamaz, karar veremez ve kendi başına agent komutu çalıştıramaz.
- APNs gönderimi, cihaz varlığı, kısa ömürlü kuyruk ve bağlantı yönetimi yapar.

### Uzak node/SSH desteği

- Uzak macOS/Linux makinelerde küçük `AgentControlRemoteNode` servisi.
- Uzak makinedeki event'leri yerel Mac'e veya relay'e güvenli biçimde aktarır.
- Ana ürün hiçbir zaman parola saklamaz; anahtar tabanlı SSH ve sistem Keychain kullanılır.

## 1.4 Çalışma modları

### Mod A — Local Only

- Hesap gerekmez.
- İnternet gerekmez.
- Tüm veriler Mac'te kalır.
- Yerel bildirimler ve terminale geçiş çalışır.
- iPhone uzaktan onay özelliği kapalıdır.

### Mod B — Personal Remote

- Sign in with Apple hesabı gerekir.
- Mac ile iPhone QR kod/tek kullanımlık eşleme koduyla eşleştirilir.
- Relay yalnızca şifreli zarfları taşır.
- Kullanıcının prompt, kod, komut ve dosya içeriği sunucuda açık metin olarak bulunmaz.

### Mod C — Self-Hosted Remote

- Kullanıcı kendi Vapor relay kurulumunu çalıştırır.
- Aynı istemciler, farklı `RELAY_BASE_URL` ve sertifika sabitleme yapılandırmasıyla çalışır.
- Kurumsal kullanım için ileride SSO/RBAC eklenebilir; 1.0 kapsamı kişisel kullanım olarak kalır.

## 1.5 Hedef kullanıcılar

- Aynı anda birden fazla AI coding agent kullanan bireysel geliştiriciler.
- Birden fazla repo, terminal veya uzak makine üzerinde çalışan yazılım ekipleri.
- Agent görevlerini uzun süre arka planda çalıştıran geliştiriciler.
- Telefon üzerinden düşük riskli onay vermek isteyen kullanıcılar.
- Güvenlik nedeniyle otomatik onay yerine kontrollü insan-onay akışı isteyen ekipler.

## 1.6 Temel ürün ilkeleri

1. **Local-first:** Uzak özellikler kapalıyken ürün eksiksiz yerel izleme aracı olarak çalışmalıdır.
2. **Structured events first:** Resmî app-server, hook veya API event'i varsa terminal metni taranmaz.
3. **Doğruluk görünüşten önemlidir:** Desteklenmeyen eylem için sahte buton gösterilmez; terminale yönlendirme yapılır.
4. **Mac son otoritedir:** Telefon yalnızca imzalı karar gönderir; agent'a uygulanmış nihai durum Mac/helper doğrulamasından sonra gösterilir.
5. **Sessiz otomatik onay yoktur:** Kullanıcı açıkça kural tanımlamadıkça ve risk politikası izin vermedikçe hiçbir izin kendiliğinden verilmez.
6. **Minimum yetki:** Root daemon, screen recording ve genel Accessibility izni varsayılan gereksinim değildir.
7. **Gizlilik varsayılanı:** Prompt, kod, terminal çıktısı ve dosya içeriği varsayılan olarak kaydedilmez veya relay'e gönderilmez.
8. **Graceful degradation:** Entegrasyon bozulursa agent'ın kendi terminal prompt'u çalışmaya devam eder.
9. **Sürüm farkındalığı:** Adapter'lar agent sürümünü ve desteklediği yetenekleri algılar; bilinmeyen sürümde monitor-only moda düşer.
10. **Native kalite:** Uygulama düşük kaynak tüketmeli, VoiceOver ve klavye kullanımını desteklemeli, macOS/iOS tasarım diline uymalıdır.

## 1.7 1.0 hedefleri

- Codex, Claude Code ve Gemini CLI için güvenilir oturum durumu.
- Codex için yüksek doğruluklu managed `app-server` entegrasyonu.
- Üç agent için resmî hook tabanlı mevcut terminal oturumlarını izleme.
- İzin onayı/red, agent sorusuna yanıt, plan inceleme ve tamamlanma bildirimi.
- Menu bar, kompakt üst panel, dashboard ve geçmiş.
- Exact terminal/IDE jump için destek matrisi ve güvenli fallback.
- Long-running, idle, stale, failed ve waiting alert'leri.
- iPhone eşleme, actionable notification, metin yanıtı, Face ID ve Live Activity.
- SSH/remote node.
- Developer ID ile imzalı/notarized macOS dağıtımı ve Sparkle güncelleme.
- TestFlight/App Store üzerinden iOS/watchOS dağıtımı.

## 1.8 1.0 dışında bırakılanlar

- Agent'ın yaptığı kodu otomatik merge/deploy etme.
- Kritik komutları telefondan tek dokunuşla onaylama.
- Kullanıcının terminal çıktısını sürekli ekran görüntüsü/OCR ile okuma.
- Root ayrıcalıklı daemon.
- Her agent için tam süreç kontrolü; yalnızca adapter yetenekleri kadar kontrol.
- Kurumsal RBAC, takım faturalandırması ve çok kiracılı yönetim paneli.
- LLM tabanlı otomatik risk kararı.
- Prompt/kod içeriğinin bulut tarafında aranması veya analiz edilmesi.

## 1.9 Başarı ölçütleri

### Ürün ölçütleri

- Onay talebinin doğru oturum ve doğru projeyle eşleşme oranı: `%99.9+`.
- Yanlış “onaylandı” gösterimi: `0` tolerans.
- Desteklenen adapter'larda yakalanan tamamlanma/izin olayları: `%99+`.
- Bildirimden ilgili oturuma ulaşma: en fazla iki kullanıcı etkileşimi.
- Hook kurulumu sonrası agent'ın doğal çalışma akışının bozulmaması.

### Performans bütçeleri

- Helper boşta CPU: ortalama `%1` altı.
- Ana uygulama + helper boşta bellek hedefi: `150 MB` altı.
- Yerel event'in UI'a düşme p95 süresi: `250 ms` hedef, `500 ms` üst sınır.
- Yerel onay kararının adapter'a dönme p95 süresi: `300 ms` hedef.
- Online Mac için telefon kararının Mac'e ulaşması p95: APNs gecikmesi hariç `2 saniye` hedef.
- Aynı node üzerinde en az `100` eşzamanlı oturum kaydı.
- Uygulama açılışında ilk kullanılabilir görünüm: `2 saniye` altında.
- SQLite veri tabanı WAL ile yoğun event altında UI bloklamamalıdır.

## 1.10 Ana kullanıcı akışları

### Yerel onay akışı

1. Agent resmî protokol/hook üzerinden izin ister.
2. Hook veya adapter event'i helper'a gönderir.
3. Helper event'i doğrular, normalize eder, SQLite'a yazar ve risk sınıfını hesaplar.
4. XPC üzerinden macOS UI güncellenir; gerekirse yerel bildirim oluşur.
5. Kullanıcı Approve veya Deny seçer.
6. Helper kararın güncel request ID, sürüm, expiry ve policy ile uyumunu doğrular.
7. Adapter kararı agent'a döndürür.
8. Agent/provider acknowledgment gönderir.
9. UI ancak bu acknowledgment sonrasında `approvedApplied` veya `deniedApplied` gösterir.

### iPhone onay akışı

1. Helper onay isteği için minimum gerekli bilgiyi içeren şifreli zarf üretir.
2. Zarf relay'e gönderilir; relay içeriği okuyamaz.
3. Relay APNs'e wake/notification iletir.
4. Notification Service Extension zarfı cihaz anahtarıyla çözer ve bildirim metnini oluşturur.
5. Düşük/orta riskte kullanıcı authentication-required Approve/Deny action kullanabilir.
6. Yüksek riskte bildirim yalnızca Review ve Deny sunar; Review uygulamayı açar.
7. Uygulama Face ID, tam bağlam ve hold-to-approve uygular.
8. iPhone kararı cihaz özel anahtarıyla imzalar ve Mac'e yönelik olarak şifreler.
9. Helper imza, request ID, nonce, sürüm ve expiry doğrulaması yapar.
10. Agent'a karar uygulanır; acknowledgment iPhone'a geri gönderilir.
11. Telefon `Applied`, `Expired`, `Rejected by policy`, `Mac offline` veya `Superseded` durumunu gösterir.

### Agent sorusuna metin yanıtı

1. Adapter sorunun tipini `choice`, `multiChoice`, `text`, `secret`, `confirmation` olarak normalize eder.
2. `secret` tipi uzaktan yanıta kapalıdır.
3. `choice` ve `text` tipi notification action veya iOS uygulaması üzerinden yanıtlanabilir.
4. Yanıt doğrulanır, imzalanır, agent'a iletilir ve agent acknowledgment beklenir.

### SSH/uzak node akışı

1. Remote node kullanıcı seviyesinde çalışır ve yerel agent hook event'lerini toplar.
2. Node kimliği ilk eşlemede karşılıklı anahtar değişimiyle kurulur.
3. Event'ler yerel ağda doğrudan veya relay üzerinden E2E şifreli aktarılır.
4. Mac/iPhone UI node'u, hostname yerine kullanıcının verdiği güvenli görünen adla gösterir.
5. Node offline olduğunda bekleyen istekler expiry süresince kuyrukta kalır; otomatik onay verilmez.

## 1.11 Risk sınıfları

| Sınıf | Örnek | Mac | iPhone bildirimi | iPhone uygulaması | Watch |
|---|---|---:|---:|---:|---:|
| Low | Workspace içinde salt-okuma, test sonucu görüntüleme | Onay/Red | Onay/Red + cihaz kilidi | Onay/Red | Onay/Red |
| Medium | Workspace içinde dosya değişikliği, güvenli package install | Onay/Red | Onay/Red + cihaz kilidi | Face ID opsiyonel | Review/Deny |
| High | Ağ erişimi, workspace dışı dosya, git push, veri silme ihtimali | Onay/Red + ayrıntı | Review/Deny | Face ID + hold-to-approve | Review/Deny |
| Critical | `sudo`, secret erişimi, prod deploy, destructive wildcard, bilinmeyen shell composition | Mac'te açık onay | Deny/Open Mac | Deny/Open Mac | Deny/Open Mac |

Risk sınıfı deterministik kurallarla hesaplanır. Agent'ın kendi “safe” etiketi tek başına güvenilir kabul edilmez.

## 1.12 Sürüm yol haritası

- **1.0:** macOS, iPhone, Codex/Claude/Gemini, relay, SSH node, temel analytics.
- **1.1:** Watch, widgets, yerel ağ direct path, saved launchers, queue ve OpenCode iyileştirmeleri.
- **1.2:** Adapter SDK, webhook/Slack bildirimleri, gelişmiş kurallar ve export.
- **2.0:** Team mode, RBAC, merkezi audit, politika paketleri ve self-hosted yönetim paneli.

---

# 2 — Tech stack

## 2.1 Toolchain ve minimum platformlar

- **IDE:** Xcode 26.6 stable.
- **Dil:** Swift 6.3.
- **Concurrency:** Swift Strict Concurrency, complete checking.
- **macOS deployment target:** macOS 14.0+.
- **iOS deployment target:** iOS 17.0+.
- **watchOS deployment target:** watchOS 10.0+.
- **Server:** Swift 6.x, Vapor 4, Linux container.
- **Project generation:** XcodeGen.
- **Package management:** Swift Package Manager.
- **Build configuration:** `.xcconfig` dosyaları; secret olmayan public build değerleri burada tutulur.

macOS 14/iOS 17 tabanı; modern SwiftUI, Observation, ActivityKit ve bildirim özelliklerini kullanırken eski donanımı gereksiz yere dışlamamak için seçilmiştir.

## 2.2 Native UI

### macOS

- SwiftUI: ana ekranlar, dashboard, settings, onboarding.
- AppKit bridge:
  - `NSPanel` ile üst-merkez floating panel.
  - `NSStatusItem`/`MenuBarExtra` ile menu bar.
  - `NSWorkspace` ile uygulama aktive etme.
  - `AXUIElement` yalnızca exact terminal jump fallback'i için.
  - Global hotkey için Carbon hotkey API veya güvenli AppKit wrapper.
- Observation (`@Observable`) ve `@MainActor` view model'ler.

### iOS/watchOS

- SwiftUI.
- UserNotifications.
- LocalAuthentication.
- ActivityKit ve WidgetKit.
- App Intents yalnızca güvenli, yüksek seviyeli navigasyon/okuma eylemleri için.
- WatchConnectivity, Watch bağımsız push almadığında state eşitleme için.

## 2.3 Arka plan ve IPC

- `SMAppService` ile kullanıcı seviyesinde LaunchAgent kaydı.
- Ana app ↔ helper: `NSXPCConnection` ve code-signing doğrulamalı XPC interface.
- Hook/CLI ↔ helper: Unix domain socket, length-prefixed versioned binary/JSON envelope.
- Hook fallback: atomik spool dosyası ve kısa polling; socket geçici olarak yoksa event kaybolmaz.
- Helper yaşam döngüsü: launchd tarafından yönetilir; app'in açık olmasına bağlı değildir.
- No root daemon.

## 2.4 Veri depolama

- Yerel: Apple `SQLite3` C API üzerinde ince, proje içi typed persistence katmanı.
- SQLite ayarları:
  - WAL mode.
  - Foreign keys açık.
  - Busy timeout.
  - Prepared statements.
  - Explicit migrations.
  - Sensitive field-level encryption gereken alanlarda CryptoKit.
- Keychain:
  - cihaz private key referansları.
  - refresh token.
  - relay credential.
  - SSH key bookmark/reference; private key içeriği DB'ye yazılmaz.
- macOS bookmark data: security-scoped erişim gereken kullanıcı seçili dosya/klasörleri için.
- Server: PostgreSQL.
- Presence ve kısa ömürlü queue: Redis.

SQLite doğrudan seçilmiştir; runtime bağımlılığı azaltır, migration ve sorgu davranışını tamamen kontrol altında tutar. UI hiçbir zaman doğrudan SQLite çağrısı yapmaz; tüm erişim `DatabaseActor` üzerinden geçer.

## 2.5 Ağ ve senkronizasyon

- Client WebSocket: `URLSessionWebSocketTask`.
- REST bootstrap/auth: `URLSession`.
- Relay: Vapor 4 + SwiftNIO.
- PostgreSQL: FluentPostgresDriver.
- Redis: Vapor/Redis entegrasyonu.
- APNs provider: APNSwift.
- Linux kriptografi: `swift-crypto`.
- Retry: exponential backoff + full jitter.
- Offline delivery: durable outbox, idempotency key, monotonic sequence.
- Direct LAN 1.1: Bonjour discovery + Network.framework, relay fallback.

## 2.6 Güvenlik ve kriptografi

- CryptoKit:
  - X25519/Curve25519 key agreement.
  - HKDF-SHA256.
  - ChaChaPoly veya AES-GCM authenticated encryption.
  - Ed25519/Curve25519 signing.
- Secure Enclave:
  - desteklenen cihazlarda cihaz kimlik anahtarının korunması.
  - Secure Enclave desteklenmeyen durumda Keychain `ThisDeviceOnly` erişim sınıfı.
- LocalAuthentication:
  - Face ID/Touch ID.
  - cihaz passcode fallback politikası ayrı ayar.
- Key rotation:
  - eşleme sonrası cihaz anahtarı.
  - kullanıcı tarafından revoke.
  - relay token rotation.
- Replay koruması:
  - request ID.
  - monotonik decision revision.
  - nonce.
  - expiry.
  - son kullanılan nonce cache'i.

## 2.7 Agent entegrasyonları

### Codex

- Birincil yüksek doğruluk modu: `codex app-server`.
- Transport: production'da stdio JSONL veya Unix socket.
- Deneysel WebSocket transport kullanılmaz.
- Kurulu Codex sürümünden protokol şeması üretme/okuma.
- Approval request/response, item lifecycle, turn ve thread event'leri normalize edilir.
- Bağımsız terminal/IDE oturumları için resmî hook adapter'ı.

### Claude Code

- Resmî lifecycle hooks.
- `PermissionRequest`, `Notification`, `SessionStart`, `SessionEnd`, `Stop`, tool events.
- Hook stdout yalnızca sözleşmeye uygun JSON; loglar stderr.
- Helper erişilemiyorsa neutral/fallback ile Claude'un kendi prompt'una dönülür.

### Gemini CLI

- Resmî synchronous hooks.
- Hook giriş/çıkış JSON şemasına sadık kalınır.
- Exit code ve decision semantiği version-aware uygulanır.
- Hook sırasında stdout kirletilmez.

### OpenCode ve diğerleri

- Yetenek bazlı adapter.
- Structured API/SSE/plugin varsa kullanılır.
- Yalnızca process detection varsa monitor-only.
- Generic `agentcontrol emit` CLI protokolü ile üçüncü taraf entegrasyon.

## 2.8 Terminal/IDE entegrasyonu

- `NSWorkspace` activation ve URL schemes.
- AppleScript yalnızca kullanıcı tarafından izin verilen uygulamalarda.
- Accessibility exact pane/tab fallback'i; opt-in.
- VS Code/Cursor için küçük TypeScript extension:
  - active terminal ID.
  - workspace URI.
  - session correlation token.
  - reveal terminal komutu.
- Terminal adapter'ları:
  - Terminal.app.
  - iTerm2.
  - Ghostty.
  - Warp.
  - WezTerm.
  - VS Code.
  - Cursor.
- Başarı seviyesi kaydedilir: `exactPane`, `window`, `application`, `projectFolder`, `unsupported`.

## 2.9 Bildirimler

- macOS/iOS: UserNotifications.
- Notification Service Extension:
  - E2E payload decrypt.
  - privacy-safe title/body üretimi.
  - kategori ve action belirleme.
- Notification Content Extension: 1.1; zengin diff/command kartı gerekiyorsa.
- Action types:
  - Approve.
  - Deny.
  - Review.
  - Open Mac.
  - Text reply.
  - predefined choice.
- Hassas action'lar `.authenticationRequired`.
- Live Activities: ActivityKit + push update token.

## 2.10 Dağıtım ve güncelleme

### macOS

- Mac App Store birincil kanal değildir.
- Developer ID Application sertifikası.
- Hardened Runtime.
- Notarization (`notarytool`).
- Staple edilmiş DMG/ZIP.
- Sparkle 2:
  - EdDSA imzalı update.
  - appcast.
  - staged rollout.
  - rollback koşulları.

### iOS/watchOS

- TestFlight beta.
- App Store production.
- Associated domains yalnızca gerçekten kullanılıyorsa.
- Push, Sign in with Apple ve App Groups entitlement'ları.

## 2.11 Test araçları

- Swift Testing: yeni unit ve integration testleri.
- XCTest/XCUITest: UI ve legacy gerektiren testler.
- `swift test` ve `xcodebuild test`.
- Fake agent simulator.
- JSON schema contract testleri.
- Golden fixture testleri.
- Property-based test yardımcıları; proje içi minimal generator veya yalnızca test dependency.
- Network fault injection.
- Toxiproxy benzeri container yalnızca relay integration testlerinde.
- `xcrun simctl push` ile notification testleri.
- Instruments:
  - Time Profiler.
  - Allocations.
  - Leaks.
  - Energy Log.
  - Network.

## 2.12 Kod kalitesi ve CI

- SwiftFormat; sabit sürüme pinlenir.
- SwiftLint; yalnızca yüksek sinyal kuralları.
- GitHub Actions:
  - package tests.
  - macOS build/test.
  - iOS/watchOS simulator test.
  - server Linux test.
  - static analysis.
  - dependency audit.
  - archive/sign/notarize release job.
- Conventional commits zorunlu değildir; değişiklik başlığı net olmalıdır.
- Her mimari karar için ADR.
- SemVer.
- `main` her zaman release edilebilir olmalıdır.

## 2.13 Runtime bağımlılık politikası

İstemci runtime bağımlılıkları minimum tutulacaktır.

İzin verilen ana bağımlılıklar:

- Sparkle 2 — yalnızca macOS updater.
- Server tarafında Vapor, FluentPostgresDriver, Redis, APNSwift, swift-crypto.
- Test/lint araçları build çıktısına dahil edilmez.

UI, state management, analytics model veya networking için gereksiz üçüncü taraf framework kullanılmayacaktır.

---

# 3 — Proje ağacı (work tree)

```text
AgentControl/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── SECURITY.md
├── CONTRIBUTING.md
├── CODEOWNERS
├── Makefile
├── project.yml
├── Package.swift
├── Package.resolved
├── .gitignore
├── .swiftformat
├── .swiftlint.yml
├── .editorconfig
├── .env.example
├── .github/
│   ├── workflows/
│   │   ├── ci.yml
│   │   ├── macos-release.yml
│   │   ├── ios-testflight.yml
│   │   ├── relay-deploy.yml
│   │   └── dependency-audit.yml
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
│
├── Config/
│   ├── Base.xcconfig
│   ├── Debug.xcconfig
│   ├── Staging.xcconfig
│   ├── Release.xcconfig
│   ├── Local.example.xcconfig
│   ├── Entitlements/
│   │   ├── AgentControlMac.entitlements
│   │   ├── AgentControlHelper.entitlements
│   │   ├── AgentControliOS.entitlements
│   │   ├── AgentControlWatch.entitlements
│   │   ├── NotificationService.entitlements
│   │   └── LiveActivity.entitlements
│   ├── LaunchAgents/
│   │   └── com.yusuf.agentcontrol.helper.plist
│   ├── Privacy/
│   │   ├── PrivacyInfo.xcprivacy
│   │   └── DataUsage.md
│   └── StoreKit/
│       └── AgentControl.storekit
│
├── Apps/
│   ├── macOS/
│   │   ├── AgentControlMacApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppEnvironment.swift
│   │   ├── Commands/
│   │   ├── MenuBar/
│   │   │   ├── MenuBarCoordinator.swift
│   │   │   ├── MenuBarContentView.swift
│   │   │   └── MenuBarStatusIcon.swift
│   │   ├── FloatingPanel/
│   │   │   ├── AgentPanelController.swift
│   │   │   ├── AgentPanelWindow.swift
│   │   │   ├── CompactPanelView.swift
│   │   │   └── ExpandedPanelView.swift
│   │   ├── Dashboard/
│   │   │   ├── DashboardRootView.swift
│   │   │   ├── Overview/
│   │   │   ├── ActiveSessions/
│   │   │   ├── Inbox/
│   │   │   ├── History/
│   │   │   ├── Analytics/
│   │   │   ├── Nodes/
│   │   │   ├── Integrations/
│   │   │   ├── Automations/
│   │   │   ├── Diagnostics/
│   │   │   └── Settings/
│   │   ├── SessionDetail/
│   │   ├── ApprovalDetail/
│   │   ├── PlanReview/
│   │   ├── Onboarding/
│   │   ├── Notifications/
│   │   ├── Accessibility/
│   │   ├── DeepLinks/
│   │   └── Resources/
│   │       ├── Assets.xcassets
│   │       ├── Localizable.xcstrings
│   │       └── PreviewContent/
│   │
│   ├── iOS/
│   │   ├── AgentControliOSApp.swift
│   │   ├── AppEnvironment.swift
│   │   ├── Navigation/
│   │   ├── Authentication/
│   │   ├── Pairing/
│   │   ├── Nodes/
│   │   ├── ActiveSessions/
│   │   ├── ApprovalInbox/
│   │   ├── ApprovalReview/
│   │   ├── QuestionReply/
│   │   ├── SessionDetail/
│   │   ├── History/
│   │   ├── LiveActivities/
│   │   ├── DeviceSecurity/
│   │   ├── Settings/
│   │   ├── Notifications/
│   │   ├── DeepLinks/
│   │   └── Resources/
│   │       ├── Assets.xcassets
│   │       └── Localizable.xcstrings
│   │
│   ├── watchOS/
│   │   ├── AgentControlWatchApp.swift
│   │   ├── Inbox/
│   │   ├── SessionStatus/
│   │   ├── NotificationController/
│   │   ├── Connectivity/
│   │   └── Resources/
│   │
│   └── Extensions/
│       ├── NotificationService/
│       │   ├── NotificationService.swift
│       │   ├── PayloadDecryptor.swift
│       │   └── NotificationCategoryBuilder.swift
│       ├── AgentLiveActivity/
│       │   ├── AgentActivityAttributes.swift
│       │   ├── AgentLiveActivityWidget.swift
│       │   └── AgentLiveActivityViews.swift
│       └── AgentWidgets/
│           ├── ActiveAgentsWidget.swift
│           └── ApprovalCountWidget.swift
│
├── Services/
│   ├── AgentControlHelper/
│   │   ├── main.swift
│   │   ├── HelperApplication.swift
│   │   ├── XPC/
│   │   │   ├── HelperXPCProtocol.swift
│   │   │   ├── HelperXPCListener.swift
│   │   │   ├── ClientIdentityValidator.swift
│   │   │   └── DTOs.swift
│   │   ├── Socket/
│   │   │   ├── UnixSocketServer.swift
│   │   │   ├── PeerCredentialValidator.swift
│   │   │   ├── FrameDecoder.swift
│   │   │   └── SpoolImporter.swift
│   │   ├── Sessions/
│   │   ├── Approvals/
│   │   ├── Rules/
│   │   ├── Notifications/
│   │   ├── Integrations/
│   │   ├── Relay/
│   │   ├── Persistence/
│   │   ├── Health/
│   │   └── Resources/
│   │
│   ├── AgentControlHook/
│   │   ├── main.swift
│   │   ├── HookCommand.swift
│   │   ├── InputReader.swift
│   │   ├── OutputWriter.swift
│   │   ├── HelperClient.swift
│   │   ├── TimeoutPolicy.swift
│   │   └── Commands/
│   │       ├── EmitCommand.swift
│   │       ├── RequestDecisionCommand.swift
│   │       ├── NotifyCommand.swift
│   │       ├── InstallCommand.swift
│   │       ├── DoctorCommand.swift
│   │       └── VersionCommand.swift
│   │
│   └── AgentControlRemoteNode/
│       ├── main.swift
│       ├── NodeApplication.swift
│       ├── Pairing/
│       ├── Transport/
│       ├── LocalHooks/
│       ├── Health/
│       └── Config/
│
├── Packages/
│   └── AgentControlKit/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── AgentDomain/
│       │   │   ├── Models/
│       │   │   ├── Events/
│       │   │   ├── StateMachine/
│       │   │   ├── Policies/
│       │   │   └── Errors/
│       │   ├── AgentProtocol/
│       │   │   ├── EventEnvelope.swift
│       │   │   ├── WireProtocol.swift
│       │   │   ├── VersionNegotiation.swift
│       │   │   └── JSONSchema/
│       │   ├── AgentPersistence/
│       │   │   ├── SQLiteDatabase.swift
│       │   │   ├── DatabaseActor.swift
│       │   │   ├── Migrations/
│       │   │   ├── Repositories/
│       │   │   └── Queries/
│       │   ├── AgentSecurity/
│       │   │   ├── DeviceIdentity.swift
│       │   │   ├── KeychainStore.swift
│       │   │   ├── EnvelopeCrypto.swift
│       │   │   ├── DecisionSigner.swift
│       │   │   ├── ReplayProtector.swift
│       │   │   ├── Redactor.swift
│       │   │   └── RiskClassifier.swift
│       │   ├── AgentIntegrations/
│       │   │   ├── AgentAdapter.swift
│       │   │   ├── CapabilityMatrix.swift
│       │   │   ├── AdapterRegistry.swift
│       │   │   ├── IntegrationInstaller.swift
│       │   │   └── VersionDetector.swift
│       │   ├── TerminalNavigation/
│       │   │   ├── TerminalAdapter.swift
│       │   │   ├── NavigationResult.swift
│       │   │   ├── AccessibilityBridge.swift
│       │   │   └── Adapters/
│       │   ├── RelayClient/
│       │   │   ├── RelayConnectionActor.swift
│       │   │   ├── RelayAPI.swift
│       │   │   ├── WebSocketTransport.swift
│       │   │   ├── Outbox.swift
│       │   │   └── Presence.swift
│       │   ├── RulesEngine/
│       │   │   ├── Rule.swift
│       │   │   ├── RuleEvaluator.swift
│       │   │   ├── AlertPolicy.swift
│       │   │   └── QuietHours.swift
│       │   ├── Diagnostics/
│       │   │   ├── DiagnosticReport.swift
│       │   │   ├── HealthCheck.swift
│       │   │   ├── LogExporter.swift
│       │   │   └── PrivacyScrubber.swift
│       │   ├── DesignSystem/
│       │   │   ├── Components/
│       │   │   ├── Tokens/
│       │   │   ├── Icons/
│       │   │   └── Accessibility/
│       │   └── TestSupport/
│       │       ├── FakeClock.swift
│       │       ├── FakeAgent.swift
│       │       ├── FixtureLoader.swift
│       │       └── DeterministicCrypto.swift
│       └── Tests/
│           ├── AgentDomainTests/
│           ├── AgentProtocolTests/
│           ├── AgentPersistenceTests/
│           ├── AgentSecurityTests/
│           ├── AgentIntegrationsTests/
│           ├── TerminalNavigationTests/
│           ├── RelayClientTests/
│           └── RulesEngineTests/
│
├── Integrations/
│   ├── Codex/
│   │   ├── CodexAdapter.swift
│   │   ├── AppServer/
│   │   │   ├── CodexAppServerProcess.swift
│   │   │   ├── CodexRPCClient.swift
│   │   │   ├── CodexSchemaLoader.swift
│   │   │   ├── CodexEventMapper.swift
│   │   │   └── CodexApprovalResponder.swift
│   │   ├── Hooks/
│   │   │   ├── CodexHookInstaller.swift
│   │   │   ├── CodexHookMapper.swift
│   │   │   └── ManagedHookTemplate.json
│   │   ├── CapabilityDetection/
│   │   └── Fixtures/
│   ├── ClaudeCode/
│   │   ├── ClaudeAdapter.swift
│   │   ├── ClaudeHookInstaller.swift
│   │   ├── ClaudeEventMapper.swift
│   │   ├── ManagedHookTemplate.json
│   │   └── Fixtures/
│   ├── GeminiCLI/
│   │   ├── GeminiAdapter.swift
│   │   ├── GeminiHookInstaller.swift
│   │   ├── GeminiEventMapper.swift
│   │   ├── ManagedHookTemplate.json
│   │   └── Fixtures/
│   ├── OpenCode/
│   │   ├── OpenCodeAdapter.swift
│   │   ├── OpenCodeTransport.swift
│   │   └── Fixtures/
│   ├── Generic/
│   │   ├── GenericAdapter.swift
│   │   ├── GenericProtocol.md
│   │   └── Examples/
│   ├── VSCodeExtension/
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   ├── src/
│   │   └── README.md
│   └── Fixtures/
│       ├── version-matrix.json
│       └── malformed-events/
│
├── Server/
│   └── AgentControlRelay/
│       ├── Package.swift
│       ├── Sources/App/
│       │   ├── configure.swift
│       │   ├── routes.swift
│       │   ├── Auth/
│       │   ├── Pairing/
│       │   ├── Devices/
│       │   ├── Nodes/
│       │   ├── Envelopes/
│       │   ├── WebSockets/
│       │   ├── Push/
│       │   ├── Presence/
│       │   ├── RateLimiting/
│       │   ├── Audit/
│       │   └── Migrations/
│       ├── Sources/Run/main.swift
│       ├── Tests/AppTests/
│       ├── Dockerfile
│       ├── docker-compose.yml
│       ├── .env.example
│       └── README.md
│
├── Tests/
│   ├── Integration/
│   │   ├── HelperXPCTests/
│   │   ├── HookSocketTests/
│   │   ├── CodexAppServerTests/
│   │   ├── ClaudeHookTests/
│   │   ├── GeminiHookTests/
│   │   ├── RelayEndToEndTests/
│   │   └── NotificationRoundTripTests/
│   ├── UI/
│   │   ├── macOSUITests/
│   │   └── iOSUITests/
│   ├── Performance/
│   ├── Security/
│   ├── Migration/
│   └── Fixtures/
│
├── Tools/
│   ├── FakeAgentSimulator/
│   ├── ProtocolInspector/
│   ├── FixtureRecorder/
│   ├── AppcastGenerator/
│   └── ReleaseVerifier/
│
├── Scripts/
│   ├── bootstrap.sh
│   ├── generate_project.sh
│   ├── build_all.sh
│   ├── test_all.sh
│   ├── lint.sh
│   ├── install_dev_helper.sh
│   ├── uninstall_dev_helper.sh
│   ├── install_hooks.sh
│   ├── uninstall_hooks.sh
│   ├── package_macos.sh
│   ├── notarize_macos.sh
│   ├── generate_appcast.sh
│   ├── deploy_relay.sh
│   └── verify_release.sh
│
└── Docs/
    ├── PRODUCT.md
    ├── ARCHITECTURE.md
    ├── THREAT_MODEL.md
    ├── PRIVACY.md
    ├── PROTOCOL.md
    ├── INTEGRATION_GUIDE.md
    ├── TERMINAL_SUPPORT.md
    ├── RELEASE_PROCESS.md
    ├── QA_MATRIX.md
    ├── RUNBOOKS/
    │   ├── RelayIncident.md
    │   ├── PushFailure.md
    │   ├── DatabaseRecovery.md
    │   └── KeyRotation.md
    └── ADR/
        ├── 0001-local-first.md
        ├── 0002-helper-and-xpc.md
        ├── 0003-structured-integrations.md
        ├── 0004-event-store.md
        ├── 0005-e2e-relay.md
        ├── 0006-risk-policy.md
        ├── 0007-direct-distribution.md
        └── 0008-strict-concurrency.md
```

## 3.1 Target sorumlulukları

- `AgentControlMac`: yalnızca UI, user intent ve helper bağlantısı. Agent process izlemez.
- `AgentControlHelper`: oturumların yerel otoritesi; adapter, persistence, rules, notifications ve relay bağlantısı.
- `AgentControlHook`: çok küçük, hızlı, stateless CLI; input okur, helper'a yollar, gerekli response'u agent formatında döndürür.
- `AgentControlRemoteNode`: uzak makinedeki helper'ın daraltılmış sürümü.
- `AgentControlKit`: platformdan bağımsız domain ve paylaşılan altyapı.
- `Integrations/*`: üçüncü taraf protokollerini ortak domain event'ine çevirir.
- `AgentControlRelay`: yalnızca kimlik, bağlantı, şifreli zarf, push ve kısa ömürlü delivery state'i.
- `NotificationService`: iOS'ta şifreli bildirimi çözerek action category üretir.
- `AgentLiveActivity`: seçili oturumun durumunu kilit ekranı/Dynamic Island'da gösterir.

## 3.2 Modül bağımlılık yönü

```text
Apps / Services / Integrations
            ↓
AgentIntegrations / RelayClient / TerminalNavigation / RulesEngine
            ↓
AgentPersistence / AgentSecurity / AgentProtocol
            ↓
AgentDomain
```

`AgentDomain` hiçbir Apple UI framework'üne, SQLite'a, ağ katmanına veya agent SDK'sına bağımlı olamaz.


---

# 4 — Features

Bu bölümde `P0` 1.0 için zorunlu, `P1` 1.0 tamamlayıcı, `P2` 1.1 ve sonrası anlamına gelir. Codex, P0 eksikken P2 özelliklerine geçmemelidir.

## 4.1 Onboarding ve ilk kurulum — P0

### Akış

1. Hoş geldiniz ve ürünün local-first açıklaması.
2. Çalışma modu seçimi: `Local Only`, `Personal Remote`, `Self-Hosted Remote`.
3. Helper kurulumu ve `SMAppService` kaydı.
4. Notification izni.
5. Kurulu agent ve terminal taraması.
6. Her entegrasyon için destek seviyesi ve kurulacak hook değişikliklerinin preview'u.
7. Seçilen hook'ların atomik kurulumu.
8. İsteğe bağlı Accessibility/Automation açıklaması ve yalnızca ilgili terminal için yönlendirme.
9. Remote mod seçilmişse Sign in with Apple ve iPhone eşleme.
10. Test event'i ve ilk doğrulama.

### Kurallar

- Kullanıcıya değiştirilmek üzere olan config dosyası ve diff gösterilir.
- Kurulum önce backup alır.
- Uygulama config dosyasının tamamını yeniden yazmaz.
- Helper veya hook kurulamazsa dashboard monitor-only şekilde açılabilir.
- Onboarding tekrarlanabilir; tamamlanmış adımlar idempotent olmalıdır.

### Kabul kriterleri

- Temiz makinede kullanıcı bir agent için test event'ini görür.
- Onboarding iptal edildiğinde yarım config kalmaz.
- Uninstall işlemi yalnızca AgentControl tarafından eklenen blokları kaldırır.

## 4.2 Agent keşfi ve capability matrix — P0

Her adapter aşağıdaki yeteneklerden hangilerini desteklediğini runtime'da bildirir:

- `observeSession`
- `observeTurns`
- `observeTools`
- `observeSubagents`
- `requestApproval`
- `answerQuestion`
- `reviewPlan`
- `pause`
- `resume`
- `cancel`
- `startManagedSession`
- `jumpToTerminal`
- `streamReasoningSummary`
- `reportTokenUsage`
- `reportRateLimit`
- `remoteNode`

UI yalnızca `supported` olan eylemleri gösterir. `unknown` veya `degraded` durumda bilgi mesajı ve terminale git seçeneği sunulur.

Keşif kaynakları:

- Kurulu executable path ve version.
- Resmî config/hook sürümü.
- App-server schema version.
- IDE extension handshake.
- Process discovery; yalnızca zengin event yoksa.

## 4.3 Aktif oturum izleme — P0

Her oturum kartı şu alanları destekler:

- Agent adı ve sürümü.
- Node/Mac adı.
- Proje ve repo adı.
- Workspace path'in privacy-safe kısaltması.
- Branch adı; kullanıcı ayarına bağlı.
- Task başlığı; prompt'un tamamı değil, adapter'ın güvenli kısa özeti veya kullanıcı tanımlı etiket.
- Başlangıç saati ve geçen süre.
- Current state.
- Current tool/action.
- Parent/subagent ilişkisi.
- Bekleyen approval/question sayısı.
- Son event zamanı.
- Terminal/IDE türü.
- Remote/local göstergesi.

Görünümler:

- Tümü.
- Running.
- Waiting Approval.
- Waiting Input.
- Failed.
- Completed recently.
- Node'a göre.
- Project'e göre.

Oturum state'i event'lerden türetilir; tek bir process status'üne güvenilmez.

## 4.4 Menu bar ve kompakt üst panel — P0

### Collapsed durum

- Aktif agent sayısı.
- Bekleyen approval varsa belirgin badge.
- En yüksek öncelikli oturum için kısa durum.
- Quiet mode/focus göstergesi.

### Expanded durum

- En fazla beş aktif/bekleyen session kartı.
- Approval için Approve/Deny/Review.
- Question için seçenekler veya Reply.
- Complete/failed için Open Session.
- “Show All” ile dashboard.

### Davranış

- Kullanıcı paneli notch ekranlarda notch çevresine, diğer ekranlarda üst merkeze hizalayabilir.
- Panel hiçbir zaman tam ekran uygulamaların kritik UI'ını zorla kapatmaz.
- Multi-display davranışı ayarlanabilir: active display, main display veya tüm ekranlar.
- Escape kapatır; klavye navigasyonu tam desteklenir.
- Global shortcut varsayılanı `⌃⌥Space`; kullanıcı değiştirebilir.

## 4.5 Dashboard — P0

Sidebar bölümleri:

1. **Overview:** bugün aktif/tamamlanan/failed/waiting, ortalama süre, son olaylar.
2. **Active:** filtrelenebilir tüm aktif session'lar.
3. **Inbox:** approval, question ve plan review kuyruğu.
4. **History:** tamamlanmış session listesi ve arama.
5. **Analytics:** süre, başarı, bekleme, approval ve agent/project dağılımı.
6. **Nodes:** yerel ve uzak makineler, sağlık, last seen.
7. **Integrations:** agent/terminal adapter durumu, versiyon, test ve repair.
8. **Automations:** alert ve güvenli approval kuralları.
9. **Diagnostics:** helper, socket, database, relay, APNs, hook sağlık kontrolü.
10. **Settings:** appearance, privacy, notification, security, retention, update.

Dashboard listeleri büyük veri setlerinde pagination/virtualization kullanır.

## 4.6 Session detail — P0

Sekmeler:

- **Summary:** durum, süre, proje, adapter, node, terminal.
- **Timeline:** normalize event akışı.
- **Approvals:** istekler, kararlar, acknowledgment ve actor.
- **Tools:** tool run özetleri; içerik değil metadata.
- **Subagents:** ağaç görünümü.
- **Diagnostics:** raw event'in redacted teknik görünümü; varsayılan kapalı.

Eylemler:

- Open terminal/IDE.
- Copy safe session ID.
- Add label/note.
- Cancel/pause/resume; adapter destekliyorsa.
- Pin Live Activity.
- Mute session.
- Export redacted diagnostic bundle.

## 4.7 Approval Inbox — P0

### Kart içeriği

- Agent, project, node ve session.
- Risk badge ve risk nedenleri.
- Request type.
- Safe command preview veya file operation summary.
- Etkilenen path domain'i: workspace içi/dışı.
- Network domain/host; varsa.
- Expiry countdown.
- Agent'ın sunduğu justification; güvenilir bilgi olarak değil ayrı metin.
- Eylemler ve eylemin hangi cihazdan yapılabileceği.

### Eylemler

- Approve once.
- Deny.
- Review details.
- Open in terminal.
- Approve for session; yalnızca Mac, adapter destekliyorsa.
- Create rule; yalnızca Mac, karar sonrası ve açık preview ile.

### Queue kuralları

- Birden fazla approval paralel gösterilebilir.
- Aynı request'in duplicate event'leri idempotent birleştirilir.
- Superseded request action alamaz.
- Expired request listede history statüsüne geçer.
- Parent agent ve subagent request'leri ayrı fakat ilişkili görünür.

## 4.8 Question ve plan review — P0

Soru tipleri:

- Single choice.
- Multi choice.
- Free text.
- Confirmation.
- Secret input.

Kurallar:

- Secret input notification veya relay üzerinden cevaplanamaz; terminale yönlendirilir.
- Free text için maksimum uzunluk adapter capability'sinden alınır.
- Choice değerleri stable ID ile gönderilir; görünen label karar payload'ı değildir.
- Plan review'da plan adımları okunur, Approve/Request Changes/Deny desteklenir.
- “Request Changes” serbest metni yüksek riskli command onayıyla karıştırılmaz.

## 4.9 Local notifications ve sesler — P0

Bildirim türleri:

- Approval requested.
- Question asked.
- Plan ready.
- Session completed.
- Session failed.
- Session long-running.
- Session idle/stale.
- Rate limit.
- Remote node disconnected.
- Relay/security warning.

Özellikler:

- Agent/project bazlı ses seçimi.
- Quiet hours.
- macOS Focus/DND durumuna saygı.
- Notification grouping by session.
- Duplicate suppression.
- Completion notification için kısa güvenli sonuç özeti.
- Bildirime tıklayınca önce exact terminal, başarısızsa session detail.

## 4.10 Rules engine ve uyarılar — P0

### Alert koşulları

- `runningDuration > N`.
- `noMeaningfulEventFor > N`.
- `waitingApprovalFor > N`.
- `waitingInputFor > N`.
- `failed`.
- `rateLimited`.
- `nodeDisconnected`.
- `approvalRisk >= X`.
- Agent/project/node filtresi.
- Gün/saat ve focus filtresi.

### Eylemler

- Yerel notification.
- iPhone push.
- Sound.
- Badge.
- Session mute.
- 1.2'de webhook.

### Approval automation

1.0'da yalnızca çok dar kurallar desteklenir:

- Belirli agent + belirli proje.
- Exact tool/action type.
- Workspace içinde kalma zorunluluğu.
- Exact command executable ve argument pattern'i; shell string regex'i değil parsed argv.
- Network yok.
- Secret path yok.
- Max risk `Low`.
- Süreli ve session-scoped.
- Her otomatik kararda audit kaydı ve kullanıcıya görünür indicator.

Critical ve High hiçbir zaman otomatik onaylanmaz.

## 4.11 Long-running, idle ve stuck detection — P0

Ayrı kavramlar:

- **Long-running:** Event üretmeye devam eder fakat toplam süre eşiğini geçer.
- **Idle:** Anlamlı event üretmez; process canlı olabilir.
- **Waiting:** Agent açıkça kullanıcı/approval bekler.
- **Stale:** Hook/session heartbeat kaybolur ve process durumu doğrulanamaz.
- **Disconnected:** Remote node veya managed transport kopmuştur.

Detection, yalnızca stdout sessizliğine dayanmaz. Adapter heartbeat, tool progress, process state ve event zamanları birlikte kullanılır.

## 4.12 History ve arama — P0

- Session, project, agent, node, state, tarih ve label filtreleri.
- Full-text yalnızca kullanıcı tarafından eklenen notlar ve güvenli özet alanlarında.
- Prompt/kod için varsayılan full-text index yoktur.
- Timeline export: redacted JSON veya CSV metadata.
- Retention varsayılanı:
  - raw/redacted event metadata: 30 gün.
  - session summary: 180 gün.
  - security audit: 365 gün.
  - sensitive approval preview: 7 gün veya kullanıcı daha kısa seçebilir.
- “Delete now” ve “Delete all local data” işlemleri.

## 4.13 Analytics — P0

Gösterilecek metrikler:

- Session count.
- Completion/failure/cancel rate.
- Ortalama ve medyan session süresi.
- Approval wait süresi.
- Question wait süresi.
- Agent/project/node dağılımı.
- Approval allowed/denied/expired oranı.
- En sık risk nedenleri.
- Long-running ve stale sayısı.
- Gün/saat yoğunluğu.

Analytics tamamen yerel veriden hesaplanır. Telemetry opt-in değilse hiçbir ürün kullanım verisi sunucuya gönderilmez.

## 4.14 Terminal ve IDE jump — P0

- Session başında correlation token, process ID, terminal bundle ID, window/tab/pane ID ve workspace URI yakalanır.
- Öncelik:
  1. Resmî terminal/IDE API veya extension.
  2. URL scheme.
  3. AppleScript.
  4. Accessibility.
  5. Uygulamayı aktive etme.
  6. Project folder açma.
- UI gerçek sonuç seviyesini gösterir.
- Accessibility izni verilmemişse ürün bunu hata olarak değil capability eksikliği olarak gösterir.
- Navigation komutunda shell interpolation kullanılmaz.

## 4.15 Integration Manager — P0

Her entegrasyon ekranı:

- Installed/not installed.
- Detected version.
- Supported feature matrix.
- Hook status.
- Config location.
- Last event.
- Test integration.
- Repair.
- View managed changes.
- Restore backup.
- Uninstall AgentControl changes.
- Compatibility warning.

Config güncellemesi öncesi/sonrası hash ve managed block ID tutulur. Kullanıcı config'i dışarıdan değiştirirse merge yapılır; bütün dosya geri yazılmaz.

## 4.16 Codex managed sessions — P0

- AgentControl içinden repo/worktree ve başlangıç talimatı seçerek Codex session başlatma.
- `codex app-server` process lifecycle helper tarafından yönetilir.
- Thread/turn/item ağacı gerçek zamanlı gösterilir.
- Command ve file change approval request'leri native Inbox'a gelir.
- Plan, reasoning summary ve tool status yalnızca protokolde mevcutsa gösterilir.
- Process crash olduğunda otomatik yeniden bağlanma denenir; aynı turn sessizce tekrar başlatılmaz.
- Schema mismatch'te session monitor-only veya terminal fallback'e geçirilir.

## 4.17 Saved launchers ve task queue — P2

- Kayıtlı proje + agent + model/profile + başlangıç komutu.
- Bir launcher birden fazla worktree oluşturabilir; explicit user action gerekir.
- Queue concurrency limiti.
- Dependency: task B, task A tamamlanınca.
- Her launch öncesi preview.
- Prod deploy veya destructive action queue'dan otomatik çalıştırılamaz.

## 4.18 SSH ve remote node — P1

- QR veya one-time code ile node pairing.
- Node health, version, uptime ve supported adapters.
- SSH bootstrap script preview.
- Kullanıcı hesabı altında systemd user service/launchd user agent.
- Auto reconnect ve exponential backoff.
- Offline queue ve expiry.
- Remote terminal jump: destekleniyorsa local terminalde SSH profile/tab açma.
- Remote file path hiçbir zaman local path sanılmaz.
- Node revoke anında yeni envelope kabulünü durdurur.

## 4.19 iPhone companion — P1

Ana tab'lar:

- **Home:** node health ve önemli durumlar.
- **Active:** aktif session'lar.
- **Inbox:** approval/question/plan.
- **History:** son session'lar.
- **Settings:** security, devices, notification ve privacy.

Approval review ekranı:

- Risk summary.
- Full parsed command.
- Working directory scope.
- File/network etkileri.
- Expiry.
- Mac online/offline.
- Face ID state.
- Deny.
- Hold-to-approve; yalnızca policy izin verirse.

Telefon hiçbir zaman raw shell string'i kendi başına parse edip risk düşürmez. Risk kararı helper tarafından imzalanır; telefon ek olarak riski yükseltebilir, düşüremez.

## 4.20 Actionable push notifications — P1

Notification category'leri:

- `APPROVAL_LOW`: Approve, Deny, Review.
- `APPROVAL_MEDIUM`: Approve, Deny, Review; authentication required.
- `APPROVAL_HIGH`: Review, Deny.
- `APPROVAL_CRITICAL`: Open Mac, Deny.
- `QUESTION_CHOICE`: dinamik seçenekler uygun değilse Reply/Open.
- `QUESTION_TEXT`: text input reply.
- `SESSION_COMPLETED`: Open, Mute Project.
- `SESSION_FAILED`: Review, Open Mac.
- `SESSION_LONG_RUNNING`: Open, Mute 1h.
- `NODE_OFFLINE`: Open Nodes.

APNs payload açık metinde hassas komut taşımayacaktır. Notification Service Extension şifreli zarfı çözdükten sonra cihazda içerik üretir. Extension key'e ulaşamazsa genel “AgentControl'da yeni bir istek var” bildirimi gösterir.

## 4.21 Live Activity ve widgets — P1/P2

### Live Activity — P1

- Kullanıcı aynı anda en fazla bir session'ı pinler.
- State, geçen süre, agent ve proje kısa adı.
- Waiting approval/input durumu.
- Tamamlandı/failed final state.
- Live Activity üzerinden doğrudan approval yoktur; uygulamaya deep link verir.
- Payload küçük tutulur; timeline ayrıntıları uygulamada kalır.

### Widgets — P2

- Active agent count.
- Pending approval count.
- Son tamamlanan task.
- Widget eylemleri yalnızca uygulamaya yönlendirir veya güvenli mute işlemi yapar.

## 4.22 Apple Watch — P2

- Inbox count ve en yüksek öncelikli kart.
- Completion/failure status.
- Düşük riskli Approve/Deny.
- Diğer işlemler iPhone'a handoff.
- Watch unlock durumu ve device policy doğrulanır.
- Kritik ayrıntılar küçük ekranda kısaltılıp onay verilmez.

## 4.23 Cihaz eşleme ve yönetim — P1

- Sign in with Apple sonrası Mac yeni device identity oluşturur.
- iPhone QR kod tarar veya Mac'te gösterilen tek kullanımlık kodu girer.
- QR payload: pairing session ID, relay origin, ephemeral public key, expiry ve checksum.
- Her iki cihaz karşılıklı public key fingerprint'i gösterir.
- Kullanıcı Mac'te eşlemeyi onaylar.
- Paired device listesi:
  - cihaz adı.
  - platform ve sürüm.
  - last seen.
  - key created at.
  - allowed actions.
  - revoke.
- Revoke, relay token ve device key yetkisini geçersiz kılar.

## 4.24 Privacy kontrolleri — P0/P1

- Project name masking.
- Path masking.
- Branch name paylaşımını kapatma.
- Command preview redaction.
- Remote notification content level:
  - Generic.
  - Project only.
  - Safe summary.
  - Full parsed details; varsayılan değildir.
- Diagnostic export preview.
- Telemetry tamamen opt-in.
- Crash report gönderilmeden önce kullanıcı onayı ve scrubber.

## 4.25 Diagnostics ve self-healing — P0

Health check'ler:

- App/helper code-signing match.
- XPC handshake.
- Socket permissions ve peer UID.
- SQLite integrity check.
- Migration state.
- Disk free space.
- Hook config hash.
- Agent executable/version.
- Relay TLS/auth/WebSocket.
- APNs token registration.
- Notification permission.
- Accessibility/Automation permission.
- Clock skew.

Self-healing:

- Helper restart.
- Socket recreate.
- Stale spool import.
- Hook repair.
- Database checkpoint.
- Relay reconnect.
- APNs token refresh.

Hiçbir self-healing adımı kullanıcı config'ini habersizce silmez.

## 4.26 Updates ve release notes — P0

- Sparkle update kontrolü.
- Stable/beta channel.
- Update imza doğrulaması.
- Helper ile app sürüm uyumluluğu.
- Migration öncesi backup.
- Release notes'ta integration compatibility değişiklikleri.
- Rollback yalnızca schema backward-compatible ise otomatik; aksi halde kullanıcıya açık recovery yolu.

## 4.27 Generic adapter SDK — P2

CLI örneği:

```bash
agentcontrol emit session.started --json event.json
agentcontrol request-decision --json approval.json
agentcontrol emit session.completed --session-id "$ID"
```

SDK gereksinimleri:

- Versioned JSON schema.
- Stable event IDs.
- Capability declaration.
- Timeout/fallback behavior.
- Security guide.
- Fixture-based certification test.
- Üçüncü taraf adapter kodu helper process içine dinamik olarak yüklenmez; ayrı process/protocol sınırı kullanılır.

---

# 5 — Architecture decisions and rules

## 5.1 Üst düzey mimari

```text
Codex app-server / Official Hooks / IDE Extension / Remote Node
                            │
                            ▼
                 AgentControlHook / Adapter
                            │
                 Unix Socket + Peer Validation
                            │
                            ▼
                 AgentControlHelper (authority)
       ┌────────────────────┼─────────────────────┐
       ▼                    ▼                     ▼
 Session Registry       SQLite/WAL          Rules & Risk
       │                    │                     │
       ├──────── XPC ───────┘                     │
       ▼                                          ▼
 macOS Menu/UI                              Local Notification
       │                                          │
       └───────────────────┬──────────────────────┘
                           ▼
                 E2E Encrypted Relay Client
                           │
                           ▼
             Vapor Relay + APNs (ciphertext only)
                           │
                           ▼
       Notification Extension / iPhone / Watch
                           │
                  Signed Encrypted Decision
                           │
                           ▼
                 Helper validates & applies
                           │
                           ▼
                 Agent provider acknowledgment
```

## 5.2 ADR kararları

### ADR-001 — Local-first

Uygulamanın temel izleme ve yerel onay işlevleri hesap veya relay olmadan çalışır. Remote mode isteğe bağlıdır.

### ADR-002 — Ayrı helper zorunludur

Ana UI kapanabilir veya yeniden başlatılabilir. Agent hook'ları beklerken yaşam döngüsü UI'a bağlanamaz. Bu nedenle launchd yönetimli helper yerel otoritedir.

### ADR-003 — Structured integration önceliği

Öncelik sırası:

1. Managed structured protocol/app-server.
2. Resmî hook.
3. Resmî IDE extension/API.
4. Process discovery.
5. Accessibility yalnızca navigation için.
6. Terminal text scraping kullanılmaz.

### ADR-004 — Event store + materialized snapshot

Tüm domain değişiklikleri append-only event olarak kaydedilir. Hızlı UI için session snapshot tabloları transaction içinde güncellenir. Debug ve audit için event izi korunur.

### ADR-005 — SQLite doğrudan kullanım

Yerel persistence için üçüncü taraf ORM kullanılmaz. Typed repository ve migration katmanı proje içinde yazılır.

### ADR-006 — Relay zero-knowledge tasarım

Relay şifre çözme anahtarı tutmaz. Bildirim içeriği E2E zarf içindedir. Server yalnızca routing metadata, ciphertext, expiry ve delivery state görür.

### ADR-007 — Root ve screen recording yok

1.0 hiçbir root daemon veya Screen Recording izni istemez. Accessibility yalnızca opt-in navigation fallback'idir.

### ADR-008 — Direct macOS distribution

Derin CLI/config/helper entegrasyonları nedeniyle macOS uygulaması Developer ID + notarization + Sparkle ile dağıtılır. iOS/watchOS App Store üzerinden gider.

### ADR-009 — Deterministik risk policy

Risk, parsed action verisi ve sabit policy ile hesaplanır. LLM veya agent'ın kendi açıklaması risk seviyesini düşüremez.

### ADR-010 — Strict concurrency

Paylaşılan mutable state actor tarafından sahiplenilir. Production kodunda gerekçesiz `@unchecked Sendable`, `nonisolated(unsafe)` veya global mutable singleton yasaktır.

### ADR-011 — Managed config patch

Entegrasyon kurulumu dosyanın tamamını yeniden üretmez. Managed entry/block, backup, atomic write ve rollback zorunludur.

### ADR-012 — Capability-driven UI

UI agent adına göre hardcode davranış seçmez. Adapter capability matrix ve request payload eylemleri belirler.

## 5.3 Domain modelleri

Temel ID'ler ayrı strong type olmalıdır:

- `NodeID`
- `ProjectID`
- `SessionID`
- `TurnID`
- `ToolRunID`
- `ApprovalRequestID`
- `QuestionID`
- `DeviceID`
- `EnvelopeID`
- `EventID`

Temel modeller:

```swift
struct AgentSession: Sendable, Codable, Identifiable {
    let id: SessionID
    let nodeID: NodeID
    let adapterID: AdapterID
    let externalSessionID: String?
    let project: ProjectReference
    let terminalContext: TerminalContext?
    let parentSessionID: SessionID?
    var state: SessionState
    var startedAt: Date
    var endedAt: Date?
    var lastMeaningfulEventAt: Date
    var snapshotRevision: Int64
}
```

```swift
struct ApprovalRequest: Sendable, Codable, Identifiable {
    let id: ApprovalRequestID
    let sessionID: SessionID
    let providerRequestID: String
    let action: AgentAction
    let risk: RiskAssessment
    let createdAt: Date
    let expiresAt: Date?
    let revision: Int64
    var status: ApprovalStatus
}
```

```swift
enum AgentAction: Sendable, Codable {
    case executeCommand(ParsedCommand)
    case modifyFiles(FileChangeSummary)
    case accessNetwork(NetworkAccessSummary)
    case useTool(ToolInvocationSummary)
    case changePlan(PlanSummary)
    case custom(CustomActionSummary)
}
```

Raw provider payload domain modele sızdırılmaz; adapter diagnostics alanında redacted biçimde tutulabilir.

## 5.4 Event envelope

Tüm local/remote event'ler aşağıdaki ortak zarfa çevrilir:

```json
{
  "protocolVersion": 1,
  "eventID": "uuid",
  "eventType": "approval.requested",
  "source": {
    "adapterID": "codex",
    "adapterVersion": "x.y.z",
    "nodeID": "uuid",
    "processID": 1234
  },
  "sessionID": "uuid",
  "providerSessionID": "opaque",
  "sequence": 42,
  "occurredAt": "RFC3339",
  "receivedAt": "RFC3339",
  "payload": {},
  "privacyClass": "sensitive",
  "correlationID": "uuid",
  "schemaHash": "sha256"
}
```

Kurallar:

- `eventID` global unique.
- `(source, providerSessionID, sequence)` mümkünse unique.
- Aynı event tekrar gelirse idempotent no-op.
- Unknown event type diagnostics'e alınır, state machine'i bozmaz.
- Payload size localde ve relay'de limitlidir.
- Timestamp güvenilirliği source'a göre etiketlenir; ordering için sequence tercih edilir.

## 5.5 Session state machine

State'ler:

```text
discovered
starting
thinking
running
executing
waitingApproval
waitingInput
paused
completed
failed
cancelled
disconnected
stale
```

Öncelik sırası:

```text
waitingApproval > waitingInput > failed > completed > executing > running > thinking > starting > disconnected > stale
```

Bu sıra görünür “attention state” içindir; gerçek lifecycle transition kuralları ayrıdır.

Kurallar:

- Terminal state'ler: completed, failed, cancelled.
- Terminal state sonrası geç gelen event timeline'a eklenebilir fakat session tekrar running olmaz; açık provider resume event'i gerekir.
- Approval beklerken tool progress gelirse approval durumu kaybolmaz.
- Bir session birden fazla pending request taşıyabilir.
- Parent tamamlandı diye subagent otomatik tamamlanmış sayılmaz.
- Elapsed duration için monotonic clock; persistence ve UI tarihi için wall clock.
- Process kaybolduğunda hemen failed denmez; grace period sonrası stale/disconnected.

## 5.6 Approval lifecycle

```text
received
classified
presented
userDecisionPending
signedDecisionReceived
policyValidated
sentToProvider
providerAcknowledged
applied
```

Alternatif son durumlar:

```text
deniedApplied
expired
superseded
providerRejected
policyRejected
deliveryFailed
cancelledByProvider
```

Kritik kural: `Approve` dokunulması `applied` anlamına gelmez. UI önce `Sending…`, provider acknowledgment sonrası `Approved` gösterir.

## 5.7 Risk engine

### Girdiler

- Action type.
- Parsed executable ve argv.
- Shell composition var mı.
- Working directory.
- Workspace boundary.
- File paths ve operation type.
- Network destination.
- Environment variable names; değerler alınmaz.
- Secret path patterns.
- Privilege escalation.
- Destructive keywords/flags.
- Git remote/branch.
- Adapter trust/capability.
- User-created policy.

### Her zaman risk yükselten örnekler

- `sudo`, `su`, privilege escalation.
- `/`, home dışı veya workspace dışı recursive delete/change.
- `rm -rf`, destructive wildcard, disk tools.
- Production deployment.
- Secret/keychain/credential files.
- Pipe-to-shell veya downloaded script execution.
- Unknown shell parsing.
- Network + secret exposure kombinasyonu.
- `git push --force`, protected branch.
- Database destructive migration.

### Parser kuralları

- Provider structured argv veriyorsa onu kullan.
- Tek shell string'i varsa güvenli shell lexer ile parse etmeye çalış; belirsizlik risk düşürmez.
- `&&`, `||`, `;`, pipe, command substitution, redirection ve glob karmaşıklığı riski yükseltir.
- UI parsed komutu ve orijinal redacted preview'u ayrı gösterir.
- Risk classifier pure function ve kapsamlı fixture testlerine sahip olmalıdır.

## 5.8 Telefon approval policy

- Low: notification action ile, cihaz kilidi/authentication required.
- Medium: notification action yalnızca kullanıcı ayarı açıksa; aksi halde app review.
- High: app + Face ID + hold-to-approve.
- Critical: remote approve kapalı; Deny veya Open Mac.
- Mac offline: karar `pendingDelivery` olabilir fakat başarı gösterilmez.
- Request expiry sonrası karar kabul edilmez.
- Aynı request'e iki cihaz karar verirse helper ilk geçerli revision'ı uygular; diğerine `superseded` döner.
- “Approve always/session” remote cihazda 1.0'da yoktur.

## 5.9 Veri tabanı şeması

### `schema_migrations`

- version.
- applied_at.
- checksum.

### `nodes`

- id.
- display_name.
- platform.
- os_version.
- app_version.
- public_key.
- trust_state.
- last_seen_at.
- revoked_at.

### `projects`

- id.
- stable_path_hash.
- display_name.
- redacted_path.
- repository_identity.
- created_at.

### `agent_sessions`

- id.
- provider_session_id.
- adapter_id/version.
- node_id/project_id.
- parent_session_id.
- state.
- attention_state.
- timestamps.
- snapshot_revision.
- terminal_context_id.

### `session_events`

- event_id.
- session_id.
- sequence.
- event_type.
- occurred_at/received_at.
- privacy_class.
- encrypted_or_redacted_payload.
- schema_hash.

### `turns`

- id.
- session_id.
- provider_turn_id.
- state.
- timestamps.
- safe_summary.

### `tool_runs`

- id.
- session_id/turn_id.
- tool_name.
- safe_action_summary.
- state.
- timestamps.
- risk_level.

### `approval_requests`

- id/provider_request_id.
- session_id.
- type.
- risk level/reasons.
- action summary.
- revision.
- status.
- expiry.

### `approval_decisions`

- id/request_id.
- actor_device_id.
- decision.
- signature.
- policy_result.
- sent/applied timestamps.
- provider_ack.

### `questions`

- id/session_id.
- type.
- prompt summary.
- options JSON.
- response encrypted/redacted.
- status/expiry.

### Diğer tablolar

- `terminal_contexts`.
- `integration_installations`.
- `rules`.
- `notification_deliveries`.
- `paired_devices`.
- `sync_outbox`.
- `replay_nonces`.
- `audit_log`.
- `settings`.
- `diagnostic_incidents`.

Tüm foreign key ve index'ler migration testleriyle doğrulanır. Audit tablosu append-only API ile yazılır.

## 5.10 Persistence kuralları

- Her write `DatabaseActor` içinde transaction.
- UI thread üzerinde disk I/O yok.
- Migration önce backup/checkpoint alır.
- Migration checksum değişirse startup fail-fast ve recovery UI.
- SQLite corruption durumunda read-only recovery/export denenir.
- Sensitive blob'lar field-level key ile şifrelenir.
- DB encryption ürünün tüm içeriğini şifreleme iddiasında bulunmaz; FileVault önerilir.
- Retention cleanup batch ve düşük öncelikli çalışır.
- Vacuum yalnızca uygun zamanda ve kullanıcıya görünür health bilgisiyle.

## 5.11 Local IPC protokolü

### XPC

- App ve helper karşılıklı protocol version negotiation yapar.
- Helper incoming client'ın code signing requirement'ını doğrular.
- XPC DTO'ları `NSSecureCoding` veya güvenli Codable wrapper kullanır.
- Uzun timeline verisi pagination ile alınır.
- UI event stream için callback endpoint veya AsyncStream bridge.
- XPC disconnect sonrası exponential reconnect.

### Unix domain socket

- Socket yolu app group/application support altında kullanıcıya özel.
- Mode `0600`.
- Peer UID doğrulaması.
- Frame: magic + protocol version + message type + length + payload checksum.
- Maksimum frame boyutu.
- Hook request-decision çağrısı timeout'lu.
- Helper yoksa hook, agent'ın native prompt'una izin veren neutral sonuç döndürür.
- Hook hiçbir zaman relay'e doğrudan bağlanmaz.

## 5.12 Hook timeout ve failure policy

- Status/notification hook: en fazla kısa fire-and-forget timeout; spool fallback.
- Approval hook: adapter'ın izin verdiği sınır içinde helper yanıtı bekler.
- Helper unavailable:
  - Otomatik allow yok.
  - Mümkünse `no decision/continue native prompt`.
  - Provider neutral semantik sunmuyorsa deny yerine güvenli ve açık fallback seçilir; adapter ADR'ında belgelenir.
- Relay offline olması local approval'ı etkilemez.
- Hook stdout sadece provider response'u; diagnostics stderr/file log.
- Hook input boyutu ve JSON nesting limitleri uygulanır.

## 5.13 Integration adapter interface

```swift
protocol AgentAdapter: Sendable {
    var descriptor: AdapterDescriptor { get }
    func detectInstallation() async -> InstallationStatus
    func capabilities(for version: AgentVersion) async -> CapabilityMatrix
    func installManagedIntegration() async throws -> IntegrationChangeSet
    func uninstallManagedIntegration() async throws
    func normalize(_ input: ProviderEvent) async throws -> [AgentEvent]
    func respond(to request: AgentRequest, decision: AgentDecision) async throws -> ProviderAcknowledgment
    func healthCheck() async -> AdapterHealth
}
```

Kurallar:

- Adapter third-party payload'ı doğrudan UI'a vermez.
- Version-specific mapper ayrı dosyada tutulur.
- Unknown field tolerate edilir; unknown required semantic monitor-only'a düşürür.
- Fixtures gerçek sürüm numarası ve schema hash'iyle saklanır.
- Adapter regression testinde eski fixture'lar da çalışır.

## 5.14 Codex mimari kuralları

### Managed app-server modu

- Helper `Process` üzerinden `codex app-server` başlatır.
- Tercih sırası: stdio JSONL, destekleniyorsa Unix socket.
- Experimental TCP/WebSocket transport 1.0 production'da kullanılmaz.
- Startup handshake version/schema alır.
- Kurulu binary ile eşleşen schema artifact'i cache'lenir.
- Thread/turn/item event'leri sequence ve ID ile map edilir.
- Command/file approval RPC request'i geldiğinde native request oluşturulur.
- Response yalnızca hâlâ açık provider request'e yazılır.
- Item completion provider açısından authoritative kabul edilir.
- Process stdout protokol, stderr diagnostics olarak ayrılır.
- Crash loop limiti ve kullanıcıya health warning.

### Hook modu

- User-level hook config tercih edilir.
- Project-local hook yalnızca repo trusted ise.
- App kendi managed hook entry'sini benzersiz ID ile ekler.
- Auto-review veya provider'ın user-facing approval üretmediği event'lerde kart oluşturulmaz.
- Hook schema kurulu Codex sürümüyle eşleştirilir.
- False positive ihtimalinde request adapter tarafından `informational` işaretlenir; action butonu yoktur.

## 5.15 Claude Code mimari kuralları

- `PermissionRequest` native approval'a çevrilir.
- `Notification` tek başına approval sayılmaz.
- Hook matcher ve scope açıkça yönetilir.
- Provider'ın permission decision şeması versioned mapper'dan çıkar.
- Hook komutunda shell quoting güvenli olmalıdır; executable mutlak path.
- Config JSON merge comments desteklemiyorsa format preservation testleri bulunur.
- Helper unavailable durumunda Claude'un normal permission dialog'u çalışmalıdır.

## 5.16 Gemini CLI mimari kuralları

- Synchronous hook event listesi version detection ile belirlenir.
- stdin tamamen okunur; size limit aşılırsa neutral fallback.
- stdout tam olarak tek JSON response.
- stderr logları privacy redacted.
- Exit code semantiği fixture ve contract testleriyle doğrulanır.
- Decision ve reason alanları provider şemasından üretilir.

## 5.17 Remote relay protokolü

Zarf başlığı:

```json
{
  "envelopeVersion": 1,
  "envelopeID": "uuid",
  "senderDeviceID": "uuid",
  "recipientDeviceID": "uuid",
  "kind": "approval.request",
  "createdAt": "RFC3339",
  "expiresAt": "RFC3339",
  "sequence": 100,
  "keyID": "uuid",
  "ciphertext": "base64",
  "signature": "base64"
}
```

Relay'in görebileceği metadata minimum tutulur. Project, command, path ve risk reason ciphertext içindedir.

API taslağı:

- `POST /v1/auth/apple`.
- `POST /v1/auth/refresh`.
- `POST /v1/pairing/sessions`.
- `POST /v1/pairing/sessions/:id/complete`.
- `GET /v1/devices`.
- `DELETE /v1/devices/:id`.
- `POST /v1/nodes/register`.
- `GET /v1/ws?device_id=...`.
- `POST /v1/envelopes`.
- `GET /v1/envelopes/pending`.
- `POST /v1/envelopes/:id/ack`.
- `POST /v1/push/tokens`.
- `DELETE /v1/push/tokens/:id`.
- `GET /v1/health`.

Tüm mutation endpoint'leri idempotency key kabul eder.

## 5.18 E2E pairing ve key derivation

1. Mac ephemeral X25519 key pair üretir.
2. Pairing session relay'de kısa ömürlü ID olarak açılır.
3. QR, relay origin + session ID + Mac ephemeral public key + expiry taşır.
4. iPhone kendi ephemeral key'ini üretir ve pairing session'a yollar.
5. Her iki taraf shared secret üretir.
6. HKDF ile `pairing-confirmation`, `envelope-encryption`, `device-binding` anahtarları türetilir.
7. Kullanıcı iki cihazda kısa fingerprint'i karşılaştırır/onaylar.
8. Kalıcı device public key'leri şifreli kanal üzerinden değiştirilir.
9. Relay yalnızca public key ve device routing metadata saklar.
10. Ephemeral anahtarlar silinir.

Key rotation cihaz başına yeni key ID üretir. Eski anahtar yalnızca grace period boyunca bekleyen zarfları çözmek için tutulabilir.

## 5.19 APNs pipeline

- Helper zarfı relay'e gönderir.
- Relay recipient push token'ı bulur.
- APNs payload yalnızca envelope ID, ciphertext parçası veya fetch token ve category hint taşır.
- Payload limitine sığmayan ciphertext relay'de kısa süre saklanır; extension authenticated fetch yapar.
- Notification Service Extension time limitine göre hızlı decrypt/render eder.
- Extension başarısız olursa generic notification fallback.
- Action response iOS app/extension güvenli shared container üzerinden outbox'a yazılır.
- Background task veya app launch ile relay'e gönderilir.
- Push teslimi başarı garantisi değildir; WebSocket/pending fetch reconciliation yapılır.

## 5.20 Sync ve offline model

- Her cihazda durable `sync_outbox`.
- Envelope state: queued, sent, serverAccepted, recipientDelivered, recipientAcked, expired.
- WebSocket bağlanınca sequence cursor ile catch-up.
- Duplicate envelope idempotent.
- Clock skew server zamanı ve expiry tolerance ile izlenir.
- Mac offline iken approval request expiry geçerse iPhone action disable edilir.
- Relay'de ciphertext retention kısa ve configurable; ack sonrası silinir.

## 5.21 Terminal context modeli

```swift
struct TerminalContext: Sendable, Codable {
    let applicationBundleID: String
    let processID: Int32?
    let windowIdentifier: String?
    let tabIdentifier: String?
    let paneIdentifier: String?
    let workspaceURI: URL?
    let correlationToken: String
    let capturedAt: Date
}
```

- PID tek başına kalıcı kimlik değildir.
- Correlation token agent env/hook event'ine taşınır.
- Sensitive path UI/relay öncesi redacted edilir.
- Exact jump başarısızsa result reason kaydedilir, otomatik sürekli permission prompt üretilmez.

## 5.22 Config patch engine

Gereksinimler:

- JSON, JSONC, TOML ve düz shell snippet formatları için ayrı patcher.
- Managed entry ID ve comment marker.
- Dosya izinlerini koruma.
- Symlink attack koruması; target path ve ownership doğrulama.
- Temp file aynı filesystem'de.
- Write → fsync → atomic rename.
- Backup rotation.
- Parse/serialize sonrası semantic equivalence testi.
- Kullanıcı değişikliğiyle conflict olursa açık diff.
- Uninstall yalnızca kendi entry'sini kaldırır.
- Golden fixtures: boş dosya, yorumlu dosya, bozuk dosya, duplicate entry, symlink, read-only, concurrent edit.

## 5.23 Concurrency modeli

Actor sahiplikleri:

- `SessionRegistryActor`: session state machine.
- `DatabaseActor`: tüm SQLite connection/write.
- `IntegrationManagerActor`: adapter install/health.
- `RelayConnectionActor`: WebSocket ve outbox.
- `NotificationCoordinatorActor`: dedupe ve scheduling.
- `RuleEngineActor`: rule evaluation.
- `TerminalNavigationActor`: serial permission-sensitive operations.
- UI view model'leri `@MainActor`.

Kurallar:

- Arbitrary `Task.detached` yasak; yalnızca ADR ile.
- Her long-running task cancellation handle tutar.
- AsyncStream continuation leak etmemelidir.
- Actor içinde blocking process wait veya SQLite busy loop yok.
- Callback API'ler checked continuation ile wrap edilir ve tek-resume testi bulunur.

## 5.24 Error modeli

Typed error category'leri:

- `ConfigurationError`.
- `IntegrationError`.
- `ProtocolError`.
- `PersistenceError`.
- `SecurityError`.
- `RelayError`.
- `NotificationError`.
- `NavigationError`.
- `PolicyError`.

Her hata:

- Stable code.
- User-safe message.
- Technical redacted context.
- Retryability.
- Suggested recovery action.

Production kodunda `fatalError`, `try!` ve force unwrap yalnızca gerçekten unreachable generated/bootstrap noktalarında ve testle kanıtlanmışsa kullanılabilir.

## 5.25 Retry ve backpressure

- WebSocket reconnect: exponential backoff + full jitter + max cap.
- APNs/server 429: `Retry-After`.
- Hook socket: kısa bounded retry; agent'ı uzun süre kilitlemez.
- Event stream bounded buffer; overflow diagnostics ve snapshot resync.
- SQLite batch insert.
- UI timeline pagination.
- Relay kullanıcı/device rate limit.
- Approval kararı hiçbir zaman kör retry ile iki kez uygulanmaz; idempotency key zorunlu.

## 5.26 Observability ve logging

- Unified Logging (`Logger`/OSLog).
- Subsystem/category standardı.
- `privacy: .private` ve hash/redaction.
- Default log level info/warning; raw payload yalnızca açık debug toggle ve otomatik expiry ile.
- Correlation ID session/request/envelope boyunca korunur.
- Server structured JSON logs.
- Metrics:
  - connection count.
  - envelope delivery latency.
  - APNs result codes.
  - queue depth.
  - auth failures.
  - rate limit.
- Prompt, command, path veya token metric label olarak kullanılamaz.

## 5.27 Threat model

### Tehditler

- Kötü niyetli repo project-local hook ekler/değiştirir.
- Aynı kullanıcı hesabındaki başka process socket'e sahte event yollar.
- Relay breach.
- Telefon kaybı.
- Replay/tampering.
- Config patch üzerinden command injection.
- Diagnostic loglardan secret sızıntısı.
- Compromised update.
- Agent'ın yanlış veya yanıltıcı risk metadata göndermesi.
- Push action'ın request expire olduktan sonra uygulanması.

### Mitigations

- Trusted project kontrolü.
- UDS mode 0600 + peer UID + executable/code-signing bilgisi mümkünse.
- E2E AEAD + device signature.
- Face ID, device revoke, ThisDeviceOnly keys.
- Nonce/revision/expiry/replay cache.
- Shell yerine argv ve mutlak executable path.
- Central redactor ve privacy tests.
- Developer ID/notarization/Sparkle signature.
- Deterministik local risk classifier.
- Provider acknowledgment ve stale request validation.

## 5.28 Privacy sınıfları

- `publicMetadata`: agent adı, generic state.
- `privateMetadata`: project adı, branch, node adı.
- `sensitive`: command, path, question text.
- `secret`: token, credential, secret answer; persist/relay edilmez veya yalnızca zorunlu cihaz-local secure path.

Her event field'i privacy class taşır. Notification, log, export ve relay serializer bu sınıfa göre davranır.

## 5.29 Coding rules

- Dosya başına ana sorumluluk.
- Dependency injection; global mutable singleton yok.
- Protocol yalnızca gerçek substitution/test sınırı olduğunda.
- View içinde business logic yok.
- UI string'leri String Catalog.
- `Date.now` doğrudan domain'de kullanılmaz; injected `Clock`.
- UUID üretimi test edilebilir provider üzerinden.
- File path için `URL`, raw string değil.
- Shell command birleştirme yok; `Process.executableURL` + `arguments`.
- Codable wire type ile domain type gerektiğinde ayrılır.
- Public API'ler doc comment.
- Her TODO issue ID taşır; release branch'te belirsiz TODO yok.
- Placeholder/fake success production'a çıkamaz.

## 5.30 Test stratejisi

### Unit

- State transition matrix.
- Risk classifier fixture'ları.
- Redactor.
- Event dedupe/order.
- Rule evaluator.
- Crypto encrypt/decrypt/sign/verify.
- Config patch.
- Retention.

### Contract

- Her agent version fixture'ı.
- Unknown/new field tolerance.
- Missing required field fallback.
- Hook stdout exactness.
- App-server request/response correlation.

### Integration

- Hook → socket → helper → DB → XPC.
- Approval round trip.
- Relay encrypted round trip.
- APNs simulated payload → extension → action → helper.
- Helper restart sırasında pending request.
- Network partition/reconnect.
- DB migration/rollback.

### UI

- Onboarding.
- Inbox action.
- Expired approval.
- Offline Mac.
- Face ID success/failure simulation.
- VoiceOver labels ve keyboard navigation.

### Security

- Replay.
- Tampered ciphertext/signature.
- Wrong device.
- Symlink config attack.
- Oversized/deep JSON.
- Malformed frame.
- Log redaction snapshot.
- Critical remote approval rejection.

### Performance

- 100 active sessions.
- 100k events.
- 100 parallel pending approvals.
- Burst 1000 events.
- DB startup/migration.
- Timeline scroll.
- Idle energy.

## 5.31 Accessibility ve localization

- Türkçe ve İngilizce 1.0'da tamamlanır.
- VoiceOver için state/risk/action anlamlı label.
- Sadece renkle durum anlatılmaz.
- Dynamic Type iOS'ta.
- Reduce Motion.
- Increase Contrast.
- Full Keyboard Access macOS.
- RTL-ready layout; 1.0 çeviri zorunlu değil.
- Date/duration/number locale-aware.

## 5.32 Global Definition of Done

Bir feature tamamlanmış sayılmak için:

1. Domain ve failure davranışı uygulanmış olmalı.
2. Unit/contract/integration testleri geçmeli.
3. Accessibility label ve keyboard akışı olmalı.
4. Türkçe/İngilizce string'ler olmalı.
5. Privacy classification ve log redaction değerlendirilmiş olmalı.
6. Diagnostics/health etkisi eklenmiş olmalı.
7. Error recovery kullanıcıya görünür olmalı.
8. Dokümantasyon ve gerekiyorsa ADR güncellenmiş olmalı.
9. Performance budget ihlal edilmemeli.
10. Fake/mock yalnızca debug/test build'de kalmalı.


---

# 6 — Implementation phases

Fazlar sırayla yürütülür. Bir sonraki faza geçmek için önceki fazın kabul kriterleri geçmelidir. UI geliştirmesi gerçek agent'a bağımlı kalmaması için ilk günden Fake Agent Simulator ile yapılır.

## Faz doğrulama durumu

Bu tablo yalnız gerçek test kanıtıyla güncellenir. Doğrulanan değişiklikler bir
commit SHA'sına sahip olmadan `Verified` işaretlenmez. 18 Temmuz 2026 düzeltme
çalışması `52eae6d` tabanı üzerinde henüz commit edilmemiştir.

| Faz | Durum | Kanıt / açık bloklayıcı |
|---|---|---|
| 0 | Pending verification | Tam regresyon ve clean-clone CI sonucu bekleniyor |
| 1 | Pending verification | Tam regresyon sonucu ve remediation commit SHA bekleniyor |
| 2 | Blocked | Ayrı-process transaction crash ve MainActor profiling kapısı eksik |
| 3 | Blocked | Signed `SMAppService` force-quit/uninstall E2E kapısı eksik |
| 4 | Pending verification | Contract mevcut; release donanımı p95 kaydı bekleniyor |
| 5 | Blocked | Gerçek managed Codex command/file approval oturumu çalıştırılmadı |
| 6 | Blocked | Kurulu provider'larda canlı install/repair/uninstall smoke çalıştırılmadı |
| 7 | Blocked | Hotkey düzeltildi; release UI first-render/scroll ölçümü bekleniyor |
| 8 | Blocked | Soru/plan ve callback contract düzeltildi; gerçek notification → provider ack smoke bekleniyor |
| 9 | Not started | Faz 0–8 kapısı geçmeden başlanmaz |

## Faz 0 — Repository bootstrap ve kararların sabitlenmesi

### Amaç

Tek komutla üretilebilen, test edilebilen ve CI'da doğrulanabilen monorepo temeli oluşturmak.

### İşler

- Repository ve work tree'yi oluştur.
- `project.yml`, root `Package.swift`, Makefile ve scriptleri ekle.
- XcodeGen ile macOS/iOS/watchOS/extensions/helper targets üret.
- Build configuration'ları: Debug, Staging, Release.
- SwiftFormat/SwiftLint sabit sürüm yapılandırması.
- GitHub Actions temel CI.
- String Catalog ve Türkçe/İngilizce localization temeli.
- `Docs/ADR/0001...0008` kararlarını yaz.
- `SECURITY.md`, `PRIVACY.md`, `THREAT_MODEL.md` iskeletlerini doldur.
- Debug build için feature flag sistemi.
- App group ve bundle identifier şeması.
- `make bootstrap`, `make generate`, `make test` komutları.

### Teslimatlar

- Tüm target'lar boş shell olarak derlenir.
- Package dependency graph cycle içermez.
- CI clean checkout üzerinde çalışır.

### Kabul kriterleri

- `make bootstrap && make generate && make test` temiz makinede başarılı.
- Debug/Staging/Release ayrı config kullanıyor.
- Hiçbir gerçek secret repoda yok.
- Ana mimari ADR'lar review edilmiş durumda.

## Faz 1 — AgentDomain, wire protocol ve state machine

### Amaç

UI ve entegrasyonlardan bağımsız, deterministik çekirdeği kurmak.

### İşler

- Strong ID type'ları.
- Session, turn, tool, approval, question, node ve project modelleri.
- `AgentEvent` enum ve versioned `EventEnvelope`.
- Session state machine ve transition guard'ları.
- Approval lifecycle.
- Capability matrix.
- Privacy class.
- Clock/UUID abstractions.
- Typed error model.
- JSON schemas ve sample fixtures.
- Risk engine'in ilk sürümü: action type, path scope, privilege, network, destructive operation.

### Testler

- Tüm state transition matrisi.
- Duplicate/out-of-order event.
- Parent/subagent.
- Multiple pending approvals.
- Terminal state sonrası geç event.
- Risk fixture'ları.
- Codable backward/forward tolerance.

### Kabul kriterleri

- Domain target Apple UI framework import etmiyor.
- `%90+` line coverage hedefi; kritik state/risk branch'leri `%100`.
- Unknown event state machine'i crash ettirmiyor.
- Critical risk örnekleri remote-approvable olamıyor.

## Faz 2 — SQLite persistence ve migration altyapısı

### Amaç

Event store, materialized snapshot ve audit'in güvenilir yerel deposunu oluşturmak.

### İşler

- SQLite wrapper ve `DatabaseActor`.
- Initial schema tabloları ve index'ler.
- Event append + snapshot transaction.
- Repository ve read model query'leri.
- WAL, foreign key, busy timeout ve checkpoint.
- Migration runner/checksum.
- Retention cleanup.
- Backup, integrity check ve read-only recovery.
- Sensitive field encryption abstraction.
- 100k event performance fixture'ı.

### Kabul kriterleri

- Crash simülasyonunda committed event kaybı yok.
- Duplicate event iki kez uygulanmıyor.
- Migration tekrar çalıştırılınca no-op.
- Corrupt DB güvenli recovery ekranı için tanılanabiliyor.
- UI thread üzerinde database çağrısı olmadığını test/profiling doğruluyor.

## Faz 3 — Helper LaunchAgent, XPC ve Unix socket

### Amaç

Ana uygulamadan bağımsız yerel otoriteyi kurmak.

### İşler

- `AgentControlHelper` executable.
- LaunchAgent plist ve `SMAppService` register/unregister.
- XPC protocol, version negotiation ve code-signing validation.
- Unix socket server, frame codec, mode 0600 ve peer UID validation.
- Hook spool directory ve importer.
- Session registry actor.
- Health endpoint ve heartbeat.
- App-helper reconnect.
- Graceful shutdown/update handoff.

### Testler

- XPC authorized/unauthorized client.
- Socket same-user/wrong-user fixture.
- Malformed/oversized frame.
- Helper restart.
- App kapalıyken event persistence.
- Burst event/backpressure.

### Kabul kriterleri

- Ana app force quit olsa da helper test event'i işler.
- Helper yeniden başlayınca aktif snapshot geri yüklenir.
- Yetkisiz XPC/socket istemcisi reddedilir.
- LaunchAgent uninstall temiz çalışır.

## Faz 4 — AgentControlHook ve Fake Agent Simulator

### Amaç

Gerçek agent entegrasyonundan önce uçtan uca event ve decision akışını kanıtlamak.

### İşler

- `agentcontrol-hook` CLI.
- `emit`, `request-decision`, `notify`, `doctor`, `version` komutları.
- stdin JSON reader, stdout exact response writer, stderr logger.
- Timeout ve native-prompt fallback contract'ı.
- Spool fallback.
- Fake Agent Simulator:
  - running/progress.
  - approval.
  - question.
  - plan.
  - subagent.
  - completion/failure.
  - malformed/duplicate/out-of-order event.
- Protocol Inspector.

### Kabul kriterleri

- Fake approval'ın Mac helper'a gidip cevabın simulator'a dönmesi.
- Helper kapalıyken simulator native fallback davranışı alıyor.
- Hook stdout'a log sızmıyor.
- Event round-trip p95 yerel hedefi karşılıyor.

## Faz 5 — Codex managed app-server entegrasyonu

### Amaç

Ürünün referans ve en yüksek doğruluklu agent entegrasyonunu tamamlamak.

### İşler

- Codex binary/version detection.
- `codex app-server` process manager.
- stdio JSONL transport; supported ise Unix socket seçeneği.
- Handshake ve schema loader/generator.
- Thread/turn/item event mapping.
- Tool/current action state mapping.
- Command/file approval RPC request mapping.
- Decision response ve provider acknowledgment.
- Managed session start/cancel.
- Crash/reconnect ve schema mismatch fallback.
- Redacted diagnostic capture.

### Contract testleri

- Recorded/generated app-server fixtures.
- Approval request correlation.
- Parallel requests.
- Request expiry/cancel.
- Item completion authority.
- Unknown event.
- Process crash.

### Kabul kriterleri

- AgentControl içinden başlatılan Codex session gerçek zamanlı izlenir.
- Command ve file approval güvenli biçimde onay/red olur.
- UI provider ack öncesi applied göstermez.
- Experimental WebSocket transport production path'inde yoktur.
- Version mismatch monitor-only/fallback ile açıklanır.

## Faz 6 — Codex hook, Claude Code ve Gemini CLI adapter'ları

### Amaç

Kullanıcının mevcut terminal/IDE oturumlarını ortak protokole bağlamak.

### İşler

- Managed config patch engine'in JSON/JSONC/TOML desteği.
- Codex user-level hook installer/mapper.
- Claude Code hook installer/mapper.
- Gemini CLI synchronous hook installer/mapper.
- Version/capability detection.
- Hook diff preview, backup, repair ve uninstall.
- Her adapter için fixture matrix.
- Auto-review/false-positive approval filtreleri.
- Generic adapter'ın ilk monitoring sürümü.

### Kabul kriterleri

- Her üç agent için session started/progress/wait/completed akışı.
- Provider destekliyorsa approval/question round-trip.
- Helper yokken agent'ın doğal prompt akışı bozulmuyor.
- Kullanıcı config yorumları ve bağımsız alanları korunuyor.
- Unknown agent sürümü otomatik allow üretmiyor.

## Faz 7 — macOS menu bar, floating panel ve temel dashboard

### Amaç

Yerel çekirdeği üretim kalitesinde native arayüze bağlamak.

### İşler

- MenuBarExtra/NSStatusItem coordinator.
- NSPanel floating panel ve multi-display placement.
- Collapsed/expanded kartlar.
- Dashboard shell/sidebar.
- Overview, Active, Inbox ve Session Detail.
- XPC AsyncStream bridge.
- Global hotkey.
- Empty/loading/error/offline states.
- Design system ve status/risk tokens.
- VoiceOver, keyboard ve Reduce Motion.

### Kabul kriterleri

- 100 active session listesinde akıcı scroll.
- Approval klavyeyle tamamen yönetilebilir.
- Panel fullscreen/multi-display testlerinden geçer.
- Ana app helper disconnect/reconnect'i veri kaybetmeden gösterir.
- Türkçe ve İngilizce metinler tamamdır.

## Faz 8 — Approval UX, questions, plan review ve macOS notifications

### Amaç

İnsan-onay deneyimini eksiksiz hale getirmek.

### İşler

- Approval detail ve parsed command görünümü.
- Risk reason açıklamaları.
- Approve/Deny/Review/Open Terminal.
- Parallel queue ve expiry.
- Question choice/text ve secret fallback.
- Plan review.
- UserNotifications categories.
- Quiet hours, sound, focus-aware davranış.
- Duplicate suppression ve notification grouping.
- Local acknowledgment status.

### Kabul kriterleri

- Duplicate request tek kart.
- Expired request action alamıyor.
- Secret question notification ile yanıtlanamıyor.
- Focus/quiet policy testleri geçiyor.
- Yanlış applied state üretilmiyor.

## Faz 9 — Rules engine, history, analytics ve diagnostics

### Amaç

Uzun süreli kullanım, proaktif uyarı ve bakım özelliklerini tamamlamak.

### İşler

- Alert rule builder.
- Long-running/idle/stale/wait detection.
- Dar Low-risk session automation.
- History filters/search.
- Analytics queries/charts.
- Retention settings.
- Diagnostics health checks.
- Redacted diagnostic export.
- Repair actions.
- Privacy settings.

### Kabul kriterleri

- Fake clock ile tüm duration rule testleri deterministik.
- High/Critical hiçbir automation ile allow olmuyor.
- Analytics sorguları 100k event'te performans bütçesinde.
- Diagnostic export secret fixture'larını sızdırmıyor.
- Data deletion/retention uçtan uca çalışıyor.

## Faz 10 — Terminal/IDE navigation ve onboarding tamamlaması

### Amaç

Bildirimden doğru çalışma bağlamına dönmeyi ve güvenli kurulumu tamamlamak.

### İşler

- TerminalContext capture.
- Terminal.app, iTerm2, Ghostty, Warp, WezTerm adapter'ları.
- VS Code/Cursor extension.
- URL scheme, AppleScript ve AX fallback.
- Navigation result level.
- Accessibility/Automation izin açıklama ekranları.
- Tam onboarding akışı.
- Integration Manager.
- Hook install/repair/uninstall.
- Full uninstall/reinstall testleri.

### Kabul kriterleri

- Desteklenen terminalde exact pane testleri.
- Başarısız exact jump doğru fallback seviyesini gösteriyor.
- İzin yokken crash veya tekrarlayan sistem prompt'u yok.
- Onboarding yarıda kesilince config bozulmuyor.
- Uninstall yalnızca AgentControl değişikliklerini kaldırıyor.

## Faz 11 — Remote node ve SSH

### Amaç

Başka Mac/Linux makinelerde çalışan agent'ları aynı control center'a eklemek.

### İşler

- `AgentControlRemoteNode` service.
- Node identity/pairing.
- Launchd user agent ve systemd user service paketleri.
- Local hook socket.
- Encrypted node transport.
- Health/heartbeat/version.
- Auto reconnect ve offline queue.
- SSH bootstrap preview ve uninstall.
- Remote terminal profile jump.

### Kabul kriterleri

- Remote node offline/online state doğru.
- Pending request expiry sonrası uygulanmıyor.
- Node revoke yeni event/decision kabul etmiyor.
- Ağ kesintisinde duplicate event yok.
- Remote path local path olarak açılmıyor.

## Faz 12 — Relay backend, auth ve E2E pairing

### Amaç

Telefon erişimini içerik göremeyen güvenli relay ile sağlamak.

### İşler

- Vapor project ve migrations.
- Sign in with Apple token verification.
- Access/refresh token ve device sessions.
- Pairing endpoints.
- Device/node registry.
- WebSocket gateway.
- Encrypted envelope store/forward.
- Redis presence/short queue.
- Rate limiting ve abuse controls.
- APNs provider.
- E2E key agreement/signature/replay protection.
- Dockerfile, health/readiness ve runbook.

### Security testleri

- Invalid Apple token.
- Wrong recipient.
- Tampered envelope.
- Replay.
- Expired pairing.
- Revoked device.
- Token rotation.
- Rate limit.
- Server DB breach modelinde plaintext bulunmaması.

### Kabul kriterleri

- Server log/DB'de prompt, path ve command plaintext yok.
- Mac↔test client encrypted round trip.
- WebSocket kopunca pending fetch ile reconciliation.
- Revoke anında uygulanıyor.
- APNs failure codes doğru işleniyor.

## Faz 13 — iOS companion, actionable notifications ve Face ID

### Amaç

Güvenli telefon kontrolünü production kalitesinde tamamlamak.

### İşler

- Sign in with Apple.
- QR/pairing UI ve fingerprint confirmation.
- Device key storage.
- Nodes, Active, Inbox, Session Detail, History.
- Notification Service Extension decrypt/render.
- Action categories ve text reply.
- Decision signing/encryption/outbox.
- Face ID ve hold-to-approve.
- Offline/expired/superseded state.
- Deep links.
- Privacy content settings.
- Device revoke.

### Kabul kriterleri

- Low/Medium notification action policy'ye göre çalışıyor.
- High uygulama açmadan approve edilemiyor.
- Critical uzaktan approve edilemiyor.
- Face ID failure/cancel güvenli fallback.
- Mac provider acknowledgment gelmeden success gösterilmiyor.
- Extension decrypt edemediğinde generic notification çıkıyor.

## Faz 14 — Live Activity, widgets ve Apple Watch

### Amaç

Durumu hızlı görünür kılmak ve düşük riskli kararları wearable'a taşımak.

### İşler

- Activity attributes ve lifecycle.
- APNs Live Activity update.
- Dynamic Island/Lock Screen views.
- Active/pending widgets.
- Watch app ve WatchConnectivity.
- Low-risk Watch approval.
- iPhone handoff.

### Kabul kriterleri

- Aynı anda yalnızca seçili session Live Activity.
- Live Activity'den direct approval yok.
- Watch High/Critical approve etmiyor.
- Stale activity otomatik sonlandırılıyor.
- Payload limitleri test ediliyor.

## Faz 15 — Security, reliability ve performance hardening

### Amaç

Release candidate öncesi tüm sistem sınırlarını doğrulamak.

### İşler

- Threat model review.
- External-style security checklist.
- Fuzz/malformed protocol testleri.
- Symlink/config injection testleri.
- Crypto key rotation/revoke drills.
- Database recovery drills.
- Network partition/APNs outage tests.
- 100 session/100k event performance.
- Instruments profiling.
- Memory leak/energy tuning.
- Accessibility audit.
- Localization QA.
- Privacy manifest ve data-use review.
- Dependency/SBOM audit.

### Kabul kriterleri

- Açık Critical/High security bug yok.
- Performance bütçeleri karşılanıyor veya belgelenmiş bloklayıcı ADR var.
- Crash-free smoke suite.
- VoiceOver ve keyboard kritik akışları tamam.
- Recovery runbook'ları uygulanarak test edilmiş.

## Faz 16 — Signing, notarization, update ve store release pipeline

### Amaç

Tekrarlanabilir ve doğrulanabilir dağıtım sürecini kurmak.

### İşler

- macOS archive/export.
- Developer ID signing.
- Hardened Runtime ve entitlements verification.
- Notarization/stapling.
- DMG/ZIP packaging.
- Sparkle EdDSA key ve appcast.
- Staged update channel.
- Helper/app compatibility check.
- iOS/watchOS archive ve TestFlight upload.
- dSYM/symbol yönetimi.
- Release verifier script.
- SBOM/checksum.

### Kabul kriterleri

- Temiz Mac'te Gatekeeper uyarısız kurulum.
- Notarization/staple doğrulanıyor.
- Sparkle update eski stable build'den yeni build'e çalışıyor.
- Migration ve helper update başarıyla tamamlanıyor.
- TestFlight build push, pairing ve notification entitlement'larıyla çalışıyor.

## Faz 17 — Beta, launch ve operasyon

### Amaç

Ürünü kontrollü beta ile doğrulayıp 1.0'a çıkarmak.

### İşler

- Internal alpha feature flag seti.
- Adapter compatibility matrix toplama.
- Redacted diagnostics feedback flow.
- Beta release notes ve known issues.
- Crash/relay/APNs dashboard.
- Incident runbooks.
- Privacy policy, support ve data deletion akışı.
- 1.0 release checklist.
- Post-release rollback ve emergency disable flags.

### 1.0 release gate

- P0 ve P1 kapsamı tamam.
- Codex/Claude/Gemini destek matrisi yayınlanmış.
- Local-only mode hesap olmadan test edilmiş.
- Remote E2E security testleri geçmiş.
- macOS notarized stable ve iOS production review gereksinimleri hazır.
- Critical/High açık hata yok.
- Supportable diagnostic ve recovery araçları mevcut.

## 6.1 Codex çalışma kuralları

Codex bu projeyi uygularken:

1. Faz sırasını korur.
2. Her fazın başında ilgili ADR ve test planını günceller.
3. Önce domain/contract testi, sonra production implementation yazar.
4. Yeni agent payload'ını fixture olmadan mapper'a eklemez.
5. UI geliştirmesini Fake Agent Simulator ile bağımsız tutar.
6. Güvenlik veya wire protocol değişikliğini ADR'sız yapmaz.
7. Config dosyasını bütün olarak overwrite eden çözüm üretmez.
8. Agent/provider acknowledgment olmadan success state üretmez.
9. Production koduna hardcoded token, URL secret veya development bypass koymaz.
10. Her faz sonunda `make test`, integration suite ve ilgili UI smoke testlerini çalıştırır.
11. Bir capability desteklenmiyorsa butonu gizler veya açık fallback gösterir; sahte davranış üretmez.
12. `TODO`, stub veya `fatalError("not implemented")` ile fazı tamamlanmış saymaz.

## 6.2 Milestone çıktıları

- **M0 — Core:** Faz 0–4; fake agent uçtan uca.
- **M1 — Codex Alpha:** Faz 5 ve temel Faz 7; gerçek Codex managed session.
- **M2 — Multi-Agent Mac Alpha:** Faz 6–10.
- **M3 — Remote Alpha:** Faz 11–13.
- **M4 — Feature Complete:** Faz 14.
- **M5 — Release Candidate:** Faz 15–16.
- **1.0:** Faz 17 release gate.

---

# 7 — Environment variables

## 7.1 Temel yaklaşım

Native uygulamalar production'da davranışlarını kullanıcı shell environment'ından almamalıdır. Yapılandırma üç sınıfa ayrılır:

1. **Public build configuration:** `.xcconfig` ve `Info.plist` substitution.
2. **Runtime user settings:** SQLite/UserDefaults/Keychain; uygulama UI'ından yönetilir.
3. **Secrets:** Keychain, CI secret store veya server secret manager.

Environment variable'lar esas olarak local development, test, CI ve relay container için kullanılır. Hiçbir private key veya token source control'e girmez.

## 7.2 Client build settings (`.xcconfig`)

```text
AGENTCONTROL_ENV=debug|staging|production
PRODUCT_BUNDLE_IDENTIFIER=com.yusuf.agentcontrol.mac
IOS_BUNDLE_IDENTIFIER=com.yusuf.agentcontrol.ios
WATCH_BUNDLE_IDENTIFIER=com.yusuf.agentcontrol.watch
HELPER_BUNDLE_IDENTIFIER=com.yusuf.agentcontrol.helper
NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER=com.yusuf.agentcontrol.ios.NotificationService
LIVE_ACTIVITY_BUNDLE_IDENTIFIER=com.yusuf.agentcontrol.ios.LiveActivity
DEVELOPMENT_TEAM=$(AGENTCONTROL_TEAM_ID)
AGENTCONTROL_TEAM_ID=XXXXXXXXXX
APP_GROUP_ID=group.com.yusuf.agentcontrol
KEYCHAIN_ACCESS_GROUP=$(AppIdentifierPrefix)com.yusuf.agentcontrol.shared
URL_SCHEME=agentcontrol
RELAY_BASE_URL=https://relay.example.com
RELAY_WS_URL=wss://relay.example.com/v1/ws
SIGN_IN_WITH_APPLE_CLIENT_ID=com.yusuf.agentcontrol.service
SPARKLE_FEED_URL=https://updates.example.com/appcast.xml
SPARKLE_PUBLIC_ED_KEY=PUBLIC_KEY_ONLY
CERT_PIN_SHA256=
SENTRY_DSN=
FEATURE_REMOTE_MODE=YES
FEATURE_SSH=YES
FEATURE_WATCH=YES
FEATURE_DIRECT_LAN=NO
FEATURE_TELEMETRY=NO
```

Kurallar:

- `Local.xcconfig` gitignore içindedir.
- `Base.xcconfig` secret içermez.
- Release build'de debug/mock flags compile-time assertion ile kapalıdır.
- Bundle ID, App Group ve entitlement değerleri CI'da doğrulanır.
- `SPARKLE_PUBLIC_ED_KEY` public olduğu için repo/config içinde olabilir; private update key olamaz.

## 7.3 macOS/iOS local development environment

```text
AGENTCONTROL_LOG_LEVEL=debug|info|warning|error
AGENTCONTROL_DATA_DIR=/absolute/dev/path
AGENTCONTROL_DATABASE_PATH=/absolute/dev/path/agentcontrol.sqlite
AGENTCONTROL_SOCKET_PATH=/absolute/dev/path/agentcontrol.sock
AGENTCONTROL_MOCK_EVENTS_FILE=/absolute/dev/path/events.jsonl
AGENTCONTROL_FORCE_OFFLINE=0|1
AGENTCONTROL_DISABLE_RELAY=0|1
AGENTCONTROL_DISABLE_HOOK_INSTALL=0|1
AGENTCONTROL_DISABLE_ACCESSIBILITY=0|1
AGENTCONTROL_DISABLE_NOTIFICATIONS=0|1
AGENTCONTROL_USE_FAKE_CLOCK=0|1
AGENTCONTROL_RETENTION_DAYS=30
AGENTCONTROL_RELAY_BASE_URL=http://127.0.0.1:8080
AGENTCONTROL_RELAY_WS_URL=ws://127.0.0.1:8080/v1/ws
AGENTCONTROL_ALLOW_INSECURE_LOCALHOST=0|1
AGENTCONTROL_FIXTURE_SEED=12345
AGENTCONTROL_FEATURE_OVERRIDES=comma,separated,debug,flags
```

`AGENTCONTROL_ALLOW_INSECURE_LOCALHOST=1` yalnızca Debug build'de kabul edilir. Release build bu değişkeni yok sayar ve assertion/log üretir.

## 7.4 Helper environment

```text
AGENTCONTROL_HELPER_LOG_LEVEL=info
AGENTCONTROL_APP_GROUP_PATH=/resolved/path
AGENTCONTROL_SOCKET_PATH=/resolved/path/agentcontrol.sock
AGENTCONTROL_SPOOL_DIR=/resolved/path/spool
AGENTCONTROL_DATABASE_PATH=/resolved/path/agentcontrol.sqlite
AGENTCONTROL_MAX_FRAME_BYTES=1048576
AGENTCONTROL_SOCKET_BACKLOG=128
AGENTCONTROL_EVENT_BUFFER_LIMIT=5000
AGENTCONTROL_XPC_PROTOCOL_VERSION=1
AGENTCONTROL_DISABLE_RELAY=0
AGENTCONTROL_HEALTH_INTERVAL_SECONDS=30
AGENTCONTROL_STALE_SESSION_SECONDS=300
AGENTCONTROL_REDACTION_MODE=strict
```

Production helper path'leri environment'tan kör biçimde kabul etmez; app group ve ownership doğrulaması yapar. Environment override yalnızca Debug/CI'da açıktır.

## 7.5 Hook environment

```text
AGENTCONTROL_SOCKET=/resolved/path/agentcontrol.sock
AGENTCONTROL_HOOK_TIMEOUT_MS=25000
AGENTCONTROL_STATUS_TIMEOUT_MS=250
AGENTCONTROL_SPOOL_DIR=/resolved/path/spool
AGENTCONTROL_NODE_ID=uuid
AGENTCONTROL_SESSION_CORRELATION_ID=uuid
AGENTCONTROL_TERMINAL_CONTEXT_TOKEN=opaque-token
AGENTCONTROL_DEBUG=0|1
AGENTCONTROL_NATIVE_FALLBACK=1
AGENTCONTROL_MAX_INPUT_BYTES=1048576
```

Kurallar:

- Hook environment içinde relay token, private key veya user auth token bulunmaz.
- Socket peer doğrulaması environment secret'ına dayanmaz.
- `AGENTCONTROL_NATIVE_FALLBACK=0` Release'te varsayılan olamaz.
- Hook absolute executable path ile çağrılır.
- Debug log stdout'a yazılmaz.

## 7.6 Remote node environment

```text
AGENTCONTROL_NODE_ENV=development|production
AGENTCONTROL_NODE_ID=uuid
AGENTCONTROL_NODE_DISPLAY_NAME=Build-Mac
AGENTCONTROL_NODE_DATA_DIR=/home/user/.local/share/agentcontrol
AGENTCONTROL_NODE_SOCKET_PATH=/run/user/1000/agentcontrol.sock
AGENTCONTROL_RELAY_BASE_URL=https://relay.example.com
AGENTCONTROL_RELAY_WS_URL=wss://relay.example.com/v1/ws
AGENTCONTROL_NODE_CREDENTIAL_FILE=/secure/path/credential
AGENTCONTROL_NODE_LOG_LEVEL=info
AGENTCONTROL_NODE_HEARTBEAT_SECONDS=30
AGENTCONTROL_NODE_OFFLINE_QUEUE_LIMIT=10000
AGENTCONTROL_NODE_ENVELOPE_TTL_SECONDS=300
AGENTCONTROL_NODE_ALLOWED_ADAPTERS=codex,claude,gemini
```

Credential file mode `0600` olmalı ve systemd/launchd user service çalıştıran kullanıcıya ait olmalıdır. Mümkün olan platformlarda credential Keychain/secret service kullanılır.

## 7.7 Relay server environment

```text
APP_ENV=development|staging|production
HOST=0.0.0.0
PORT=8080
PUBLIC_BASE_URL=https://relay.example.com
DATABASE_URL=postgres://user:password@postgres:5432/agentcontrol
REDIS_URL=redis://redis:6379
LOG_LEVEL=info
TRUST_PROXY_HEADERS=1

JWT_SIGNING_PRIVATE_KEY_B64=
JWT_SIGNING_KEY_ID=
TOKEN_HASH_PEPPER=
ACCESS_TOKEN_TTL_SECONDS=900
REFRESH_TOKEN_TTL_DAYS=30
PAIRING_TTL_SECONDS=300
ENVELOPE_TTL_SECONDS=600
PRESENCE_TTL_SECONDS=90
MAX_ENVELOPE_BYTES=65536
MAX_PENDING_ENVELOPES_PER_DEVICE=1000
RATE_LIMIT_REQUESTS_PER_MINUTE=120
RATE_LIMIT_PAIRING_PER_HOUR=20

APNS_KEY_ID=
APNS_TEAM_ID=
APNS_PRIVATE_KEY_B64=
APNS_TOPIC=com.yusuf.agentcontrol.ios
APNS_LIVE_ACTIVITY_TOPIC=com.yusuf.agentcontrol.ios.push-type.liveactivity
APNS_ENVIRONMENT=sandbox|production

SIWA_CLIENT_ID=com.yusuf.agentcontrol.service
SIWA_TEAM_ID=
SIWA_KEY_ID=
SIWA_PRIVATE_KEY_B64=
SIWA_ALLOWED_AUDIENCES=com.yusuf.agentcontrol.ios,com.yusuf.agentcontrol.service

TLS_CERT_PATH=
TLS_KEY_PATH=
CERT_PIN_SET=
CORS_ALLOWED_ORIGINS=
METRICS_ENABLED=1
METRICS_BIND=127.0.0.1:9090
SENTRY_DSN=
SENTRY_ENVIRONMENT=production
ADMIN_TOKEN_HASH=
DATA_RETENTION_HOURS=24
AUDIT_RETENTION_DAYS=365
```

Kurallar:

- Production secret'ları `.env` dosyasında değil secret manager'da.
- `DATABASE_URL`, Redis ve private key loglanmaz.
- CORS yalnızca ileride admin web UI varsa açılır; default boş.
- Metrics public internete bind edilmez.
- `DATA_RETENTION_HOURS` relay ciphertext için kısa tutulur.
- Startup required secret eksikse fail-fast.
- JWT signing key rotation `JWT_SIGNING_KEY_ID` ile desteklenir.

## 7.8 CI/CD secrets

```text
APPLE_DEVELOPER_ID_P12_BASE64
APPLE_DEVELOPER_ID_P12_PASSWORD
APPLE_TEAM_ID
APPLE_NOTARY_KEY_ID
APPLE_NOTARY_ISSUER_ID
APPLE_NOTARY_PRIVATE_KEY_BASE64
ASC_KEY_ID
ASC_ISSUER_ID
ASC_PRIVATE_KEY_BASE64
MATCH_PASSWORD
SPARKLE_PRIVATE_ED_KEY
APNS_KEY_ID
APNS_TEAM_ID
APNS_PRIVATE_KEY_BASE64
SIWA_KEY_ID
SIWA_PRIVATE_KEY_BASE64
SENTRY_AUTH_TOKEN
CONTAINER_REGISTRY_USERNAME
CONTAINER_REGISTRY_PASSWORD
RELAY_DEPLOY_TOKEN
RELAY_DATABASE_MIGRATION_TOKEN
```

CI kuralları:

- Fork PR'larına secret verilmez.
- Signing release workflow environment approval ister.
- Secret output masking.
- Artifact checksum ve provenance.
- Notarization sonucu doğrulanmadan release publish edilmez.
- Sparkle private key yalnızca release job'da.
- TestFlight/App Store upload ayrı protected environment.

## 7.9 `.env.example` — relay

```dotenv
APP_ENV=development
HOST=0.0.0.0
PORT=8080
PUBLIC_BASE_URL=http://localhost:8080
DATABASE_URL=postgres://agentcontrol:agentcontrol@localhost:5432/agentcontrol
REDIS_URL=redis://localhost:6379
LOG_LEVEL=debug

JWT_SIGNING_PRIVATE_KEY_B64=replace_me
JWT_SIGNING_KEY_ID=dev-key-1
TOKEN_HASH_PEPPER=replace_me
ACCESS_TOKEN_TTL_SECONDS=900
REFRESH_TOKEN_TTL_DAYS=30
PAIRING_TTL_SECONDS=300
ENVELOPE_TTL_SECONDS=600
PRESENCE_TTL_SECONDS=90
MAX_ENVELOPE_BYTES=65536
MAX_PENDING_ENVELOPES_PER_DEVICE=1000
RATE_LIMIT_REQUESTS_PER_MINUTE=120

APNS_KEY_ID=replace_me
APNS_TEAM_ID=replace_me
APNS_PRIVATE_KEY_B64=replace_me
APNS_TOPIC=com.yusuf.agentcontrol.ios
APNS_LIVE_ACTIVITY_TOPIC=com.yusuf.agentcontrol.ios.push-type.liveactivity
APNS_ENVIRONMENT=sandbox

SIWA_CLIENT_ID=com.yusuf.agentcontrol.service
SIWA_TEAM_ID=replace_me
SIWA_KEY_ID=replace_me
SIWA_PRIVATE_KEY_B64=replace_me
SIWA_ALLOWED_AUDIENCES=com.yusuf.agentcontrol.ios,com.yusuf.agentcontrol.service

METRICS_ENABLED=1
METRICS_BIND=127.0.0.1:9090
DATA_RETENTION_HOURS=24
AUDIT_RETENTION_DAYS=365
```

Bu dosyadaki değerler yalnızca örnektir. Gerçek key üretimi ve secret injection script/runbook üzerinden yapılır.

## 7.10 Runtime user settings — environment değildir

Aşağıdaki değerler environment variable olarak değil app settings store'da tutulur:

- Quiet hours.
- Notification content level.
- Project/path masking.
- Sound preference.
- Retention.
- Rule definitions.
- Paired device permissions.
- Selected relay/self-hosted endpoint; endpoint public setting, credential Keychain'de.
- Live Activity selection.
- Accessibility/navigation preferences.
- Update channel.
- Telemetry opt-in.

## 7.11 Secret saklama matrisi

| Değer | macOS/iOS | Server | Repoya girer mi? |
|---|---|---|---:|
| Device private key | Secure Enclave/Keychain | Yok | Hayır |
| Relay refresh token | Keychain ThisDeviceOnly | Hash/session record | Hayır |
| APNs provider key | Yok | Secret manager | Hayır |
| Sign in with Apple private key | Yok | Secret manager | Hayır |
| Sparkle public key | App config | Yok | Evet, public |
| Sparkle private key | Yok | CI secret | Hayır |
| SQLite field key | Keychain | Yok | Hayır |
| SSH private key | System Keychain/reference | Yok | Hayır |
| Sentry DSN | Public client config olabilir | Env | DSN public risk değerlendirmesiyle |

## 7.12 Yapılandırma doğrulama

Uygulama/server başlangıcında:

- URL scheme ve TLS koşulları doğrulanır.
- Production'da `http://` ve `ws://` reddedilir.
- Bundle/App Group/Team ID uyumu kontrol edilir.
- Required entitlements runtime health check'e yazılır.
- APNs topic bundle ID ile karşılaştırılır.
- Sign in with Apple audience allowlist zorunlu.
- Secret placeholder (`replace_me`) production'da fail-fast.
- Key ve token loglanmaz.
- Server clock skew health metric'i üretilir.

---

# Son uygulama talimatı

Codex ilk olarak Faz 0 için repository'yi kurmalı; ardından Faz 1–4 ile Fake Agent Simulator üzerinden tamamen çalışan local event/approval omurgasını üretmelidir. Gerçek agent entegrasyonu bu omurga kanıtlanmadan başlamamalıdır. Codex entegrasyonu referans adapter olarak tamamlandıktan sonra diğer adapter'lar aynı capability ve contract modeline uymalıdır. Telefon özelliği, helper'ın yerel otorite olduğu ve provider acknowledgment kuralının hiçbir yerde ihlal edilmediği E2E relay modeli üzerine kurulmalıdır.

Projenin 1.0 başarısı; çok özellik göstermekten önce doğru oturumu doğru state ile göstermesi, izinleri yanlış uygulamaması, kullanıcı config'ini bozmaması ve remote relay compromise durumunda dahi hassas içeriği korumasıyla ölçülecektir.
