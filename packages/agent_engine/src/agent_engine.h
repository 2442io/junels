// agent_engine.h — schlanke C-Schnittstelle über llama.cpp für die Offline Agent App.
//
// Bewusst einfache Signaturen (nur Zeiger, int, float, double), damit die
// Dart-FFI-Bindings ohne Struct-Layouts aus llama.h auskommen.
//
// Threading: Alle Funktionen außer ae_stop() und ae_*_memory() werden aus
// genau einem Thread (dem Engine-Isolate) aufgerufen. ae_stop() ist
// thread-sicher und darf jederzeit aus dem UI-Isolate kommen.

#ifndef AGENT_ENGINE_H
#define AGENT_ENGINE_H

#include <stdint.h>

#if defined(_WIN32)
#define AE_API __declspec(dllexport)
#else
#define AE_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ae_engine ae_engine;

// Rückgabewerte von ae_next()
#define AE_DONE          (-1)  // Ende: EOG-Token, max_tokens erreicht oder gestoppt
#define AE_ERROR         (-2)  // Fehler, Details über ae_last_error()
#define AE_CONTEXT_FULL  (-3)  // Context-Fenster voll

AE_API int32_t ae_version(void);

// Lädt ein GGUF-Modell und legt einen Context an.
// n_gpu_layers: -1 = alle (Metal), 0 = nur CPU.
// Gibt NULL zurück, wenn das Laden fehlschlägt; Fehlertext in err.
AE_API ae_engine * ae_create(const char * model_path,
                             int32_t n_ctx,
                             int32_t n_threads,
                             int32_t n_gpu_layers,
                             int32_t kv_quant_q8,   // 1 = KV-Cache als q8_0 (spart ~50 % RAM)
                             char * err, int32_t err_len);

AE_API void ae_destroy(ae_engine * e);

// Modell-Infos als JSON: {"desc","size_bytes","n_params","n_ctx","n_ctx_train","chat_template"}
// Rückgabe: benötigte Länge (ohne \0). Ist sie >= buf_len, Puffer vergrößern.
AE_API int32_t ae_model_info(ae_engine * e, char * buf, int32_t buf_len);

// Wendet das Chat-Template des Modells an (Fallback: ChatML).
// Rückgabe: benötigte Länge; negativ bei Fehler.
AE_API int32_t ae_format_chat(ae_engine * e,
                              const char ** roles, const char ** contents, int32_t n_msg,
                              int32_t add_assistant,
                              char * out, int32_t out_len);

// Zählt Tokens eines Textes (für Context-Budget in Dart).
AE_API int32_t ae_count_tokens(ae_engine * e, const char * text);

// Startet eine Generierung. Übernimmt den gemeinsamen Präfix aus dem
// KV-Cache des vorherigen Aufrufs (wichtig für den Agenten-Loop).
// grammar: GBNF-Text oder NULL/"" für freien Text. Root-Regel heißt "root".
// Rückgabe: 0 = ok, AE_CONTEXT_FULL, AE_ERROR.
AE_API int32_t ae_begin(ae_engine * e,
                        const char * prompt,
                        const char * grammar,
                        float temperature, float top_p, float min_p,
                        int32_t seed, int32_t max_tokens);

// Erzeugt das nächste Stück Text (immer vollständige UTF-8-Zeichen).
// Rückgabe: Anzahl geschriebener Bytes (>= 0; 0 = Token ohne sichtbaren
// Text, einfach weiter aufrufen) oder AE_DONE / AE_ERROR / AE_CONTEXT_FULL.
AE_API int32_t ae_next(ae_engine * e, char * buf, int32_t buf_len);

// Bricht Prompt-Verarbeitung und Generierung ab (thread-sicher).
// --- Bildverständnis (libmtmd) ---------------------------------------------
// Markierung, die im (bereits formatierten) Prompt für jedes Bild steht.
AE_API const char * ae_vision_marker(void);
// Projektor-Datei (mmproj-*.gguf) zum geladenen Modell laden. 1 = ok.
AE_API int32_t ae_vision_load(ae_engine * e, const char * mmproj_path, int32_t n_threads, int32_t use_gpu);
AE_API int32_t ae_vision_ready(ae_engine * e);
// Startet eine Antwort zu Bildern; danach wie gewohnt ae_next() aufrufen.
// Der Text-KV-Cache wird dabei verworfen.
AE_API int32_t ae_vision_begin(ae_engine * e, const char * prompt, const char ** image_paths, int32_t n_images,
                               float temperature, int32_t max_tokens);

// --- Bildgenerierung (stable-diffusion.cpp) ---------------------------------
typedef struct ae_image ae_image;
AE_API ae_image * ae_img_create(const char * model_path, int32_t n_threads, int32_t vae_tiling,
                                char * err, int32_t err_len);
AE_API void ae_img_destroy(ae_image * im);
// 0 = ok (out_rgb mit ae_free freigeben), 1 = abgebrochen, -1 = Fehler (ae_img_last_error)
AE_API int32_t ae_img_generate(ae_image * im, const char * prompt, const char * negative,
                               int32_t width, int32_t height, int32_t steps, float cfg, int64_t seed,
                               const char * method, int32_t vae_tiling,
                               uint8_t ** out_rgb, int32_t * out_w, int32_t * out_h);
AE_API void ae_img_cancel(ae_image * im);
AE_API void ae_img_progress(int32_t * step, int32_t * steps);
AE_API const char * ae_img_last_error(ae_image * im);
AE_API void ae_free(void * p);

// KV-Cache auf Platte sichern / laden. Rückgabe: Anzahl Tokens (0 = nicht möglich).
AE_API int32_t ae_state_save(ae_engine * e, const char * path);
AE_API int32_t ae_state_load(ae_engine * e, const char * path);

AE_API void ae_stop(ae_engine * e);

// Statistik der letzten Generierung, in out[0..7]:
// 0 prompt_tokens_neu, 1 prompt_ms, 2 gen_tokens, 3 gen_ms,
// 4 n_past, 5 n_ctx, 6 prompt_tokens_wiederverwendet, 7 zeit_bis_erstes_token_ms
AE_API void ae_stats(ae_engine * e, double * out8);

// Letzte Fehlermeldung (gültig bis zum nächsten Aufruf).
AE_API const char * ae_last_error(ae_engine * e);

// Speicher des Geräts in Bytes. available: was die App noch nutzen darf
// (iOS: os_proc_available_memory, sonst MemAvailable / freie+inaktive Pages).
AE_API int64_t ae_total_memory(void);
AE_API int64_t ae_available_memory(void);
// Aktueller Speicherverbrauch des eigenen Prozesses (RSS / phys_footprint).
AE_API int64_t ae_process_memory(void);

// Prüft eine GBNF-Grammatik, ohne zu generieren. 1 = gültig.
AE_API int32_t ae_validate_grammar(ae_engine * e, const char * grammar);

#ifdef __cplusplus
}
#endif

#endif

// ---------------------------------------------------------------------------
// Spracherkennung (whisper.cpp, teilt sich ggml mit llama.cpp)
// ---------------------------------------------------------------------------
#ifndef AGENT_ENGINE_STT_H
#define AGENT_ENGINE_STT_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ae_stt ae_stt;

// Lädt ein Whisper-Modell im ggml-Format (z. B. ggml-large-v3-turbo-q5_0.bin).
AE_API ae_stt * ae_stt_create(const char * model_path, int32_t use_gpu, char * err, int32_t err_len);
AE_API void     ae_stt_destroy(ae_stt * s);

// Transkribiert 16-kHz-Mono-Audio (float -1..1). language: "auto", "de", "en", …
// Rückgabe: benötigte Länge des Texts (ohne \0) oder < 0 bei Fehler/Abbruch.
AE_API int32_t  ae_stt_transcribe(ae_stt * s, const float * pcm, int32_t n_samples,
                                  const char * language, int32_t n_threads,
                                  char * out, int32_t out_len);
// Erkannte Sprache der letzten Transkription ("de", "en", …).
AE_API const char * ae_stt_language(ae_stt * s);
AE_API void     ae_stt_stop(ae_stt * s);              // thread-sicher
AE_API const char * ae_stt_last_error(ae_stt * s);

// Freier Speicherplatz im Dateisystem von path (Bytes), -1 bei Fehler.
AE_API int64_t  ae_free_disk(const char * path);

#ifdef __cplusplus
}
#endif
#endif
