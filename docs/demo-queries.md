# Demo queries

Set de 8 interogari atent alese pentru a evidentia diferentele dintre **cautarea
vectoriala** (semantica) si **cautarea keyword** (lexicala) pe acelasi corpus
StackOverflow Q&A.

Pentru fiecare query mentionam:
- **Tipul de cautare asteptat sa castige** (vector / keyword / tie)
- **De ce** - mecanismul lingvistic / informational implicat

> ATENTIE: rezultatele exacte depind de sample-ul concret de 5000 randuri
> incarcate. Dupa setup, ruleaza queries-urile manual si reordoneaza acest
> document in functie de comportamentul observat.

---

## 1. "how to make my code run faster"

**Asteptat**: VECTOR castiga.

Query-ul nu contine cuvinte tehnice (`optimize`, `performance`, `parallel`).
Cautarea vectoriala recunoaste conceptul de optimizare prin embedding-uri si va
returna intrebari despre stream-uri, paralelizare, profiling, big-O - chiar daca
acele intrebari nu contin literal expresia "make my code run faster".

Cautarea keyword va prinde doar intrebari care contin literal aceste cuvinte,
ratand toate variatiile lingvistice.

---

## 2. "ConcurrentModificationException"

**Asteptat**: KEYWORD castiga (sau egalitate).

Exceptii Java au nume canonice. Embedding-ul poate "intelege" conceptul, dar
in practica un dezvoltator vrea exact stack-trace-uri si cazuri cu acest nume.
Indexul Oracle Text returneaza exact post-urile care mentioneaza exceptia, cu
scor TF-IDF mare.

Vector poate aluneca catre intrebari similare conceptual (alte exceptii
de concurenta) - corecte tematic, dar nu ce cauti.

---

## 3. "loop iterates too slowly"

**Asteptat**: VECTOR castiga.

"Loop slow" este o descriere conceptuala. Solutiile reale sunt:
parallelStream, ExecutorService, vectorization, etc. Cautarea vectoriala
recunoaste relatia conceptuala intre "iterates slowly" si "parallelize".

Keyword va returna doar post-uri care contin "loop" si "slow" si "iterates" -
mult mai restrans.

---

## 4. "NullPointerException best practices"

**Asteptat**: KEYWORD castiga.

Combinatia "NullPointerException" + "best practices" este o cautare relativ
literala. Dezvoltatorii folosesc termenii standard. Indexul Oracle Text
returneaza precis intrebari cu acesti termeni.

Vector poate returna intrebari mai generale despre defensive programming sau
Optional - utile, dar mai putin precise.

---

## 5. "avoid changing data after creation"

**Asteptat**: VECTOR castiga.

Conceptul cautat este **imutabilitatea** - dar query-ul nu contine cuvantul
"immutable", "final" sau "record". Embedding-urile moderne (MiniLM) recunosc
parafrazarile conceptuale.

Keyword va esua aproape complet - termeni prea generici ("data", "creation").

---

## 6. "Collectors.toMap"

**Asteptat**: KEYWORD castiga.

Numele unei API-uri Java. Dezvoltatorii cauta exact aceasta forma. Oracle Text
gaseste imediat post-urile care folosesc `Collectors.toMap()`.

Vector poate returna intrebari despre `groupingBy`, `LinkedHashMap`, etc -
contextual relevante dar nu exact ce s-a cerut.

---

## 7. "memory keeps growing in my application"

**Asteptat**: VECTOR castiga.

Conceptul cautat: **memory leak**. Query-ul descrie simptomul, nu termenul
tehnic. Embedding-urile fac legatura intre "memory growing" si "memory leak",
"GC issues", "heap dump".

Keyword va prinde doar post-uri cu cuvintele literale "memory" si "growing" -
o fractiune din ce vrei tu.

---

## 8. "convert string to integer"

**Asteptat**: TIE / KEYWORD usor in fata.

Aceasta este o cautare foarte specifica si comuna. Ambele metode vor returna
rezultate similare pentru ca termenii sunt deja cei naturali.

Diferenta interesanta: vector poate returna intrebari despre `parseInt`,
`Integer.valueOf`, `Long.parseLong` (toate concepte legate), in timp ce
keyword va fi mai literal. Pentru un user de StackOverflow, ambele sunt OK.

---

## Cum prezentati la demo (5 queries pentru 5 minute)

Recomandam **acest ordin** pentru impact maxim:

1. **"convert string to integer"** - Start neutru, ambele cauta bine.
   *"Daca ambele dau rezultate similare, e usor sa crezi ca nu conteaza ce alegi.
   Dar..."*
2. **"how to make my code run faster"** - PRIMUL WOW. Vectoriala domina.
   *"Acelasi corpus, dar embeddings-urile inteleg conceptul. Keyword se opreste
   la cuvinte literale."*
3. **"ConcurrentModificationException"** - REVERS. Keyword domina.
   *"Important: vector NU e mereu mai bun. Pentru termeni canonici, keyword-ul
   ramane dominant si mai precis."*
4. **"avoid changing data after creation"** - **A doua mostra de putere semantica**.
   *"Aici e magia reala: query-ul nu contine deloc cuvantul 'immutable',
   dar vector returneaza exact post-urile despre records si final classes."*
5. **"NullPointerException best practices"** - INCHIDERE NUANTATA.
   *"Concluzie: alegerea depinde de tipul de query. Solutia ideala?
   Hybrid search - dar asta este tema 11."*

Fiecare query: ~1 minut (read query → click search → arata partea care castiga →
explica de ce). Total: 5 minute live demo.
