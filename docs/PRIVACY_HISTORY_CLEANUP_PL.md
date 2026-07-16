# Czyszczenie prywatnych danych z historii Gita

Ten playbook dotyczy sytuacji, w ktorej prywatne dane byly kiedys zapisane w
repozytorium. Samo poprawienie README albo usuniecie pliku w najnowszym commicie
nie usuwa danych z historii.

## Kiedy wykonac

- Przed upublicznieniem repozytorium.
- Po przypadkowym commicie tokenow, adresow prywatnych, nazw hostow, sekretow
  release albo danych osobowych.
- Po audycie, ktory wykazal prywatne dane w historii.

## Procedura

1. Zrob pelny backup repozytorium poza katalogiem roboczym.
2. Spisz wszystkie sekrety, ktore mogly byc w historii.
3. Zrotuj te sekrety przed publikacja: tokeny admina, klucze release, hasla,
   invite tokeny, webhooki i dane reverse proxy.
4. Uruchom `git filter-repo` albo BFG Repo-Cleaner na lokalnej kopii.
5. Sprawdz wynik przez `git grep`, `git log -S` i reczny przeglad README/docs.
6. Wypchnij przepisana historie przez `git push --force-with-lease`.
7. Popros GitHuba o purge cache, jezeli dane byly publicznie dostepne.
8. Poinformuj osoby z clone/fork, ze musza pobrac repo od nowa.

## Uwagi

Nie wykonuj tej procedury automatycznie w zwyklym commicie naprawczym. To
przepisuje publiczna historie i moze zepsuc forki, pull requesty oraz lokalne
kopie innych osob.
