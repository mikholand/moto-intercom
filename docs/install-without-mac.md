# Установка AudioSpike на iPhone без Mac

Схема: GitHub Actions собирает неподписанный `AudioSpike.ipa`, а Sideloadly на Windows подписывает его бесплатным Apple ID и ставит на iPhone по USB.

## Ограничения бесплатной подписи

- Приложение работает **7 дней**, потом его нужно переустановить тем же способом. Журналы в приложении при переустановке поверх сохраняются.
- Не больше 3 таких приложений на устройстве одновременно.
- Пароль Apple ID вводится в стороннюю программу. **Используйте отдельный, второстепенный Apple ID**, а не основной.

## Один раз: подготовка

1. Установите Sideloadly с официального сайта: https://sideloadly.io
2. Если Sideloadly не видит iPhone, поставьте iTunes с сайта Apple (не из Microsoft Store).
3. Подключите iPhone кабелем и нажмите «Доверять этому компьютеру».
4. На iPhone включите режим разработчика: **Настройки → Конфиденциальность и безопасность → Режим разработчика**, затем перезагрузка и подтверждение. Пункт может появиться только после первой установки через Sideloadly.

## Каждый раз: сборка и установка

1. Сборка запускается сама при push в `ios/AudioSpike/`. Вручную: GitHub → Actions → «AudioSpike iOS build» → Run workflow.

   ```bash
   gh workflow run audiospike.yml -R mikholand/moto-intercom
   ```

2. Скачайте IPA последней успешной сборки (`-R` позволяет запускать из любой папки):

   ```bash
   gh run download -R mikholand/moto-intercom --name AudioSpike-ipa --dir build-ipa
   ```

   Или вручную: страница запуска в Actions → Artifacts → `AudioSpike-ipa` (zip, внутри `AudioSpike.ipa`).
3. В Sideloadly: выберите iPhone, перетащите `AudioSpike.ipa`, введите Apple ID, нажмите **Start**.
4. При первой установке на iPhone: **Настройки → Основные → VPN и управление устройством** → профиль вашего Apple ID → «Доверять».
5. Запустите AudioSpike и разрешите доступ к микрофону.

## Журналы с iPhone

- В приложении: «Экспорт журнала (JSONL)», затем AirDrop, почта или «Сохранить в Файлы».
- Или через iTunes на Windows: iPhone → Общий доступ к файлам → AudioSpike → папка `logs`.

## Если сборка упала

Ошибки компиляции видны в шаге «Build (unsigned)», полный лог лежит в артефакте `build-log`.

```bash
gh run view -R mikholand/moto-intercom --log-failed
```
