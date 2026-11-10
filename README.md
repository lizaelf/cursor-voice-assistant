# Voice Cursor Controller — крок 1

Окрема програма **Voice**. Вона сама просить мікрофон і доступ до клавіші Command+D. Cursor у ці списки додавати не потрібно.

**Command+D** виводить Cursor наперед і починає запис. Повторне **Command+D** зупиняє запис, розпізнає українську через `whisper.cpp` і вставляє текст у чат Cursor.

ESP32 у тій самій Wi-Fi мережі керує записом через `POST /start` і `POST /stop` на порту **8765**. Адреса з’являється в консолі і в меню **V**. Розпізнавання лишається тим самим.

## Що встановити

Потрібні Homebrew, Python 3.13 і доступ до мікрофона.

```bash
brew install portaudio
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### whisper.cpp

Якщо Homebrew ставить готовий `whisper-cli`:

```bash
brew install whisper-cpp
```

На macOS 12 готової пляшки немає, і формула тягне важкі залежності. Тоді зберіть CLI локально (потрібні CMake і Command Line Tools):

```bash
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git third_party/whisper.cpp
cmake -S third_party/whisper.cpp -B third_party/whisper.cpp/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=Apple \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build third_party/whisper.cpp/build -j --target whisper-cli
```

На цьому Intel Mac Metal і OpenMP вимкнені, рахунок іде на Accelerate. Так збірка проходить на macOS 12 без окремих пляшок Homebrew.

Програма шукає бінарник так: змінна `WHISPER_CLI`, далі `whisper-cli` у `PATH`, далі `third_party/whisper.cpp/build/bin/whisper-cli`.

### Модель

`ggml-small` (~466 МБ) — баланс якості української і швидкості на Intel.

```bash
mkdir -p models
curl -fL --retry 3 -o models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

## Запуск

Зібрати програму і відкрити її:

```bash
macos/build.sh
open dist/Voice.app
```

1. macOS запитає **мікрофон** для Voice. Дозволь його цій програмі.
2. У вікні **Захист і безпека → Конфіденційність → Доступність** увімкни **Voice**. Cursor у цьому списку не потрібен.
3. Натисни **Command+D** (⌘D), говори, натисни **Command+D** ще раз.
4. Текст з’явиться в чаті Cursor.

Сполучення слухає сама програма Voice, навіть коли попереду вікно Cursor.

Перевірочні фрази:

- «Подивись на цей компонент і зроби картку менш перевантаженою».
- «Перевір адаптивність цього екрану на маленьких розмірах».
- «Знайди де тут використовується цей API».

Мова розпізнавання — українська (`-l uk`). Стартовий prompt теж українською: «Українською мовою.»

## ESP32

Прошивка: `esp32/voice_button/voice_button.ino`. На початку файлу впиши Wi-Fi і адресу Mac з меню **V**. Кнопка на GPIO 27 замикається на землю: утримання надсилає `POST /start`, відпускання — `POST /stop`.

Перевірка без плати:

```bash
curl -s -X POST http://127.0.0.1:8765/stop
curl -s -X POST http://127.0.0.1:8765/start
curl -s -X POST http://127.0.0.1:8765/start
curl -s -X POST http://127.0.0.1:8765/stop
```

Повторний `/start` не починає другий запис. `/stop` без запису відповідає і не зупиняє програму.

Автоматичні перевірки цих правил, української мови і вставки в чат:

```bash
macos/test.sh
```

## Якщо щось не так

- `Не вдалося почати запис` — дозволь мікрофон для **Voice** у Захист і безпека → Конфіденційність → Мікрофон.
- Клавіша не реагує — у списку Доступність має бути **Voice**, не Cursor. Після ввімкнення зачекай секунду, програма підхопить дозвіл сама.
- `Не знайдено whisper-cli` або `Немає моделі` — виконайте кроки збірки та завантаження вище.
