# marshall-recon

Narzędzie rozpoznawcze do sluchawek **Marshall Major V** (kryptonim wewnetrzny `plant`)
i innych urzadzen Zounda na tym samym protokole GATT.

Cel: ustalic **ktora charakterystyka BLE odpowiada ktorej funkcji** i **jaki ma format
danych** — zanim napiszemy wlasciwa aplikacje.

---

## Co juz wiadomo (z binarki aplikacji Marshall 3.8.6)

| | |
|---|---|
| Transport | czysty BLE GATT (CoreBluetooth). **Nie** MFi/iAP2 dla sterowania. |
| Serwis | `DEAD0001-1337-1DEA-FEED-C0FFEE70C0DE` |
| Charakterystyki | `000000NN-1337-1dea-feed-c0ffee70c0de`, 36 znanych identyfikatorow |
| Autoryzacja | **brak** — zadnego challenge/response, klucza parowania ani szyfrowania warstwy aplikacyjnej |

Pelna lista tego, co wyciagnieto z binarki:

```
./mr reference
```

**Czego brakuje:** przypisania `nazwa charakterystyki -> konkretny UUID`. Enum nazw
jest pewny (z metadanych refleksji Swifta), pula UUID-ow jest pewna (literaly w kodzie),
ale switch laczacy jedno z drugim siedzi w stripped Swiftcie. **To wypelniasz empirycznie —
o tym jest cala reszta tego pliku.**

---

## Budowanie

```bash
./build.sh          # buduje i pakuje w marshall-recon.app
./mr help
```

Zero zaleznosci zewnetrznych — buduje sie offline.

### Uprawnienie Bluetooth

macOS przyznaje dostep do Bluetooth **tylko aplikacjom z bundlem i kluczem
`NSBluetoothAlwaysUsageDescription` w Info.plist**. Dlatego `build.sh` pakuje binarke
w `marshall-recon.app` — samo `swift run` **nie zadziala**, proces zostanie ubity
przez system (SIGABRT) bez zadnego komunikatu.

Przy pierwszym uruchomieniu macOS zapyta o zgode. Jesli program ginie po cichu:

1. Ustawienia systemowe → Prywatnosc i ochrona → **Bluetooth** → dodaj/wlacz `marshall-recon`
2. Podpis jest ad-hoc, wiec **po kazdej przebudowie system moze zapytac ponownie** — to normalne
3. Sprawdz, czy proces w ogole widzi swoj bundel: `./mr env`

---

## Metodologia: jak ustalic co jest czym

### Krok 0 — przygotuj urzadzenie

**Parowanie sluchawek z macOS nie jest potrzebne.** BLE to osobna warstwa niz
klasyczne parowanie audio — laczymy sie bezposrednio z ich serwisem GATT.

Wystarczy:

1. **wlacz sluchawki**,
2. **wylacz Bluetooth w iPhonie** (albo przynajmniej ubij aplikacje Marshall).

Punkt 2 jest istotny: sluchawki utrzymuja jedno polaczenie BLE i zajete potrafia
przestac sie rozglaszac.

Jesli mimo to nie widac ich w skanie — wprowadz je w **tryb parowania**
(podwojne nacisniecie pokretla, LED wolno pulsuje na niebiesko). Wtedy rozglaszaja
sie na pewno.

> Jesli sluchawki sa juz sparowane z Makiem jako urzadzenie audio i wlasnie
> polaczone, **nie pojawia sie w skanie** — polaczone urzadzenia przestaja sie
> rozglaszac. Narzedzie pobiera je osobno przez `retrieveConnectedPeripherals`
> i wypisuje w sekcji „Polaczone z systemem". Dziala to tak samo dobrze.

### Krok 1 — znajdz sluchawki

```bash
./mr scan --seconds 10
```

Szukasz wpisu z `Major` / `Marshall` w nazwie. Zanotuj identyfikator — dalej mozesz
uzywac `--id <UUID>` zamiast zgadywania po nazwie.

### Krok 2 — pelny zrzut

```bash
./mr dump --out 00-baza.json --note "stan wyjsciowy"
```

Dostajesz kazdy serwis, kazda charakterystyke, jej flagi (`read/write/notify`) i wartosc
— w hexie, jako ASCII i zinterpretowana jako `u8` / `u16le` / `u32le`. Wiekszosc tych
charakterystyk to jeden albo dwa bajty, wiec od razu widac, czy to bool, enum, czy minuty.

Juz na tym etapie kilka pozycji rozpoznasz na oko: numer modelu i seryjny beda czytelnym
tekstem, poziom baterii bedzie jednym bajtem 0–100.

### Krok 3 — metoda roznicowa (to jest sedno)

Dla **kazdej** z funkcji, ktore chcesz odtworzyc, robisz ten sam cykl:

```bash
./mr dump --out 01-przed.json --note "interaction sounds WLACZONE"
# -> wlacz Bluetooth w telefonie, w aplikacji Marshall PRZELACZ JEDNO ustawienie,
#    wylacz Bluetooth w telefonie
./mr dump --out 02-po.json    --note "interaction sounds WYLACZONE"

./mr diff 01-przed.json 02-po.json
```

`diff` pokaze dokladnie te charakterystyki, ktorych wartosc sie zmienila. Zwykle bedzie
to jedna. Masz UUID i masz format.

**Zasada: zmieniaj jedna rzecz na raz.** Jak przestawisz dwie, nie bedziesz wiedzial,
ktora zmiana odpowiada ktorej charakterystyce.

Kolejnosc od najlatwiejszych:

| Funkcja | Czego sie spodziewac |
|---|---|
| Interaction sounds (`uiSounds`) | 1 bajt, `00` / `01` |
| Battery preservation | 1 bajt, enum `none/low/medium/max` → prawdopodobnie `00..03` |
| Power off timer (`autoOffTimeSettings`) | minuty jako `u16le` + prawdopodobnie flaga wl/wyl |
| Tryb przycisku M (`actionButtonConfiguration`) | tabela `(buttonIdx, pressType, action)` — najbogatsza, rob ja na koncu |

Przy przycisku M zrob **trzy** zrzuty: EQ, asystent glosowy, Spotify Tap. Trzy warianty
tego samego pola pokaza, ktory bajt jest akcja, a co jest stala rama.

### Krok 4 — test przycisku M (to rozstrzyga sprawe Apple Music)

W protokole jest charakterystyka `actionButtonEvent` z flaga NOTIFY oraz enum typow
nacisniecia: `singlePress, doublePress, triplePress, longPress, singlePressAndHold`.

**Nie wiadomo, czy firmware Major V faktycznie ja wysyla** — enum jest wspolny dla
wszystkich urzadzen Zounda, w tym glosnikow. To jest test:

```bash
./mr watch --for 180
```

Subskrybuje wszystko, co ma NOTIFY, i wypisuje z czasem, co przychodzi. Podczas nasluchu:

1. nacisnij przycisk M **pojedynczo**, odczekaj 3 sekundy
2. nacisnij **dwukrotnie**, odczekaj 3 sekundy
3. **przytrzymaj**, odczekaj 3 sekundy
4. dla porownania pokrec/nacisnij pokretlo (play/pause, glosnosc)

**Jesli po nacisnieciu M cokolwiek przyleci** — droga „przycisk M uruchamia Apple Music"
jest otwarta: wlasna aplikacja iOS subskrybuje ta charakterystyke, dziala w tle
(`UIBackgroundModes: bluetooth-central`, iOS budzi na notyfikacje BLE) i na zdarzeniu
wola `MPMusicPlayerController.systemMusicPlayer.play()`.

**Jesli nic nie przychodzi** — przycisk M jest obslugiwany wylacznie w firmware
i ta droga jest zamknieta. Zostaje ustawienie akcji `playPauseOnly` (patrz `./mr reference`),
co i tak duplikuje pojedyncze nacisniecie pokretla.

### Krok 5 — zapis

Dopiero **gdy wiesz, co jest czym**:

```bash
./mr write 0000001B 01 --i-know-what-im-doing
```

Wypisze wartosc przed i po. Flaga jest wymagana celowo.

> **Uwaga.** Slepy zapis w nieznana charakterystyke moze trafic w punkt kontrolny DFU
> albo ustawienie fabryczne. Nie zapisuj niczego, czego formatu nie potwierdziles
> wczesniej metoda roznicowa.

---

## Alternatywa dla krokow 2–3: PacketLogger

Jesli metoda roznicowa bedzie zbyt zmudna, jest szybsza droga — **PacketLogger**
z pakietu *Additional Tools for Xcode* (darmowy, developer.apple.com).

Instalujesz na iPhonie profil logowania Bluetooth, podlaczasz telefon do Maca,
odpalasz PacketLogger i **oficjalna** aplikacje Marshall, klikasz po kolei kazda funkcje.
Dostajesz pelny ruch GATT z UUID-ami i payloadami — komplet mapowan w jedna sesje,
bez jailbreaka. To jest wlasciwe narzedzie do tego zadania; niniejszy program przydaje sie
potem do weryfikacji i eksperymentow z zapisem.

---

## Struktura kodu

| Plik | Co robi |
|---|---|
| `ZoundProtocol.swift` | Wszystko, co odzyskano z binarki: UUID-y, enumy, listy akcji. Czysta wiedza, zero logiki. |
| `BLEClient.swift` | Warstwa async/await nad CoreBluetooth. **To jedyny plik do przeniesienia na iOS** — API jest identyczne, roznica to Info.plist i tryb pracy w tle. |
| `Snapshot.swift` | Model zrzutu, zapis/odczyt JSON, formatowanie hex i interpretacje liczbowe. |
| `CLI.swift` | Komendy. |

## Poza zakresem

**Aktualizacje firmware.** To osobny stos: protokol GAIA Qualcomma, wlasny protokol
retransmisji RWCP, maszyna stanow DFU i pobieranie z prywatnego bucketa S3
(`zoundapps_gaia_client_core_ios` w oryginalnej aplikacji). Tygodnie pracy i realne
ryzyko zamurowania sprzetu. Zostaw oficjalna aplikacje do aktualizacji; ta moze
najwyzej czytac `firmwareRevision` i pokazac wersje.
