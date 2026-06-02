// LinguaPi Frontend Logic

document.addEventListener("DOMContentLoaded", () => {
  // UI Elements
  const configInfo = document.getElementById("config-info");
  const languageSelect = document.getElementById("language-select");
  const passageTitle = document.getElementById("passage-title");
  const passageCategory = document.getElementById("passage-category");

  // Dual Paragraph Elements
  const passagePrimaryContainer = document.getElementById("passage-primary-container");
  const passagePrimaryLabel = document.getElementById("passage-primary-label");
  const passagePrimary = document.getElementById("passage-primary");
  const passageSecondaryContainer = document.getElementById("passage-secondary-container");
  const passageSecondary = document.getElementById("passage-secondary");

  const englishTranslation = document.getElementById("english-translation");
  const translationDetails = document.getElementById("translation-details");
  const categorySelect = document.getElementById("category-select");
  const nextBtn = document.getElementById("next-btn");
  const difficultySelect = document.getElementById("difficulty-select");

  // TTS Elements
  const ttsPlayBtn = document.getElementById("tts-play-btn");
  const ttsStopBtn = document.getElementById("tts-stop-btn");
  const ttsSpeed = document.getElementById("tts-speed");
  const speedLabel = document.getElementById("speed-label");
  const ttsHelpBtn = document.getElementById("tts-help-btn");
  const ttsHelpModal = document.getElementById("tts-help-modal");
  const closeTtsHelp = document.getElementById("close-tts-help");

  // History Elements
  const historyList = document.getElementById("history-list");

  // Analyzer Elements
  const analyzerPanel = document.getElementById("analyzer-panel");
  const sheetBackdrop = document.getElementById("sheet-backdrop");
  const closeAnalyzer = document.getElementById("close-analyzer");
  const analyzerDefault = document.getElementById("analyzer-default");
  const analyzerLoading = document.getElementById("analyzer-loading");
  const loadingWordName = document.getElementById("loading-word-name");
  const analyzerResults = document.getElementById("analyzer-results");

  const resultWord = document.getElementById("result-word");
  const resultPos = document.getElementById("result-pos");
  const resultTranslation = document.getElementById("result-translation");
  const resultDefinition = document.getElementById("result-definition");
  const resultTenseBlock = document.getElementById("result-tense-block");
  const resultTense = document.getElementById("result-tense");
  const resultSynonyms = document.getElementById("result-synonyms");
  const resultUsages = document.getElementById("result-usages");
  const resultConjugationBlock = document.getElementById("result-conjugation-block");
  const resultConjugationTable = document.getElementById("result-conjugation-table");

  const modelSelect = document.getElementById("model-select");
  const themeToggle = document.getElementById("theme-toggle");
  const themeIcon = document.getElementById("theme-icon");

  // Settings modal elements
  const settingsOpenBtn  = document.getElementById("settings-open-btn");
  const settingsModal    = document.getElementById("settings-modal");
  const closeSettings    = document.getElementById("close-settings");
  const cfgProvider      = document.getElementById("cfg-provider");
  const cfgEndpoint      = document.getElementById("cfg-endpoint");
  const cfgApiKey        = document.getElementById("cfg-apikey");
  const cfgApiKeyRow     = document.getElementById("cfg-apikey-row");
  const settingsSaveBtn  = document.getElementById("settings-save-btn");
  const settingsHealthMsg = document.getElementById("settings-health-msg");
  const fontSizeSlider   = document.getElementById("font-size-slider");

  let connectionHealthy = true;

  // --- Theme ---
  const savedTheme = localStorage.getItem("linguapi_theme") || "dark";
  document.documentElement.setAttribute("data-theme", savedTheme);
  themeIcon.textContent = savedTheme === "dark" ? "light_mode" : "dark_mode";

  themeToggle.addEventListener("click", () => {
    const current = document.documentElement.getAttribute("data-theme");
    const next = current === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("linguapi_theme", next);
    themeIcon.textContent = next === "dark" ? "light_mode" : "dark_mode";
  });

  // --- Font Size ---
  const fontSizeSteps = ["1rem", "1.1rem", "1.25rem", "1.45rem", "1.65rem"];
  const savedFontStep = parseInt(localStorage.getItem("linguapi_font_size") || "3", 10);
  fontSizeSlider.value = savedFontStep;
  applyFontSize(savedFontStep);

  fontSizeSlider.addEventListener("input", (e) => {
    const step = parseInt(e.target.value, 10);
    applyFontSize(step);
    localStorage.setItem("linguapi_font_size", step);
  });

  function applyFontSize(step) {
    document.documentElement.style.setProperty("--passage-font-size", fontSizeSteps[step - 1]);
  }

  // --- Settings Modal ---
  function showProviderFields() {
    const isOpenAI = cfgProvider.value === "openai";
    cfgApiKeyRow.classList.toggle("hidden", !isOpenAI);
  }

  cfgProvider.addEventListener("change", showProviderFields);

  difficultySelect.addEventListener("change", (e) => {
    localStorage.setItem("linguapi_difficulty", e.target.value);
  });

  settingsOpenBtn.addEventListener("click", async () => {
    // Pre-fill from current config
    try {
      const res = await fetch("/api/config");
      const cfg = await res.json();
      cfgProvider.value = cfg.llm_provider || "ollama";
      cfgEndpoint.value = cfg.llm_endpoint || "";
      cfgApiKey.placeholder = cfg.has_api_key ? "API key set — leave blank to keep" : "Leave blank to keep current";
      cfgApiKey.value = "";
    } catch (_) {}
    showProviderFields();
    settingsHealthMsg.classList.add("hidden");
    // Lazy-load models on first open
    if (!modelsFetched) {
      modelsFetched = true;
      fetchModels();
    }
    settingsModal.showModal();
  });

  closeSettings.addEventListener("click", () => settingsModal.close());
  settingsModal.addEventListener("click", (e) => { if (e.target === settingsModal) settingsModal.close(); });

  settingsSaveBtn.addEventListener("click", async () => {
    settingsSaveBtn.disabled = true;
    settingsSaveBtn.innerHTML = `<span class="spinner" style="width:16px;height:16px;margin:0;border-width:2px;display:inline-block;vertical-align:middle;"></span> Saving...`;

    const body = {
      provider: cfgProvider.value,
      endpoint: cfgEndpoint.value.trim(),
    };
    if (cfgApiKey.value.trim()) body.api_key = cfgApiKey.value.trim();

    try {
      const res = await fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await res.json();

      if (!res.ok) {
        showSettingsHealth("error", data.error || "Save failed");
      } else {
        const h = data.health;
        if (h.status === "ok") {
          showSettingsHealth("ok", `Connected: ${h.provider} / ${h.model}`);
          fetchConfig();
          fetchHistory();
          // Reset model list so it reloads on next open
          modelSelect.innerHTML = `<option>Loading models...</option>`;
          modelsFetched = false;
        } else {
          showSettingsHealth("error", h.message + (h.suggestion ? ` — ${h.suggestion}` : ""));
        }
      }
    } catch (err) {
      showSettingsHealth("error", "Network error: " + err.message);
    } finally {
      settingsSaveBtn.disabled = false;
      settingsSaveBtn.innerHTML = `<span class="material-icons-round">save</span> Save &amp; Reconnect`;
    }
  });

  function showSettingsHealth(type, msg) {
    settingsHealthMsg.className = `settings-health-msg settings-health-${type}`;
    settingsHealthMsg.textContent = msg;
    settingsHealthMsg.classList.remove("hidden");
  }

  // Application State
  let currentPassage = null;
  let activeLanguage = localStorage.getItem("linguapi_active_language") || "Spanish";
  let synth = window.speechSynthesis;
  let speechUtterance = null;
  let isSpeaking = false;

  // Restore persisted study preferences
  languageSelect.value = activeLanguage;
  const savedDifficulty = localStorage.getItem("linguapi_difficulty") || "2";
  difficultySelect.value = savedDifficulty;

  // --- Initialize Config / Health Check / History ---
  checkHealth();
  fetchConfig();
  fetchHistory();

  // Models are lazy-loaded when settings opens
  let modelsFetched = false;

  // --- Core Health Check ---

  async function checkHealth() {
    try {
      const res = await fetch("/api/health", { timeout: 3000 });
      const health = await res.json();

      if (health.status !== "ok") {
        connectionHealthy = false;
        showConnectionError(health);
        disableAppUI();
        return;
      }
      connectionHealthy = true;
      clearConnectionError();
    } catch (err) {
      connectionHealthy = false;
      showConnectionError({
        status: "error",
        message: "Cannot reach the backend server",
        suggestion: "Make sure the LinguaPi server is running. Check the server logs for details.",
      });
      disableAppUI();
    }
  }

  function showConnectionError(health) {
    const errorDiv = document.createElement("div");
    errorDiv.id = "connection-error";
    errorDiv.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 9999;
      padding: 20px;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    `;

    const content = document.createElement("div");
    content.style.cssText = `
      background: white;
      border-radius: 12px;
      padding: 40px;
      max-width: 500px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
    `;

    const icon = document.createElement("div");
    icon.style.cssText = `
      font-size: 64px;
      margin-bottom: 20px;
    `;
    icon.textContent = "⚠️";

    const title = document.createElement("h1");
    title.style.cssText = `
      font-size: 24px;
      font-weight: 600;
      color: #1a1a1a;
      margin: 0 0 12px 0;
    `;
    title.textContent = health.provider ? `${health.provider} Connection Failed` : "Connection Error";

    const message = document.createElement("p");
    message.style.cssText = `
      font-size: 14px;
      color: #666;
      margin: 0 0 16px 0;
      line-height: 1.6;
    `;
    message.textContent = health.message || "Unable to connect to the backend service.";

    const suggestion = document.createElement("div");
    suggestion.style.cssText = `
      background: #f5f5f5;
      border-left: 4px solid #ff6b6b;
      padding: 16px;
      margin: 20px 0;
      border-radius: 4px;
      text-align: left;
      font-size: 13px;
      color: #444;
      line-height: 1.6;
    `;
    suggestion.innerHTML = `<strong>What to do:</strong><br>${health.suggestion || "Check your configuration and try again."}`;

    const retryBtn = document.createElement("button");
    retryBtn.textContent = "Retry Connection";
    retryBtn.style.cssText = `
      background: #2a5298;
      color: white;
      border: none;
      padding: 12px 24px;
      border-radius: 6px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.3s;
    `;
    retryBtn.onmouseover = () => (retryBtn.style.background = "#1e3c72");
    retryBtn.onmouseout = () => (retryBtn.style.background = "#2a5298");
    retryBtn.addEventListener("click", () => {
      errorDiv.remove();
      checkHealth();
    });

    content.appendChild(icon);
    content.appendChild(title);
    content.appendChild(message);
    content.appendChild(suggestion);
    content.appendChild(retryBtn);
    errorDiv.appendChild(content);
    document.body.appendChild(errorDiv);
  }

  function clearConnectionError() {
    const errorDiv = document.getElementById("connection-error");
    if (errorDiv) {
      errorDiv.remove();
    }
  }

  function disableAppUI() {
    nextBtn.disabled = true;
    categorySelect.disabled = true;
    languageSelect.disabled = true;
    ttsPlayBtn.disabled = true;
    ttsStopBtn.disabled = true;
  }

  function enableAppUI() {
    nextBtn.disabled = false;
    categorySelect.disabled = false;
    languageSelect.disabled = false;
  }

  // --- Event Listeners ---
  languageSelect.addEventListener("change", (e) => {
    activeLanguage = e.target.value;
    localStorage.setItem("linguapi_active_language", activeLanguage);
    showToast(`Language set to ${activeLanguage}. Click "Get New Passage" to load a text.`, "info");
  });

  modelSelect.addEventListener("change", async (e) => {
    const model = e.target.value;
    if (!model || model === "Loading models...") return;
    try {
      const res = await fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model })
      });
      if (res.ok) {
        showToast(`Model switched to ${model}`, "success");
        fetchConfig();
      } else {
        const data = await res.json();
        showToast(data.error || "Failed to update model", "error");
      }
    } catch (err) {
      showToast("Network error updating model", "error");
    }
  });

  nextBtn.addEventListener("click", fetchNewPassage);
  ttsPlayBtn.addEventListener("click", toggleSpeech);
  ttsStopBtn.addEventListener("click", stopSpeech);

  // TTS Help Dialog Modal Events
  ttsHelpBtn.addEventListener("click", () => ttsHelpModal.showModal());
  closeTtsHelp.addEventListener("click", () => ttsHelpModal.close());
  ttsHelpModal.addEventListener("click", (e) => {
    if (e.target === ttsHelpModal) {
      ttsHelpModal.close();
    }
  });
  ttsSpeed.addEventListener("input", (e) => {
    const val = parseFloat(e.target.value).toFixed(1);
    speedLabel.textContent = `${val}x`;
    if (speechUtterance) {
      speechUtterance.rate = val;
    }
  });

  // Mouse selection for multi-word highlights on both primary and secondary paragraphs
  passagePrimary.addEventListener("mouseup", () => handleTextSelection(passagePrimary));
  passagePrimary.addEventListener("touchend", () => handleTextSelection(passagePrimary));
  passageSecondary.addEventListener("mouseup", () => handleTextSelection(passageSecondary));
  passageSecondary.addEventListener("touchend", () => handleTextSelection(passageSecondary));

  // Close analyzer panel
  closeAnalyzer.addEventListener("click", hideAnalyzerPanel);
  sheetBackdrop.addEventListener("click", hideAnalyzerPanel);

  // --- Core API Functions ---

  async function fetchConfig() {
    try {
      const res = await fetch("/api/config");
      const data = await res.json();
      configInfo.textContent = `${data.llm_provider}: ${data.llm_model}`;
    } catch (err) {
      console.error("Failed to fetch configuration:", err);
      configInfo.textContent = "Offline Mode";
    }
  }

  async function fetchModels() {
    try {
      const res = await fetch("/api/models");
      if (!res.ok) {
        const data = await res.json();
        console.warn("Could not load models:", data.error);
        modelSelect.innerHTML = `<option value="">No models found</option>`;
        return;
      }
      const models = await res.json();
      modelSelect.innerHTML = models.map(m => `<option value="${m}">${m}</option>`).join("");
      // Set current model from config
      const cfg = await fetch("/api/config").then(r => r.json());
      if (cfg.llm_model && modelSelect.querySelector(`option[value="${cfg.llm_model}"]`)) {
        modelSelect.value = cfg.llm_model;
      }
    } catch (err) {
      console.error("Failed to fetch models:", err);
      modelSelect.innerHTML = `<option value="">Unavailable</option>`;
    }
  }

  // Fetch history from the backend history.json instead of localStorage
  async function fetchHistory() {
    try {
      const res = await fetch("/api/history");
      if (res.ok) {
        const historyData = await res.json();
        renderHistoryList(historyData);
      }
    } catch (err) {
      console.error("Failed to fetch history:", err);
    }
  }

  // Fetch new random/themed text from Go API
  async function fetchNewPassage() {
    if (!connectionHealthy) {
      showToast("Cannot generate: LLM connection is not available. Check the error message above.", "error");
      return;
    }

    nextBtn.disabled = true;
    const originalText = nextBtn.innerHTML;
    nextBtn.innerHTML = `<span class="spinner" style="width:16px;height:16px;margin:0;border-width:2px;display:inline-block;vertical-align:middle;"></span> Loading...`;

    stopSpeech();
    translationDetails.removeAttribute("open");

    const category = categorySelect.value;
    try {
      const difficulty = parseInt(difficultySelect.value, 10);
      const response = await fetch("/api/generate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ category, language: activeLanguage, difficulty })
      });

      const data = await response.json();
      if (response.ok) {
        loadPassageData(data);
        fetchHistory();
        enableAppUI();
        maybePromptQuiz();
      } else {
        showToast(data.error || "Failed to generate reading material", "error");
        if (data.error && data.error.includes("connection")) {
          checkHealth();
        }
      }
    } catch (error) {
      console.error(error);
      showToast("Network error contacting backend.", "error");
      checkHealth();
    } finally {
      nextBtn.disabled = false;
      nextBtn.innerHTML = originalText;
    }
  }

  // Load paragraph content into the active view
  function loadPassageData(data) {
    currentPassage = data;
    passageTitle.textContent = data.title;
    passageCategory.textContent = data.category || "General";
    englishTranslation.textContent = data.translation;

    // Enable speech controls
    ttsPlayBtn.disabled = false;
    ttsStopBtn.disabled = false;

    // Handle Dual Rendering for non-Latin script languages (Kannada, Telugu)
    const hasTransliteration = data.transliteration && data.transliteration.trim() !== "";
    const isNonLatin = activeLanguage.toLowerCase() === "kannada" || activeLanguage.toLowerCase() === "telugu";

    if (hasTransliteration && isNonLatin) {
      // 1. Show labels
      passagePrimaryLabel.classList.remove("hidden");
      passageSecondaryContainer.classList.remove("hidden");

      // 2. Render primary as Romanized (transliterated) pronunciation
      renderInteractiveText(data.transliteration, passagePrimary);

      // 3. Render secondary as native non-Latin script
      renderInteractiveText(data.text, passageSecondary);
    } else {
      // Hide labels and secondary text container
      passagePrimaryLabel.classList.add("hidden");
      passageSecondaryContainer.classList.add("hidden");

      // Render native script directly in primary
      renderInteractiveText(data.text, passagePrimary);
    }
    
    // Reset Analyzer view
    resetAnalyzer();
  }

  // Split paragraph into click-actionable words
  function renderInteractiveText(text, containerElement) {
    containerElement.innerHTML = "";
    
    // Split text by whitespace, preserving words and punctuation
    const tokens = text.split(/(\s+)/);
    
    tokens.forEach(token => {
      if (token.trim().length === 0) {
        containerElement.appendChild(document.createTextNode(token));
      } else {
        const span = document.createElement("span");
        span.className = "word-span";
        span.textContent = token;
        
        // Extract a clean word without symbols (for LLM dictionary lookup)
        const cleanWord = token.replace(/[¿?¡!.,;:()[\]""'']/g, "").trim();
        span.setAttribute("data-clean-word", cleanWord);
        
        span.addEventListener("click", (e) => {
          e.stopPropagation();
          // Remove active class from all other words in both text blocks
          document.querySelectorAll(".word-span").forEach(w => w.classList.remove("active-word"));
          span.classList.add("active-word");
          
          analyzeWordOrPhrase(cleanWord);
        });
        
        containerElement.appendChild(span);
      }
    });
  }

  // Handle custom selections (e.g. phrases, idioms or sentences)
  function handleTextSelection(containerElement) {
    const selection = window.getSelection();
    const selectedText = selection.toString().trim();
    
    if (selectedText.length > 0 && selectedText.includes(" ")) {
      // Clear active class from all single word clicks
      document.querySelectorAll(".word-span").forEach(w => w.classList.remove("active-word"));
      
      // Analyze the phrase
      analyzeWordOrPhrase(selectedText);
    }
  }

  // Trigger Backend Analysis
  async function analyzeWordOrPhrase(targetText) {
    if (!currentPassage) return;

    if (!connectionHealthy) {
      showToast("Cannot analyze: LLM connection is not available.", "error");
      return;
    }

    showAnalyzerPanel();

    analyzerDefault.classList.add("hidden");
    analyzerResults.classList.add("hidden");
    analyzerLoading.classList.remove("hidden");
    loadingWordName.textContent = targetText;

    try {
      const response = await fetch("/api/analyze", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          text: targetText,
          context: currentPassage.text,
          language: activeLanguage
        })
      });

      const data = await response.json();
      if (response.ok) {
        renderAnalysisResults(data);
      } else {
        showToast(data.error || "Analysis failed", "error");
        resetAnalyzer();
      }
    } catch (error) {
      console.error(error);
      showToast("Connection error while analyzing text", "error");
      resetAnalyzer();
      checkHealth();
    }
  }

  // Render Grammar Breakdown details
  function renderAnalysisResults(data) {
    analyzerLoading.classList.add("hidden");
    analyzerResults.classList.remove("hidden");

    resultWord.textContent = data.word_or_phrase;
    resultPos.textContent = data.part_of_speech || "Word";
    resultTranslation.textContent = data.translation;
    resultDefinition.textContent = data.definition;

    // Show/hide tense/conjugation block
    if (data.tense_or_conjugation && data.tense_or_conjugation.trim() !== "" && data.tense_or_conjugation.trim().toUpperCase() !== "N/A") {
      resultTenseBlock.classList.remove("hidden");
      resultTense.textContent = data.tense_or_conjugation;
    } else {
      resultTenseBlock.classList.add("hidden");
    }

    // Synonyms
    resultSynonyms.innerHTML = "";
    if (data.synonyms && data.synonyms.length > 0) {
      data.synonyms.forEach(syn => {
        const pill = document.createElement("span");
        pill.className = "synonym-pill";
        pill.textContent = syn;
        pill.addEventListener("click", () => {
          analyzeWordOrPhrase(syn);
        });
        resultSynonyms.appendChild(pill);
      });
    } else {
      resultSynonyms.innerHTML = `<span style="color: var(--text-subtle); font-size: 0.9rem;">None found</span>`;
    }

    // Usage Examples
    resultUsages.innerHTML = "";
    if (data.usages && data.usages.length > 0) {
      data.usages.forEach(example => {
        const item = document.createElement("div");
        item.className = "usage-item";
        
        const spanOriginal = document.createElement("p");
        spanOriginal.className = "usage-spanish";
        spanOriginal.textContent = example.original;
        
        const spanTranslation = document.createElement("p");
        spanTranslation.className = "usage-english";
        spanTranslation.textContent = example.translation;
        
        item.appendChild(spanOriginal);
        item.appendChild(spanTranslation);
        resultUsages.appendChild(item);
      });
    } else {
      resultUsages.innerHTML = `<p style="color: var(--text-subtle); margin:0; font-size:0.9rem;">No examples loaded</p>`;
    }

    // Conjugation Table
    resultConjugationTable.innerHTML = "";
    if (data.conjugation_table && data.conjugation_table.length > 0) {
      resultConjugationBlock.classList.remove("hidden");

      // Build a matrix: collect all unique persons (rows) in order from first tense
      const persons = data.conjugation_table[0].forms.map(f => f.person);
      const tenses  = data.conjugation_table.map(t => t.tense);

      const table = document.createElement("table");
      table.className = "conj-table";

      // Header row — tense names
      const thead = table.createTHead();
      const hrow  = thead.insertRow();
      hrow.insertCell().textContent = ""; // empty corner
      tenses.forEach(t => {
        const th = document.createElement("th");
        th.textContent = t;
        hrow.appendChild(th);
      });

      // Body — one row per person
      const tbody = table.createTBody();
      persons.forEach((person, pi) => {
        const row = tbody.insertRow();
        const th = document.createElement("th");
        th.textContent = person;
        row.appendChild(th);

        data.conjugation_table.forEach(tenseObj => {
          const cell = row.insertCell();
          cell.textContent = tenseObj.forms[pi]?.form ?? "—";
        });
      });

      resultConjugationTable.appendChild(table);
    } else {
      resultConjugationBlock.classList.add("hidden");
    }
  }

  // Reset Analyzer state
  function resetAnalyzer() {
    analyzerLoading.classList.add("hidden");
    analyzerResults.classList.add("hidden");
    analyzerDefault.classList.remove("hidden");
    
    // Clear word highlights
    document.querySelectorAll(".word-span").forEach(w => w.classList.remove("active-word"));
  }

  // Slide-in / bottom-sheet helpers
  function showAnalyzerPanel() {
    analyzerPanel.classList.add("active");
    sheetBackdrop.classList.add("active");
  }

  function hideAnalyzerPanel() {
    analyzerPanel.classList.remove("active");
    sheetBackdrop.classList.remove("active");
    document.querySelectorAll(".word-span").forEach(w => w.classList.remove("active-word"));
  }

  // --- TTS Handling (SpeechSynthesis) ---
  
  function toggleSpeech() {
    if (!currentPassage) return;

    if (synth.speaking) {
      if (synth.paused) {
        synth.resume();
        updateSpeechButtonState(true);
      } else {
        synth.pause();
        updateSpeechButtonState(false);
      }
      return;
    }

    let textToSpeak = currentPassage.text;
    let langCode = "es-ES";
    const currentLangLower = activeLanguage.toLowerCase();
    const isNonLatin = currentLangLower === "kannada" || currentLangLower === "telugu";
    
    if (currentLangLower === "spanish") {
      langCode = "es";
    } else if (currentLangLower === "german") {
      langCode = "de";
    } else if (currentLangLower === "portuguese") {
      langCode = "pt";
    } else if (currentLangLower === "italian") {
      langCode = "it";
    } else if (currentLangLower === "kannada") {
      langCode = "kn";
    } else if (currentLangLower === "telugu") {
      langCode = "te";
    }

    const voices = synth.getVoices();
    let selectedVoice = null;

    // Try finding native TTS voice
    for (let voice of voices) {
      if (voice.lang.startsWith(langCode)) {
        selectedVoice = voice;
        if (voice.localService) break;
      }
    }

    if (selectedVoice) {
      speechUtterance = new SpeechSynthesisUtterance(textToSpeak);
      speechUtterance.voice = selectedVoice;
      console.log("Selected TTS Voice:", selectedVoice.name, selectedVoice.lang);
    } else {
      // If it's a non-Latin script and no native voice is found, read Romanized transliteration in English!
      if (isNonLatin && currentPassage.transliteration) {
        textToSpeak = currentPassage.transliteration;
        langCode = "en-US";
        
        // Find default English voice
        for (let voice of voices) {
          if (voice.lang.startsWith("en")) {
            selectedVoice = voice;
            break;
          }
        }
        
        speechUtterance = new SpeechSynthesisUtterance(textToSpeak);
        if (selectedVoice) {
          speechUtterance.voice = selectedVoice;
        } else {
          speechUtterance.lang = "en-US";
        }
        
        showToast(`System ${activeLanguage} voice not found. Tap here to learn how to install it.`, "info", () => {
          ttsHelpModal.showModal();
        });
        console.log("Fallback to Romanized speech synthesis in English:", textToSpeak);
      } else {
        // Standard fallback for Latin languages without explicit voice install
        speechUtterance = new SpeechSynthesisUtterance(textToSpeak);
        speechUtterance.lang = langCode;
        console.log("No explicit voice found, falling back to language code:", langCode);
      }
    }

    // Settings
    speechUtterance.rate = parseFloat(ttsSpeed.value);
    
    speechUtterance.onstart = () => {
      isSpeaking = true;
      updateSpeechButtonState(true);
    };

    speechUtterance.onend = () => {
      isSpeaking = false;
      updateSpeechButtonState(false);
      speechUtterance = null;
    };

    speechUtterance.onerror = (e) => {
      console.error("TTS Error:", e);
      isSpeaking = false;
      updateSpeechButtonState(false);
      speechUtterance = null;
      showToast("Speech playback failed. Check browser speech support.", "error");
    };

    synth.speak(speechUtterance);
  }

  function stopSpeech() {
    if (synth.speaking) {
      synth.cancel();
    }
    isSpeaking = false;
    updateSpeechButtonState(false);
    speechUtterance = null;
  }

  function updateSpeechButtonState(playing) {
    if (playing) {
      ttsPlayBtn.innerHTML = `<span class="material-icons-round">pause</span>`;
      ttsPlayBtn.title = "Pause Audio";
    } else {
      ttsPlayBtn.innerHTML = `<span class="material-icons-round">play_arrow</span>`;
      ttsPlayBtn.title = "Listen Text";
    }
  }

  if (synth.onvoiceschanged !== undefined) {
    synth.onvoiceschanged = () => synth.getVoices();
  }

  // --- Quiz ---
  const quizModal          = document.getElementById("quiz-modal");
  const closeQuiz          = document.getElementById("close-quiz");
  const quizPassageEl      = document.getElementById("quiz-passage");
  const quizAnswerEl       = document.getElementById("quiz-answer");
  const quizCheckBtn       = document.getElementById("quiz-check-btn");
  const quizCheckRow       = document.getElementById("quiz-check-row");
  const quizRevealBlock    = document.getElementById("quiz-reveal-block");
  const quizActualTranslation = document.getElementById("quiz-actual-translation");
  const quizPassedBtn      = document.getElementById("quiz-passed-btn");
  const quizFailedBtn      = document.getElementById("quiz-failed-btn");

  const QUIZ_INTERVAL = 10;
  let currentQuizPassage = null;

  function getPassageCount() {
    return parseInt(localStorage.getItem("linguapi_passage_count") || "0", 10);
  }
  function incrementPassageCount() {
    const n = getPassageCount() + 1;
    localStorage.setItem("linguapi_passage_count", n);
    return n;
  }
  function resetPassageCount() {
    localStorage.setItem("linguapi_passage_count", "0");
  }

  function maybePromptQuiz() {
    const count = incrementPassageCount();
    if (count >= QUIZ_INTERVAL) {
      resetPassageCount();
      showToast("Ready for a quick quiz? Tap here to test yourself.", "info", () => openQuizModal());
    }
  }

  async function openQuizModal() {
    try {
      const res = await fetch("/api/quiz");
      if (!res.ok) {
        showToast("Not enough history for a quiz yet — keep reading!", "info");
        return;
      }
      currentQuizPassage = await res.json();
    } catch (err) {
      showToast("Could not load quiz passage.", "error");
      return;
    }

    // Reset state
    quizPassageEl.textContent = currentQuizPassage.text;
    quizAnswerEl.value = "";
    quizRevealBlock.classList.add("hidden");
    quizCheckRow.classList.remove("hidden");
    quizActualTranslation.textContent = currentQuizPassage.translation;
    quizModal.showModal();
  }

  closeQuiz.addEventListener("click", () => quizModal.close());
  quizModal.addEventListener("click", (e) => { if (e.target === quizModal) quizModal.close(); });

  quizCheckBtn.addEventListener("click", () => {
    quizRevealBlock.classList.remove("hidden");
    quizCheckRow.classList.add("hidden");
  });

  async function submitQuizResult(passed) {
    quizModal.close();
    try {
      await fetch("/api/quiz/result", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ history_id: currentQuizPassage.id, passed })
      });
    } catch (_) {}
    showToast(passed ? "Nice work! Keep it up." : "Keep practicing — you'll get it!", passed ? "success" : "info");
  }

  quizPassedBtn.addEventListener("click", () => submitQuizResult(true));
  quizFailedBtn.addEventListener("click", () => submitQuizResult(false));

  // --- Render Backend History ---

  function renderHistoryList(historyData) {
    historyList.innerHTML = "";
    if (!historyData || historyData.length === 0) {
      historyList.innerHTML = `<li class="empty-history">Your generated reading history will appear here.</li>`;
      return;
    }

    historyData.forEach((item) => {
      const li = document.createElement("li");
      li.className = "history-item";
      li.innerHTML = `
        <div class="history-item-left">
          <span class="history-item-title">${item.title}</span>
          <span class="history-item-category">${item.category}</span>
        </div>
        <div class="history-item-right">
          <span>Study</span>
          <span class="material-icons-round" style="font-size:1.1rem;">arrow_forward</span>
        </div>
      `;

      li.addEventListener("click", () => {
        loadPassageData(item);
        showToast(`Loaded: ${item.title}`, "success");
      });

      historyList.appendChild(li);
    });
  }

  // --- Toast Notification Helpers ---
  function showToast(message, type = "info", onClickAction = null) {
    const container = document.getElementById("toast-container");
    const toast = document.createElement("div");
    toast.className = `toast ${type}`;
    if (onClickAction) {
      toast.classList.add("clickable-toast");
    }
    
    let icon = "info";
    if (type === "success") icon = "check_circle";
    if (type === "error") icon = "error_outline";

    toast.innerHTML = `
      <span class="material-icons-round">${icon}</span>
      <span>${message}</span>
    `;

    if (onClickAction) {
      toast.addEventListener("click", (e) => {
        e.stopPropagation();
        onClickAction();
        toast.remove();
      });
    }

    container.appendChild(toast);

    setTimeout(() => {
      if (toast.parentNode) {
        toast.style.animation = "slide-in 0.3s cubic-bezier(0.18, 0.89, 0.32, 1.28) reverse forwards";
        setTimeout(() => {
          if (toast.parentNode) toast.remove();
        }, 300);
      }
    }, onClickAction ? 7000 : 4000);
  }
});
