package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

var DB *sql.DB

func InitDB() error {
	dir, err := GetConfigDir()
	if err != nil {
		return err
	}

	dbPath := filepath.Join(dir, "linguapi.db")
	db, err := sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_foreign_keys=on")
	if err != nil {
		return err
	}
	DB = db

	if err := createTables(); err != nil {
		return err
	}

	migrateHistoryJSON(dir)
	return nil
}

func createTables() error {
	_, err := DB.Exec(`
		CREATE TABLE IF NOT EXISTS users (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			username      TEXT    NOT NULL UNIQUE,
			password_hash TEXT    NOT NULL,
			created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);

		CREATE TABLE IF NOT EXISTS sessions (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			token      TEXT    NOT NULL UNIQUE,
			user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			expires_at DATETIME NOT NULL,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);

		CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token);

		CREATE TABLE IF NOT EXISTS history (
			id              INTEGER PRIMARY KEY AUTOINCREMENT,
			title           TEXT    NOT NULL,
			text            TEXT    NOT NULL UNIQUE,
			transliteration TEXT    NOT NULL DEFAULT '',
			translation     TEXT    NOT NULL,
			category        TEXT    NOT NULL DEFAULT '',
			language        TEXT    NOT NULL DEFAULT '',
			difficulty      INTEGER NOT NULL DEFAULT 2,
			created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);

		CREATE TABLE IF NOT EXISTS quiz_results (
			id          INTEGER PRIMARY KEY AUTOINCREMENT,
			history_id  INTEGER NOT NULL REFERENCES history(id) ON DELETE CASCADE,
			passed      INTEGER NOT NULL DEFAULT 0,
			attempted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);

		CREATE INDEX IF NOT EXISTS idx_history_created   ON history(created_at DESC);
		CREATE INDEX IF NOT EXISTS idx_quiz_history_id   ON quiz_results(history_id);
	`)
	return err
}

// migrateHistoryJSON moves history.json into SQLite once and renames the file.
func migrateHistoryJSON(dir string) {
	jsonPath := filepath.Join(dir, "history.json")
	if _, err := os.Stat(jsonPath); os.IsNotExist(err) {
		return
	}

	data, err := os.ReadFile(jsonPath)
	if err != nil {
		log.Printf("Migration: could not read history.json: %v", err)
		return
	}

	var entries []struct {
		Title           string    `json:"title"`
		Text            string    `json:"text"`
		Transliteration string    `json:"transliteration"`
		Translation     string    `json:"translation"`
		Category        string    `json:"category"`
		Timestamp       time.Time `json:"timestamp"`
	}
	if err := json.Unmarshal(data, &entries); err != nil {
		log.Printf("Migration: could not parse history.json: %v", err)
		return
	}

	inserted := 0
	for _, e := range entries {
		_, err := DB.Exec(`
			INSERT OR IGNORE INTO history (title, text, transliteration, translation, category, created_at)
			VALUES (?, ?, ?, ?, ?, ?)`,
			e.Title, e.Text, e.Transliteration, e.Translation, e.Category, e.Timestamp)
		if err == nil {
			inserted++
		}
	}

	os.Rename(jsonPath, jsonPath+".bak")
	log.Printf("Migration: imported %d entries from history.json → SQLite (backup at history.json.bak)", inserted)
}

// --- History ---

type HistoryEntry struct {
	ID              int64     `json:"id"`
	Title           string    `json:"title"`
	Text            string    `json:"text"`
	Transliteration string    `json:"transliteration,omitempty"`
	Translation     string    `json:"translation"`
	Category        string    `json:"category"`
	Language        string    `json:"language"`
	Difficulty      int       `json:"difficulty"`
	CreatedAt       time.Time `json:"created_at"`
}

func GetHistory() ([]HistoryEntry, error) {
	rows, err := DB.Query(`
		SELECT id, title, text, transliteration, translation, category, language, difficulty, created_at
		FROM history ORDER BY created_at DESC LIMIT 25`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var entries []HistoryEntry
	for rows.Next() {
		var e HistoryEntry
		if err := rows.Scan(&e.ID, &e.Title, &e.Text, &e.Transliteration,
			&e.Translation, &e.Category, &e.Language, &e.Difficulty, &e.CreatedAt); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func AddHistory(text, transliteration, translation, title, category, language string, difficulty int) error {
	_, err := DB.Exec(`
		INSERT OR IGNORE INTO history (title, text, transliteration, translation, category, language, difficulty)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		title, text, transliteration, translation, category, language, difficulty)
	return err
}

// --- Quiz ---

// GetQuizPassage returns a random history entry, biased toward those least recently quizzed.
func GetQuizPassage() (*HistoryEntry, error) {
	var e HistoryEntry
	err := DB.QueryRow(`
		SELECT h.id, h.title, h.text, h.transliteration, h.translation, h.category, h.language, h.difficulty, h.created_at
		FROM history h
		LEFT JOIN (
			SELECT history_id, MAX(attempted_at) AS last_quiz
			FROM quiz_results GROUP BY history_id
		) q ON h.id = q.history_id
		ORDER BY COALESCE(q.last_quiz, '1970-01-01') ASC, RANDOM()
		LIMIT 1`).Scan(
		&e.ID, &e.Title, &e.Text, &e.Transliteration, &e.Translation,
		&e.Category, &e.Language, &e.Difficulty, &e.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &e, nil
}

func RecordQuizResult(historyID int64, passed bool) error {
	passedInt := 0
	if passed {
		passedInt = 1
	}
	_, err := DB.Exec(
		`INSERT INTO quiz_results (history_id, passed) VALUES (?, ?)`,
		historyID, passedInt)
	return err
}
