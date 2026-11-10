// Утримання екрана або кнопки BOOT: POST /start. Відпускання: POST /stop.
// Пароль Wi-Fi додає вікно Voice і записує його лише на час прошивки.

#include <WiFi.h>
#include <HTTPClient.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ILI9341.h>
#include "secrets.h"

const char* WIFI_SSID = WIFI_SSID_SECRET;
const char* WIFI_PASSWORD = WIFI_PASSWORD_SECRET;
const char* VOICE_HOST = VOICE_HOST_SECRET;
const uint16_t VOICE_PORT = 8765;

// ESP32-2432S028, екран на платі.
const int TFT_MOSI = 13;
const int TFT_MISO = 12;
const int TFT_SCLK = 14;
const int TFT_CS = 15;
const int TFT_DC = 2;
const int TFT_RST = -1;
const int TFT_BL = 21;
const int BUTTON_PIN = 0;
const int TOUCH_CLK = 25;
const int TOUCH_MISO = 39;
const int TOUCH_MOSI = 32;
const int TOUCH_CS = 33;
const int TOUCH_IRQ = 36;
const int PADDING = 12;
const int SCREEN_W = 240;
const int SCREEN_H = 320;

SPIClass tftSpi(HSPI);
Adafruit_ILI9341 tft(&tftSpi, TFT_DC, TFT_CS, TFT_RST);
GFXcanvas1 textCanvas(240, 96);

enum ScreenState { Ready, Listening, Processing, Sent };
ScreenState screen = Ready;
bool held = false;
unsigned long sentAt = 0;
int touchX = 0;
int touchY = 0;
int touchZ = 0;
int touchZ1 = 0;
int touchZ2 = 0;
int idleX = 0;
int idleY = 0;
int idleZ = 40;

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(TFT_BL, OUTPUT);
  digitalWrite(TFT_BL, HIGH);
  pinMode(TOUCH_CS, OUTPUT);
  pinMode(TOUCH_CLK, OUTPUT);
  pinMode(TOUCH_MOSI, OUTPUT);
  pinMode(TOUCH_MISO, INPUT);
  pinMode(TOUCH_IRQ, INPUT);
  digitalWrite(TOUCH_CS, HIGH);
  digitalWrite(TOUCH_CLK, LOW);
  digitalWrite(TOUCH_MOSI, LOW);
  delay(20);
  measureIdle();

  // SS = -1: апаратний CS інакше рве команду на кожному байті, і вікно лишається 240×240.
  tftSpi.begin(TFT_SCLK, TFT_MISO, TFT_MOSI, -1);
  tft.begin(27000000);
  tft.setRotation(1);
  panelFill(ILI9341_RED);
  delay(200);
  draw(Ready);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.printf("WiFi %s\n", WIFI_SSID);
  unsigned long started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < 15000) {
    delay(100);
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("IP ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("WiFi failed");
  }
  draw(Ready);
}

void loop() {
  if (screen == Sent && millis() - sentAt > 900) {
    draw(Ready);
  }

  static int confirm = 0;
  bool raw = digitalRead(BUTTON_PIN) == LOW || screenTouched();
  if (raw) {
    if (confirm < 4) {
      confirm++;
    }
  } else if (confirm > 0) {
    confirm--;
  }
  bool down = confirm >= 4;

  static unsigned long lastTouchLog = 0;
  if (millis() - lastTouchLog > 300) {
    lastTouchLog = millis();
    Serial.printf("touch x=%d y=%d z=%d z1=%d z2=%d irq=%d raw=%d down=%d\n", touchX, touchY, touchZ, touchZ1, touchZ2, digitalRead(TOUCH_IRQ), raw, down);
  }

  if (down && !held && screen == Ready) {
    held = true;
    if (postPath("/start")) {
      draw(Listening);
    }
  } else if (!down && held) {
    held = false;
    if (screen == Listening) {
      draw(Processing);
      postPath("/stop");
      draw(Sent);
      sentAt = millis();
    }
  }
}

void touchWrite(uint8_t command) {
  for (int bit = 7; bit >= 0; bit--) {
    digitalWrite(TOUCH_MOSI, (command >> bit) & 1);
    digitalWrite(TOUCH_CLK, LOW);
    delayMicroseconds(2);
    digitalWrite(TOUCH_CLK, HIGH);
    delayMicroseconds(2);
  }
  digitalWrite(TOUCH_MOSI, LOW);
  digitalWrite(TOUCH_CLK, LOW);
}

int touchReadChannel(uint8_t command) {
  touchWrite(command);
  int result = 0;
  for (int bit = 15; bit >= 0; bit--) {
    digitalWrite(TOUCH_CLK, HIGH);
    delayMicroseconds(2);
    digitalWrite(TOUCH_CLK, LOW);
    delayMicroseconds(2);
    result |= digitalRead(TOUCH_MISO) << bit;
  }
  return result >> 4;
}

void readTouch() {
  digitalWrite(TOUCH_CS, LOW);
  int z1 = touchReadChannel(0xB1);
  int z2 = touchReadChannel(0xC1);
  int x = touchReadChannel(0x91);
  int y = touchReadChannel(0xD1);
  digitalWrite(TOUCH_CS, HIGH);
  int z = z1 + 4095 - z2;
  if (z < 0) {
    z = 0;
  }
  touchX = x;
  touchY = y;
  touchZ = z;
  touchZ1 = z1;
  touchZ2 = z2;
}

int medianOf(int *values) {
  for (int i = 1; i < 5; i++) {
    int key = values[i];
    int j = i - 1;
    while (j >= 0 && values[j] > key) {
      values[j + 1] = values[j];
      j--;
    }
    values[j + 1] = key;
  }
  return values[2];
}

void measureIdle() {
  int xs[5];
  int ys[5];
  int zmax = 0;
  for (int i = 0; i < 5; i++) {
    readTouch();
    xs[i] = touchX;
    ys[i] = touchY;
    if (touchZ > zmax) {
      zmax = touchZ;
    }
    delay(2);
  }
  idleX = medianOf(xs);
  idleY = medianOf(ys);
  idleZ = zmax;
  Serial.printf("idle x=%d y=%d z=%d\n", idleX, idleY, idleZ);
}

bool screenTouched() {
  int xs[5];
  int ys[5];
  int zs[5];
  for (int i = 0; i < 5; i++) {
    readTouch();
    xs[i] = touchX;
    ys[i] = touchY;
    zs[i] = touchZ;
  }
  int z = medianOf(zs);
  if (z > idleZ + 12) {
    touchZ = z;
    return true;
  }
  int xmin = xs[0];
  int xmax = xs[0];
  int ymin = ys[0];
  int ymax = ys[0];
  for (int i = 1; i < 5; i++) {
    if (xs[i] < xmin) xmin = xs[i];
    if (xs[i] > xmax) xmax = xs[i];
    if (ys[i] < ymin) ymin = ys[i];
    if (ys[i] > ymax) ymax = ys[i];
  }
  int x = medianOf(xs);
  int y = medianOf(ys);
  touchX = x;
  touchY = y;
  touchZ = z;
  // Краї дають слабкий тиск, але обидві осі лишаються в робочому діапазоні
  // і не стрибають, на відміну від відпущеного скла.
  if (xmax - xmin > 350 || ymax - ymin > 350) {
    return false;
  }
  if (x <= 180 || x >= 3920 || y <= 180 || y >= 3920) {
    return false;
  }
  int dx = x - idleX;
  int dy = y - idleY;
  if (dx < 0) {
    dx = -dx;
  }
  if (dy < 0) {
    dy = -dy;
  }
  return dx > 120 || dy > 120;
}

void panelWriteBytes(const uint8_t *data, int count) {
  for (int i = 0; i < count; i++) {
    tftSpi.transfer(data[i]);
  }
}

void panelCommand(uint8_t cmd, const uint8_t *data, int count) {
  digitalWrite(TFT_CS, LOW);
  digitalWrite(TFT_DC, LOW);
  tftSpi.transfer(cmd);
  if (count > 0) {
    digitalWrite(TFT_DC, HIGH);
    panelWriteBytes(data, count);
  }
  digitalWrite(TFT_CS, HIGH);
}

void panelWriteFrame(uint8_t madctl, int width, int height, uint16_t color) {
  tftSpi.beginTransaction(SPISettings(10000000, MSBFIRST, SPI_MODE0));
  panelCommand(0x36, &madctl, 1);
  uint8_t caset[] = {
    0x00, 0x00, (uint8_t)((width - 1) >> 8), (uint8_t)((width - 1) & 0xFF)
  };
  uint8_t paset[] = {
    0x00, 0x00, (uint8_t)((height - 1) >> 8), (uint8_t)((height - 1) & 0xFF)
  };
  // Довга сторона скла — вісь Y. Її кінець має бути 319, інакше справа лишається шум.
  panelCommand(0x2A, caset, 4);
  panelCommand(0x2B, paset, 4);
  digitalWrite(TFT_CS, LOW);
  digitalWrite(TFT_DC, LOW);
  tftSpi.transfer(0x2C);
  digitalWrite(TFT_DC, HIGH);
  uint8_t hi = color >> 8;
  uint8_t lo = color & 0xFF;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      tftSpi.transfer(hi);
      tftSpi.transfer(lo);
    }
    yield();
  }
  digitalWrite(TFT_CS, HIGH);
  tftSpi.endTransaction();
}

void panelFillRect(int x, int y, int w, int h, uint16_t color) {
  if (w <= 0 || h <= 0) {
    return;
  }
  if (x < 0) {
    w += x;
    x = 0;
  }
  if (y < 0) {
    h += y;
    y = 0;
  }
  if (x + w > SCREEN_W) {
    w = SCREEN_W - x;
  }
  if (y + h > SCREEN_H) {
    h = SCREEN_H - y;
  }
  if (w <= 0 || h <= 0) {
    return;
  }
  int x2 = x + w - 1;
  int y2 = y + h - 1;
  uint8_t caset[] = {(uint8_t)(x >> 8), (uint8_t)x, (uint8_t)(x2 >> 8), (uint8_t)x2};
  uint8_t paset[] = {(uint8_t)(y >> 8), (uint8_t)y, (uint8_t)(y2 >> 8), (uint8_t)y2};
  tftSpi.beginTransaction(SPISettings(10000000, MSBFIRST, SPI_MODE0));
  panelCommand(0x2A, caset, 4);
  panelCommand(0x2B, paset, 4);
  digitalWrite(TFT_CS, LOW);
  digitalWrite(TFT_DC, LOW);
  tftSpi.transfer(0x2C);
  digitalWrite(TFT_DC, HIGH);
  uint8_t hi = color >> 8;
  uint8_t lo = color & 0xFF;
  for (int i = 0; i < w * h; i++) {
    tftSpi.transfer(hi);
    tftSpi.transfer(lo);
  }
  digitalWrite(TFT_CS, HIGH);
  tftSpi.endTransaction();
}

void panelFill(uint16_t color) {
  // 0x28 лишає текст горизонтальним, а рядки 0..319 лягають на ширину скла.
  panelWriteFrame(0x28, SCREEN_W, SCREEN_H, color);
}

bool postPath(const char* path) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("no wifi");
    return false;
  }
  HTTPClient http;
  String url = String("http://") + VOICE_HOST + ":" + String(VOICE_PORT) + path;
  Serial.println(url);
  http.setTimeout(4000);
  if (!http.begin(url)) {
    return false;
  }
  int code = http.POST("");
  http.end();
  Serial.printf("%s %d\n", path, code);
  return code == 200;
}

void draw(ScreenState next) {
  screen = next;
  uint16_t background = 0x1082;
  uint16_t ink = ILI9341_WHITE;
  const char* top = "HOLD";
  const char* bottom = "TO TALK";
  if (next == Listening) {
    background = ILI9341_RED;
    top = "LISTENING";
    bottom = "";
  } else if (next == Processing) {
    background = ILI9341_YELLOW;
    ink = ILI9341_BLACK;
    top = "PROCESSING";
    bottom = "";
  } else if (next == Sent) {
    background = ILI9341_GREEN;
    top = "SENT";
    bottom = "";
  }

  panelFill(background);
  int alongLimit = SCREEN_H - PADDING * 2;
  int topSize = fittedSize(top, alongLimit, 4);
  int bottomSize = bottom[0] == '\0' ? 0 : fittedSize(bottom, alongLimit, 4);
  drawRotatedCentered(top, bottom, topSize, bottomSize, ink);
}

int fittedSize(const char* text, int maxWidth, int preferred) {
  int size = preferred;
  while (size > 1 && int(strlen(text)) * 6 * size > maxWidth) {
    size -= 1;
  }
  return size;
}

void drawRotatedCentered(const char* top, const char* bottom, int topSize, int bottomSize, uint16_t ink) {
  textCanvas.fillScreen(0);
  textCanvas.setTextWrap(false);
  textCanvas.setTextColor(1);

  int16_t topX = 0;
  int16_t topY = 0;
  uint16_t topW = 0;
  uint16_t topH = 0;
  int16_t bottomX = 0;
  int16_t bottomY = 0;
  uint16_t bottomW = 0;
  uint16_t bottomH = 0;
  textCanvas.setTextSize(topSize);
  textCanvas.getTextBounds(top, 0, 0, &topX, &topY, &topW, &topH);
  if (bottom[0] != '\0') {
    textCanvas.setTextSize(bottomSize);
    textCanvas.getTextBounds(bottom, 0, 0, &bottomX, &bottomY, &bottomW, &bottomH);
  }

  int gap = bottom[0] == '\0' ? 0 : 12;
  int blockW = topW > bottomW ? topW : bottomW;
  int blockH = (int)topH + gap + (int)bottomH;
  if (blockW > textCanvas.width()) {
    blockW = textCanvas.width();
  }
  if (blockH > textCanvas.height()) {
    blockH = textCanvas.height();
  }

  textCanvas.setTextSize(topSize);
  textCanvas.setCursor((blockW - (int)topW) / 2 - topX, -topY);
  textCanvas.print(top);
  if (bottom[0] != '\0') {
    textCanvas.setTextSize(bottomSize);
    textCanvas.setCursor((blockW - (int)bottomW) / 2 - bottomX, (int)topH + gap - bottomY);
    textCanvas.print(bottom);
  }

  // 90° за годинниковою: ширина тексту стає висотою екрана.
  int drawnW = blockH;
  int drawnH = blockW;
  int originX = (SCREEN_W - drawnW) / 2;
  int originY = (SCREEN_H - drawnH) / 2;
  if (originX < PADDING) {
    originX = PADDING;
  }
  if (originY < PADDING) {
    originY = PADDING;
  }

  for (int row = 0; row < blockW; row++) {
    int runStart = -1;
    int runEnd = -1;
    for (int col = 0; col <= blockH; col++) {
      bool on = col < blockH && textCanvas.getPixel(row, col);
      int destX = on ? blockH - 1 - col : -1;
      if (on && runStart < 0) {
        runStart = destX;
        runEnd = destX;
      } else if (on) {
        if (destX < runStart) {
          runStart = destX;
        }
        if (destX > runEnd) {
          runEnd = destX;
        }
      }
      if (!on && runStart >= 0) {
        panelFillRect(originX + runStart, originY + row, runEnd - runStart + 1, 1, ink);
        runStart = -1;
      }
    }
  }
}
