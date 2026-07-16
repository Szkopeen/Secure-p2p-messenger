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
- Kompromitacja root identity key konta. Vault zawiera klucz tozsamosci konta,
  wiec kompromitacja vaultu lub urzadzenia z tym kluczem pozwala zatwierdzac
  urzadzenia i rotacje do czasu recznego odzyskania konta.
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
  chronione tokenem administratora i allowlista adresow IP. Przy zaufanym
  reverse proxy allowlista sprawdza rozpoznany adres klienta, a nie lokalny
  adres TCP proxy.
- Katalog nie zwraca globalnej listy uzytkownikow; wyszukiwanie wymaga
  dokladnego loginu.
- Legacy relay i stare aktywne grupy sa usuniete z klienta.
- Manifest aktualizacji jest podpisywany Ed25519, a artefakty maja SHA-256.
- Klient sprawdza `keyId`, podpis manifestu, deklarowany rozmiar, limit
  pobierania i SHA-256 artefaktu aktualizacji.
- SQLite pracuje w WAL i ma testowany backup online oraz restore kopii.

## Capability gate

Ta wersja nie ma capability dla zastosowan wysokiego ryzyka. W szczegolnosci
nie ma jeszcze audytowanego Double Ratchet/PQXDH ani OPAQUE/PAKE. Ma lokalny
append-only key transparency log jednej instancji, ale nie ma jeszcze
zewnetrznych witnessow ani publicznego gossip/audytu root hashy. Do czasu
wdrozenia tych protokolow produkt nalezy opisywac jako self-hosted komunikator
dla malej, zaufanej grupy, a nie jako system odporny na aktywnie zlosliwy serwer
albo post-compromise compromise recovery.

## Pozostale ryzyka do zamkniecia przed wysokim ryzykiem

- Audytowana biblioteka OPAQUE albo rownowazne logowanie, w ktorym serwer nie
  otrzymuje hasla aplikacyjnego.
- Zewnetrzne witnessy i publiczny gossip dla key transparency publicznych
  tozsamosci Ed25519.
- Oddzielenie root identity key od vaultu i model zatwierdzania nowych
  urzadzen bez wspoldzielenia klucza root na wszystkie urzadzenia.
- Audytowane X3DH/PQXDH + Double Ratchet dla rozmow 1:1.
- MLS albo audytowany sender-key protocol dla grup.
- Rekey dla przyszlych grup przez MLS albo audytowany protokol sender-key.
- Niezalezny pentest backendu, klienta Windows, klienta Android i procesu
  aktualizacji.
- Niezalezny audyt kryptograficzny protokolu.

## Wymagania operacyjne

- Wymuszaj HTTPS/WSS poza localhostem.
- `ADMIN_TOKEN`, klucz release i backupy trzymaj poza repozytorium.
- Klucz podpisywania release trzymaj poza serwerem produkcyjnym.
- `SECURE_CHAT_UPDATE_KEY_ID` musi odpowiadac `keyId` w podpisanym
  manife?cie; rotacje kluczy release dokumentuj razem z wydaniem.
- Nie uzywaj hasla konta jako sekretu vaultu. Klient to blokuje, poniewaz
  haslo konta jest przekazywane serwerowi podczas logowania.
- Nazwy urzadzen traktuj jako metadane. Klient wysyla tylko neutralna nazwe
  platformy, a backend anonimizuje starsze wpisy `deviceName`.
- Regularnie wykonuj `npm run backup-sqlite -- --out ...` albo offline kopie
  kompletnego zestawu `.sqlite`, `.sqlite-wal`, `.sqlite-shm`.
- Przed udostepnieniem testerom uruchamiaj checklisty z
  `docs/RELEASE_PROCESS_PL.md`.
- Testerom opisuj produkt zgodnie z ograniczeniami z
  `docs/SECURITY_ROADMAP_PL.md`.
- Jezeli w historii Gita byly prywatne dane, wykonaj procedury z
  `docs/PRIVACY_HISTORY_CLEANUP_PL.md`, zrotuj sekrety i dopiero potem
  zapraszaj nowych testerow.
