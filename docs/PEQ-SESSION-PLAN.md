# Plan sesji pomiarowej — brakujące pola equalizera

Cel: domknąć trzy niewiadome w bloku współczynników `PEQ_REALTIME`. Wszystko inne
jest już potwierdzone (patrz [PROTOCOL.md](PROTOCOL.md)).

## Przygotowanie

1. Zainstaluj ponownie profil Bluetooth: na iPhonie
   **developer.apple.com/bug-reporting/profiles-and-logs** → Bluetooth → Zainstaluj
   → **zrestartuj telefon**
2. Podłącz iPhone kablem, odblokuj
3. **Zatrzymaj muzykę** — bez tego log puchnie kilkanaście razy
4. PacketLogger → **File → New iOS Trace** → wybierz telefon → Record
5. W oficjalnej aplikacji Marshalla wejdź w equalizer, slot 2, preset **Custom**

**Zapisz nagranie jako `.pklg`, nie jako tekst.** Eksport tekstowy przycina duże
pakiety do kilkunastu bajtów i właśnie przez to poprzednia sesja nie wystarczyła.

## Nie musisz nic notować

Każdy pakiet ze współczynnikami jest poprzedzony pakietem z definicjami pasm,
który zawiera dokładne wartości wszystkich pięciu suwaków. Prawda o tym, co było
ustawione, jest w samym nagraniu.

## Przebieg

Po każdej zmianie **odczekaj 3 sekundy**, żeby pakiety się rozdzieliły.

### Część 1 — bajty 3 i 7 (najważniejsza)

Wszystkie pasma na zero. Potem **tylko pasmo 1 kHz**, po kolei:

```
-6.0   -5.0   -4.0   -3.0   -2.0   -1.0   0.0   +1.0   +2.0   +3.0   +4.0   +5.0   +6.0
```

Trzynaście punktów przy znanych `a1` i `a2` wystarczy, żeby dopasować, czym są
pozostałe dwa bajty.

### Część 2 — pierwsza połówka gniazda

Wszystkie na zero. Potem, z **pięciosekundowymi** przerwami:

```
160 Hz na +6.0   →   160 Hz na -6.0   →   160 Hz na 0.0
```

Długie przerwy pozwolą sprawdzić, czy pierwsza połówka zależy od stanu poprzedniego.

### Część 3 — nagłówek i ogon elementu

Ustaw wszystkie pasma na **różne** wartości:

```
160 Hz  +6.0
400 Hz  +3.0
1 kHz    0.0
2.5 kHz -3.0
6.25 kHz -6.0
```

Jeśli nagłówek albo ogon się zmieni, znaczy że zależą od konfiguracji.

### Część 4 — sprawdzian

Jedna konfiguracja z remisami, do weryfikacji reguły sortowania:

```
160 Hz  +3.0
400 Hz  +3.0
1 kHz   -3.0
2.5 kHz -3.0
6.25 kHz 0.0
```

## Po nagraniu

Stop, zapisz `.pklg` do `~/Downloads`, potem:

```
python3 analyse-peq.py ~/Downloads/nagranie.pklg
```

Skrypt sparuje komendy, zweryfikuje `a1`/`a2` i wypisze układ gniazd oraz
zawartość nieznanych pól przy każdym ustawieniu.

Profil możesz usunąć zaraz po sesji.
