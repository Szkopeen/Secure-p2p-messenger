# Threat model Secure Chat

Ten dokument opisuje, przed czym aktualna wersja ma chronic i czego jeszcze
nie obiecuje. To jest dokument operacyjny dla self-hosted bety, nie zamiennik
niezaleznego audytu kryptograficznego.

## Klasyfikacja produktu

Aktualna wersja to self-hosted komunikator cloud-only dla malej, zaufanej
grupy. Tresc rozmow, plikow i vaultu jest szyfrowana po stronie klienta, ale
serwer nadal przechowuje i widzi metadane techniczne.

Projekt nie jest jeszcze odpowiednikiem Signala i nie jest przeznaczony dla
scenariuszy wysokiego ryzyka.

## Chronione zasoby

- Prywatne klucze tozsamosci Ed25519 konta i urzadzen.
- Sekret vaultu oraz klucz vaultu.
- Klucze rozmow 1:1.
- Tresc wiadomosci, plikow i lokalnej historii.
- Tokeny sesji, tickety WebSocket i zaproszenia.
- Prywatny klucz podpisywania release.
- Baza SQLite, WAL/SHM i backupy serwera.

## Zaufane komponenty

- Klient uruchomiony na urzadzeniu uzytkownika.
- Systemowy secure storage uzywany przez klienta.
- Lokalna implementacja kryptografii klienta.
- Administrator self-hosted instancji w zakresie utrzymania dostepnosci,
  backupow i konfiguracji TLS.
- Zaufany komputer release, na ktorym lezy prywatny klucz podpisywania
  manifestow aktualizacji.

## Niezaufane lub tylko czesciowo zaufane komponenty

- Publiczna siec.
- Reverse proxy i logi infrastruktury.
- Serwer aplikacyjny jako zrodlo metadanych i ciphertextow.
- Backupy, jesli sa przechowywane bez kontroli dostepu.
- Pierwsza odpowiedz katalogu uzytkownikow przed porownaniem safety number.
- Pliki aktualizacji hostowane na serwerze produkcyjnym, dopoki nie przejda
  weryfikacji podpisu manifestu i SHA-256 artefaktu.

## Atakujacy w zakresie modelu

- Osoba w internecie bez konta.
- Uzytkownik z wlasnym kontem probujacy enumeracji, DoS albo naduzyc storage.
- Przechwycenie lub replay pakietow sieciowych.
- Kradziez tokenu sesji.
- Proba podszycia sie pod cudze urzadzenie.
- Proba zapisu wiadomosci bez podpisu urzadzenia albo z cofnietym licznikiem.
- Proba podmiany pliku aktualizacji na serwerze.
- Awaria procesu serwera podczas zapisu SQLite.

## Poza obecnym zakresem ochrony

- Aktywnie zlosliwy serwer, ktory przy pierwszym kontakcie podstawia rozne
  tozsamosci roznym uzytkownikom.
- Kompromitacja urzadzenia z odczytem kluczy rozmow.
- Pelna forward secrecy i post-compromise security.
- Anonimowosc komunikacji i ukrywanie grafu kontaktow.
- Ochrona przed zlosliwym systemem operacyjnym klienta.
- Duza publiczna usluga z wieloma procesami backendu bez osobnego planu
  storage i migracji.

## Obecne gwarancje

- Nowe wiadomosci cloud wymagaja protokolu v2, licznika, hasha poprzedniej
  wiadomosci, certyfikatu urzadzenia i podpisu Ed25519 urzadzenia.
- Backend wymusza unikalny licznik strumienia
  `conversation + sender + device + counter` w SQLite.
- Append wiadomosci i aktualizacja rozmowy ida w jednej transakcji
  `BEGIN IMMEDIATE`.
- Po uniewaznieniu urzadzenia klient rotuje klucze aktywnych rozmow 1:1 i
  opakowuje je tylko dla pozostalych uczestnikow.
- Sesje maja konfigurowalny TTL i idle timeout, a WebSocket uzywa
  jednorazowego ticketu.
- Publiczny `/healthz` nie ujawnia metryk. Szczegoly sa w `/metrics`,
  chronione tokenem administratora i allowlista adresow IP.
- Katalog nie zwraca globalnej listy uzytkownikow; wyszukiwanie wymaga
  dokladnego loginu.
- Legacy relay i stare aktywne grupy sa usuniete z klienta.
- Manifest aktualizacji jest podpisywany Ed25519, a artefakty maja SHA-256.
- SQLite pracuje w WAL i ma testowany backup online oraz restore kopii.

## Pozostale ryzyka do zamkniecia przed wysokim ryzykiem

- OPAQUE albo rownowazne logowanie, w ktorym serwer nie otrzymuje hasla
  aplikacyjnego.
- Key transparency dla publicznych tozsamosci Ed25519.
- Double Ratchet/PQXDH dla rozmow 1:1.
- MLS albo audytowany sender-key protocol dla grup.
- Rekey dla przyszlych grup przez MLS albo audytowany protokol sender-key.
- Niezalezny pentest backendu, klienta Windows, klienta Android i procesu
  aktualizacji.
- Niezalezny audyt kryptograficzny protokolu.

## Wymagania operacyjne

- Wymuszaj HTTPS/WSS poza localhostem.
- `ADMIN_TOKEN`, klucz release i backupy trzymaj poza repozytorium.
- Klucz podpisywania release trzymaj poza serwerem produkcyjnym.
- Regularnie wykonuj `npm run backup-sqlite -- --out ...` albo offline kopie
  kompletnego zestawu `.sqlite`, `.sqlite-wal`, `.sqlite-shm`.
- Przed udostepnieniem testerom uruchamiaj checklisty z
  `docs/RELEASE_PROCESS_PL.md`.
- Testerom opisuj produkt zgodnie z ograniczeniami z
  `docs/SECURITY_ROADMAP_PL.md`.
- Jezeli w historii Gita byly prywatne dane, wykonaj procedury z
  `docs/PRIVACY_HISTORY_CLEANUP_PL.md`, zrotuj sekrety i dopiero potem
  zapraszaj nowych testerow.
