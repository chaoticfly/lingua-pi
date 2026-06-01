# व्यं LinguaPi

A self-hosted language learning web app designed for Raspberry Pi (and any machine running Go). Generates reading passages using a local or remote LLM, lets you click any word for instant grammar breakdown, and tracks your study history — all without sending data to the cloud.

---

## Features

- **Passage generation** — short reading texts at Beginner / Intermediate / Advanced difficulty, across categories (stories, news, culture, literature)
- **Grammar analyzer** — click any word or select a phrase to get translation, part of speech, tense/conjugation, synonyms, and example sentences
- **Multi-language** — Spanish, German, Portuguese, Italian, Kannada, Telugu (non-Latin scripts include romanized transliteration)
- **TTS playback** — uses the browser's Speech Synthesis API with per-language voice selection and speed control
- **Study history** — last 25 generated passages stored locally in `~/.linguapi/history.json`
- **Model selector** — switch between installed Ollama models (or OpenAI models) from the UI without restarting
- **Dark / light mode** — persisted across sessions
- **Ollama health check** — verifies the LLM connection on startup and exposes `/api/health`

---

## Requirements

- [Go 1.22+](https://go.dev/dl/)
- [Ollama](https://ollama.com/) running locally **or** an OpenAI-compatible API key

---

## Quick Start

### 1. Clone

```bash
git clone <your-repo-url>
cd lingua-pi
```

### 2. Configure

Copy the example config to `~/.linguapi/config.json` (created automatically on first run if missing):

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

For OpenAI:

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
| `POST` | `/api/config` | Updates the active model `{ "model": "..." }` |
| `GET` | `/api/models` | Lists available models from the provider |
| `GET` | `/api/health` | LLM connection status |
| `POST` | `/api/generate` | Generate a passage `{ "category", "language", "difficulty" }` |
| `POST` | `/api/analyze` | Analyze a word/phrase `{ "text", "context", "language" }` |
| `GET` | `/api/history` | Returns the last 25 study entries |

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

Config lives at `~/.linguapi/config.json`. The model can also be changed live from the UI.

---

## Data storage

All data is stored in `~/.linguapi/`:

```
~/.linguapi/
├── config.json      # your configuration
└── history.json     # study history (up to 25 entries)
```

---

## Raspberry Pi notes

Build on your dev machine for ARM and copy the binary:

```bash
GOOS=linux GOARCH=arm64 go build -o lingua-pi
scp lingua-pi pi@raspberrypi.local:~/
```

To run on boot, create a systemd service:

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
sudo cp linguapi.service /etc/systemd/system/
sudo systemctl enable --now linguapi
```

---

## License

MIT
