# Security roadmap

Ten dokument opisuje aktualny model zaufania i kierunek rozwoju projektu po
tescie bezpieczenstwa. Projekt nalezy obecnie traktowac jako self-hosted
komunikator chmurowy dla malej, zaufanej grupy, a nie jako komunikator
zero-trust odporny na aktywnie zlosliwy serwer.

## Aktualna klasyfikacja

Najtrafniejszy opis obecnego produktu:

> Self-hosted komunikator chmurowy z szyfrowaniem tresci po stronie klienta,
> zaszyfrowana historia na serwerze i synchronizacja wielu urzadzen,
> przeznaczony dla malych, zaufanych grup.

Serwer nadal widzi metadane techniczne: konta, relacje, adresy IP, czas,
rozmiary pakietow i fakt komunikacji. Nie jest to system anonimowy.

## Zmiany wykonane po tescie

- Aktywny P2P/WebRTC zostal usuniety z klienta.
- Haslo konta zostalo oddzielone od sekretu vaultu.
- Haslo konta nadal jest wysylane do serwera w celu logowania, ale przez
  wymuszony HTTPS poza localhostem i nie sluzy do odszyfrowania vaultu.
- Sekret vaultu jest uzywany lokalnie do wyprowadzenia klucza vaultu i nie jest
  wysylany do API.
- Klient wymaga HTTPS/WSS poza localhostem.
- Dodano trwala tozsamosc Ed25519 w vaulcie.
- Klucz X25519 uzywany do szyfrowania kluczy rozmow jest podpisywany przez
  Ed25519.
- Podpis klucza X25519 obejmuje UUID konta oraz origin serwera, zeby serwer nie
  mogl bez wykrycia przypisac poprawnego pakietu kluczy do innego konta albo
  innej instancji.
- Origin serwera jest kanonizowany przed podpisem: schemat i host malymi
  literami, bez sciezki, query, fragmentu i bez domyslnego portu.
- Normalizacja originu odrzuca userinfo i obce schematy, zachowuje porty
  niestandardowe, stabilizuje IPv6 oraz normalizuje hosty IDN do ASCII/Punycode.
- Klient weryfikuje podpisane pakiety kluczy z serwera i blokuje niepoprawne
  albo zmienione tozsamosci.
- Dodano TOFU/pinning podpisanej tozsamosci kontaktu.
- Dodano safety number liczony z UUID obu kont i tozsamosci Ed25519 kontaktow w
  kanonicznie uporzadkowany sposob.
- Dodano testy negatywne dla podmiany klucza X25519, podmiany klucza Ed25519,
  innego UUID, innego originu/portu, uszkodzonego Base64 i starego formatu
  podpisu v1.
- Dodano podpisana rotacje tozsamosci Ed25519: nowy klucz tozsamosci jest
  podpisywany dotychczasowym kluczem, a klient akceptuje zmiane kontaktu tylko
  wtedy, gdy dowod rotacji pasuje do przypietego starego klucza.
- Dowod rotacji zawiera monotoniczny `rotationEpoch`, hash poprzedniego dowodu
  rotacji oraz podpis nowym kluczem, ktory potwierdza posiadanie nowego klucza
  prywatnego w chwili rotacji.
- Dodano podpisane aktualizacje: manifest release jest podpisywany Ed25519, a
  klient weryfikuje podpis kluczem publicznym wbudowanym przy buildzie.
- Dodano anty-replay nowych wiadomosci cloud: kazda nowa wiadomosc zawiera w
  AAD `senderDeviceId`, monotoniczny `messageCounter` oraz
  `previousMessageHash`, a klient trwale zapisuje ostatni zaakceptowany licznik
  i hash dla strumienia `rozmowa + nadawca + urzadzenie`.
- Hash lancucha wiadomosci jest liczony z kanonicznej koperty calej
  zaszyfrowanej wiadomosci w domenie `secure-chat/message-chain/v1`, a pierwsza
  wiadomosc strumienia musi wskazywac staly genesis hash.
- Wiadomosci dostarczone poza kolejnoscia sa buforowane jako luka i klient
  probuje dociagnac brakujace pakiety, zamiast od razu trwale blokowac rozmowe.
- Wysylanie z jednego urzadzenia w jednej rozmowie jest kolejkowane, zeby dwa
  pakiety nie dostaly tego samego licznika i poprzedniego hasha.
- Dodano kryptograficzna tozsamosc urzadzenia: kazde urzadzenie generuje
  lokalny klucz Ed25519, publikuje podpisany przez tozsamosc konta certyfikat
  urzadzenia i podpisuje nim zaszyfrowana koperte wiadomosci.
- Hash lancucha wiadomosci obejmuje rowniez podpis urzadzenia, dzieki czemu
  nastepna wiadomosc zalezy nie tylko od szyfrogramu, ale tez od tego, ktore
  urzadzenie podpisalo poprzednia koperte.
- Klient blokuje downgrade podpisanego strumienia: jezeli dany strumien
  `rozmowa + nadawca + urzadzenie` przeszedl na podpisy urzadzen, kolejne
  wiadomosci bez poprawnego podpisu sa odrzucane.
- Token sesji cloud WebSocket nie jest juz wysylany ani w query stringu URL,
  ani w naglowku handshake. Klient pobiera krotko zyjacy, jednorazowy ticket
  przez HTTPS i zuzywa go jako pierwsza ramke WebSocket.
- Legacy relay ze wspolnym sekretem zostal usuniety z aktywnej sciezki serwera.
- Dodano podpisana, wersjonowana liste urzadzen konta:
  `deviceListEpoch`, `previousDeviceListHash`, aktywne urzadzenia,
  uniewaznione urzadzenia i podpis aktualna tozsamoscia Ed25519 konta.
- Klient przypina przy kontakcie ostatni zaakceptowany epoch/hash listy
  urzadzen i odrzuca rollback albo rozwidlona galez listy.
- Backend zapisuje liste urzadzen z mechanizmem compare-and-swap na
  `expectedDeviceListEpoch` i `expectedDeviceListHash`, zeby dwie rownolegle
  aktualizacje nie nadpisywaly sie po cichu.
- Dodano uniewaznianie urzadzen: klient tworzy kolejny podpisany epoch listy,
  przenosi urzadzenie do `revokedDevices`, a backend usuwa jego aktywne sesje i
  zamyka polaczenia WebSocket.
- Nowe wiadomosci podpisane przez uniewaznione albo nieaktywne urzadzenie sa
  odrzucane. Wczesniej zapisane wiadomosci historyczne pozostaja w lokalnej
  historii.

Uwaga migracyjna: stare konta mialy vault szyfrowany haslem logowania. Przy
pierwszym logowaniu po tej zmianie mozna wpisac to samo haslo jako `Haslo
konta` i `Sekret vaultu`, a nastepnie utworzyc nowe konto testowe z osobnym
sekretem.

## Najwieksze pozostale ryzyka

1. Brak OPAQUE lub rownowaznego protokolu logowania bez ujawniania hasla
   aplikacyjnego serwerowi.
2. Pierwsze dodanie kontaktu nadal ufa tozsamosci dostarczonej przez serwer,
   dopoki uzytkownicy nie porownaja safety number poza serwerem.
3. Brak publicznego key transparency logu.
4. Bez key transparency zlosliwy serwer nadal moze probowac rozdzielic rozne
   pierwsze galezie rotacji miedzy grupy kontaktow, zanim zobacza one wspolny
   lancuch.
5. Rotacja X25519 nadal nie rewrapuje automatycznie istniejacych kluczy rozmow.
6. Anty-replay dziala dla nowych wiadomosci po aktualizacji; backend
   przejsciowo przyjmuje tez format legacy bez licznikow, zeby aktualizacja
   serwera nie odciela starszych klientow.
7. Uniewaznienie urzadzenia blokuje nowe podpisane wiadomosci i sesje, ale nie
   odbiera jeszcze dostepu do przyszlych szyfrogramow, jesli skompromitowane
   urzadzenie nadal posiada klucze rozmow.
8. Brak Double Ratchet, czyli brak nowego klucza wiadomosci dla kazdego
   komunikatu.
9. Prywatny klucz podpisywania release musi byc operacyjnie chroniony poza
   serwerem produkcyjnym.
10. Backend nadal uzywa plikow JSON i synchronicznych zapisow, co jest dobre dla
   prototypu, ale nie dla duzej uslugi.

## Priorytet 1: prawdziwsze E2EE wzgledem serwera

1. Wdrozyc OPAQUE albo inny protokol logowania, w ktorym serwer nie otrzymuje
   sekretu pozwalajacego odszyfrowac vault.
2. Dodac key transparency log dla publicznych tozsamosci Ed25519.
3. Po uniewaznieniu urzadzenia rotowac klucze aktywnych rozmow i opakowywac je
   wylacznie dla pozostalych aktywnych urzadzen.
4. Wprowadzic zatwierdzanie nowych urzadzen przez istniejace urzadzenie albo
   recovery key.

## Priorytet 2: forward secrecy

1. Dodac Double Ratchet dla rozmow 1:1.
2. Usuwac zuzyte klucze wiadomosci natychmiast po uzyciu.
3. Oddzielic klucze do historii lokalnej, synchronizacji i nowych wiadomosci.
4. Dla grup zaczac od sender keys, a potem rozwazyc bardziej zaawansowany MLS.

## Priorytet 3: urzadzenia i infrastruktura

1. Dodac panel sesji i liste aktywnych urzadzen.
2. Dodac wylogowanie konkretnego urzadzenia.
3. Przeniesc backend z JSON do PostgreSQL.
4. Dodac migracje, transakcje, rate limiting, limity przechowywania i paginacje.
5. Dodac testy integracyjne, fuzzing parserow i CI dla Windows, Android oraz
   Linux.

## Czego nie obiecywac testerom

Nie nalezy opisywac obecnej wersji jako:

- odpornej na aktywnie zlosliwy serwer,
- odpowiednika Signal/WhatsApp pod wzgledem kryptografii,
- gotowej dla sygnalistow, dziennikarzy, prawnikow, lekarzy lub danych
  regulowanych,
- anonimowej,
- gotowej do masowego publicznego wdrozenia.

## Co mozna uczciwie testowac

- Self-hosted komunikator dla malej zaufanej grupy.
- Szyfrowanie tresci po stronie klienta.
- Szyfrowany vault i historia na serwerze.
- Synchronizacja wielu urzadzen.
- Wygoda klientow Windows, Android i Linux.
- Zachowanie po zmianie klucza kontaktu i porownywanie safety number.
