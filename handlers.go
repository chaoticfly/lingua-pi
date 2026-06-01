package main

import (
	"encoding/json"
	"log"
	"net/http"
	"path/filepath"
)

type GenerateRequest struct {
	Category   string          `json:"category"`
	Language   string          `json:"language"`
	Difficulty DifficultyLevel `json:"difficulty"`
}

type AnalyzeRequest struct {
	Text     string `json:"text"`
	Context  string `json:"context"`
	Language string `json:"language"`
}

func RegisterRoutes() {
	fs := http.FileServer(http.Dir("static"))
	http.Handle("/static/", http.StripPrefix("/static/", fs))

	http.HandleFunc("/", serveIndex)
	http.HandleFunc("/api/config", handleConfig)
	http.HandleFunc("/api/models", handleGetModels)
	http.HandleFunc("/api/health", handleHealth)
	http.HandleFunc("/api/generate", handleGenerate)
	http.HandleFunc("/api/analyze", handleAnalyze)
	http.HandleFunc("/api/history", handleGetHistory)
}

func serveIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, filepath.Join("static", "index.html"))
}

func handleConfig(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodGet {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"language":     CurrentConfig.Language,
			"llm_provider": CurrentConfig.LlmProvider,
			"llm_model":    CurrentConfig.LlmModel,
			"llm_endpoint": CurrentConfig.LlmEndpoint,
		})
		return
	}

	if r.Method == http.MethodPost {
		var body struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Model == "" {
			http.Error(w, "Bad request. 'model' field is required.", http.StatusBadRequest)
			return
		}

		CurrentConfig.LlmModel = body.Model
		if err := SaveConfig(); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		log.Printf("Model updated to: %s", body.Model)
		json.NewEncoder(w).Encode(map[string]string{"model": body.Model})
		return
	}

	http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
}

func handleGetModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	models, err := ListAvailableModels()
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	json.NewEncoder(w).Encode(models)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	health := CheckLLMHealth()
	w.Header().Set("Content-Type", "application/json")

	if health.Status != "ok" {
		w.WriteHeader(http.StatusServiceUnavailable)
	}

	json.NewEncoder(w).Encode(health)
}

func handleGetHistory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	history, err := GetHistory()
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(history)
}

func handleGenerate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req GenerateRequest
	_ = json.NewDecoder(r.Body).Decode(&req)

	if req.Language == "" {
		req.Language = CurrentConfig.Language
	}
	if req.Category == "" {
		req.Category = "random"
	}

	log.Printf("Request to generate paragraph for category: %s, language: %s, difficulty: %d", req.Category, req.Language, req.Difficulty)
	result, err := GenerateParagraph(req.Category, req.Language, req.Difficulty)
	if err != nil {
		log.Printf("Error generating paragraph: %v", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	// Save to backend JSON history file
	err = AddHistory(result.Text, result.Transliteration, result.Translation, result.Title, result.Category)
	if err != nil {
		log.Printf("Error adding history: %v", err)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func handleAnalyze(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req AnalyzeRequest
	err := json.NewDecoder(r.Body).Decode(&req)
	if err != nil || req.Text == "" || req.Context == "" {
		http.Error(w, "Bad request. 'text' and 'context' fields are required.", http.StatusBadRequest)
		return
	}

	if req.Language == "" {
		req.Language = CurrentConfig.Language
	}

	log.Printf("Request to analyze word/phrase: '%s' in %s", req.Text, req.Language)
	result, err := AnalyzeText(req.Text, req.Context, req.Language)
	if err != nil {
		log.Printf("Error analyzing text: %v", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}
