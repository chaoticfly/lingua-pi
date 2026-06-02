package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Ollama request/response structs
type OllamaChatRequest struct {
	Model    string        `json:"model"`
	Messages []ChatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
	Format   string        `json:"format,omitempty"` // "json"
}

type OllamaChatResponse struct {
	Message ChatMessage `json:"message"`
}

// OpenAI request/response structs
type OpenAIResponseFormat struct {
	Type string `json:"type"` // "json_object"
}

type OpenAIChatRequest struct {
	Model          string                `json:"model"`
	Messages       []ChatMessage         `json:"messages"`
	Stream         bool                  `json:"stream"`
	ResponseFormat *OpenAIResponseFormat `json:"response_format,omitempty"`
}

type OpenAIChatChoice struct {
	Message ChatMessage `json:"message"`
}

type OpenAIChatResponse struct {
	Choices []OpenAIChatChoice `json:"choices"`
}

// Result structs for backend handlers
type ParagraphResult struct {
	Text            string `json:"text"`
	Transliteration string `json:"transliteration"` // Added for non-latin transliterations
	Translation     string `json:"translation"`
	Title           string `json:"title"`
	Category        string `json:"category"`
}

type UsageExample struct {
	Original    string `json:"original"`
	Translation string `json:"translation"`
}

type ConjugationForm struct {
	Person string `json:"person"`
	Form   string `json:"form"`
}

type ConjugationTense struct {
	Tense string             `json:"tense"`
	Forms []ConjugationForm  `json:"forms"`
}

type AnalysisResult struct {
	WordOrPhrase       string             `json:"word_or_phrase"`
	Translation        string             `json:"translation"`
	PartOfSpeech       string             `json:"part_of_speech"`
	Definition         string             `json:"definition"`
	TenseOrConjugation string             `json:"tense_or_conjugation"`
	Synonyms           []string           `json:"synonyms"`
	Usages             []UsageExample     `json:"usages"`
	ConjugationTable   []ConjugationTense `json:"conjugation_table"`
}

// CallLLM performs the actual HTTP request to the LLM backend
func CallLLM(systemPrompt, userPrompt string, forceJSON bool) (string, error) {
	var requestBody []byte
	var apiURL string
	var err error

	client := &http.Client{
		Timeout: 45 * time.Second,
	}

	messages := []ChatMessage{
		{Role: "system", Content: systemPrompt},
		{Role: "user", Content: userPrompt},
	}

	if CurrentConfig.LlmProvider == "ollama" {
		apiURL = strings.TrimSuffix(CurrentConfig.LlmEndpoint, "/") + "/api/chat"
		reqPayload := OllamaChatRequest{
			Model:    CurrentConfig.LlmModel,
			Messages: messages,
			Stream:   false,
		}
		if forceJSON {
			reqPayload.Format = "json"
		}
		requestBody, err = json.Marshal(reqPayload)
	} else {
		// OpenAI compatible provider
		apiURL = strings.TrimSuffix(CurrentConfig.LlmEndpoint, "/") + "/chat/completions"
		reqPayload := OpenAIChatRequest{
			Model:    CurrentConfig.LlmModel,
			Messages: messages,
			Stream:   false,
		}
		if forceJSON {
			reqPayload.ResponseFormat = &OpenAIResponseFormat{Type: "json_object"}
		}
		requestBody, err = json.Marshal(reqPayload)
	}

	if err != nil {
		return "", fmt.Errorf("failed to marshal request: %v", err)
	}

	req, err := http.NewRequest("POST", apiURL, bytes.NewBuffer(requestBody))
	if err != nil {
		return "", fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if CurrentConfig.LlmProvider == "openai" && CurrentConfig.LlmApiKey != "" {
		req.Header.Set("Authorization", "Bearer "+CurrentConfig.LlmApiKey)
	}

	log.Printf("Calling LLM API at: %s using model: %s", apiURL, CurrentConfig.LlmModel)
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("HTTP request failed: %v", err)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("LLM API returned status %d: %s", resp.StatusCode, string(respBytes))
	}

	var content string
	if CurrentConfig.LlmProvider == "ollama" {
		var ollamaResp OllamaChatResponse
		if err := json.Unmarshal(respBytes, &ollamaResp); err != nil {
			return "", fmt.Errorf("failed to parse Ollama response: %v, raw: %s", err, string(respBytes))
		}
		content = ollamaResp.Message.Content
	} else {
		var openaiResp OpenAIChatResponse
		if err := json.Unmarshal(respBytes, &openaiResp); err != nil {
			return "", fmt.Errorf("failed to parse OpenAI response: %v, raw: %s", err, string(respBytes))
		}
		if len(openaiResp.Choices) == 0 {
			return "", fmt.Errorf("OpenAI API returned 0 choices: %s", string(respBytes))
		}
		content = openaiResp.Choices[0].Message.Content
	}

	return content, nil
}

type DifficultyLevel int

const (
	Beginner     DifficultyLevel = 1
	Intermediate DifficultyLevel = 2
	Advanced     DifficultyLevel = 3
)

func difficultyGuidelines(level DifficultyLevel) string {
	switch level {
	case Beginner:
		return `Difficulty: BEGINNER.
- Use only the most common, everyday vocabulary (A1-A2 level).
- Write very short, simple sentences in present tense only.
- Avoid all complex grammar: no subjunctive, no conditional, no passive voice.
- Prefer direct subject-verb-object structure throughout.
- Approx 30-45 words total.`
	case Advanced:
		return `Difficulty: ADVANCED.
- Use rich, varied vocabulary including idiomatic expressions and nuanced terms (B2-C1 level).
- Employ complex grammar: subjunctive mood, conditional clauses, passive constructions, relative clauses.
- Vary sentence length and structure; mix compound and complex sentences.
- Approx 60-80 words total.`
	default: // Intermediate
		return `Difficulty: INTERMEDIATE.
- Use a mix of common and moderately advanced vocabulary (B1 level).
- Use a variety of tenses (past, present, future) with natural flow.
- Include some subordinate clauses but avoid advanced subjunctive or complex conditionals.
- Approx 45-60 words total.`
	}
}

// GenerateParagraph generates a random text paragraph in the target language and translates it
func GenerateParagraph(category, language string, difficulty DifficultyLevel) (*ParagraphResult, error) {
	if language == "" {
		language = CurrentConfig.Language
	}

	if category == "" || category == "random" {
		categories := []string{"stories", "culture", "novels", "news"}
		idx := time.Now().UnixNano() % int64(len(categories))
		category = categories[idx]
	}

	if difficulty < Beginner || difficulty > Advanced {
		difficulty = Intermediate
	}

	// Dynamic instruction for non-Latin script languages (Kannada, Telugu)
	isNonLatin := strings.ToLower(language) == "kannada" || strings.ToLower(language) == "telugu"

	systemPrompt := fmt.Sprintf(`You are an expert language teacher specializing in teaching %s to English speakers.
Your job is to generate a short learning passage in the native script.
You MUST respond with a valid JSON object only. Do NOT include markdown code blocks.
JSON structure:
{
  "text": "The %s text in the native script (using proper characters).",
  "transliteration": "Phonetic transliteration of the text using English characters so English speakers can read the pronunciation. IMPORTANT: ONLY write this transliteration if the target language uses a non-Latin script (like Kannada or Telugu). For Latin-script languages (German, Spanish, Portuguese, Italian), leave this field empty \"\".",
  "translation": "Accurate, natural English translation",
  "title": "A short descriptive title in English",
  "category": "The category of the text (e.g. story, culture, novel, news)"
}`, language, language)

	userPrompt := fmt.Sprintf(`Generate a reading paragraph in %s from the "%s" category.
Guidelines:
1. %s
2. Make sure the content is interesting and culturally relevant.
3. Output MUST be formatted as a single JSON object.`, language, category, difficultyGuidelines(difficulty))

	if isNonLatin {
		userPrompt += fmt.Sprintf("\n4. Since %s is a non-Latin script, make sure to fill the 'transliteration' field with the exact phonetic English pronunciation of the text.", language)
	}

	content, err := CallLLM(systemPrompt, userPrompt, true)
	if err != nil {
		return nil, err
	}

	content = cleanJSONString(content)

	var result ParagraphResult
	if err := json.Unmarshal([]byte(content), &result); err != nil {
		return nil, fmt.Errorf("failed to unmarshal paragraph JSON: %v, response content: %s", err, content)
	}

	return &result, nil
}

// AnalyzeText performs word/phrase breakdown using the context paragraph
func AnalyzeText(selectedText, contextText, language string) (*AnalysisResult, error) {
	if language == "" {
		language = CurrentConfig.Language
	}

	systemPrompt := fmt.Sprintf(`You are a helpful %s language dictionary and grammar assistant.
Analyze the selected word or phrase in the context of the paragraph provided.
Important: The user may select either the native script form of the word, or the romanized (transliterated phonetic English) spelling of the word. You must identify which was clicked, map them correctly, and perform the breakdown.
You MUST respond with a valid JSON object only. Do NOT include markdown code blocks.
JSON structure:
{
  "word_or_phrase": "The analyzed word/phrase in its native script form",
  "translation": "Direct English translation in this specific context",
  "part_of_speech": "noun, verb, adjective, preposition, phrase, etc.",
  "definition": "Detailed explanation of meaning, nuance, and usage in English. If the input was a transliterated word, also explain its spelling in the native script.",
  "tense_or_conjugation": "If it is a verb: detail its infinitive, tense, mood, and subject (e.g. Present Subjunctive, 3rd Person Plural, infinitive: speak/hable/etc.). For nouns: mention gender, count or other traits. Otherwise, leave blank or write 'N/A'.",
  "synonyms": ["synonym_1_native", "synonym_2_native"],
  "usages": [
    {
      "original": "A simple sentence using the word in its native script (with its English transliteration in parentheses if it is a non-Latin script language like Kannada or Telugu)",
      "translation": "The English translation of that sentence"
    },
    {
      "original": "Another simple sentence using the word in its native script (with its English transliteration in parentheses if it is a non-Latin script language like Kannada or Telugu)",
      "translation": "The English translation of that sentence"
    }
  ],
  "conjugation_table": [
    {
      "tense": "Tense name in English (e.g. Present, Preterite, Imperfect, Future, Conditional, Present Subjunctive)",
      "forms": [
        {"person": "pronoun in %s", "form": "conjugated verb form in native script"}
      ]
    }
  ]
}
CONJUGATION RULES:
- Only populate conjugation_table when part_of_speech is a verb. For all other parts of speech return "conjugation_table": [].
- Include the 6 most pedagogically useful tenses for the language (e.g. for Spanish: Present, Preterite, Imperfect, Future, Conditional, Present Subjunctive).
- Always conjugate the infinitive of the verb, not the inflected form.
- Use the correct subject pronouns for %s (e.g. Spanish: yo/tú/él/nosotros/vosotros/ellos, German: ich/du/er/wir/ihr/sie, Italian: io/tu/lui/noi/voi/loro).
- Each tense must have exactly one entry per grammatical person.`, language, language, language)

	userPrompt := fmt.Sprintf(`Selected Text (could be native script or transliterated romanized text): "%s"
Context Paragraph: "%s"

Analyze the selected text relative to its context. Return the JSON response.`, selectedText, contextText)

	content, err := CallLLM(systemPrompt, userPrompt, true)
	if err != nil {
		return nil, err
	}

	content = cleanJSONString(content)

	var result AnalysisResult
	if err := json.Unmarshal([]byte(content), &result); err != nil {
		return nil, fmt.Errorf("failed to unmarshal analysis JSON: %v, response content: %s", err, content)
	}

	return &result, nil
}

// ListAvailableModels returns the models available from the configured provider
func ListAvailableModels() ([]string, error) {
	client := &http.Client{Timeout: 5 * time.Second}

	if CurrentConfig.LlmProvider == "ollama" {
		resp, err := client.Get(strings.TrimSuffix(CurrentConfig.LlmEndpoint, "/") + "/api/tags")
		if err != nil {
			return nil, fmt.Errorf("cannot reach Ollama at %s: %v", CurrentConfig.LlmEndpoint, err)
		}
		defer resp.Body.Close()

		var body struct {
			Models []struct {
				Name string `json:"name"`
			} `json:"models"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return nil, fmt.Errorf("failed to parse Ollama model list: %v", err)
		}

		names := make([]string, len(body.Models))
		for i, m := range body.Models {
			names[i] = m.Name
		}
		return names, nil
	}

	// For OpenAI-compatible providers return a fixed set of common models
	return []string{
		"gpt-4o",
		"gpt-4o-mini",
		"gpt-4-turbo",
		"gpt-3.5-turbo",
	}, nil
}

// HealthCheckResult contains the status of the LLM connection
type HealthCheckResult struct {
	Status     string `json:"status"`      // "ok" or "error"
	Provider   string `json:"provider"`    // "ollama" or "openai"
	Model      string `json:"model"`
	Message    string `json:"message"`     // Error details if status is "error"
	Suggestion string `json:"suggestion"` // What to fix
}

// CheckLLMHealth verifies the LLM connection is working
func CheckLLMHealth() *HealthCheckResult {
	client := &http.Client{
		Timeout: 5 * time.Second,
	}

	if CurrentConfig.LlmProvider == "ollama" {
		// Check if Ollama is running
		ollamaURL := strings.TrimSuffix(CurrentConfig.LlmEndpoint, "/") + "/api/tags"
		resp, err := client.Get(ollamaURL)
		if err != nil {
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "ollama",
				Model:      CurrentConfig.LlmModel,
				Message:    fmt.Sprintf("Cannot connect to Ollama at %s: %v", CurrentConfig.LlmEndpoint, err),
				Suggestion: fmt.Sprintf("Make sure Ollama is running. Start it with: ollama serve. Endpoint: %s", CurrentConfig.LlmEndpoint),
			}
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "ollama",
				Model:      CurrentConfig.LlmModel,
				Message:    fmt.Sprintf("Ollama returned status %d: %s", resp.StatusCode, string(body)),
				Suggestion: "Check your Ollama installation and configuration.",
			}
		}

		// Parse response and check if model is available
		var ollamaResp struct {
			Models []struct {
				Name string `json:"name"`
			} `json:"models"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&ollamaResp); err != nil {
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "ollama",
				Model:      CurrentConfig.LlmModel,
				Message:    fmt.Sprintf("Failed to parse Ollama response: %v", err),
				Suggestion: "Verify your Ollama installation is working correctly.",
			}
		}

		// Check if the configured model is available
		modelFound := false
		for _, m := range ollamaResp.Models {
			if m.Name == CurrentConfig.LlmModel {
				modelFound = true
				break
			}
		}

		if !modelFound {
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "ollama",
				Model:      CurrentConfig.LlmModel,
				Message:    fmt.Sprintf("Model '%s' is not installed in Ollama", CurrentConfig.LlmModel),
				Suggestion: fmt.Sprintf("Pull the model with: ollama pull %s", CurrentConfig.LlmModel),
			}
		}

		return &HealthCheckResult{
			Status:   "ok",
			Provider: "ollama",
			Model:    CurrentConfig.LlmModel,
			Message:  "Connected to Ollama successfully",
		}

	} else if CurrentConfig.LlmProvider == "openai" {
		// Basic check for OpenAI: verify API key is set
		if CurrentConfig.LlmApiKey == "" {
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "openai",
				Model:      CurrentConfig.LlmModel,
				Message:    "OpenAI API key is not configured",
				Suggestion: "Set your OpenAI API key in the configuration file.",
			}
		}

		// Try a simple API call to verify key validity
		testReq := OpenAIChatRequest{
			Model:    CurrentConfig.LlmModel,
			Messages: []ChatMessage{{Role: "user", Content: "test"}},
			Stream:   false,
		}

		body, _ := json.Marshal(testReq)
		req, _ := http.NewRequest("POST", strings.TrimSuffix(CurrentConfig.LlmEndpoint, "/")+"/chat/completions", bytes.NewBuffer(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+CurrentConfig.LlmApiKey)

		resp, err := client.Do(req)
		if err != nil {
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "openai",
				Model:      CurrentConfig.LlmModel,
				Message:    fmt.Sprintf("Cannot reach OpenAI API: %v", err),
				Suggestion: "Check your internet connection and OpenAI endpoint configuration.",
			}
		}
		defer resp.Body.Close()

		if resp.StatusCode == 401 || resp.StatusCode == 403 {
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "openai",
				Model:      CurrentConfig.LlmModel,
				Message:    "OpenAI API key is invalid or expired",
				Suggestion: "Update your API key in the configuration file.",
			}
		}

		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusBadRequest {
			body, _ := io.ReadAll(resp.Body)
			return &HealthCheckResult{
				Status:     "error",
				Provider:   "openai",
				Model:      CurrentConfig.LlmModel,
				Message:    fmt.Sprintf("OpenAI API error: %d", resp.StatusCode),
				Suggestion: fmt.Sprintf("Response: %s", string(body)),
			}
		}

		return &HealthCheckResult{
			Status:   "ok",
			Provider: "openai",
			Model:    CurrentConfig.LlmModel,
			Message:  "Connected to OpenAI successfully",
		}
	}

	return &HealthCheckResult{
		Status:     "error",
		Provider:   CurrentConfig.LlmProvider,
		Message:    fmt.Sprintf("Unknown LLM provider: %s", CurrentConfig.LlmProvider),
		Suggestion: "Configure a valid provider (ollama or openai) in your config file.",
	}
}

// Helper to remove any ```json ... ``` markdown packaging some models put in responses
func cleanJSONString(input string) string {
	input = strings.TrimSpace(input)
	if strings.HasPrefix(input, "```json") {
		input = strings.TrimPrefix(input, "```json")
		input = strings.TrimSuffix(input, "```")
	} else if strings.HasPrefix(input, "```") {
		input = strings.TrimPrefix(input, "```")
		input = strings.TrimSuffix(input, "```")
	}
	return strings.TrimSpace(input)
}
