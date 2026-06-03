# व्यं LinguaPi

A self-hosted language learning web app designed for Raspberry Pi (and any machine running Go). Generates reading passages using a local or remote LLM, lets you click any word for instant grammar breakdown, tracks your study history in SQLite, and runs spaced quiz sessions — all without sending data to the cloud.

---

## Features

- **Passage generation** — short reading texts at Beginner / Intermediate / Advanced difficulty, across categories (stories, news, culture, literature)
- **Grammar analyzer** — click any word or select a phrase to get translation, part of speech, tense/conjugation, synonyms, and example sentences
- **Conjugation tables** — for verbs, a full conjugation table across 6 tenses with language-appropriate pronouns is shown inline
- **Multi-language** — Spanish, German, Portuguese, Italian, Kannada, Telugu (non-Latin scripts include romanized transliteration)
- **TTS playback** — uses the browser's Speech Synthesis API with per-language voice selection and speed control
- **Study history** — passages stored in a local SQLite database (`~/.linguapi/linguapi.db`)
- **Spaced quiz** — every 10 passages a quiz is offered; a passage from your history is shown and you translate it; results are recorded and biased toward least-recently-quizzed passages
- **Settings modal** — change language, difficulty, model, LLM provider/endpoint/API key, and font size from the UI without restarting
- **Model selector** — lazy-loaded list of installed Ollama models (or OpenAI models); switch live from settings
- **Dark / light mode** — persisted across sessions
- **LLM health check** — verifies the connection on startup and exposes `/api/health`; the UI shows inline status when saving settings

---

## Requirements

- [Go 1.22+](https://go.dev/dl/) — no CGO required (uses `modernc.org/sqlite`)
- [Ollama](https://ollama.com/) running locally **or** an OpenAI-compatible API key

---

## Install from a release

Pre-built binaries are available for every [GitHub release](https://github.com/chaoticfly/lingua-pi/releases) for Linux, macOS, and Windows on both amd64 and arm64.

### macOS / Linux (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/chaoticfly/lingua-pi/master/scripts/install.sh | bash
```

Installs to `/opt/lingua-pi/` and creates a wrapper at `/usr/local/bin/lingua-pi`.  
To install a specific version: `VERSION=v1.0.0 bash <(curl -fsSL .../install.sh)`

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/chaoticfly/lingua-pi/master/scripts/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\LinguaPi\` and adds it to your user `PATH`.  
To install a specific version: `$env:VERSION = "v1.0.0"; irm .../install.ps1 | iex`

### Manual download

Download the archive for your platform from the [releases page](https://github.com/chaoticfly/lingua-pi/releases), extract it, and run `./lingua-pi` from inside the extracted folder (the binary looks for `static/` in its working directory).

| Archive | OS | Arch |
|---------|----|------|
| `lingua-pi-linux-amd64.tar.gz` | Linux | x86-64 |
| `lingua-pi-linux-arm64.tar.gz` | Linux | ARM64 (Raspberry Pi 5) |
| `lingua-pi-darwin-amd64.tar.gz` | macOS | Intel |
| `lingua-pi-darwin-arm64.tar.gz` | macOS | Apple Silicon |
| `lingua-pi-windows-amd64.zip` | Windows | x86-64 |
| `lingua-pi-windows-arm64.zip` | Windows | ARM64 |

---

## Build from source

### 1. Clone

```bash
git clone <your-repo-url>
cd lingua-pi
```

### 2. Configure (or skip and use the Settings UI)

A config file is created automatically at `~/.linguapi/config.json` on first run. To pre-configure, create it manually:

**Ollama (default):**
```json
{
  "server_port": 8080,
  "language": "Spanish",
  "llm_provider": "ollama",
  "llm_endpoint": "http://localhost:11434",
  "llm_model": "gemma3:4b",
  "llm_api_key": ""
}
```

**OpenAI:**
```json
{
  "server_port": 8080,
  "language": "Spanish",
  "llm_provider": "openai",
  "llm_endpoint": "https://api.openai.com/v1",
  "llm_model": "gpt-4o-mini",
  "llm_api_key": "sk-..."
}
```

All fields can also be changed live from the **Settings** panel in the UI.

### 3. Pull a model (Ollama only)

```bash
ollama pull gemma3:4b
```

### 4. Build and run

```bash
go build -o lingua-pi
./lingua-pi
```

Open `http://localhost:8080` in your browser.

---

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/config` | Returns current provider, model, language |
| `POST` | `/api/config` | Updates config fields; returns a fresh health check |
| `GET` | `/api/models` | Lists available models from the configured provider |
| `GET` | `/api/health` | LLM connection status |
| `POST` | `/api/generate` | Generate a passage `{ "category", "language", "difficulty" }` |
| `POST` | `/api/analyze` | Analyze a word/phrase `{ "text", "context", "language" }` |
| `GET` | `/api/history` | Returns the last 25 study entries |
| `GET` | `/api/quiz` | Returns a passage for a quiz (biased toward least-recently-quizzed) |
| `POST` | `/api/quiz/result` | Record a quiz verdict `{ "history_id", "passed" }` |

### Difficulty levels

| Value | Level | Description |
|-------|-------|-------------|
| `1` | Beginner | A1/A2 — simple present tense, everyday vocabulary, ~30–45 words |
| `2` | Intermediate | B1 — mixed tenses, natural flow, ~45–60 words |
| `3` | Advanced | B2/C1 — subjunctive, conditionals, idioms, ~60–80 words |

---

## Configuration reference

| Field | Default | Description |
|-------|---------|-------------|
| `server_port` | `8080` | HTTP port to listen on |
| `language` | `Spanish` | Default study language |
| `llm_provider` | `ollama` | `ollama` or `openai` |
| `llm_endpoint` | `http://localhost:11434` | Base URL of the LLM API |
| `llm_model` | `gemma3:4b` | Model name |
| `llm_api_key` | _(empty)_ | API key (required for OpenAI) |

Config lives at `~/.linguapi/config.json`. All fields can be changed live from the Settings modal.

---

## Offline corpus (recommended)

The "Novels & Literature" category fetches books from Project Gutenberg at runtime by default. For faster, fully-offline generation with much more variety, download a local corpus first:

```bash
# macOS / Linux — all supported languages (default: 50 books each)
bash scripts/download-corpus.sh

# Specific languages only
bash scripts/download-corpus.sh Spanish German French

# More books
BOOKS_PER_LANG=200 bash scripts/download-corpus.sh Spanish
```

```powershell
# Windows
.\scripts\download-corpus.ps1
.\scripts\download-corpus.ps1 Spanish German
.\scripts\download-corpus.ps1 -BooksPerLang 200 Spanish
```

Books are stored in `~/.linguapi/corpus/{lang_code}/pg{id}.txt`. Once present, LinguaPi automatically prefers local files and picks a random passage from anywhere in the full book text — much more variety than live fetches, which are limited to the opening chapters due to bandwidth constraints. The internet fallback remains active for languages without a local corpus.

Re-run the script whenever you want fresher content. Already-downloaded books are skipped automatically; use `--force` / `-Force` to re-download everything.

---

## Data storage

All data is stored in `~/.linguapi/`:

```
~/.linguapi/
├── config.json       # your configuration
└── linguapi.db       # SQLite database (history + quiz results)
```

### Database schema

**`history`** — every generated passage:

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | auto-increment |
| `title` | TEXT | short English title |
| `text` | TEXT UNIQUE | native-script passage |
| `transliteration` | TEXT | phonetic romanization (non-Latin scripts) |
| `translation` | TEXT | English translation |
| `category` | TEXT | story / culture / novel / news |
| `language` | TEXT | e.g. Spanish |
| `difficulty` | INTEGER | 1 / 2 / 3 |
| `created_at` | DATETIME | UTC |

**`quiz_results`** — quiz attempts:

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | |
| `history_id` | INTEGER FK | references `history.id` |
| `passed` | BOOLEAN | |
| `attempted_at` | DATETIME | UTC |

If you have an existing `history.json` from an earlier version, it is automatically migrated to SQLite on first run and renamed to `history.json.bak`.

---

## Raspberry Pi notes

The easiest path is to download the `linux-arm64` binary from the releases page and run the one-liner installer on the Pi itself.

If you prefer to build from source, the project uses `modernc.org/sqlite` — a pure Go SQLite driver that requires no CGO and cross-compiles cleanly:

```bash
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o lingua-pi
scp lingua-pi pi@raspberrypi.local:~/
scp -r static pi@raspberrypi.local:~/
```

To run on boot, create a systemd service at `/etc/systemd/system/linguapi.service`:

```ini
[Unit]
Description=LinguaPi
After=network.target

[Service]
ExecStart=/home/pi/lingua-pi
WorkingDirectory=/home/pi
Restart=on-failure
User=pi

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now linguapi
```

---

## License

MIT
