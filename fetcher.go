package main

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"html"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var fetchClient = &http.Client{Timeout: 10 * time.Second}

// wikiGet performs a GET request with the User-Agent header required by the
// Wikimedia API policy. Plain fetchClient.Get sends "Go-http-client/1.1"
// which Wikimedia rejects with HTTP 403.
func wikiGet(url string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "LinguaPi/1.0 (https://github.com/chaoticfly/lingua-pi; self-hosted language learning app)")
	return fetchClient.Do(req)
}

// FetchedContent holds real content retrieved from an external source.
type FetchedContent struct {
	Title      string
	Text       string
	SourceName string
	SourceURL  string
}

// languageCodes maps LinguaPi language names to ISO 639-1 codes.
var languageCodes = map[string]string{
	"Spanish":    "es",
	"German":     "de",
	"Portuguese": "pt",
	"Italian":    "it",
	"Kannada":    "kn",
	"Telugu":     "te",
}

// newsFeedList maps language → list of {feedURL, displayName}.
// Feeds are tried in random order; the first successful one is used.
var newsFeedList = map[string][][2]string{
	"Spanish": {
		{"https://feeds.bbci.co.uk/mundo/rss.xml", "BBC Mundo"},
		{"https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada", "El País"},
	},
	"German": {
		{"https://www.tagesschau.de/xml/rss2", "Tagesschau"},
		{"https://www.spiegel.de/schlagzeilen/index.rss", "Der Spiegel"},
	},
	"Portuguese": {
		{"https://feeds.bbci.co.uk/portuguese/rss.xml", "BBC Brasil"},
		{"https://feeds.folha.uol.com.br/emcimadahora/rss091.xml", "Folha de São Paulo"},
	},
	"Italian": {
		{"https://www.ansa.it/sito/ansait_rss.xml", "ANSA"},
		{"https://www.corriere.it/rss/homepage.xml", "Corriere della Sera"},
	},
	"Kannada": {
		{"https://www.prajavani.net/feed", "Prajavani"},
	},
	"Telugu": {
		{"https://www.eenadu.net/feed", "Eenadu"},
	},
}

// FetchRealContent fetches content from an external source for the given category and language.
// Returns an error if the category has no external source or if all sources fail.
func FetchRealContent(category, language string) (*FetchedContent, error) {
	switch category {
	case "news":
		return fetchNews(language)
	case "novels", "stories":
		return fetchNovel(language)
	case "culture":
		return fetchWikipedia(language)
	default:
		return nil, fmt.Errorf("no real content source for category: %s", category)
	}
}

// gutenbergBookURL converts a pg{id}.txt path or URL to the book's page on gutenberg.org.
func gutenbergBookURL(pathOrURL string) string {
	base := filepath.Base(pathOrURL)
	base = strings.TrimSuffix(base, ".txt")
	if strings.HasPrefix(base, "pg") {
		if id, err := strconv.Atoi(strings.TrimPrefix(base, "pg")); err == nil && id > 0 {
			return fmt.Sprintf("https://www.gutenberg.org/ebooks/%d", id)
		}
	}
	return ""
}

// ── News via RSS ─────────────────────────────────────────────────────────────

type rssDoc struct {
	Items []rssItem `xml:"channel>item"`
}

type rssItem struct {
	Title       string `xml:"title"`
	Description string `xml:"description"`
	Link        string `xml:"link"`
	Encoded     string `xml:"encoded"` // content:encoded (some feeds)
}

func fetchNews(language string) (*FetchedContent, error) {
	feeds, ok := newsFeedList[language]
	if !ok || len(feeds) == 0 {
		return nil, fmt.Errorf("no news feeds configured for %s", language)
	}

	// Try feeds in random order
	order := rand.Perm(len(feeds))
	var lastErr error
	for _, i := range order {
		content, err := fetchRSSItem(feeds[i][0], feeds[i][1])
		if err == nil {
			return content, nil
		}
		log.Printf("RSS %s failed: %v", feeds[i][0], err)
		lastErr = err
	}
	return nil, fmt.Errorf("all news feeds failed for %s: %v", language, lastErr)
}

func fetchRSSItem(feedURL, sourceName string) (*FetchedContent, error) {
	resp, err := fetchClient.Get(feedURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, feedURL)
	}

	var doc rssDoc
	if err := xml.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return nil, fmt.Errorf("RSS parse error: %v", err)
	}
	if len(doc.Items) == 0 {
		return nil, fmt.Errorf("empty RSS feed from %s", feedURL)
	}

	// Skip the first item (often a pinned/meta entry) and pick randomly from the rest.
	start := 1
	if len(doc.Items) == 1 {
		start = 0
	}
	item := doc.Items[start+rand.Intn(len(doc.Items)-start)]

	// Prefer content:encoded (richer body) over description (usually a snippet).
	body := stripHTML(item.Encoded)
	if len(body) < 80 {
		body = stripHTML(item.Description)
	}
	// If still nothing useful, use the title itself as the seed text.
	if len(body) < 20 {
		body = stripHTML(item.Title)
	}

	// Truncate to ~1500 chars so we don't overload the LLM context.
	if len(body) > 1500 {
		body = body[:1500]
		if i := strings.LastIndex(body, "."); i > 800 {
			body = body[:i+1]
		}
	}

	return &FetchedContent{
		Title:      stripHTML(item.Title),
		Text:       body,
		SourceName: sourceName,
		SourceURL:  strings.TrimSpace(item.Link),
	}, nil
}

// ── Culture via Wikipedia random summary ────────────────────────────────────

func fetchWikipedia(language string) (*FetchedContent, error) {
	code, ok := languageCodes[language]
	if !ok {
		return nil, fmt.Errorf("no ISO language code for %s", language)
	}

	apiURL := fmt.Sprintf("https://%s.wikipedia.org/api/rest_v1/page/random/summary", code)
	resp, err := wikiGet(apiURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Wikipedia returned HTTP %d", resp.StatusCode)
	}

	var result struct {
		Title       string `json:"title"`
		Extract     string `json:"extract"`
		ContentURLs struct {
			Desktop struct {
				Page string `json:"page"`
			} `json:"desktop"`
		} `json:"content_urls"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	if len(result.Extract) < 50 {
		return nil, fmt.Errorf("Wikipedia extract too short for article: %s", result.Title)
	}

	extract := truncateToSentence(result.Extract, 2000)

	return &FetchedContent{
		Title:      result.Title,
		Text:       extract,
		SourceName: "Wikipedia",
		SourceURL:  result.ContentURLs.Desktop.Page,
	}, nil
}

// ── Literature: local corpus first, then Gutenberg online ────────────────────

// fetchNovel tries the local corpus (~/.linguapi/corpus/{code}/) before
// falling back to live fetches. Order: local corpus → Gutenberg → Wikisource.
func fetchNovel(language string) (*FetchedContent, error) {
	if content, err := fetchNovelLocal(language); err == nil {
		return content, nil
	}
	log.Printf("No local corpus for %s — trying Gutenberg", language)
	if content, err := fetchNovelGutenberg(language); err == nil {
		return content, nil
	}
	log.Printf("Gutenberg unavailable for %s — trying Wikisource", language)
	return fetchNovelWikisource(language)
}

// fetchNovelLocal picks a random .txt file from the local Gutenberg corpus,
// strips the Project Gutenberg header/footer, and returns a random passage.
func fetchNovelLocal(language string) (*FetchedContent, error) {
	code, ok := languageCodes[language]
	if !ok {
		return nil, fmt.Errorf("no ISO code for %s", language)
	}

	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	corpusDir := filepath.Join(homeDir, ".linguapi", "corpus", code)

	entries, err := os.ReadDir(corpusDir)
	if err != nil {
		return nil, fmt.Errorf("corpus dir missing for %s: %v", language, err)
	}

	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".txt") {
			files = append(files, filepath.Join(corpusDir, e.Name()))
		}
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no .txt files in corpus for %s", language)
	}

	path := files[rand.Intn(len(files))]
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := string(raw)

	// Extract title from the PG header ("Title: ...") before stripping it.
	title := strings.TrimSuffix(filepath.Base(path), ".txt")
	for _, line := range strings.SplitN(text[:min(3000, len(text))], "\n", 100) {
		if strings.HasPrefix(line, "Title:") {
			title = strings.TrimSpace(strings.TrimPrefix(line, "Title:"))
			break
		}
	}

	// Strip Project Gutenberg header/footer.
	for _, marker := range []string{
		"*** START OF THE PROJECT GUTENBERG",
		"***START OF THE PROJECT GUTENBERG",
	} {
		if i := strings.Index(text, marker); i >= 0 {
			text = text[i:]
			if nl := strings.Index(text, "\n"); nl >= 0 {
				text = strings.TrimSpace(text[nl+1:])
			}
			break
		}
	}
	for _, marker := range []string{
		"*** END OF THE PROJECT GUTENBERG",
		"***END OF THE PROJECT GUTENBERG",
	} {
		if i := strings.Index(text, marker); i >= 0 {
			text = text[:i]
			break
		}
	}
	text = strings.TrimSpace(text)

	paragraphs := extractParagraphs(text)
	if len(paragraphs) == 0 {
		return nil, fmt.Errorf("no paragraphs extracted from %s", path)
	}

	// Skip short leading entries (chapter headings, TOC lines).
	start := 0
	for start < len(paragraphs) && len(paragraphs[start]) < 120 {
		start++
	}
	if start >= len(paragraphs) {
		start = 0
	}

	// Pick a random starting paragraph anywhere in the substantive body.
	// Using the full range (not just the first 10) gives far more variety
	// when the same book is hit on different calls.
	pStart := start + rand.Intn(max(1, len(paragraphs)-start))

	var buf strings.Builder
	for i := pStart; i < len(paragraphs) && buf.Len() < 1500; i++ {
		buf.WriteString(paragraphs[i])
		buf.WriteString("\n\n")
	}
	// If we ran off the end, wrap around from the beginning of the body.
	if buf.Len() < 200 && start < pStart {
		for i := start; i < pStart && buf.Len() < 1500; i++ {
			buf.WriteString(paragraphs[i])
			buf.WriteString("\n\n")
		}
	}
	excerpt := strings.TrimSpace(buf.String())
	if len(excerpt) < 100 {
		return nil, fmt.Errorf("excerpt too short from %s", path)
	}

	log.Printf("Local corpus: serving passage from %s (%s)", filepath.Base(path), language)
	return &FetchedContent{
		Title:      title,
		Text:       excerpt,
		SourceName: "Project Gutenberg",
		SourceURL:  gutenbergBookURL(path),
	}, nil
}

// fetchNovelGutenberg fetches a random book from gutendex.com (live internet).
func fetchNovelGutenberg(language string) (*FetchedContent, error) {
	code, ok := languageCodes[language]
	if !ok {
		return nil, fmt.Errorf("no ISO language code for %s", language)
	}

	// Random page (1–8) to get different books across calls.
	page := rand.Intn(8) + 1
	apiURL := fmt.Sprintf("https://gutendex.com/books/?languages=%s&mime_type=text%%2Fplain&page=%d", code, page)

	resp, err := fetchClient.Get(apiURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var gResult struct {
		Results []struct {
			Title   string            `json:"title"`
			Formats map[string]string `json:"formats"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&gResult); err != nil {
		return nil, err
	}
	if len(gResult.Results) == 0 {
		return nil, fmt.Errorf("no Gutenberg books found for language %s", language)
	}

	// Shuffle and find the first book with a plain-text download URL.
	rand.Shuffle(len(gResult.Results), func(i, j int) {
		gResult.Results[i], gResult.Results[j] = gResult.Results[j], gResult.Results[i]
	})

	var textURL, bookTitle string
	for _, book := range gResult.Results {
		for k, v := range book.Formats {
			if strings.HasPrefix(k, "text/plain") && !strings.HasSuffix(v, ".zip") {
				textURL = v
				bookTitle = book.Title
				break
			}
		}
		if textURL != "" {
			break
		}
	}
	if textURL == "" {
		return nil, fmt.Errorf("no text/plain URL found in Gutenberg results for %s", language)
	}

	// Fetch the first 20 KB — enough to clear the PG header and reach real prose.
	req, err := http.NewRequest("GET", textURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Range", "bytes=0-20000")

	textResp, err := fetchClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer textResp.Body.Close()

	raw, err := io.ReadAll(textResp.Body)
	if err != nil {
		return nil, err
	}
	text := string(raw)

	// Strip the Project Gutenberg header (ends with the *** START *** line).
	for _, marker := range []string{
		"*** START OF THE PROJECT GUTENBERG",
		"***START OF THE PROJECT GUTENBERG",
	} {
		if i := strings.Index(text, marker); i >= 0 {
			text = text[i:]
			if nl := strings.Index(text, "\n"); nl >= 0 {
				text = strings.TrimSpace(text[nl+1:])
			}
			break
		}
	}
	// Strip footer.
	for _, marker := range []string{
		"*** END OF THE PROJECT GUTENBERG",
		"***END OF THE PROJECT GUTENBERG",
	} {
		if i := strings.Index(text, marker); i >= 0 {
			text = text[:i]
			break
		}
	}
	text = strings.TrimSpace(text)

	paragraphs := extractParagraphs(text)
	if len(paragraphs) == 0 {
		return nil, fmt.Errorf("could not extract any paragraphs from %s", textURL)
	}

	// Skip short leading entries (table of contents, chapter headings).
	start := 0
	for start < len(paragraphs) && len(paragraphs[start]) < 120 {
		start++
	}
	if start >= len(paragraphs) {
		start = 0
	}

	// Pick a random starting paragraph within the first ten substantive ones.
	window := len(paragraphs) - start
	if window > 10 {
		window = 10
	}
	pStart := start + rand.Intn(window)

	var buf strings.Builder
	for i := pStart; i < len(paragraphs) && buf.Len() < 1500; i++ {
		buf.WriteString(paragraphs[i])
		buf.WriteString("\n\n")
	}
	excerpt := strings.TrimSpace(buf.String())

	if len(excerpt) < 100 {
		return nil, fmt.Errorf("excerpt too short from %s", textURL)
	}

	return &FetchedContent{
		Title:      bookTitle,
		Text:       excerpt,
		SourceName: "Project Gutenberg",
		SourceURL:  gutenbergBookURL(textURL),
	}, nil
}

// extractParagraphs splits a Gutenberg text body on blank lines and returns
// non-trivially-short paragraphs with internal newlines collapsed.
func extractParagraphs(text string) []string {
	raw := strings.Split(text, "\n\n")
	out := make([]string, 0, len(raw))
	for _, p := range raw {
		p = strings.TrimSpace(strings.ReplaceAll(p, "\n", " "))
		if len(p) > 30 {
			out = append(out, p)
		}
	}
	return out
}

// ── Wikisource (runtime fallback for Indian-script languages) ─────────────────

// fetchNovelWikisource fetches a random text from the target-language Wikisource
// using the MediaWiki API. It tries up to 10 random pages, returning the first
// one with enough content after stripping wiki markup.
func fetchNovelWikisource(language string) (*FetchedContent, error) {
	code, ok := languageCodes[language]
	if !ok {
		return nil, fmt.Errorf("no ISO code for %s", language)
	}

	apiBase := "https://" + code + ".wikisource.org/w/api.php"

	// 1. Fetch a batch of random page IDs from the main namespace.
	randomURL := apiBase + "?action=query&list=random&rnnamespace=0&rnlimit=10&format=json"
	resp, err := wikiGet(randomURL)
	if err != nil {
		return nil, fmt.Errorf("Wikisource random query failed: %v", err)
	}
	defer resp.Body.Close()

	var randomResult struct {
		Query struct {
			Random []struct {
				ID    int    `json:"id"`
				Title string `json:"title"`
			} `json:"random"`
		} `json:"query"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&randomResult); err != nil {
		return nil, fmt.Errorf("Wikisource random decode: %v", err)
	}

	pages := randomResult.Query.Random
	if len(pages) == 0 {
		return nil, fmt.Errorf("Wikisource returned no pages for %s", language)
	}
	rand.Shuffle(len(pages), func(i, j int) { pages[i], pages[j] = pages[j], pages[i] })

	// 2. For each candidate page, fetch raw wikitext and clean it.
	for _, page := range pages {
		revURL := fmt.Sprintf(
			"%s?action=query&pageids=%d&prop=revisions&rvprop=content&rvslots=main&format=json",
			apiBase, page.ID)

		revResp, err := wikiGet(revURL)
		if err != nil {
			continue
		}

		var revResult struct {
			Query struct {
				Pages map[string]struct {
					Title     string `json:"title"`
					Revisions []struct {
						Slots struct {
							Main struct {
								Content string `json:"*"`
							} `json:"main"`
						} `json:"slots"`
					} `json:"revisions"`
				} `json:"pages"`
			} `json:"query"`
		}
		decodeErr := json.NewDecoder(revResp.Body).Decode(&revResult)
		revResp.Body.Close()
		if decodeErr != nil {
			continue
		}

		for _, p := range revResult.Query.Pages {
			if len(p.Revisions) == 0 {
				break
			}
			raw := p.Revisions[0].Slots.Main.Content
			cleaned := stripWikitext(raw)
			if len(cleaned) < 300 {
				break
			}
			if len(cleaned) > 2000 {
				cleaned = cleaned[:2000]
			}
			return &FetchedContent{
				Title:      p.Title,
				Text:       cleaned,
				SourceName: "Wikisource",
				SourceURL:  "https://" + code + ".wikisource.org/wiki/" + strings.ReplaceAll(p.Title, " ", "_"),
			}, nil
		}
	}

	return nil, fmt.Errorf("no suitable Wikisource content found for %s", language)
}

// wikitextRules strips common wiki markup and returns approximate plain text.
var wikitextRules = []*regexp.Regexp{
	regexp.MustCompile(`(?s)<ref[^>]*>.*?</ref>`),           // inline references
	regexp.MustCompile(`\{\{[^{}]*\}\}`),                    // templates (one level)
	regexp.MustCompile(`(?i)\[\[(?:File|Image|Category):[^\]]*\]\]`), // media links
	regexp.MustCompile(`\[\[(?:[^|\]]*\|)?([^\]]+)\]\]`),   // [[link|text]] -> text
	regexp.MustCompile(`\[https?://\S+ ([^\]]+)\]`),         // [url text] -> text
	regexp.MustCompile(`\[https?://\S+\]`),                  // bare urls
	regexp.MustCompile(`<[^>]+>`),                           // HTML tags
	regexp.MustCompile(`(?m)={2,}[^=]+=+`),                  // headings
	regexp.MustCompile(`'{2,}`),                             // bold/italic markers
	regexp.MustCompile(`(?m)^\|.*$`),                        // table rows
	regexp.MustCompile(`(?m)^\*`),                           // list bullets
	regexp.MustCompile(`\n{3,}`),                            // excess blank lines
}

func stripWikitext(s string) string {
	// Apply simple replacements first
	for _, re := range wikitextRules[:len(wikitextRules)-1] {
		if re.NumSubexp() == 1 {
			s = re.ReplaceAllString(s, "$1")
		} else {
			s = re.ReplaceAllString(s, "")
		}
	}
	// Collapse blank lines last
	s = wikitextRules[len(wikitextRules)-1].ReplaceAllString(s, "\n\n")
	return strings.TrimSpace(s)
}

// truncateToSentence cuts s to at most maxBytes, ending on the last sentence
// boundary (period) found after the halfway point so the text stays coherent.
func truncateToSentence(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	chunk := s[:maxBytes]
	if i := strings.LastIndex(chunk, "."); i > maxBytes/2 {
		return chunk[:i+1]
	}
	return chunk
}

// ── HTML stripping ────────────────────────────────────────────────────────────

var htmlTagRe = regexp.MustCompile(`<[^>]+>`)

func stripHTML(s string) string {
	s = htmlTagRe.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	return strings.TrimSpace(s)
}
