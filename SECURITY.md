# Security Policy

## Zakres

Ten dokument dotyczy aktualnej galezi projektu Secure P2P Messenger. Projekt jest self-hosted i przeznaczony do uruchomienia na wlasnym serwerze Ubuntu.

## Zglaszanie problemow

Nie publikuj szczegolow podatnosci w publicznym issue, jezeli pozwalaja one na przejecie kont, odczyt danych, obejscie aktualizacji albo odmowe uslugi. Przygotuj zgloszenie z:

- opisem podatnosci,
- minimalnymi krokami odtworzenia,
- spodziewanym i faktycznym skutkiem,
- zakresem wersji lub commitem,
- informacja, czy problem wymaga lokalnego dostepu, konta uzytkownika, czy dostepu sieciowego.

Nie dolaczaj prawdziwych sekretow, prywatnych kluczy, danych kont ani logow zawierajacych dane osobowe.

## Sekrety

Za sekrety uwazaj:

- `ADMIN_TOKEN`,
- prywatny klucz podpisu aktualizacji,
- pliki `.env`,
- hasla kont,
- backupy danych,
- prywatne adresy serwera, jezeli sa czescia prywatnej infrastruktury.

Sekret, ktory trafil do repozytorium albo publicznego logu, trzeba obrocic. Samo usuniecie pliku z ostatniego commita nie wystarcza.

## Znane ograniczenia

Aktualna wersja ma mocne zabezpieczenia aplikacyjne, ale nie jest pelnym odpowiednikiem protokolu Signal:

- pelny Double Ratchet i post-compromise security sa nadal elementem roadmapy,
- OPAQUE/PAKE nie jest jeszcze uzywany w logowaniu,
- key transparency jest lokalnym logiem na self-hosted serwerze, bez zewnetrznych swiadkow,
- bezpieczenstwo klienta zalezy od systemowego magazynu kluczy i zabezpieczen urzadzenia.

## Reakcja na incydent

1. Zatrzymaj publikacje nowych buildow.
2. Obroc wszystkie dotkniete sekrety.
3. Zabezpiecz kopie logow i danych do analizy.
4. Przygotuj poprawke i test regresji.
5. Wydaj podpisana aktualizacje klienta oraz instrukcje dla administratorow serwera.
6. Jezeli naruszono klucze aktualizacji, zmien `SECURE_CHAT_UPDATE_KEY_ID` i opublikuj nowy build klienta z nowym kluczem publicznym.
