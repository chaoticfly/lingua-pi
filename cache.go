package main

import (
	"crypto/sha256"
	"fmt"
	"sync"
)

var analysisCache struct {
	mu      sync.RWMutex
	entries map[string]*AnalysisResult
}

func init() {
	analysisCache.entries = make(map[string]*AnalysisResult)
}

func analysisCacheKey(text, language, context string) string {
	h := sha256.Sum256([]byte(language + "\x00" + text + "\x00" + context))
	return fmt.Sprintf("%x", h)
}

func getCachedAnalysis(text, language, context string) (*AnalysisResult, bool) {
	key := analysisCacheKey(text, language, context)
	analysisCache.mu.RLock()
	result, ok := analysisCache.entries[key]
	analysisCache.mu.RUnlock()
	return result, ok
}

func setCachedAnalysis(text, language, context string, result *AnalysisResult) {
	key := analysisCacheKey(text, language, context)
	analysisCache.mu.Lock()
	analysisCache.entries[key] = result
	analysisCache.mu.Unlock()
}
