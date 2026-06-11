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
	http.HandleFunc("/api/health", handleHealth)
	http.HandleFunc("/api/register", handleRegister)
	http.HandleFunc("/api/login", handleLogin)
	http.HandleFunc("/api/logout", handleLogout)
	http.HandleFunc("/api/me", handleMe)
	http.HandleFunc("/api/config", requireAuth(handleConfig))
	http.HandleFunc("/api/models", requireAuth(handleGetModels))
	http.HandleFunc("/api/generate", requireAuth(handleGenerate))
	http.HandleFunc("/api/analyze", requireAuth(handleAnalyze))
	http.HandleFunc("/api/history", requireAuth(handleGetHistory))
	http.HandleFunc("/api/quiz", requireAuth(handleQuiz))
	http.HandleFunc("/api/quiz/result", requireAuth(handleQuizResult))
	http.HandleFunc("/api/preferences", requireAuth(handlePreferences))
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
			"has_api_key":  CurrentConfig.LlmApiKey != "",
		})
		return
	}

	if r.Method == http.MethodPost {
		var body struct {
			Model    string `json:"model"`
			Provider string `json:"provider"`
			Endpoint string `json:"endpoint"`
			ApiKey   string `json:"api_key"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "Bad request: invalid JSON.", http.StatusBadRequest)
			return
		}

		if body.Model != "" {
			CurrentConfig.LlmModel = body.Model
		}
		if body.Provider != "" {
			CurrentConfig.LlmProvider = body.Provider
		}
		if body.Endpoint != "" {
			CurrentConfig.LlmEndpoint = body.Endpoint
		}
		if body.ApiKey != "" {
			CurrentConfig.LlmApiKey = body.ApiKey
		}

		if err := SaveConfig(); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		log.Printf("Config updated: provider=%s model=%s endpoint=%s",
			CurrentConfig.LlmProvider, CurrentConfig.LlmModel, CurrentConfig.LlmEndpoint)

		// Return fresh health status so the UI can react immediately
		health := CheckLLMHealth()
		json.NewEncoder(w).Encode(map[string]interface{}{
			"model":    CurrentConfig.LlmModel,
			"provider": CurrentConfig.LlmProvider,
			"health":   health,
		})
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

	history, err := GetHistory(userIDFromRequest(r))
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

	if err = AddHistory(userIDFromRequest(r), result.Text, result.Transliteration, result.Translation, result.Title, result.Category, req.Language, int(req.Difficulty)); err != nil {
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

	if cached, ok := getCachedAnalysis(req.Text, req.Language, req.Context); ok {
		log.Printf("Cache hit for '%s' in %s", req.Text, req.Language)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(cached)
		return
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

	setCachedAnalysis(req.Text, req.Language, req.Context, result)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func handleQuiz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	passage, err := GetQuizPassage(userIDFromRequest(r))
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "No history available for quiz yet."})
		return
	}
	json.NewEncoder(w).Encode(passage)
}

func handlePreferences(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	userID := userIDFromRequest(r)

	if r.Method == http.MethodGet {
		language, difficulty, err := GetUserPreferences(userID)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(map[string]interface{}{"language": language, "difficulty": difficulty})
		return
	}

	if r.Method == http.MethodPost {
		var body struct {
			Language   string `json:"language"`
			Difficulty int    `json:"difficulty"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Language == "" {
			http.Error(w, "Bad request", http.StatusBadRequest)
			return
		}
		if err := SetUserPreferences(userID, body.Language, body.Difficulty); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		return
	}

	http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
}

func handleQuizResult(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var body struct {
		HistoryID int64 `json:"history_id"`
		Passed    bool  `json:"passed"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.HistoryID == 0 {
		http.Error(w, "Bad request. 'history_id' is required.", http.StatusBadRequest)
		return
	}

	if err := RecordQuizResult(body.HistoryID, body.Passed); err != nil {
		log.Printf("Error recording quiz result: %v", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"ok": true})
}
