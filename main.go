package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	// Load config from home dot folder
	err := LoadConfig()
	if err != nil {
		log.Fatalf("Error loading configuration: %v", err)
	}

	// Validate LLM connection on startup
	log.Printf("Validating LLM connection...")
	health := CheckLLMHealth()
	if health.Status != "ok" {
		log.Printf("⚠️  WARNING: LLM connection check failed: %s", health.Message)
		log.Printf("   Suggestion: %s", health.Suggestion)
		log.Printf("   The server will start, but generating content will fail until this is resolved.")
	} else {
		log.Printf("✓ LLM connection verified: %s (%s)", health.Provider, health.Model)
	}

	RegisterRoutes()

	addr := fmt.Sprintf(":%d", CurrentConfig.ServerPort)
	log.Printf("Starting LinguaPi server on %s", addr)
	log.Printf("Point your browser to http://localhost%s", addr)

	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
