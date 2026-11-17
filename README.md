# Bacheca Lavoro – Back-end

Server REST in **Dart + [shelf](https://pub.dev/packages/shelf)** per l'app Flutter
[Bacheca Lavoro](https://github.com/dtype1/job_board_app). Gestisce aziende, annunci, candidature e i file
dei curriculum. Nessun servizio esterno: dati e file restano sul computer locale.

## Avvio

```bash
dart pub get
dart run bin/server.dart
```

All'avvio il server stampa gli indirizzi a cui è raggiungibile, ad esempio:

```
Server in ascolto sulla porta 8080
Indirizzi utilizzabili dallo smartphone:
  http://192.168.1.2:8080   (Wi-Fi)
```

Quell'indirizzo va inserito nell'app (icona *Impostazioni server* in alto a destra).
Smartphone e PC devono essere sulla stessa rete Wi-Fi; se Windows lo chiede,
consentire a Dart l'accesso alle **reti private** nel firewall.

Variabili d'ambiente opzionali: `PORT` (default `8080`), `DATA_DIR` (default `data`).

## Persistenza

- `data/db.json` – aziende, annunci, candidature e sessioni (riscritto a ogni modifica, scrittura atomica)
- `data/uploads/` – i curriculum caricati

I dati restano disponibili dopo il riavvio del server e la chiusura dell'app.
Le password sono salvate come hash SHA-256 iterato con salt casuale.

## API

| Metodo | Endpoint | Auth | Descrizione | Req. |
|---|---|---|---|---|
| POST | `/api/auth/register` | – | Registrazione azienda `{name, email, password, description?}` | R1 |
| POST | `/api/auth/login` | – | Login → `{token, company}` | R2 |
| POST | `/api/auth/logout` | Bearer | Invalida il token | R3 |
| GET | `/api/auth/me` | Bearer | Azienda autenticata | – |
| POST | `/api/jobs` | Bearer | Pubblica annuncio `{title, description, location?, contractType?}` | R4 |
| GET | `/api/jobs` | – | Elenco annunci (bacheca) | R5 |
| GET | `/api/jobs/{id}` | – | Dettaglio annuncio | R5 |
| POST | `/api/jobs/{id}/applications` | – | Candidatura (multipart: `firstName`, `lastName`, `email`, `phone?`, `message?`, file `cv`) | R6 |
| GET | `/api/company/jobs` | Bearer | Annunci dell'azienda con numero di candidature | R7 |
| GET | `/api/company/jobs/{id}/applications` | Bearer | Candidature di un proprio annuncio | R7 |
| GET | `/api/company/applications/{id}` | Bearer | Dettaglio candidatura | R7 |
| GET | `/api/company/applications/{id}/cv` | Bearer | Download del curriculum | R7 |
| GET | `/api/health` | – | Verifica che il server sia attivo | – |

Autenticazione: header `Authorization: Bearer <token>`. Un'azienda può vedere solo
le candidature dei **propri** annunci. Errori restituiti come `{"error": "messaggio"}`.
CV ammessi: PDF, DOC, DOCX fino a 10 MB.

## Struttura

```
bin/server.dart        avvio del server HTTP
lib/src/api.dart       endpoint REST e validazione
lib/src/store.dart     persistenza su file JSON, hashing password
test/api_test.dart     test end-to-end degli scenari S1–S3
```

## Test

```bash
dart test
```

Il test esegue gli scenari S1–S3 via HTTP, riavviando il server a metà per
verificare la persistenza, e controlla che dopo il logout l'area riservata
non sia più accessibile.
