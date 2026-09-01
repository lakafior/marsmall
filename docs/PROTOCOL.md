# Mapowanie protokołu Marshall Major V

Sprzęt: **MAJOR V**, firmware **6.4.9**, hardware **5.0.0**, chip **Airoha AB156x**,
producent `Marshall Group AB`.

Sterowanie: **BLE GATT, serwis `FCCD`**. Odczyt i zapis wymagają **sparowania (bondingu)**
z hostem — bez tego wszystkie odczyty zawodzą. Bonding naprawia też rotację prywatnego
adresu BLE, przez którą identyfikator zmienia się po każdym wyłączeniu słuchawek.

Notyfikacje na `FCCD` **nie działają** — urządzenie odrzuca zapis do CCCD błędem ATT 0x0D
(`invalid attribute value length`) dla wszystkich 12 charakterystyk. Dlatego zamiast
`watch` używamy `poll` (odczyt w pętli + wykrywanie zmian).

---

## POTWIERDZONE pomiarem

Metoda: `./mr poll` z równoległym przełączaniem ustawień w oficjalnej aplikacji.

### `0000000B` — interaction sounds (`uiSounds`)
```
0100 = włączone      0000 = wyłączone
```
Format: `[enabled:u8][?:u8]`

### `0000002F` — battery preservation
```
000403 = max     000402 = medium     000401 = low     000400 = none
        ^^                  ^^               ^^               ^^
```
Format: `[00][04][poziom:u8]`, poziom 0–3. Zgadza się z enumem z binarki
`batteryPreservationNone / Low / Medium / Max`.

### `00000032` — timery wyłączania (`autoOffTimeSettings`)
```
00 02 03 | 00 01 2A30 | 01 02 0708
   ^^         ^^ ^^^^      ^^ ^^^^
   count      id  wartość  id  wartość
```
Dwa wpisy po 4 bajty: `[id:u8][typ:u8][sekundy:u16be]`.
Zmierzone wartości: `2A30`=3 h, `1C20`=2 h, `0708`=30 min, `0BB8`=50 min, `04B0`=20 min.
Wpis `id=00` to timer „connected and paused", `id=01` to „not connected".

### `0000000D` — tryb przycisku M (`actionButtonConfiguration`)

**Odczyt i zapis mają różne formaty.**

Odczyt zwraca 5-bajtowy raport stanu:
```
FF 01 01 00 XX
^^ ^^ ^^ ^^ ^^
|  |  |  |  akcja
|  |  |  selektor (buttonIdx albo pressType — na Major V 0x00 w obu przypadkach)
|  |  numberOfEventTypes = 1
|  numberOfButtons = 1
marker raportu
```

Zapis przyjmuje **2 bajty**: `[selektor][akcja]`. Zapis pełnej ramki 5-bajtowej jest
odrzucany błędem ATT 0x0D (`invalid attribute value length`) — stąd wcześniejsze
nieudane próby.

```
./mr write 0000000D 0012 --i-know-what-im-doing     # akcja 0x12 = playPauseOnly
```

> `numberOfButtons = 1` i `numberOfEventTypes = 1` sugerują, że Major V ma jeden
> konfigurowalny przycisk i jeden typ naciśnięcia — czyli mapowanie podwójnego
> kliknięcia prawdopodobnie nie jest dostępne. Niesprawdzone.

Zmierzone przełączanie w aplikacji:

| Ustawienie w aplikacji | Bajt | Nazwa z binarki |
|---|---|---|
| do nothing | `00` | `noAction` |
| voice assistant | `01` | `defaultVoiceAssistant` |
| equalizer | `08` | `eqSlotsToggle` |
| Spotify Tap | `09` | `spotifyTapGoCommand` |

**Cztery na cztery zgodnie z kolejnością deklaracji enuma z binarki.** To dowodzi,
że indeks w enumie = wartość na drucie, więc pozostałe 20 akcji też znamy:

```
0x00 noAction              0x08 eqSlotsToggle          0x10 adidasRunningStartStopRun
0x01 defaultVoiceAssistant 0x09 spotifyTapGoCommand    0x11 adidasRunningPauseResumeRun
0x02 googleVoiceAssistant  0x0A volumeUp               0x12 playPauseOnly
0x03 equalizerPresetsTogg. 0x0B volumeDown             0x13 skipForwardAnswerEndCall
0x04 playbackOnlyTranspar. 0x0C playAndPauseAnswerEnd  0x14 soundstage
0x05 playbackOnlyNCTransp. 0x0D skipForwardRejectCall  0x15 soundImage
0x06 noiseCancellingTrans. 0x0E skipBack               0x16 strobe
0x07 playbackOnlyNC        0x0F rejectCall             0x17 mute
```

Osobna sprawa: **czy firmware Major V realizuje każdą z nich.** Aplikacja pokazuje
tylko cztery.

**Zmierzone:** firmware **przyjmuje** `playPauseOnly` (0x12) — zapis przechodzi,
a odczyt kontrolny zwraca `ff01010012`. Nie jest odrzucany ani zamieniany na
wartość domyślną. Czy przycisk fizycznie wykonuje wtedy play/pause — do
potwierdzenia testem ręcznym.

### `0000000A` — teraz odtwarzane (`audioNowPlaying`)
Rekordy `[pole:u32be][typ:u16 = 0x006A][długość:u16be][dane UTF-8]`.
Pola: 1 = tytuł, 2 = wykonawca/album, 3 = data, 7 = liczba (czas?).

### `00000007` — głośność
**Potwierdzone.** Wartość rośnie i maleje przy kręceniu pokrętłem głośności.
Jeden bajt.

---

## Nazwy charakterystyk odzyskane z binarki

Aplikacja emituje **po jednej małej funkcji na przypadek enuma**, w kolejności
deklaracji, każda ładująca swój literał UUID. Skanując `__text` po parach
`adrp`/`add` oraz po stałych inline (krótkie UUID-y SIG i legacy `AAxx` są
kodowane jako `mov`/`movk`) odtwarza się cała tablica.

Weryfikacja: **8 zmierzonych par pasuje, 0 niezgodności**. Jedna luka w środku
(indeksy 30–31, `wearSensor*`) nie emituje literału i została wywnioskowana.

| UUID | Nazwa | Na Major V |
|---|---|---|
| `00000003` | rename | |
| `00000007` | volume | tak |
| `00000009` | **audioControl** | tak |
| `0000000A` | audioNowPlaying | tak |
| `0000000B` | uiSounds | tak |
| `0000000C` | actionButtonEvent | tak |
| `0000000D` | actionButtonConfiguration | tak |
| `0000000F` | graphicalEqualizer | |
| `00000013` | ancConfiguration | |
| `00000014` | touchLock | |
| `00000016` | uiLanguage | |
| `00000017` | equalizerSettings | tak |
| `00000018` | equalizerSettingsCustomPreset | |
| `00000019` / `0000001A` | ancConfiguration Transparency / NC | |
| `0000001B` | **audioSource** | tak |
| `0000001C` | partyMode | |
| `0000001D` | ecoCharging | |
| `0000001E` | roomPlacement | |
| `0000001F` | nightMode | |
| `00000025` | toneControl | |
| `0000002F` | batteryPreservation | tak |
| `00000030` | dynamicAudio | |
| `00000032` | autoOffTimeSettings | tak |
| `00000033` | soundStage | |
| `00000034` | **bluetoothConnectionControl** | tak |
| `00000035`–`00000038` | broadcast* (LE Audio) | |
| `0000003A` | ledIntensity | |
| `00000044` | audioFeatureConfig | |
| `00000045` | audioInputConfig | |
| `00000048` | usbConfiguration | |

### Pięć nierozpoznanych — stan końcowy

| UUID | Ustalenie | Jak |
|---|---|---|
| `00000009` | **audioControl** — stan odtwarzania, `01` gra / `00` pauza | zmierzone: pauza przełącza wartość bez żadnych kabli |
| `0000001B` | **audioSource** — aktywne wejście | zmierzone: kabel AUX do Mac mini dał `02` |
| `00000034` | **bluetoothConnectionControl** | nazwa odzyskana, format komend nieznany (write-only) |
| `00000001` | nieznane | brak w binarce aplikacji |
| `00000008` | nieznane, stałe `20` | brak w binarce aplikacji |

#### `audioSource` — wartości

Enum protokołowy z binarki (szerszy niż lista z ekranu odtwarzacza, bo ten sam
protokół obsługuje głośniki i soundbary). **Dwa na dwa zmierzone:**

```
0  bluetoothClassic  ← zmierzone     6  bleAudio
1  wifi                              7  usbc
2  aux               ← zmierzone     8  bleAudioBroadcast
3  rca                               9  eArcHdmi
4  optical                          10  error
5  hdmi
```

#### `audioControl` — wyjątek od reguły

`01` = gra, `00` = pauza. Enum w binarce wymienia stany jako
`playing, paused, stopped, unknown`, co dałoby playing = 0 — pomiar mówi
inaczej. **To jedyne miejsce w tym protokole, gdzie kolejność deklaracji NIE jest
wartością na drucie.** Wszędzie indziej (akcje przycisku, moduły MMI, źródła
audio, poziomy battery preservation) zgadzała się co do jednego.

### `00000001` i `00000008` — nie istnieją w aplikacji

Urządzenie je wystawia, ale **w binarce oficjalnej aplikacji nie ma takich
literałów UUID w ogóle**. Nie ma czego odzyskać i nie ma zachowania odniesienia
do podglądnięcia — aplikacja nawet nie wie, że te charakterystyki istnieją.

---

## Nierozpoznane

| | Flagi | Wartość | Uwagi |
|---|---|---|---|
| `00000001` | r n | `00` | status |
| `2A19` (180F) | r n | `00` | **poziom baterii NIE działa** — patrz niżej |
| `2BED` (180F) | r n | `00c100` | **Battery Level Status (SIG)** — działa, patrz niżej |
| `00000008` | r | `20` | stałe |
| `00000009` | r w n | `01` | przełącznik |
| `0000000C` | **n** | — | **kandydat na `actionButtonEvent`** — nie da się odczytać ani zasubskrybować |
| `00000017` | r w n | `ff020001010002` | rodzina `FF`, jak `0000000D`; nie zmieniło się w teście |
| `0000001B` | r w n | `00` | przełącznik |
| `00000034` | w n | — | punkt kontrolny |

---

## Bateria: przez GATT się nie da

Standardowa charakterystyka **`2A19` w serwisie `180F` zwraca `00`** na iPhonie,
mimo że na Macu zwracała `4f` (79%). Sprawdzone: występuje tylko raz, więc to nie
jest kwestia duplikatów instancji.

Pozostałe kandydatury też odpadają:

- `2BED` = `00c100` — Battery Level Status wg SIG; flagi `00` oznaczają, że pole
  poziomu **nie jest obecne**, struktura niesie tylko stan zasilania
- `2BEA` = `06000015` — zmienne, ale nie procent
- żadna charakterystyka `FCCD` nie zawierała wartości odpowiadającej realnemu
  poziomowi (sprawdzone przy 77% = `0x4D`)

**Potwierdzone ostatecznie:** `2A19` zwraca `00` także po naprawie wyboru
peryferala i na obu wpisach urządzenia (`MAJOR V` i `MAJOR V [LE]`). To wada
firmware, nie błąd po naszej stronie. Ciekawostka: w przechwyconym logu oficjalna
aplikacja **odczytała `4D`** z tej samej charakterystyki — czego nie udało się
powtórzyć.

Różnica Mac kontra iPhone bierze się prawdopodobnie stąd, że przy podłączonym
hoście audio słuchawki raportują baterię kanałem HFP i zostawiają charakterystykę
GATT wyzerowaną. W iOS widać wtedy dwa osobne urządzenia: `MAJOR V` (klasyczne)
i `MAJOR V [LE]`.

**Rozwiązanie: kanał RACE Airohy.**

```
TWS_GET_BATTERY   race_id 0x0CD6
  żądanie:    [agent_or_client: u8]           (0x00 = samo urządzenie)
  odpowiedź:  [status: u8][agent_or_client: u8][procent: u8]
```

Ramkowanie `[0x05][0x5A][len: u16le][race_id: u16le][payload]`, odpowiedź typu
`0x5D`. Kanał: serwis `5052494D-…AirohaBLE`, zapis na `CHAR-.2`, odbiór
na `CHAR-.1` (ta subskrybuje się bez problemu, w przeciwieństwie do wszystkich
charakterystyk `FCCD`).

---

## Formaty zapisu — POTWIERDZONE podsłuchem

Wszystkie poniższe pochodzą z przechwycenia tego, co wysyła oficjalna aplikacja
(PacketLogger). Wcześniejsze zgadywanie „wytnij kawałek ramki odczytu" dało dwa
błędne formaty na pięć — konwencja jest **selektor pola plus wartość**, a jej
kształt różni się między charakterystykami.

| Charakterystyka | Zapis | Uwagi |
|---|---|---|
| `0000000B` interaction sounds | `0100` / `0000` | 2 bajty, jak odczyt |
| `0000002F` battery preservation | `00`…`03` | **1 bajt**, sam poziom (odczyt ma 3) |
| `00000032` timery | `[01][id][typ][sekundy u16be]` | 5 bajtów, selektor `01` |
| `0000000D` przycisk M | `[00][akcja]` | 2 bajty |
| `00000017` equalizer, slot | `[00][slot]` | slot 0-based |
| `00000017` equalizer, preset | `[01][slot][preset]` | 3 bajty |

Przykłady timerów: `0100011C20` = wpis 0, typ 1, 2 h. `01010204B0` = wpis 1,
typ 2, 20 min.

---

## Custom EQ — rozłożony w większości, brakuje dwóch pól

> **Korekta.** Wcześniej zapisano tu, że blok współczynników jest nie do
> rozszyfrowania rozsądnym kosztem. **To była przedwczesna ocena.** Po dokładniejszym
> rozbiorze okazało się, że to zwykłe filtry RBJ w stałym przecinku.

### Komenda `0x0E2B` — definicje pasm (POTWIERDZONE)

Nieudokumentowana, struktura odtworzona z podsłuchu. Payload 193 bajty:

```
[00 × 5]
[01 02][freq ×100][gain ×100][szerokość ×100][Q ×100]   × 5 pasm, i32le
[00 × 90]
[headroom ×100][headroom ×100]                          u32le
```

Pasma: **160 Hz** (Q 0.70), **400 Hz** (Q 0.70), **1 kHz**, **2.5 kHz**,
**6.25 kHz** (Q 1.00). Zakres ±6.00 dB. Szerokość = częstotliwość / Q.

**Headroom** to rzeczywisty szczyt sumarycznej charakterystyki, nie największe
wzmocnienie — sąsiednie pasma się dodają. Odtworzone kaskadą RBJ przy 44.1 kHz:
10 na 10, z czego 7 co do bajtu.

**Zmierzone: sama ta komenda nie zmienia brzmienia.** Potrzebny też blok
współczynników poniżej.

### Komenda `0x0E03` PEQ_REALTIME — blok współczynników

Payload 445 bajtów: `[number_of_element: u16be = 4][algorithm_ver: u16][dane 441 B]`.

**Element = częstotliwość próbkowania.** Wyliczone wstecz ze współczynników
(`a2 → alpha`, `a1 → cos w0`, `fs = 2πf0/w0`):

| element | offset | fs |
|---|---|---|
| 0 | 2 | **44 100 Hz** |
| 1 | 112 | **48 000 Hz** |
| 2 | 222 | **88 200 Hz** |
| 3 | 332 | **96 000 Hz** |

**Element (110 B)** = `[nagłówek 9B] + 5 × [gniazdo 16B]` rozdzielone `ff7f00ff`
+ `[ogon 5B]`. Gniazdo to dwie połówki po 8 bajtów.

**Połówka 8-bajtowa** (POTWIERDZONE, 5 pasm na 5, do piątego miejsca po przecinku):

```
[i16 LE]  a1 w Q14  (×16384, ze znakiem)
[u8]      zawsze 0x00
[u8]      NIEZNANE
[u16 LE]  a2 w Q15  (×32767)
[u8]      zawsze 0x00
[u8]      NIEZNANE
```

To zwykły filtr peaking wg receptury RBJ — ta sama, którą trafiono headroom.

### Układ gniazd (POTWIERDZONE, 29 przechwyceń na 29)

**Pasma są sortowane malejąco po wzmocnieniu**, stabilnie przy remisach.
Podbite pasmo ląduje na gnieździe 0, obcięte na gnieździe 4, płaskie zostają
w naturalnej kolejności pośrodku. To tłumaczy, czemu zmiana jednego pasma
rozrzuca zmiany po całym bloku — pozostałe się przesuwają.

### Co zostało

1. **Bajty 3 i 7** każdej połówki — jedyne niewiadome pola
2. **Pierwsza połówka gniazda** kontra druga — druga niesie bieżące współczynniki;
   pierwsza nie jest ani kopią, ani poprzednim stanem (sprawdzone: 59/140 i 101/145)
3. **Nagłówek 9 B i ogon 5 B** elementu — stałe we wszystkich przechwyceniach
4. Zapis trwały: `UPDATE_NVKEY` (`0x0A0D`, klucz `0xEF00`, 189 B) + `NOTIFY_FWSAVE_PEQNVKEY_FINISHED`
   (`0x09FD`). Aplikacja tego nie wysyła.

Narzędzia: [parse-pklg.py](../tools/parse-pklg.py) czyta surowe nagranie (eksport tekstowy
przycina duże pakiety), [analyse-peq.py](../tools/analyse-peq.py) paruje komendy i rozkłada blok.

---

## Kanał RACE — co działa

Serwis `5052494D-…AirohaBLE`, zapis na `CHAR-.2`, odbiór na `CHAR-.1`
(subskrybuje się bez problemu, w przeciwieństwie do wszystkich charakterystyk `FCCD`).

| Komenda | race_id | Wynik |
|---|---|---|
| `GET_FWVERSION` | `0x1C07` | działa, wymaga `[agent_or_client]` |
| `TWS_GET_BATTERY` | `0x0CD6` | **działa** — `[status][agent][procent]` |
| `GET_CHARGE_INFO` | `0x0009` | działa |
| `FIND_ME` | `0x2C01` | **dźwięk działa**, parametr światła nic nie robi |
| `GET_MMI_ENUM` | `0x0901` | działa — patrz niżej |
| `ENABLE_KEY_EVENT` | `0x1101` | **nie ruszać** — wykonuje akcje MMI, `0x18` wyłącza słuchawki |

### `GET_MMI_ENUM` — moduły

Odpowiedź to `[moduł: u16][status: u8][dane]` — **echo modułu przed statusem**.
Numeracja odzyskana z metadanych refleksji SDK potwierdzona **osiem na osiem**:
każdy zaimplementowany moduł odbił własny numer.

| # | Moduł | Status | Dane |
|---|---|---|---|
| 0 | **PEQGroup** | OK | `01` — aktywny slot korektora |
| 2 | VpLanguage | 0x01 | `00` |
| 3 | VpGet | 0x01 | `ff` |
| 5 | AncStatus | OK | `00000001` |
| 6 | GameMode | OK | `00` |
| 7 | GetPassThruGain | OK | `0000` |
| 10 | AudioPath | OK | `00` |
| 11 | AgentBattery | OK | `01` (stan, nie procent) |

Niezaimplementowane: `VpOnOff`, `VpSet`, `MicSwap`, `ECNREN`, `PartnerBattery`,
`BoxBattery`, `AwsState`, `StopFindMe` — te trzy ostatnie dotyczą słuchawek
dokanałowych (drugi pchełka, etui), więc ich brak jest spójny.

---

## `2BED` — Battery Level Status (SIG)

Działa i przyjmuje powiadomienia (w przeciwieństwie do wszystkich charakterystyk
`FCCD`). Format `[flagi: u8][power state: u16le]`; Major V wysyła flagi `00`,
więc obecny jest tylko power state.

Potwierdzone podłączeniem kabla USB-C:

```
00C100  →  bateria obecna, rozładowuje aktywnie, poziom dobry
00A302  →  bateria obecna, zasilanie przewodowe, ŁADUJE, prąd stały
```

Bity power state wg specyfikacji SIG: 0 obecność baterii, 1–2 zasilanie
przewodowe, 3–4 bezprzewodowe, 5–6 stan ładowania, 7–8 poziom, 9–11 typ ładowania.

Serwis `180F` przyjmuje zapis CCCD, więc `2A19` i `2BED` mogą iść pushem zamiast
odpytywaniem.

---

## Equalizer — podprojekt

Stan wiedzy:

- **Slot 1** = fabryczne brzmienie Marshalla, niezmienne
- **Slot 2** = wybrany tryb: bass boost, mid boost, treble boost, mid reduction, custom
- przycisk M w trybie „equalizer" przełącza między slotami
- aktywny slot: `GET_MMI_ENUM` moduł `0` (PEQGroup) → `01` albo `02`
- przełączanie slotu: `SET_MMI_ENUM` (`0x0900`), moduł `0` — **niesprawdzone**
- `00000017` w `FCCD` = `ff020001010002` — zaczyna się `ff` jak charakterystyka
  przycisku M i ma `02` na drugiej pozycji; mocny kandydat na konfigurację
  dwóch slotów. Do potwierdzenia metodą różnicową.

---

## Przycisk M — stan badania

### Co sprawdzono i z jakim wynikiem

**1. Warstwa Zounda `0000000D` — akcje spoza listy aplikacji.** Firmware **przyjmuje**
zapis dowolnej z 24 wartości (`playPauseOnly` 0x12, `soundstage` 0x14, `mute` 0x17
potwierdzone odczytem kontrolnym), ale przycisk **fizycznie nie reaguje** na żadną
z nich. Realizowane są tylko cztery wystawiane przez aplikację: `noAction`,
`defaultVoiceAssistant`, `eqSlotsToggle`, `spotifyTapGoCommand`. Ślepy zaułek.

**2. Kanał RACE Airohy — działa.** Ramka `[0x05][typ][len:u16le][race_id:u16le][payload]`
potwierdzona. `GET_FWVERSION(agent=0)` zwraca status 0x00. Kanał zapisu i notyfikacji
w pełni sprawny, subskrypcja bez problemu.

**3. `ENABLE_KEY_EVENT` (0x1101) — nazwa myli.** To **nie** jest włączanie raportowania
zdarzeń. Komenda **wykonuje akcję MMI** o podanym numerze. Zmierzone: `key_event_id
= 0x0018` niezawodnie wyłącza słuchawki. Nie przemiatać tego parametru na ślepo.

**4. `GET_MMI_ENUM` / `SET_MMI_ENUM`** to generyczny akcesor stanu (ANC, baterie,
grupy PEQ, język podpowiedzi), nie mapa gestów.

**5. Mapa gest→akcja na poziomie chipu** siedzi w NVKEY-ach (`UPDATE_NVKEY` 0x0A09
i pokrewne). Zapis NVKEY może trwale uszkodzić urządzenie — **zablokowane w narzędziu**,
niezalecane.

**6. `0000000C` — subskrypcja niemożliwa.** Zapis do CCCD odrzucany błędem ATT 0x0D
(`invalid attribute value length`) dla **wszystkich** charakterystyk `FCCD`, podczas gdy
bateria, Fast Pair i Airoha subskrybują się bez problemu na tym samym połączeniu.
Sprawdzono z podłączonym iPhonem i **bez niego** — wynik identyczny, więc to nie jest
konflikt dwóch subskrybentów.

**7. Kanał RACE — też nie.** Przy przycisku ustawionym na `noAction` i włączonym
`ENABLE_FW_NOTIFY(1)` naciśnięcia **nie generują żadnej ramki** na kanale Airohy.
Sprawdzone na iPhonie z działającym kanałem (bateria i sonda modułów odpowiadają
normalnie, więc kanał na pewno żył).

### Wniosek

CoreBluetooth zawsze zapisuje do CCCD 2 bajty i **nie pozwala zapisać deskryptora
ręcznie** (`writeValue(_:for descriptor:)` jawnie tego zabrania dla CCCD). To jedyne
API BLE na iOS — więc **oficjalna aplikacja Marshalla też nie może zasubskrybować tych
charakterystyk**. Jeśli firmware odrzuca 2-bajtowy zapis CCCD, nie zrobi tego żadna
aplikacja na iOS.

**Temat zamknięty.** Dwa niezależne kanały sprawdzone i oba milczą: charakterystyka
`0000000C` odrzuca każdą subskrypcję, a kanał RACE nie wysyła nic przy naciśnięciu.
Słuchawki nie raportują naciśnięć przycisku do hosta. Przycisk M działa wyłącznie
w firmware.

Teoretycznie zostaje iAP2 (Bluetooth Classic, MFi), którego nie da się sprawdzić
z macOS — ale skoro kanał BLE Airohy, z którego korzysta oficjalna aplikacja,
milczy, jest to mało prawdopodobne.
