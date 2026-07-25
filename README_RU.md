# Lid Awake

[English version](README.md)

Lid Awake — утилита для строки меню macOS, которая позволяет MacBook продолжать работу после закрытия крышки.

> **Важно:** не кладите MacBook в сумку, пока Lid Awake включён. Закрытый ноутбук может продолжать работать и нагреваться.

## Возможности

- Включение режима на 15 минут, 1 час или 8 часов.
- Ограничение максимальной длительности работы.
- Работа только при подключённом адаптере питания.
- Автоматическая приостановка при низком заряде батареи.
- Автоматическая приостановка при серьёзном или критическом температурном состоянии macOS.
- Автоматическое возобновление после восстановления безопасных условий, пока таймер не истёк.
- Отображение оставшегося времени, источника питания, заряда и температурного состояния.
- Уведомления при изменении состояния.
- Запуск приложения и фонового агента при входе в macOS.
- Русский и английский интерфейс.
- При первой установке язык выбирается по языку macOS: русский для русской системы, английский для остальных.
- Ручной выбор **Русский** или **English** в меню приложения.
- Диагностика, журнал событий и лог фонового агента.
- Ручная проверка обновлений через GitHub Releases.
- CLI для управления и диагностики.
- Root-helper принимает только команды `on`, `off` и `status`.
- При загрузке macOS и удалении приложения автоматически восстанавливается `disablesleep 0`.

## Требования

- macOS 13 или новее;
- Xcode Command Line Tools;
- учётная запись администратора для установки.

## Установка

```bash
mkdir -p /Users/markkats/Projects
cd /Users/markkats/Projects
git clone https://github.com/bulava92/lid-awake.git
cd lid-awake
zsh ./install.sh
```

Если репозиторий уже клонирован:

```bash
cd /Users/markkats/Projects/lid-awake
git pull
zsh ./install.sh
```

После установки приложение находится здесь:

```text
/Applications/Lid Awake.app
```

## Настройки по умолчанию

- режим закрытой крышки выключен;
- требуется внешнее питание;
- порог батареи — 20%;
- максимальная длительность — 8 часов;
- защита от перегрева включена;
- уведомления включены;
- запуск при входе включён;
- язык выбирается по языку macOS.

## Язык

При первой установке установщик записывает один из двух языков:

- `russian`, если основной язык macOS — русский;
- `english` во всех остальных случаях.

В меню **Язык** доступны только два пункта:

- **Русский**;
- **English**.

Через CLI:

```bash
lid-awake language russian
lid-awake language english
```

## CLI

```bash
lid-awake on
lid-awake on 3600
lid-awake for 900
lid-awake off
lid-awake status
lid-awake settings
lid-awake ac-only on
lid-awake ac-only off
lid-awake battery-limit 20
lid-awake max-duration 28800
lid-awake thermal-protection on
lid-awake thermal-protection off
lid-awake notifications on
lid-awake notifications off
lid-awake launch-at-login on
lid-awake launch-at-login off
lid-awake diagnostics
lid-awake log-path
lid-awake version
```

`lid-awake on` без длительности использует установленную максимальную длительность. Фоновый агент проверяет питание, заряд, температуру и таймер каждые 30 секунд.

## Диагностика и логи

В меню приложения доступны:

- **Открыть диагностику…**;
- **Открыть логи**;
- **Проверить обновления…**.

CLI:

```bash
lid-awake diagnostics
lid-awake log-path
```

Файлы состояния находятся здесь:

```text
~/Library/Application Support/Lid Awake/
~/Library/Logs/Lid Awake/agent.log
```

## Ручная проверка сборки

В репозитории намеренно нет GitHub Actions.

```bash
swift build -c release
swift test
zsh -n install.sh
zsh -n uninstall.sh
zsh -n scripts/lid-awake-helper
zsh -n scripts/notarize-app.sh
```

## Подпись и нотарификация

Сейчас приложение устанавливается без подписи. Поддержка подписи уже заложена.

Сборка и установка с Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" zsh ./install.sh
```

После настройки профиля `notarytool`:

```bash
NOTARY_PROFILE="lid-awake-notary" zsh ./scripts/notarize-app.sh
```

Подробности находятся в [SIGNING.md](SIGNING.md).

## Удаление

```bash
zsh ./uninstall.sh
```

Удаление останавливает агенты, восстанавливает обычный сон и удаляет приложение, бинарники, настройки и логи.

## Лицензия

MIT
