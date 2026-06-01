package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type HistoryEntry struct {
	Title           string    `json:"title"`
	Text            string    `json:"text"`
	Transliteration string    `json:"transliteration,omitempty"`
	Translation     string    `json:"translation"`
	Category        string    `json:"category"`
	Timestamp       time.Time `json:"timestamp"`
}

var historyMutex sync.Mutex

// GetHistoryPath returns the path to ~/.linguapi/history.json
func GetHistoryPath() (string, error) {
	dir, err := GetConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "history.json"), nil
}

// GetHistory reads the history from ~/.linguapi/history.json
func GetHistory() ([]HistoryEntry, error) {
	historyMutex.Lock()
	defer historyMutex.Unlock()

	historyPath, err := GetHistoryPath()
	if err != nil {
		return nil, err
	}

	// Return empty list if history.json does not exist
	if _, err := os.Stat(historyPath); os.IsNotExist(err) {
		return []HistoryEntry{}, nil
	}

	bytes, err := os.ReadFile(historyPath)
	if err != nil {
		return nil, err
	}

	var history []HistoryEntry
	if err := json.Unmarshal(bytes, &history); err != nil {
		return nil, err
	}

	return history, nil
}

// AddHistory prepends a new entry to ~/.linguapi/history.json
func AddHistory(text, transliteration, translation, title, category string) error {
	historyMutex.Lock()
	defer historyMutex.Unlock()

	historyPath, err := GetHistoryPath()
	if err != nil {
		return err
	}

	var history []HistoryEntry

	// Read existing history if file exists
	if _, err := os.Stat(historyPath); !os.IsNotExist(err) {
		bytes, err := os.ReadFile(historyPath)
		if err == nil {
			_ = json.Unmarshal(bytes, &history)
		}
	}

	// Create new entry
	entry := HistoryEntry{
		Title:           title,
		Text:            text,
		Transliteration: transliteration,
		Translation:     translation,
		Category:        category,
		Timestamp:       time.Now(),
	}

	// Check if this text snippet already exists to avoid duplicates
	for _, h := range history {
		if h.Text == text {
			return nil // Duplicate, skip adding
		}
	}

	// Prepend to history list
	history = append([]HistoryEntry{entry}, history...)

	// Cap history list at 25 entries
	if len(history) > 25 {
		history = history[:25]
	}

	// Write back to file
	bytes, err := json.MarshalIndent(history, "", "  ")
	if err != nil {
		return err
	}

	err = os.WriteFile(historyPath, bytes, 0644)
	if err != nil {
		log.Printf("Failed to write history file to %s: %v", historyPath, err)
		return err
	}

	log.Printf("Appended new learning card history to %s", historyPath)
	return nil
}
