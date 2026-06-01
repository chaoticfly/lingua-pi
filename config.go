package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
)

type Config struct {
	ServerPort  int    `json:"server_port"`
	Language    string `json:"language"`
	LlmProvider string `json:"llm_provider"` // "ollama" or "openai"
	LlmEndpoint string `json:"llm_endpoint"`
	LlmModel    string `json:"llm_model"`
	LlmApiKey   string `json:"llm_api_key"`
}

var CurrentConfig Config

// GetConfigDir returns the path to the ~/.linguapi directory, creating it if it doesn't exist
func GetConfigDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".linguapi")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	return dir, nil
}

// LoadConfig loads config from the home directory dot folder
func LoadConfig() error {
	dir, err := GetConfigDir()
	if err != nil {
		return err
	}

	configPath := filepath.Join(dir, "config.json")

	// If config.json doesn't exist, create it with default values
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		log.Printf("config.json not found in %s, creating default configuration", dir)
		defaultConfig := Config{
			ServerPort:  8080,
			Language:    "Spanish",
			LlmProvider: "ollama",
			LlmEndpoint: "http://localhost:11434",
			LlmModel:    "gemma4:e4b",
			LlmApiKey:   "",
		}
		
		bytes, err := json.MarshalIndent(defaultConfig, "", "  ")
		if err != nil {
			return err
		}

		if err := os.WriteFile(configPath, bytes, 0644); err != nil {
			return err
		}
		CurrentConfig = defaultConfig
	} else {
		// Read existing config.json
		bytes, err := os.ReadFile(configPath)
		if err != nil {
			return err
		}

		err = json.Unmarshal(bytes, &CurrentConfig)
		if err != nil {
			return err
		}
	}

	// Validate and fallback defaults
	if CurrentConfig.ServerPort == 0 {
		CurrentConfig.ServerPort = 8080
	}
	if CurrentConfig.Language == "" {
		CurrentConfig.Language = "Spanish"
	}
	if CurrentConfig.LlmProvider == "" {
		CurrentConfig.LlmProvider = "ollama"
	}
	if CurrentConfig.LlmEndpoint == "" {
		if CurrentConfig.LlmProvider == "ollama" {
			CurrentConfig.LlmEndpoint = "http://localhost:11434"
		} else {
			CurrentConfig.LlmEndpoint = "https://api.openai.com/v1"
		}
	}
	if CurrentConfig.LlmModel == "" {
		if CurrentConfig.LlmProvider == "ollama" {
			CurrentConfig.LlmModel = "gemma4:e4b"
		} else {
			CurrentConfig.LlmModel = "gpt-4o-mini"
		}
	}

	log.Printf("Loaded config from %s: Port=%d, DefaultLang=%s, Provider=%s, Model=%s",
		configPath, CurrentConfig.ServerPort, CurrentConfig.Language, CurrentConfig.LlmProvider, CurrentConfig.LlmModel)
	return nil
}

// SaveConfig writes the current in-memory config back to ~/.linguapi/config.json
func SaveConfig() error {
	dir, err := GetConfigDir()
	if err != nil {
		return err
	}
	configPath := filepath.Join(dir, "config.json")
	bytes, err := json.MarshalIndent(CurrentConfig, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(configPath, bytes, 0644)
}
