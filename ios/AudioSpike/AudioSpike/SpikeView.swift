import SwiftUI

struct SpikeView: View {
    @StateObject private var controller = SpikeController()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                phasesSection
                RouteSection(controller: controller)
                MeterSection(capture: controller.capture)
                inputSection
                switchSection
                marksSection
                settingsSection
                LogSection(log: controller.log)
            }
            .navigationTitle("AudioSpike")
            .task { await controller.prepare() }
        }
    }

    private var presetSection: some View {
        Section {
            Picker("Пресет", selection: $controller.presetID) {
                ForEach(SessionPreset.all) { preset in
                    Text("\(preset.id) · \(preset.title)").tag(preset.id)
                }
            }
            .disabled(controller.isAutoRunning)
            let preset = controller.preset
            Text(preset.expectation).font(.footnote)
            Text("\(preset.category?.rawValue ?? "—") / \(preset.mode.rawValue)\n\(preset.options.names.joined(separator: ", ")) · VP \(preset.voiceProcessing.rawValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !preset.isAvailable {
                Text("Недоступно на этой версии iOS").foregroundStyle(.red)
            }
        } header: {
            Text("Конфигурация")
        } footer: {
            Text("Перед прогоном запустите музыку в Spotify вручную. Клип: \(controller.clipSource)")
        }
    }

    private var phasesSection: some View {
        Section("Фазы") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Phase.allCases) { phase in
                    Button(phase.title) { controller.run(phase) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(controller.isAutoRunning)
            if controller.isAutoRunning {
                Button("Остановить", role: .destructive) { controller.cancelTask() }
            } else {
                Button("Прогнать фазы 1–6 автоматически") { controller.runAllPhases() }
            }
            Text(controller.status).font(.footnote.monospaced())
        }
    }

    private var inputSection: some View {
        Section("Предпочтительный вход") {
            ForEach(controller.snapshot.availableInputs, id: \.uid) { port in
                Button(port.short) { controller.choosePreferredInput(uid: port.uid) }
            }
            Button("Сбросить (nil)") { controller.choosePreferredInput(uid: nil) }
        }
    }

    private var switchSection: some View {
        Section {
            Picker("Способ", selection: $controller.switchStrategy) {
                ForEach(SwitchStrategy.allCases) { Text($0.title).tag($0) }
            }
            Button("10 циклов, пауза 5 с") { controller.runSwitchCycles() }
                .disabled(controller.isAutoRunning)
            ForEach(controller.switchResults) { result in
                VStack(alignment: .leading) {
                    Text("#\(result.cycle) \(result.direction): \(result.milliseconds.map { String(format: "%.0f мс", $0) } ?? "таймаут/ошибка")")
                    Text(result.route).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button("Проверить bluetoothHighQualityRecording") { controller.checkHighQualityRecording() }
        } header: {
            Text("Переключение A2DP↔HFP (T7b) и T-HQ")
        } footer: {
            Text("Пресет P8, фазы 1–3, музыка играет. Паузы и щелчки отмечайте кнопками ниже.")
        }
    }

    private var marksSection: some View {
        Section("Отметки слушателя (L3)") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(["Щелчок", "Пауза музыки", "Телефонный звук", "Музыка тише",
                         "Стерео пропало", "Звук восстановился"], id: \.self) { text in
                    Button(text) { controller.mark(text) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                TextField("Своя отметка", text: $note)
                Button("Записать") {
                    controller.mark(note)
                    note = ""
                }
                .disabled(note.isEmpty)
            }
        }
    }

    private var settingsSection: some View {
        Section("Поведение") {
            Toggle("Восстанавливать после прерывания", isOn: $controller.autoResume)
            Toggle("Перезапускать вход при смене конфигурации", isOn: $controller.autoRestartEngine)
            Toggle("prefersNoInterruptionsFromSystemAlerts", isOn: $controller.noSystemAlertInterruptions)
        }
    }
}

private struct RouteSection: View {
    @ObservedObject var controller: SpikeController

    var body: some View {
        let s = controller.snapshot
        Section("Маршрут (L1)") {
            Text(s.routeSummary).font(.callout.monospaced())
            Text(s.formatSummary).font(.caption.monospaced())
            Text("active: \(controller.isSessionActive ? "да" : "нет") · otherAudio: \(s.isOtherAudioPlaying ? "да" : "нет") · silenceHint: \(s.secondaryAudioShouldBeSilencedHint ? "да" : "нет")")
                .font(.caption.monospaced())
            Text("\(s.category) / \(s.mode)\n\(s.options.joined(separator: ", "))")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeterSection: View {
    @ObservedObject var capture: CaptureEngine

    var body: some View {
        Section("Вход (L2)") {
            let r = capture.reading
            Text(capture.isRunning ? (capture.hasInput ? "Движок: вход + вывод" : "Движок: только вывод") : "Движок остановлен")
            Text(capture.inputFormat).font(.caption.monospaced())
            ProgressView(value: Double(max(0, min(1, (r.rmsDB + 80) / 80))))
            Text(String(format: "RMS %.1f dBFS · пик %.1f · буферов %ld (%ld кадров) · разрывов %ld",
                        r.rmsDB, r.peakDB, r.callbacks, r.lastFrames, r.gaps))
                .font(.caption.monospaced())
        }
    }
}

private struct LogSection: View {
    @ObservedObject var log: DiagnosticsLog

    var body: some View {
        Section {
            ShareLink("Экспорт журнала (JSONL)", item: log.fileURL)
            Button("Начать новый журнал") { log.startNewFile() }
            ForEach(log.recent.suffix(40).reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.time.formatted(date: .omitted, time: .standard)) · \(entry.kind)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(entry.message).font(.caption)
                    if let fields = entry.fields, !fields.isEmpty {
                        Text(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                            .font(.caption2.monospaced())
                    }
                }
            }
        } header: {
            Text("Журнал")
        } footer: {
            Text(log.fileURL.lastPathComponent)
        }
    }
}
