# Мото-интерком через интернет для SOARFLY Y12 — техническое исследование и план

Дата: 2026-11-09 · Статус: черновик для согласования (код ещё не пишется)

Обозначения достоверности, которые используются по всему документу:

- **[DOC]** — подтверждено официальной документацией (ссылка в разделе 12).
- **[SRC]** — подтверждено исходным кодом библиотеки.
- **[ВТОР]** — вторичные источники (форумы, рассылки, чужие SDK). Правдоподобно, но не официально.
- **[ГИП]** — гипотеза или инженерная оценка. Требует проверки на устройстве.
- **[НЕИЗВ]** — неизвестно, без теста не выяснить.

Результатов тестов в документе нет: ни одного эксперимента ещё не проводилось.

---

## 1. Краткий технический вывод

**Интерком через интернет с автоматической передачей по VAD на iOS реализуем.** Риск в другом: требования «микрофон гарнитуры Y12» и «стерео-музыка в качестве A2DP» с высокой вероятностью **несовместимы одновременно**.

Почему:

1. В классическом Bluetooth (Y12, судя по описаниям продавцов, — обычная BT 5.x гарнитура) **A2DP — профиль только на вывод**. Apple прямо пишет: *«A2DP is a stereo, output-only profile»* [DOC]. Микрофон гарнитуры доступен только через **HFP** (SCO/eSCO-канал).
2. Пока активен SCO-канал HFP, A2DP-поток на типичной гарнитуре приостанавливается: SCO полнодуплексный, рекомендованный порядок — остановить A2DP, затем поднять SCO [ВТОР]. Это ограничение Bluetooth-стека и гарнитуры, а не политика iOS. Обойти его публичным API нельзя.
3. Если у сессии одновременно разрешены HFP и A2DP, а устройство поддерживает оба профиля, iOS отдаёт **приоритет HFP** [DOC, примечание к `allowBluetoothA2DP`].
4. `bluetoothHighQualityRecording` (iOS 26) даёт полнополосный звук только на поддерживающих маршрутах, например «certain AirPods models». Apple **не рекомендует** его для real-time связи из-за роста задержки, и в ЕС он не работает [DOC]. Для Y12 это почти наверняка не вариант [ГИП, проверяется тестом T-HQ].
5. LE Audio (LC3), который теоретически снял бы ограничение, iOS для сторонних гарнитур не поддерживает [ВТОР]. Есть ли LE Audio у Y12, неизвестно.

**Что из этого следует для продукта:**

| Можно гарантировать | Нельзя гарантировать (публичным API) |
|---|---|
| Музыка из Spotify/YouTube Music **не прерывается** при входе в комнату (через `mixWithOthers`) [DOC] | Стерео A2DP-качество музыки **во время** использования микрофона Y12 |
| Приём голоса собеседников возможен **поверх A2DP** (вывод без микрофона) [DOC] | Отсутствие слышимого переключения A2DP→HFP при старте передачи с Y12 |
| Работа с заблокированным экраном, пока идёт аудио-I/O (фоновый режим `audio`) [DOC] | Перезапуск записи в фоне после прерывания звонком без возврата в приложение [ВТОР: часто падает с `cannotStartRecording`] |
| VAD и шлюз передачи на стороне приложения без остановки захвата | Отсутствие «приглушения» (ducking) музыки при Voice Processing. Можно лишь ослабить через advanced ducking, iOS 17+ [DOC] |

**Честные режимы продукта** (какой реален, выбираем по результатам этапа C):

- **Режим A — «Интерком» (HFP на всю сессию).** Микрофон Y12 открыт постоянно, VAD работает, передача без кнопок. Музыка всю сессию звучит моно и узкополосно (CVSD ≈ до 4 кГц или mSBC ≈ до 8 кГц, зависит от Y12 [НЕИЗВ]). Переключение происходит **один раз**, при входе в комнату, а не при каждой фразе. Единственный режим, где VAD работает с микрофона гарнитуры.
- **Режим B — «Музыка + PTT».** Сессия без микрофона: музыка и голоса собеседников идут в A2DP. На время своей фразы приложение переводит маршрут в HFP. Будет слышимое переключение и задержка старта передачи (сотни миллисекунд или секунды [ГИП]). VAD невозможен: без открытого микрофона нечего анализировать. Нужна кнопка, а кнопки гарнитуры (AVRCP) достаются Now Playing-приложению, то есть Spotify, а не нам [ГИП, проверить]. Реалистичный триггер — внешняя BLE-кнопка на руле.
- **Режим C — «Внешний микрофон + A2DP».** Музыка остаётся в A2DP, а голос идёт с микрофона iPhone (бесполезен в кармане на скорости) или с проводного/USB-микрофона. Работает ли USB-микрофон одновременно с A2DP-выводом, неизвестно [НЕИЗВ, тест T-USB]. Эргономика на мотоцикле сомнительная.

**Рекомендация:** до любой серверной разработки сделать нативный аудио-spike (этапы B–C). Если тест T4/T7 покажет, что с микрофоном Y12 музыка неизбежно уходит в HFP (ожидаемый исход), то MVP — **режим A**, с честным предупреждением в UI, а режим B — опция «музыкального» качества.

---

## 2. Ограничения iOS и Bluetooth

### 2.1 Bluetooth-уровень

| Факт | Достоверность |
|---|---|
| A2DP: стерео, только вывод | [DOC] Apple, `allowBluetoothA2DP` |
| Микрофон BT-гарнитуры доступен через HFP (`allowBluetoothHFP`, бывший `allowBluetooth`) | [DOC] |
| `allowBluetooth` в SDK iOS 26 помечен deprecated, замена — `allowBluetoothHFP`. Поведение идентично | [ВТОР] форум Apple, Swift Forums; заголовок SDK |
| Во время SCO A2DP-стрим на гарнитуре приостанавливается | [ВТОР] Bluetooth whitepaper в пересказе BlueZ/Android. Для Y12 [ГИП] |
| Качество HFP: CVSD 8 кГц (narrowband) или mSBC 16 кГц (wideband speech), моно | [ВТОР]. Что поддерживает Y12 — [НЕИЗВ] |
| iOS не поддерживает LE Audio для обычных сторонних гарнитур | [ВТОР] форум Apple. Официального заявления нет |
| Профили Y12 (A2DP/HFP/AVRCP, версия BT, кодеки AAC/SBC, mSBC) | [НЕИЗВ]. Только описания продавцов: BT 5.3/5.4, данные противоречивы |

### 2.2 Уровень iOS

- Маршрут — системный ресурс. Когда вход уходит на HFP-порт, вывод **всего** звука на этом устройстве, включая Spotify, тоже идёт в HFP-порт [DOC: приоритет HFP; ВТОР: практика]. Приложение не может отправить музыку другого приложения в A2DP, а свой вход взять из HFP того же устройства.
- Управлять Bluetooth-профилями напрямую нельзя. Есть только категория/опции/режим сессии и `setPreferredInput`. Вызов `setPreferredInput` лишь **запрашивает** смену маршрута, результат нужно проверять по `currentRoute` [DOC].
- `mixWithOthers` разрешён для `playAndRecord`. Без него активация сессии **прерывает** другие аудиосессии, то есть Spotify [DOC].
- Режим `voiceChat` **автоматически** добавляет `allowBluetoothHFP` и сужает набор маршрутов до «подходящих для голоса» [DOC]. Значит, `voiceChat` и «A2DP при открытом микрофоне» противоречат друг другу по определению.
- Voice Processing I/O (VPIO) **приглушает чужой звук** (ducking). С iOS 17 силу можно уменьшить: `AVAudioVoiceProcessingOtherAudioDuckingConfiguration` (AVAudioEngine) или `kAUVoiceIOProperty_OtherAudioDuckingConfiguration` (AUVoiceIO), уровни `default/min/mid/max` плюс advanced ducking по голосовой активности [DOC, WWDC23]. Отключить ducking полностью через VPIO нельзя [ГИП: документированного «off» нет].
- Если используются chat-режимы **без** VPIO, система снижает обработку и уровень воспроизведения [DOC, `voiceChat`].
- `setPrefersEchoCancelledInput` (iOS 18.2+) работает только для встроенного микрофона и динамика, с `playAndRecord` + `default` и на части моделей 2024+. Для BT-гарнитуры неприменим [DOC].

---

## 3. Рекомендуемая архитектура

### 3.1 Компоненты iOS-клиента

Предложенные имена в целом подходят. Изменения: `MicrophoneCapture` встроен в медиа-движок, потому что захват ведёт WebRTC ADM. Добавлены `TransmitGate` и `SafetyPolicy`.

| Компонент | Ответственность |
|---|---|
| `AudioSessionController` (был AudioSessionManager) | Единственный владелец `AVAudioSession`. Применяет **профиль** (A/B/C), активирует и деактивирует сессию, слушает interruption/route/mediaServicesReset, публикует состояние |
| `RouteMonitor` (был BluetoothRouteMonitor) | Снимок `currentRoute`/`availableInputs`, классификация «Y12 через HFP / Y12 через A2DP / встроенные / USB», предупреждения о качестве |
| `MediaEngine` | Обёртка над WebRTC/LiveKit: публикация локального трека, приём удалённых, кастомная обработка захваченных кадров (хук для VAD) |
| `VoiceActivityDetector` | Чистая функция над кадрами 16 кГц моно: HPF → оценка шума → Silero VAD → вероятность речи |
| `TransmitGate` | Машина состояний Muted / Listening / Transmitting / Hangover / PTT. Применяет решение VAD к задержанному потоку (pre-roll) с плавными фейдами |
| `SignalingClient` / `RoomService` | REST к нашему backend (создание и вход в комнату, токен) + подключение к SFU |
| `ConnectionRecovery` | `NWPathMonitor`, политика переподключения, ICE restart, экспоненциальный backoff |
| `AppLifecycle` | Foreground/background, мост к локальным уведомлениям («вернитесь в приложение, чтобы восстановить микрофон») |
| `SafetyPolicy` | Правила вроде «гарнитура пропала → немедленно mute, не переключаться молча на микрофон iPhone» |
| `Diagnostics` | Журнал событий JSONL **без аудио**, экспорт по запросу пользователя |
| `SettingsStore` | `UserDefaults` для настроек, Keychain для токенов/идентичности |

### 3.2 Схема

```
 Spotify / YT Music ──(свой AVAudioSession, playback)──┐
                                                       ▼
                                          [системный микшер iOS] ──► маршрут: HFP или A2DP (Y12)
                                                       ▲
 ┌──────────────── наше приложение ────────────────────┼───────────────────────────────┐
 │ SwiftUI ◄─► RoomViewModel                           │                               │
 │                │                                    │                               │
 │ AudioSessionController ◄── RouteMonitor             │                               │
 │   (category/mode/options, interruptions)            │                               │
 │                │                                    │                               │
 │ MediaEngine (WebRTC ADM: VPIO или AVAudioEngine) ───┘ playout удалённых голосов     │
 │      │ capture 48k (из HFP 8/16k)                                                   │
 │      ▼                                                                              │
 │  [resample 16k] → VoiceActivityDetector → TransmitGate (delay line + fades)          │
 │      │                                          │ open/closed                        │
 │      ▼                                          ▼                                    │
 │  Opus encoder (DTX/FEC) ──► SFU ◄── «говорит» через data channel / метаданные        │
 │                                                                                      │
 │ ConnectionRecovery ◄─ NWPathMonitor      Diagnostics      SafetyPolicy               │
 └──────────────────────────────────────────────────────────────────────────────────────┘
          │ HTTPS (FastAPI: комнаты, токены)          │ WebRTC (DTLS-SRTP, UDP / TURN-TLS 443)
          ▼                                           ▼
    FastAPI (Python)  ── серверное API ──►  LiveKit server (SFU, встроенный TURN)
```

Музыка через наш сервер не идёт: её воспроизводит чужое приложение локально, а в сеть уходит только голос после шлюза.

---

## 4. Варианты AVAudioSession и Bluetooth-маршрутизации

Механизмы взаимодействуют друг с другом, поэтому ниже **комбинации**, а не отдельные флаги. Колонка «Ожидание» — гипотезы до spike.

| # | Category / Mode / Options | Ожидание по документации | Что проверяем |
|---|---|---|---|
| P0 | Нет нашей сессии | Spotify → A2DP | Базовая линия звука |
| P1 | `playback` + `mixWithOthers` | Наш вывод и Spotify → A2DP, микрофона нет | Наш playout не портит музыку |
| P2 | `playAndRecord` / `default` / `[mixWithOthers, allowBluetoothA2DP]` | Вход — встроенный микрофон, вывод — A2DP [DOC] | Остаётся ли A2DP при работающем захвате. Уровень и ducking музыки. Режим C |
| P3 | `playAndRecord` / `default` / `[mixWithOthers, allowBluetoothHFP]` | Вход и выход — HFP Y12 | Качество музыки в HFP, частота входа (8k/16k) |
| P4 | P3 + `allowBluetoothA2DP` | HFP в приоритете [DOC] | Подтвердить. Важно: меняется ли маршрут при **активации** сессии или только при **старте входного I/O** |
| P5 | `playAndRecord` / `voiceChat` / `[mixWithOthers, allowBluetoothA2DP]` | HFP добавится автоматически [DOC] | Подтвердить, оценить ducking |
| P6 | P5 + VPIO (AVAudioEngine `setVoiceProcessingEnabled`) с ducking `default` и `advanced+min` | Ducking заметен, на `min` слабее | Громкость музыки (дБ), утечка музыки в uplink, AEC |
| P7 | P4 с VPIO в обход (`bypass`) | Нет ducking, нет AEC/AGC | Эхо удалённых голосов и музыки в микрофоне шлема |
| P8 | P2 → `setPreferredInput(Y12 HFP)` → обратно `setPreferredInput(builtIn)` | Динамическая смена A2DP↔HFP | **Режим B**: время переключения, щелчки и паузы музыки, стабильность |
| P9 | `bluetoothHighQualityRecording` (iOS 26, mode `default`) | Для Y12 `isSupported == false` [ГИП] | Закрыть вопрос окончательно |
| P10 | P2 + USB/Lightning-микрофон | [НЕИЗВ]: останется ли вывод на A2DP | Режим C с внешним микрофоном |

Ключевые наблюдения для дизайна:

- **WebRTC по умолчанию** задаёт `playAndRecord` + `voiceChat` + `allowBluetooth` и **не** ставит `mixWithOthers` [SRC: `RTCAudioSessionConfiguration.m`]. Значит, «из коробки» WebRTC прервёт Spotify. Нужна собственная конфигурация: `useManualAudio`/своя `RTCAudioSessionConfiguration`, а в LiveKit — `isAutomaticConfigurationEnabled = false` [ВТОР, документация LiveKit].
- В WebRTC ADM есть флаг `bypass_voice_processing`. Заголовок предупреждает о непредсказуемых последствиях для аудиотракта [SRC]. В LiveKit Swift есть `isVoiceProcessingBypassed` (переключается без рестарта движка) [ВТОР]. Использовать только как эксперимент P7.
- Для **ducking** нужен доступ к VPIO-юниту или к `inputNode` AVAudioEngine. В LiveKit Swift (ADM на AVAudioEngine) это потенциально достижимо, в стандартном ADM WebRTC (AudioUnit VPIO) нужен патч. Это критерий выбора медиа-стека на этапе D [НЕИЗВ].
- Нельзя делать выводы о качестве только по `currentRoute`/`sampleRate`. Решающее доказательство — **объективный спектр** на динамике гарнитуры: срез около 4 кГц (CVSD) или около 8 кГц (mSBC) против 15–20 кГц (A2DP), плюс L/R-тест. См. протокол spike.

### Базовая конфигурация режима A (иллюстрация, не финальный код)

```swift
let s = AVAudioSession.sharedInstance()
// HFP обязателен для микрофона Y12; mixWithOthers — чтобы не прерывать Spotify.
// allowBluetoothHFP требует SDK iOS 26; на старых SDK — .allowBluetooth (то же поведение).
try s.setCategory(.playAndRecord, mode: .voiceChat,
                  options: [.mixWithOthers, .allowBluetoothHFP])
try s.setActive(true)
// Явно выбрать вход Y12, если он есть в availableInputs (portType == .bluetoothHFP).
if let y12 = s.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
    try s.setPreferredInput(y12)
}
```

---

## 5. Проектирование VAD

### 5.1 Где работает VAD

- **На захваченных кадрах до кодера Opus**, внутри медиа-движка: хук кастомной обработки захвата (в форке webrtc-sdk/LiveKit есть capture post-processing delegate [ВТОР, проверить API выбранной версии]).
- Захват **не останавливается**. Решение VAD управляет только `TransmitGate`. Перезапуск I/O на каждой фразе вызывал бы перестроение маршрута и щелчки, а в фоне мог бы и вовсе не стартовать снова.
- Вход: после VPIO (AEC/NS/AGC уже применены) или сырой сигнал при bypass. Ресемплинг в 16 кГц моно, кадры по 32 мс (512 отсчётов, нативный размер Silero) [ВТОР].

### 5.2 Конвейер

1. **HPF** 120–200 Гц (настраивается профилем «двигатель/ветер»): убирает гул двигателя и низкочастотные удары ветра.
2. **Трекер шумового пола**: minimum statistics по энергии кадров с медленной адаптацией вверх и быстрой вниз.
3. **Нейросетевой VAD — Silero** (MIT, CoreML/ONNX-порты есть). WebRTC VAD (GMM, libfvad) дешевле, но заметно хуже различает речь и ветер [ГИП, сравнить на записях].
4. **Решение**: передача стартует, только если *одновременно*:
   - p(речь) ≥ `T_on` (≈0.6) на ≥ N кадров подряд (≈2–3 кадра, 64–96 мс),
   - энергия ≥ шумовой пол + `M` дБ (≈6–10 дБ). Защищает от «речеподобного» шума, но **само по себе** передачу никогда не открывает.
5. **Гистерезис окончания**: p < `T_off` (≈0.35) → состояние Hangover на 500–800 мс (стартовая гипотеза — 650 мс). Если речь вернулась за это время, передача продолжается без разрыва.
6. **Защита от коротких всплесков**: сегменты речи короче ≈200 мс без продолжения не открывают передачу (или открывают, но с откатом решения по задержанному буферу, см. 5.3).

### 5.3 Pre-roll без потери первого слога

Проблема: решение принимается через 64–96 мс после начала речи, а этот звук уже ушёл бы в кодер как «закрытый».

Решение: **линия задержки D** (стартовая гипотеза 120 мс, диапазон 80–200 мс) между VAD и шлюзом. VAD смотрит на «живой» сигнал, а шлюз открывается на задержанном. Начало фразы сохраняется полностью, а цена — +D к задержке в одну сторону. Без задержки сохранить начало невозможно, потому что нельзя отправить «прошлое» в реальном времени.

Фейды на шлюзе 10–20 мс, чтобы не было щелчков.

### 5.4 Тишина и трафик

- При закрытом шлюзе в кодер подаются нули. Opus **DTX** тогда шлёт только редкие служебные кадры, и трафик близок к нулю. Opus FEC/RED для устойчивости к потерям [ГИП: проверить настройки LiveKit по умолчанию].
- Без шлюза DTX в шлеме не помогает: внутренний VAD кодера считает ветер сигналом. Поэтому шлюз нужен в первую очередь **ради слушателей** (не транслировать им ветер), а уже потом ради трафика.
- Состояние «говорит» передаётся отдельно (data channel или метаданные участника), чтобы UI собеседников не зависел от уровня звука.
- Вариант для эксперимента: Apple «muted talker detection» (VPIO, iOS 15+) выдаёт события начала и конца речи только **в состоянии mute** [DOC, WWDC23]. Его можно сравнить с Silero как альтернативный триггер, но pre-roll он не решает.

### 5.5 Настройки пользователя

- Чувствительность (1–5) → `T_on`/`T_off`/`M`.
- Профиль шума: «Город», «Трасса», «Ветрено» → частота HPF, `M`, N кадров.
- Hangover 400–1200 мс.
- Режимы: Авто (VAD) / PTT / Mute. Mute доступен всегда, большой кнопкой.

---

## 6. WebRTC и backend

### 6.1 Mesh или SFU

| | P2P mesh | SFU (LiveKit OSS) |
|---|---|---|
| Uplink каждого телефона при N=10 | 9 потоков × ~30–40 кбит/с ≈ 300–400 кбит/с, 9 кодеров и 9 DTLS-сессий | 1 поток |
| Downlink при N=10 | 9 потоков | 9 потоков (при шлюзе активны только говорящие) |
| Сервер | Сигналинг + TURN | SFU + TURN (в LiveKit встроен) |
| Переподключения | Своя логика на каждую пару | Есть в SDK (resume / full reconnect) |
| Объём своей работы | Большой: сигналинг, glare, ICE restart | Малый: FastAPI выдаёт токены |

**Рекомендация для 2–10 участников: SFU сразу (LiveKit, self-hosted, Apache-2.0).** Mesh приемлем для 2–4 участников, но мобильный uplink в движении нестабилен, а 9 кодеров греют телефон.

FastAPI остаётся тонким сервисом комнат и авторизации. Свой WebSocket-сигналинг SDP/ICE в этой схеме не нужен.

Альтернатива (если на этапе D окажется, что LiveKit SDK не даёт нужного контроля над `AVAudioSession`/VPIO): чистый WebRTC (webrtc-sdk) + FastAPI WebSocket-сигналинг (offer/answer/ICE) + coturn + mesh до 4 участников. Позже переход на mediasoup или собственный клиент LiveKit-протокола. Это решение принимается на этапе D, а не сейчас.

### 6.2 Backend (MVP)

- **FastAPI**:
  - `POST /rooms` — создать комнату: короткий код + опциональный PIN, TTL.
  - `POST /rooms/{code}/join` — выдать JWT-токен LiveKit на 10–15 минут; клиент обновляет его при переподключении.
  - `DELETE /rooms/{code}` — закрыть комнату (создатель).
  - `GET /health`.
- **Идентичность**: анонимный ID устройства + подпись. Sign in with Apple — позже. Токены в Keychain.
- **Хранилище**: комнаты живут в памяти процесса. Если нужна переживаемость рестартов — один файл SQLite. Redis/PostgreSQL не нужны: один узел LiveKit работает без Redis, Redis требуется только для мультиузлового кластера [ГИП: сверить с документацией LiveKit версии на момент развёртывания].
- **Развёртывание**: одна VM: LiveKit server (UDP-диапазон или UDP-mux, TCP fallback, TURN/TLS на 443) + FastAPI + reverse proxy с TLS.
- **Аудио**: Opus моно, 20 мс кадры, 24–32 кбит/с, DTX вкл., FEC/RED вкл.

### 6.3 Бюджет задержки в одну сторону (оценка [ГИП])

| Звено | мс |
|---|---|
| HFP uplink гарнитура→iPhone | 20–50 |
| Буфер захвата + VPIO | 10–20 |
| Pre-roll D | 80–200 |
| Кадр Opus + кодирование | 20–25 |
| Сеть LTE + SFU | 40–120 |
| Jitter buffer | 40–120 |
| Воспроизведение + HFP/A2DP downlink | 30–150 (A2DP обычно дольше HFP) |
| **Итого** | **≈240–680**, цель — медиана ≤ 350 |

---

## 7. Фон и системные события

| Тема | Решение | Достоверность |
|---|---|---|
| Разрешение на микрофон | `NSMicrophoneUsageDescription`. Запрос — только при первом входе в комнату | [DOC] |
| Фон | `UIBackgroundModes: audio`. Аудио и микрофон работают при блокировке, **пока идёт аудио-I/O**. Сессию запускаем только из foreground по явному действию | [DOC] (основа); фоновая запись — [ВТОР] |
| Индикация | Системный оранжевый индикатор микрофона + наш индикатор TX | [DOC] |
| WebSocket/WebRTC в фоне | Живут, пока процесс не приостановлен, а процесс живёт благодаря активному аудио | [ГИП, тест T8] |
| Входящий звонок | `interruptionNotification .began` → UI «пауза», шлюз закрыт. `.ended` → попытка восстановить I/O. **В фоне может упасть с `cannotStartRecording`** — тогда локальное уведомление «Нажмите, чтобы вернуться в комнату», а сигнальное соединение сохраняется, пока это возможно | [ВТОР] форумы Apple |
| Рингтон | `setPrefersNoInterruptionsFromSystemAlerts(true)` — ринг не прерывает сессию до ответа на звонок | [DOC, проверить эффект] |
| Siri / уведомления | Прерывания и временный ducking. Обработка такая же, как у прерываний | [ГИП] |
| Route change | `oldDeviceUnavailable` (Y12 пропала) → **автоматический mute** + звуковое и визуальное предупреждение. Молча переходить на микрофон iPhone нельзя. При возврате Y12 — `setPreferredInput`, mute снимается только явно или по настройке | Дизайн |
| Media services reset | Пересоздать всё: сессию, движок, ADM, переподключиться к комнате | [DOC] |
| CallKit | **Не нужен** для уже активного сеанса. Звонок через CallKit, скорее всего, прервёт Spotify (сессия не микшируемая) [ГИП]. Рассматривать только если не решится проблема восстановления после звонка в фоне | Дизайн |
| PushKit | Нужен только для **входящих приглашений**, когда приложение не запущено, и обязательно в связке с CallKit. В MVP не входит | [DOC] |
| Сеть | `NWPathMonitor`. Смена Wi-Fi/LTE → ICE restart или resume SDK. Backoff 0.5→8 с. TURN/TLS 443 для сотовых сетей с ограничениями | [ГИП] |
| Батарея/нагрев | Экран выключен. `ProcessInfo.thermalState`: при `.serious` — легче VAD (реже инференс), ниже битрейт | [ГИП] |

Приватные API и недокументированные entitlements не используются.

---

## 8. План проверки аудиокачества

Отдельный документ: [02-audio-spike-protocol.md](02-audio-spike-protocol.md). Там тесты T1–T12 + T-HQ/T-USB, матрица P0–P10, уровни измерения и форма записи результатов.

---

## 9. Критерии приёмки MVP (все значения — гипотезы)

| Метрика | Цель | Как мерить |
|---|---|---|
| Задержка рот→ухо, одна сторона | медиана ≤ 350 мс, p95 ≤ 500 мс на LTE | Клик/хлопок, записанный на обоих концах, или loopback через два iPhone |
| Старт передачи после начала речи (без учёта D) | ≤ 100 мс | Лог VAD |
| Окончание после замолкания | hangover ± 50 мс | Лог |
| Потеря первого слога | ≤ 5 % фраз | Скрипт из 100 фраз, прослушивание на приёме |
| Потеря последнего слога | ≤ 5 % | То же |
| Ложные срабатывания VAD без речи | ≤ 1 за 10 мин при 90 км/ч; ≤ 3 за 10 мин в городе | Лог + запись приёмной стороны |
| Обрывы соединения | ≤ 1 в час при нормальном покрытии LTE | Лог |
| Восстановление после смены сети | p90 ≤ 5 с до звука | Лог |
| Восстановление после потери сети на 30 с | ≤ 10 с после появления сети | Лог |
| Батарея | ≤ 15–20 %/ч (iPhone 13+, экран выкл.) | Тест 60 мин |
| Нагрев | Нет `.serious` за 2 ч в держателе при 25 °C | `thermalState` в логе |
| Непрерывность музыки | 0 остановок Spotify по нашей вине за 60 мин | Наблюдение + лог |
| **Качество музыки** | **Нет слышимого переключения в разговорный режим во время передачи речи.** Ожидается **FAIL** для режима A с Y12 — фиксируем честно. Для режима A отдельный критерий: переключение ровно 1 раз при входе и 1 раз при выходе, без «дребезга» | Объективный спектр + слепое прослушивание |
| Ducking музыки в режиме A | ≤ 6 дБ при ducking `min` | Измерение уровня |

---

## 10. Поэтапный план

**Главное правило:** этап D не начинается, пока этап C не закрыл риск Bluetooth.

### A. Исследование (этот документ)
- **Цель**: понять реализуемость. **Задачи**: документация, гипотезы, протокол.
- **Результат**: документ + протокол.
- **Критерий**: протокол согласован.
- **Риск**: неверная гипотеза о Y12.
- **Стоп**: нет.

### B. Swift-прототип аудиосессии (AudioSpike)
- **Цель**: инструмент, который применяет пресеты P0–P10 и снимает показания.
- **Задачи**: пресеты, снимки `currentRoute`/`availableInputs`/частот/латентностей, журнал уведомлений, захват через AVAudioEngine (уровень, частота), тестовый тон и голосовой клип на вывод, переключатель VPIO и ducking, экспорт JSONL.
- **Результат**: приложение на iPhone.
- **Критерий**: все пресеты применяются, журнал экспортируется.
- **Риск**: нет Mac/Xcode, нет iPhone на актуальной iOS.
- **Стоп**: нет устройства → разработку не продолжать.

### C. Y12 + музыка
- **Цель**: закрыть ключевой риск.
- **Задачи**: протокол T1–T12, T-HQ, T-USB, объективный спектр.
- **Результат**: заполненная форма + выбор режима A/B/C.
- **Критерий**: для каждого пресета есть объективные данные (срез спектра, стерео, уровень).
- **Риск**: Y12 работает нестабильно по HFP.
- **Стоп / смена архитектуры**:
  - Если в HFP Y12 даёт неприемлемый звук или отваливается → рекомендовать другую гарнитуру (проверенную по тому же протоколу) или режим C.
  - Если P8 показывает переключение > 1,5 с или срыв музыки → режим B не делать.

### D. WebRTC между двумя iPhone
- **Цель**: голос с выбранной конфигурацией сессии.
- **Задачи**: LiveKit dev-сервер + FastAPI-токены. Отключить автоконфигурацию сессии SDK и применить профиль из C. Проверить ducking-конфиг и capture-хук.
- **Результат**: два телефона разговаривают при играющем Spotify.
- **Критерий**: маршрут и качество музыки совпадают с замерами spike (тот же спектр).
- **Риск**: SDK переопределяет сессию.
- **Стоп**: нет контроля над `mixWithOthers`/VPIO → альтернатива 6.1 (чистый WebRTC).

### E. VAD + шлюз
- **Цель**: автоматическая передача.
- **Задачи**: конвейер 5.2, линия задержки, настройки. Записи шума шлема (локально, с явного согласия, для настройки) → офлайн-подбор порогов.
- **Результат**: режим «Авто».
- **Критерий**: метрики VAD из раздела 9 на стенде и в первом выезде.
- **Риск**: ветер > 100 км/ч.
- **Стоп**: ложные срабатывания недопустимы даже на минимальной чувствительности → режим PTT как основной + шумоподавляющий микрофон (ветрозащита).

### F. Фон, восстановление, диагностика
- **Задачи**: прерывания, звонки, Siri, потеря сети, Y12 отключили и вернули, media reset, блокировка на 60 мин.
- **Критерий**: все сценарии T8–T12 восстанавливаются или дают понятное уведомление.
- **Стоп**: после звонка в фоне микрофон не восстанавливается никогда → решение: принять ручной возврат в приложение или оценить CallKit (с риском для музыки).

### G. Комнаты и 3–10 участников
- **Задачи**: создание и вход по коду, PIN, список участников, индикатор «говорит», лимиты.
- **Критерий**: 6+ телефонов, 30 мин, метрики раздела 9.
- **Риск**: трафик и нагрев.

### H. Полевые испытания
- **Задачи**: город и трасса, 2+ райдера, 1–2 ч, разные операторы, iPhone разных поколений.
- **Результат**: отчёт и тюнинг порогов.
- **Стоп**: задержка > 600 мс медиана или регулярные обрывы → пересмотр TURN/кодека/SFU-региона.

---

## 11. Неизвестные — проверять на реальном устройстве

1. Профили и кодеки Y12: HFP wideband (mSBC)? AAC для A2DP? Стабильность HFP при BT 5.x.
2. Меняется ли маршрут при **активации** `playAndRecord`+HFP или только при старте входного I/O (P4/P7).
3. Время и слышимость переключения A2DP↔HFP через `setPreferredInput` (P8).
4. Уровень ducking музыки при VPIO на `default`/`min`, работает ли advanced ducking с BT HFP.
5. Утечка музыки и голосов собеседников из динамиков шлема в микрофон Y12. Справляется ли AEC VPIO с «чужим» звуком (Spotify).
6. Приходят ли события кнопок Y12 в наше приложение при `mixWithOthers` (ожидается: нет).
7. Восстановление записи после звонка, Siri или будильника в фоне на текущей iOS.
8. Поведение `setPrefersNoInterruptionsFromSystemAlerts` с Y12.
9. Выживание WebRTC/WebSocket при длительной блокировке (60+ мин) и при переходе в зону без сети.
10. Работа USB/Lightning-микрофона одновременно с выводом в A2DP (режим C).
11. Реальная частота HFP-входа (8 или 16 кГц) и качество VAD на нём.
12. Различие поведения между поколениями iPhone и версиями iOS (минимум: iOS 18 и iOS 26).
13. Предоставляет ли выбранная версия LiveKit/webrtc-sdk доступ к ducking-конфигу и capture-хуку.
14. Энергопотребление Silero VAD на 32-мс кадрах (CPU или ANE).

---

## 12. Источники

**Apple (проверено в этом исследовании):**
- allowBluetoothA2DP — https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp
- allowBluetoothHFP — https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp
- bluetoothHighQualityRecording (iOS 26) — https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording
- mixWithOthers — https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers
- Mode.voiceChat — https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat
- setPreferredInput — https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput(_:)
- setPrefersEchoCancelledInput (iOS 18.2) — https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersechocancelledinput(_:)
- AVAudioVoiceProcessingOtherAudioDuckingConfiguration — https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration
- WWDC23 «What's new in voice processing» (ducking, muted talker detection) — https://developer.apple.com/videos/play/wwdc2023/10235/
- WWDC25 «Enhance your app's audio recording capabilities» — https://developer.apple.com/videos/play/wwdc2025/251/
- Configuring your app for media playback (фоновый режим audio) — https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback

**Apple (из базовых знаний, ссылки не перепроверялись в этой сессии):**
- Handling audio interruptions — https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
- Responding to audio route changes — https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes
- mediaServicesWereResetNotification — https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification
- setPrefersNoInterruptionsFromSystemAlerts — https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersnointerruptionsfromsystemalerts(_:)
- PushKit / CallKit — https://developer.apple.com/documentation/pushkit , https://developer.apple.com/documentation/callkit

**Форумы и вторичные источники:**
- Депрекация allowBluetooth → allowBluetoothHFP — https://developer.apple.com/forums/thread/797379 , https://forums.swift.org/t/xcode-26-avaudiosession-categoryoptions-allowbluetooth-deprecated/80956
- Запись в фоне после прерывания (`cannotStartRecording`) — https://developer.apple.com/forums/thread/120038 , https://developer.apple.com/forums/thread/813278
- LE Audio/LC3 в iOS — https://developer.apple.com/forums/thread/829759
- A2DP приостанавливается при SCO (BlueZ/whitepaper) — https://linuxlists.cc/l/15/linux-bluetooth/permalink/%3C20090625082913.GA25902%40jh-x301%3E
- Android: пауза A2DP при SCO — https://gitlab.e.foundation/e/os/android_packages_modules_bluetooth/-/commit/b553e858b21cddbef30a761678e3103d919b258a
- Sena RideConnected, отзывы о качестве (анекдотично) — https://www.ukgser.com/community/threads/sena-rideconnected-app-is-this-the-last-bit-we-have-been-waiting-for.278849/
- Описания Y12 у продавцов (ненадёжно, противоречиво) — https://sarkkart.com/shop-2/helmet-accessories/bluetooth-intercom/y12-motorcycle-helmet-headset-bluetooth-5-3-ipx6-waterproof-music-sharing-ai-voice-assistant-32h-playtime

**WebRTC / LiveKit / VAD:**
- RTCAudioSessionConfiguration (дефолты) — https://github.com/webrtc-sdk/webrtc/blob/master/sdk/objc/components/audio/RTCAudioSessionConfiguration.m
- audio_device_module.h (`bypass_voice_processing`) — https://webrtc.googlesource.com/src/+/HEAD/sdk/objc/native/api/audio_device_module.h
- LiveKit Swift SDK — https://github.com/livekit/client-sdk-swift ; управление аудио (сторонний mirror документации) — https://www.mintlify.com/livekit/client-sdk-swift/guides/audio-management
- LiveKit server — https://github.com/livekit/livekit ; https://docs.livekit.io
- Silero VAD — https://github.com/snakers4/silero-vad ; CoreML-порт — https://huggingface.co/aufklarer/Silero-VAD-v6.2.1-CoreML ; SileroVADKit — https://github.com/polRk/SileroVADKit
- libfvad (WebRTC VAD) — https://github.com/dpirch/libfvad
