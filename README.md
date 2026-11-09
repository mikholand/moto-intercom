# Moto Intercom (рабочее название)

Голосовой интерком для мотоциклистов через интернет: iPhone + Bluetooth-гарнитура SOARFLY Y12, автоматическая передача голоса по VAD, музыка из сторонних приложений.

**Статус:** этап A (исследование). Код не пишется, пока не согласован план проверки аудиориска.

- [docs/01-feasibility-study.md](docs/01-feasibility-study.md) — реализуемость, ограничения, архитектура, VAD, backend, план этапов.
- [docs/02-audio-spike-protocol.md](docs/02-audio-spike-protocol.md) — протокол проверки Y12 + музыки и форма результатов.

## Структура репозитория (целевая)

```
intercom/
├── README.md
├── docs/
│   ├── 01-feasibility-study.md
│   ├── 02-audio-spike-protocol.md
│   ├── results/                 # заполненные формы и журналы spike (этап C)
│   └── adr/                     # решения: выбор режима A/B/C, LiveKit vs чистый WebRTC
├── ios/
│   ├── AudioSpike/              # этапы B–C: изолированный инструмент проверки аудио
│   └── Intercom/                # этап D+: продукт (создаётся только после решения по этапу C)
├── backend/                     # этап D+: FastAPI (комнаты, токены LiveKit)
├── infra/                       # этап D+: livekit.yaml, docker-compose, reverse proxy
└── tools/
    └── analyze_capture.py       # анализ записей L4: срез спектра, L/R, уровни
```

## Этап B — AudioSpike

Нужен iPhone на iOS 26 (желательно второй iPhone на iOS 18).

**Без Mac:** сборку делает GitHub Actions ([.github/workflows/audiospike.yml](.github/workflows/audiospike.yml)), а установку — Sideloadly с Windows. Пошагово: [docs/install-without-mac.md](docs/install-without-mac.md).

### Сборка на Mac

```bash
brew install xcodegen
```

```bash
cd ios/AudioSpike && xcodegen generate && open AudioSpike.xcodeproj
```

В Xcode: Signing & Capabilities → своя команда (или `DEVELOPMENT_TEAM` в `project.yml`), запуск на реальном iPhone. Симулятор не подходит: в нём нет Bluetooth-маршрутов.

Без XcodeGen: создайте в Xcode пустой iOS App (SwiftUI, iOS 17+), удалите шаблонные файлы, добавьте всё из `ios/AudioSpike/AudioSpike/` и укажите `Info.plist` в Build Settings → Info.plist File, `GENERATE_INFOPLIST_FILE = NO`.

Опционально: положите в `ios/AudioSpike/AudioSpike/` файл `voice_clip.m4a` (5–10 с речи), и он будет играть вместо синтетических тонов в фазе 4.

### Файлы

| Файл | Назначение |
|---|---|
| `ios/AudioSpike/project.yml` | Спецификация XcodeGen: iOS 17+, Swift 5 mode |
| `ios/AudioSpike/AudioSpike/Info.plist` | `NSMicrophoneUsageDescription`, `UIBackgroundModes = [audio]`, доступ к журналам через Finder |
| `.../AudioSpikeApp.swift` | Точка входа |
| `.../SpikeView.swift` | Пресет, фазы 1–6 и автопрогон, маршрут (L1), уровни (L2), выбор входа, циклы A2DP↔HFP, отметки слушателя (L3), журнал и экспорт |
| `.../SpikeController.swift` | Оркестрация фаз, циклов переключения, восстановления после прерываний и сброса, heartbeat раз в 30 с |
| `.../SessionPreset.swift` | Пресеты P0–P10 (category/mode/options/VPIO); совместимость `allowBluetoothHFP` и `bluetoothHighQualityRecording` с разными SDK |
| `.../SessionSnapshot.swift` | Снимок L1: категория, маршрут, порты, частоты, латентности, батарея, нагрев, состояние приложения |
| `.../AudioSessionProbe.swift` | Применение пресета, активация, `setPreferredInput`, замер времени фактической смены маршрута |
| `.../RouteMonitor.swift` | Прерывания, смена маршрута, сброс медиасервисов, silence hint, фон и блокировка, нагрев |
| `.../CaptureEngine.swift` | AVAudioEngine: входной tap (RMS/пик/разрывы), VPIO + ducking/bypass, плеер клипа |
| `.../TestClip.swift` | Сигнал «собеседника»: `voice_clip.*` из бандла или синтетические тоны |
| `.../DiagnosticsLog.swift` | JSONL-журнал без аудио, расшифровка FourCC-кодов ошибок |
| `tools/analyze_capture.py` | Анализ WAV с динамика: граница спектра → CVSD/mSBC/A2DP, Δ уровня к P0, корреляция L/R, паузы |
| `docs/results/TEMPLATE.md` | Форма результатов для каждого прогона |

Анализатор:

```bash
pip install -r tools/requirements.txt
```

```bash
python tools/analyze_capture.py rec/P4_run1.wav --baseline rec/P0_run1.wav
```

Backend, WebRTC и VAD на этом этапе не создаются.
