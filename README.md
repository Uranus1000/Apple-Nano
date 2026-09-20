# Apple Nano

Невеликий нативний інструмент командного рядка для створення й запуску **справжньої macOS Tahoe** у віртуальній машині. Він використовує публічний фреймворк Apple `Virtualization`, а не емулятор або модифікований образ macOS.

## Вимоги

- Apple Silicon Mac із версією macOS, що підтримує гостьову macOS Tahoe;
- Xcode Command Line Tools або Xcode 15+;
- офіційний файл відновлення macOS Tahoe (`.ipsw`), отриманий від Apple;
- щонайменше 64 ГБ вільного простору для типової ВМ.

> **Важливо:** ліцензія Apple дозволяє віртуалізувати macOS лише на обладнанні Apple. Проєкт навмисно не містить обхідних механізмів для запуску macOS на звичайному ПК.

## Збірка

```bash
swift build -c release
```

Виконуваний файл буде у `.build/release/apple-nano`.

## Створення та інсталяція Tahoe

1. Завантажте сумісний офіційний Tahoe restore image (`Tahoe.ipsw`) через Apple / Xcode.
2. Створіть сховище ВМ (типово створюється розріджений диск на 64 ГБ):

   ```bash
   .build/release/apple-nano prepare \
     --restore-image ~/Downloads/Tahoe.ipsw \
     --vm-directory ~/VMs/Tahoe \
     --disk-gb 80
   ```

3. Встановіть macOS у створену ВМ:

   ```bash
   .build/release/apple-nano install \
     --restore-image ~/Downloads/Tahoe.ipsw \
     --vm-directory ~/VMs/Tahoe
   ```

4. Запустіть її. Відкриється нативне вікно з екраном macOS:

   ```bash
   .build/release/apple-nano run --vm-directory ~/VMs/Tahoe
   ```

## Дані ВМ

Каталог ВМ містить `disk.img`, `auxiliary-storage` і `machine.json`. Не змінюйте та не видаляйте `machine.json` або `auxiliary-storage`: вони зберігають ідентичність та модель віртуального Mac, необхідні для наступних завантажень. Файли образів і локальні ВМ виключені з Git через `.gitignore`.
