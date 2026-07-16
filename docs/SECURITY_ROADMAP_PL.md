# Roadmapa bezpieczenstwa

Ten dokument opisuje stan zabezpieczen i dalsze prace. Ma byc szczery: projekt nie powinien deklarowac gwarancji, ktorych jeszcze nie implementuje.

## Zrobione

- Szyfrowanie tresci rozmow po stronie klienta.
- Wymuszenie `memberKeys` z AAD v2.
- Powiazanie kopert kluczy z rozmowa, odbiorca, urzadzeniem i epoka.
- Podpisy urzadzen i kontrola epok listy urzadzen.
- Liczniki i hash-chain wiadomosci.
- Lokalny log key transparency.
- Oddzielne limity rate limitera dla wrazliwych obszarow.
- Pre-auth limity WebSocket.
- Ochrona `/metrics` za zaufanym reverse proxy.
- Bezpieczniejsze serwowanie manifestu i artefaktow aktualizacji.
- Podpisany manifest aktualizacji Ed25519.
- Utrwalona blokada PIN po restarcie aplikacji.
- Dokumentacja bez prywatnych danych.

## Do zrobienia przed mocnymi deklaracjami E2EE

### Double Ratchet

Potrzebna jest pelna integracja Double Ratchet z migracja istniejacych rozmow, testami utraty kolejnosci, wieloma urzadzeniami i rotacja kluczy. Dopoki tego nie ma, nie deklarujemy post-compromise security na poziomie Signal.

### OPAQUE/PAKE

Logowanie powinno zostac przeniesione na sprawdzona implementacje OPAQUE albo inny dobrze oceniony PAKE. Wymaga to kompatybilnej biblioteki po stronie klienta i serwera oraz migracji kont.

### Key transparency ze swiadkami

Lokalny log jest przydatny, ale operator self-hosted serwera nadal moze kontrolowac widok logu. Mocniejszy model wymaga zewnetrznych swiadkow, publicznego checkpointu albo innego mechanizmu niezaleznej obserwowalnosci.

### Audyt kryptografii

Przed wydaniem stabilnym potrzebny jest przeglad:

- formatow AAD,
- serializacji kanonicznej,
- rotacji kluczy,
- obslugi wielu urzadzen,
- backupu i przywracania,
- aktualizacji klienta.

## Zasady implementacji

- Nie dodawac wlasnej kryptografii, jezeli istnieje sprawdzona biblioteka.
- Nie obnizac walidacji serwera dla kompatybilnosci bez jawnej migracji.
- Nie deklarowac zgodnosci z Signal, OPAQUE, MLS ani publicznym key transparency bez pelnej implementacji.
- Kazda poprawka bezpieczenstwa powinna miec test regresji.
