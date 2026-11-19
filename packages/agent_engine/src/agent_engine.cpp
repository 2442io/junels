// agent_engine.cpp — Implementierung der C-Schnittstelle aus agent_engine.h.
// Gegen llama.cpp b12522 (neue batch_ext / llama_process API).

#include "agent_engine.h"
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#else
#include <unistd.h>
#endif

#define AE_VERSION 1

// ---------------------------------------------------------------------------
// Logging: llama.cpp-Ausgaben schlucken, letzte Fehlermeldung merken.
// ---------------------------------------------------------------------------

static std::mutex g_log_mutex;
static std::string g_last_llama_error;

static void ae_log_cb(enum ggml_log_level level, const char * text, void * /*user*/) {
    if (level == GGML_LOG_LEVEL_ERROR && text) {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        g_last_llama_error = text;
        while (!g_last_llama_error.empty() &&
               (g_last_llama_error.back() == '\n' || g_last_llama_error.back() == ' ')) {
            g_last_llama_error.pop_back();
        }
    }
    if (getenv("AE_VERBOSE") && text) {
        fputs(text, stderr);
    }
}

static std::string take_llama_error() {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    std::string s = g_last_llama_error;
    g_last_llama_error.clear();
    return s;
}

static void ensure_backend() {
    static std::once_flag once;
    std::call_once(once, [] {
        llama_log_set(ae_log_cb, nullptr);
        llama_backend_init();
    });
}

using clk = std::chrono::steady_clock;
static double ms_since(clk::time_point t0) {
    return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}

// ---------------------------------------------------------------------------
// Engine-Zustand
// ---------------------------------------------------------------------------

struct ae_engine {
    llama_model *       model = nullptr;
    llama_context *     ctx   = nullptr;
    const llama_vocab * vocab = nullptr;
    llama_sampler *     smpl  = nullptr;   // Sampler-Kette ohne Grammatik
    llama_sampler *     grammar = nullptr; // GBNF, wird nur bei Bedarf voll angewendet
    std::vector<llama_token_data> cand;
    llama_batch_ext *   batch = nullptr;

    int32_t n_ctx   = 0;
    int32_t n_batch = 0;

    std::vector<llama_token> cached;   // Tokens, die aktuell im KV-Cache liegen
    std::atomic<bool> stop{false};

    // laufende Generierung
    bool        active      = false;
    bool        finished    = false;
    int32_t     finish_code = AE_DONE;
    int32_t     max_tokens  = 0;
    std::string pending;              // unvollständige UTF-8-Bytes

    // Statistik
    double  prompt_ms   = 0;
    int32_t prompt_new  = 0;
    int32_t prompt_reused = 0;
    int32_t gen_tokens  = 0;
    double  ttft_ms     = -1;
    clk::time_point t_begin;
    clk::time_point t_gen_start;
    double  gen_ms      = 0;

    std::string last_error;

    // Bildverständnis (optional): Projektor-Datei zum Sprachmodell
    mtmd_context * vision = nullptr;
};

static bool abort_cb(void * data) {
    auto * e = static_cast<ae_engine *>(data);
    return e->stop.load(std::memory_order_relaxed);
}

static void set_err(ae_engine * e, const std::string & msg) {
    std::string extra = take_llama_error();
    e->last_error = extra.empty() ? msg : msg + ": " + extra;
}

// Länge des längsten Präfixes, der aus vollständigen UTF-8-Zeichen besteht.
static size_t utf8_complete_prefix(const std::string & s) {
    size_t n = s.size();
    if (n == 0) return 0;
    // höchstens die letzten 3 Bytes können ein unvollständiges Zeichen sein
    size_t start = n > 4 ? n - 4 : 0;
    size_t i = start;
    // zum Beginn eines Zeichens laufen
    while (i < n && (static_cast<unsigned char>(s[i]) & 0xC0) == 0x80) i++;
    size_t last_ok = i;
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = 1;
        if      (c >= 0xF0) len = 4;
        else if (c >= 0xE0) len = 3;
        else if (c >= 0xC0) len = 2;
        if (i + len > n) return last_ok;
        i += len;
        last_ok = i;
    }
    return last_ok;
}

static std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool add_special) {
    int32_t n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, add_special, true);
    if (n <= 0) return {};
    std::vector<llama_token> toks(n);
    int32_t got = llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), toks.data(), n, add_special, true);
    if (got < 0) return {};
    toks.resize(got);
    // doppeltes BOS vermeiden (Template enthält BOS bereits als Text)
    if (toks.size() >= 2) {
        llama_token bos = llama_vocab_bos(vocab);
        if (bos != LLAMA_TOKEN_NULL && toks[0] == bos && toks[1] == bos) toks.erase(toks.begin());
    }
    return toks;
}

static std::string json_escape(const std::string & s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:
                if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
                else o += (char) c;
        }
    }
    return o;
}

static int32_t copy_out(const std::string & s, char * buf, int32_t buf_len) {
    if (buf && buf_len > 0) {
        size_t n = std::min<size_t>(s.size(), (size_t) buf_len - 1);
        memcpy(buf, s.data(), n);
        buf[n] = '\0';
    }
    return (int32_t) s.size();
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

extern "C" {

int32_t ae_version(void) { return AE_VERSION; }

ae_engine * ae_create(const char * model_path, int32_t n_ctx, int32_t n_threads, int32_t n_gpu_layers,
                      int32_t kv_quant_q8, char * err, int32_t err_len) {
    ensure_backend();
    take_llama_error();

    auto fail = [&](const std::string & msg) -> ae_engine * {
        std::string extra = take_llama_error();
        copy_out(extra.empty() ? msg : msg + ": " + extra, err, err_len);
        return nullptr;
    };

    if (!model_path || !*model_path) return fail("kein Modellpfad");

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;
    mp.load_mode    = LLAMA_LOAD_MODE_MMAP;

    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) return fail("Modell konnte nicht geladen werden");

    if (n_ctx <= 0) n_ctx = 2048;
    int32_t n_train = llama_model_n_ctx_train(model);
    if (n_train > 0 && n_ctx > n_train) n_ctx = n_train;
    if (n_threads <= 0) n_threads = 4;

    auto make_ctx = [&](bool quant) -> llama_context * {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx           = (uint32_t) n_ctx;
        cp.n_batch         = (uint32_t) std::min(n_ctx, 512);
        cp.n_ubatch        = cp.n_batch;
        cp.n_seq_max       = 1;
        cp.n_threads       = n_threads;
        cp.n_threads_batch = n_threads;
        cp.no_perf         = true;
        if (quant) {
            cp.type_k = GGML_TYPE_Q8_0;
            cp.type_v = GGML_TYPE_Q8_0;
            cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
        } else {
            cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        }
        return llama_init_from_model(model, cp);
    };

    llama_context * ctx = make_ctx(kv_quant_q8 != 0);
    if (!ctx && kv_quant_q8) ctx = make_ctx(false);   // Fallback ohne KV-Quantisierung
    if (!ctx) {
        llama_model_free(model);
        return fail("Context konnte nicht angelegt werden (zu wenig Speicher?)");
    }

    auto * e   = new ae_engine();
    e->model   = model;
    e->ctx     = ctx;
    e->vocab   = llama_model_get_vocab(model);
    e->n_ctx   = (int32_t) llama_n_ctx(ctx);
    e->n_batch = std::min(e->n_ctx, 512);
    e->batch   = llama_batch_ext_init(ctx);
    llama_set_abort_callback(ctx, abort_cb, e);
    copy_out("", err, err_len);
    return e;
}

void ae_destroy(ae_engine * e) {
    if (!e) return;
    if (e->vision) mtmd_free(e->vision);
    if (e->smpl)  llama_sampler_free(e->smpl);
    if (e->grammar) llama_sampler_free(e->grammar);
    if (e->batch) llama_batch_ext_free(e->batch);
    if (e->ctx)   llama_free(e->ctx);
    if (e->model) llama_model_free(e->model);
    delete e;
}

int32_t ae_model_info(ae_engine * e, char * buf, int32_t buf_len) {
    if (!e) return -1;
    char desc[256] = {0};
    llama_model_desc(e->model, desc, sizeof desc);
    const char * tmpl = llama_model_chat_template(e->model, nullptr);
    std::string j = "{";
    j += "\"desc\":\"" + json_escape(desc) + "\",";
    j += "\"size_bytes\":" + std::to_string(llama_model_size(e->model)) + ",";
    j += "\"n_params\":" + std::to_string(llama_model_n_params(e->model)) + ",";
    j += "\"n_ctx\":" + std::to_string(e->n_ctx) + ",";
    j += "\"n_ctx_train\":" + std::to_string(llama_model_n_ctx_train(e->model)) + ",";
    j += "\"chat_template\":\"" + json_escape(tmpl ? tmpl : "") + "\"";
    j += "}";
    return copy_out(j, buf, buf_len);
}

int32_t ae_format_chat(ae_engine * e, const char ** roles, const char ** contents, int32_t n_msg,
                       int32_t add_assistant, char * out, int32_t out_len) {
    if (!e || n_msg < 0) return -1;
    std::vector<llama_chat_message> msgs(n_msg);
    size_t total = 0;
    for (int32_t i = 0; i < n_msg; i++) {
        msgs[i].role    = roles[i];
        msgs[i].content = contents[i];
        total += strlen(roles[i]) + strlen(contents[i]);
    }
    const char * tmpl = llama_model_chat_template(e->model, nullptr);
    const std::string t = tmpl ? tmpl : "";

    // Gemma 4 (<|turn>…<turn|>) kennt llama_chat_apply_template nicht → selbst formatieren
    if (t.find("<|turn>") != std::string::npos) {
        std::string o;
        auto trim = [](std::string x) {
            size_t a = x.find_first_not_of(" \t\n"), b = x.find_last_not_of(" \t\n");
            return a == std::string::npos ? std::string() : x.substr(a, b - a + 1);
        };
        for (int32_t i = 0; i < n_msg; i++) {
            std::string role = roles[i];
            if (role == "assistant") role = "model";
            o += "<|turn>" + role + "\n" + trim(contents[i]) + "<turn|>\n";
        }
        if (add_assistant) o += "<|turn>model\n<|channel>thought\n<channel|>";  // ohne Denkmodus
        return copy_out(o, out, out_len);
    }

    std::vector<char> buf(total * 2 + 1024);

    auto apply = [&](const char * tp) -> int32_t {
        int32_t n = llama_chat_apply_template(tp, msgs.data(), msgs.size(), add_assistant != 0,
                                              buf.data(), (int32_t) buf.size());
        if (n > (int32_t) buf.size()) {
            buf.resize(n + 1);
            n = llama_chat_apply_template(tp, msgs.data(), msgs.size(), add_assistant != 0,
                                          buf.data(), (int32_t) buf.size());
        }
        return n;
    };

    int32_t n = tmpl ? apply(tmpl) : -1;
    if (n < 0) n = apply("chatml");      // unbekanntes Template → ChatML
    if (n < 0) { set_err(e, "Chat-Template fehlgeschlagen"); return -1; }
    std::string result(buf.data(), n);
    // Hybride Denkmodelle (Qwen3/3.5): Denkphase abschalten wie enable_thinking=false
    if (add_assistant && t.find("<think>") != std::string::npos && t.find("enable_thinking") != std::string::npos) {
        result += "<think>\n\n</think>\n\n";
    }
    return copy_out(result, out, out_len);
}

int32_t ae_count_tokens(ae_engine * e, const char * text) {
    if (!e || !text) return 0;
    return (int32_t) tokenize(e->vocab, text, false).size();
}

int32_t ae_validate_grammar(ae_engine * e, const char * grammar) {
    if (!e || !grammar) return 0;
    take_llama_error();
    llama_sampler * g = llama_sampler_init_grammar(e->vocab, grammar, "root");
    if (!g) { set_err(e, "ungültige Grammatik"); return 0; }
    llama_sampler_free(g);
    return 1;
}

// Prompt-Tokens [from, to) in Blöcken verarbeiten, Logits nur für das letzte Token.
static int32_t process_tokens(ae_engine * e, const std::vector<llama_token> & toks, size_t from) {
    llama_memory_t mem = llama_get_memory(e->ctx);
    size_t i = from;
    while (i < toks.size()) {
        size_t n = std::min<size_t>(e->n_batch, toks.size() - i);
        llama_batch_ext_clear(e->batch);
        for (size_t k = 0; k < n; k++) {
            int32_t idx = llama_batch_ext_add_token(e->batch, 0, toks[i + k]);
            if (idx < 0) { set_err(e, "Batch voll"); return AE_ERROR; }
            llama_pos pos = (llama_pos) (i + k);
            llama_batch_ext_set_pos(e->batch, idx, &pos);
        }
        if (i + n == toks.size()) llama_batch_ext_set_output_logits(e->batch, (int32_t) n - 1, true);

        int32_t rc = llama_process(e->ctx, LLAMA_PROCESS_TYPE_DECODE, e->batch);
        if (rc == 2) {              // abgebrochen
            llama_memory_seq_rm(mem, 0, (llama_pos) i, -1);
            e->cached.assign(toks.begin(), toks.begin() + i);
            return AE_DONE;
        }
        if (rc == 1) { set_err(e, "kein Platz im KV-Cache"); return AE_CONTEXT_FULL; }
        if (rc != 0) { set_err(e, "Prompt-Verarbeitung fehlgeschlagen"); return AE_ERROR; }
        i += n;
        e->cached.assign(toks.begin(), toks.begin() + i);
    }
    return 0;
}

static llama_sampler * make_sampler(float temperature, float top_p, float min_p, int32_t seed) {
    llama_sampler * chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    } else {
        if (top_p > 0.0f && top_p < 1.0f) llama_sampler_chain_add(chain, llama_sampler_init_top_p(top_p, 1));
        if (min_p > 0.0f)                 llama_sampler_chain_add(chain, llama_sampler_init_min_p(min_p, 1));
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed < 0 ? LLAMA_DEFAULT_SEED : (uint32_t) seed));
    }
    return chain;
}

int32_t ae_begin(ae_engine * e, const char * prompt, const char * grammar,
                 float temperature, float top_p, float min_p, int32_t seed, int32_t max_tokens) {
    if (!e || !prompt) return AE_ERROR;
    take_llama_error();
    e->stop.store(false);
    e->active = false;
    e->finished = false;
    e->finish_code = AE_DONE;
    e->pending.clear();
    e->gen_tokens = 0;
    e->gen_ms = 0;
    e->ttft_ms = -1;
    e->t_begin = clk::now();
    e->max_tokens = max_tokens > 0 ? max_tokens : 1024;

    // Sampler-Kette neu aufbauen
    if (e->smpl) { llama_sampler_free(e->smpl); e->smpl = nullptr; }
    if (e->grammar) { llama_sampler_free(e->grammar); e->grammar = nullptr; }
    if (grammar && *grammar) {
        e->grammar = llama_sampler_init_grammar(e->vocab, grammar, "root");
        if (!e->grammar) { set_err(e, "ungültige Grammatik"); return AE_ERROR; }
    }
    e->smpl = make_sampler(temperature, top_p, min_p, seed);

    // Prompt tokenisieren
    std::vector<llama_token> toks = tokenize(e->vocab, prompt, llama_vocab_get_add_bos(e->vocab));
    if (toks.empty()) { set_err(e, "leerer Prompt"); return AE_ERROR; }
    if ((int32_t) toks.size() >= e->n_ctx - 8) {
        set_err(e, "Prompt (" + std::to_string(toks.size()) + " Tokens) passt nicht in den Context (" +
                   std::to_string(e->n_ctx) + ")");
        return AE_CONTEXT_FULL;
    }

    // gemeinsamen Präfix mit dem KV-Cache wiederverwenden
    size_t keep = 0;
    while (keep < e->cached.size() && keep < toks.size() && e->cached[keep] == toks[keep]) keep++;
    if (keep == toks.size()) keep--;   // mind. ein Token neu auswerten, um Logits zu bekommen

    llama_memory_t mem = llama_get_memory(e->ctx);
    if (!llama_memory_seq_rm(mem, 0, (llama_pos) keep, -1)) {
        llama_memory_clear(mem, true);   // z. B. rekurrente Modelle: kein Teil-Löschen möglich
        keep = 0;
    }
    e->cached.resize(keep);

    auto t0 = clk::now();
    int32_t rc = process_tokens(e, toks, keep);
    e->prompt_ms     = ms_since(t0);
    e->prompt_new    = (int32_t) (toks.size() - keep);
    e->prompt_reused = (int32_t) keep;
    if (rc == AE_DONE) { e->finished = true; e->active = true; return 0; }  // gestoppt
    if (rc != 0) return rc;

    e->active = true;
    e->t_gen_start = clk::now();
    return 0;
}

int32_t ae_next(ae_engine * e, char * buf, int32_t buf_len) {
    if (!e || !e->active) return AE_DONE;

    auto flush_pending = [&]() -> int32_t {
        std::string out = e->pending;
        e->pending.clear();
        return copy_out(out, buf, buf_len);
    };

    if (e->finished) {
        if (!e->pending.empty()) return flush_pending();
        e->active = false;
        return e->finish_code;
    }
    if (e->stop.load() || e->gen_tokens >= e->max_tokens) {
        e->finished = true;
        return ae_next(e, buf, buf_len);
    }
    if ((int32_t) e->cached.size() >= e->n_ctx - 1) {
        e->finished = true;
        e->finish_code = AE_CONTEXT_FULL;
        return ae_next(e, buf, buf_len);
    }

    // Schnellweg: ohne Grammatik ziehen und nur das gezogene Token prüfen.
    // Nur wenn es die Grammatik verletzt, wird die Grammatik auf das ganze
    // Vokabular angewendet (spart bei 150k Tokens viel Zeit pro Schritt).
    llama_token tok = llama_sampler_sample(e->smpl, e->ctx, -1);
    if (e->grammar) {
        llama_token_data one = { tok, 1.0f, 0.0f };
        llama_token_data_array single = { &one, 1, -1, false };
        llama_sampler_apply(e->grammar, &single);
        if (one.logit == -INFINITY) {
            const float * logits = llama_get_logits_ith(e->ctx, -1);
            const int32_t n_vocab = llama_vocab_n_tokens(e->vocab);
            e->cand.resize(n_vocab);
            for (int32_t i = 0; i < n_vocab; i++) e->cand[i] = { i, logits[i], 0.0f };
            llama_token_data_array cur = { e->cand.data(), e->cand.size(), -1, false };
            llama_sampler_apply(e->grammar, &cur);
            llama_sampler_apply(e->smpl, &cur);
            if (cur.selected < 0 || cur.selected >= (int64_t) cur.size) {
                set_err(e, "Grammatik lässt kein Token zu");
                e->finished = true;
                e->finish_code = AE_ERROR;
                return ae_next(e, buf, buf_len);
            }
            tok = cur.data[cur.selected].id;
        }
        llama_sampler_accept(e->grammar, tok);
    }
    if (e->ttft_ms < 0) e->ttft_ms = ms_since(e->t_begin);

    if (llama_vocab_is_eog(e->vocab, tok)) {
        e->finished = true;
        e->gen_ms = ms_since(e->t_gen_start);
        return ae_next(e, buf, buf_len);
    }

    char piece[256];
    int32_t n = llama_token_to_piece(e->vocab, tok, piece, sizeof piece, 0, false);
    if (n > 0) e->pending.append(piece, n);

    // Token in den KV-Cache schreiben, damit der nächste Schritt Logits hat
    llama_batch_ext_clear(e->batch);
    int32_t idx = llama_batch_ext_add_token(e->batch, 0, tok);
    llama_pos pos = (llama_pos) e->cached.size();
    llama_batch_ext_set_pos(e->batch, idx, &pos);
    llama_batch_ext_set_output_logits(e->batch, idx, true);
    int32_t rc = llama_process(e->ctx, LLAMA_PROCESS_TYPE_DECODE, e->batch);
    e->gen_tokens++;
    e->gen_ms = ms_since(e->t_gen_start);
    if (rc == 0) {
        e->cached.push_back(tok);
    } else if (rc == 2) {
        e->finished = true;                     // abgebrochen
    } else if (rc == 1) {
        e->finished = true;
        e->finish_code = AE_CONTEXT_FULL;
    } else {
        set_err(e, "Generierung fehlgeschlagen");
        e->finished = true;
        e->finish_code = AE_ERROR;
    }

    size_t ok = utf8_complete_prefix(e->pending);
    std::string out = e->pending.substr(0, ok);
    e->pending.erase(0, ok);
    return copy_out(out, buf, buf_len);
}

// ---------------------------------------------------------------------------
// Bildverständnis über libmtmd
// ---------------------------------------------------------------------------

const char * ae_vision_marker(void) { return mtmd_default_marker(); }

int32_t ae_vision_load(ae_engine * e, const char * mmproj_path, int32_t n_threads, int32_t use_gpu) {
    if (!e || !mmproj_path) return 0;
    take_llama_error();
    if (e->vision) { mtmd_free(e->vision); e->vision = nullptr; }
    mtmd_context_params p = mtmd_context_params_default();
    p.use_gpu       = use_gpu != 0;
    p.print_timings = false;
    p.n_threads     = n_threads > 0 ? n_threads : 4;
    p.warmup        = false;
    // dynamische Auflösung begrenzen, damit ein Bild in einen Batch passt
    p.image_max_tokens = std::min(e->n_batch, 512);
    e->vision = mtmd_init_from_file(mmproj_path, e->model, p);
    if (!e->vision) { set_err(e, "Projektor-Datei passt nicht zum Modell oder ist beschädigt"); return 0; }
    if (!mtmd_support_vision(e->vision)) {
        mtmd_free(e->vision);
        e->vision = nullptr;
        set_err(e, "Projektor-Datei unterstützt keine Bilder");
        return 0;
    }
    return 1;
}

int32_t ae_vision_ready(ae_engine * e) { return e && e->vision ? 1 : 0; }

int32_t ae_vision_begin(ae_engine * e, const char * prompt, const char ** image_paths, int32_t n_images,
                        float temperature, int32_t max_tokens) {
    if (!e || !prompt) return AE_ERROR;
    if (!e->vision) { set_err(e, "Bildverständnis nicht geladen"); return AE_ERROR; }
    take_llama_error();
    e->stop.store(false);
    e->active = false;
    e->finished = false;
    e->finish_code = AE_DONE;
    e->pending.clear();
    e->gen_tokens = 0;
    e->gen_ms = 0;
    e->ttft_ms = -1;
    e->t_begin = clk::now();
    e->max_tokens = max_tokens > 0 ? max_tokens : 768;
    if (e->smpl) { llama_sampler_free(e->smpl); e->smpl = nullptr; }
    if (e->grammar) { llama_sampler_free(e->grammar); e->grammar = nullptr; }
    e->smpl = make_sampler(temperature, 0.95f, 0.05f, -1);

    std::vector<mtmd_bitmap *> bitmaps;
    auto free_bitmaps = [&]() { for (auto * b : bitmaps) mtmd_bitmap_free(b); };
    for (int32_t i = 0; i < n_images; i++) {
        mtmd_helper_bitmap_wrapper w =
            mtmd_helper_bitmap_init_from_file(e->vision, image_paths[i], false, mtmd_helper_init_opt_default());
        if (!w.bitmap) {
            free_bitmaps();
            set_err(e, std::string("Bild nicht lesbar (JPG/PNG/GIF/BMP): ") + image_paths[i]);
            return AE_ERROR;
        }
        bitmaps.push_back(w.bitmap);
    }

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    mtmd_input_text txt = { prompt, true, true };
    int32_t rc = mtmd_tokenize(e->vision, chunks, &txt, (const mtmd_bitmap **) bitmaps.data(), bitmaps.size());
    free_bitmaps();
    if (rc != 0) {
        mtmd_input_chunks_free(chunks);
        set_err(e, rc == 1 ? "Anzahl Bild-Markierungen passt nicht zur Anzahl Bilder" : "Bild-Vorbereitung fehlgeschlagen");
        return AE_ERROR;
    }
    size_t n_tok = mtmd_helper_get_n_tokens(chunks);
    if ((int32_t) n_tok >= e->n_ctx - 16) {
        mtmd_input_chunks_free(chunks);
        set_err(e, "Bild + Frage (" + std::to_string(n_tok) + " Tokens) passen nicht in den Context");
        return AE_CONTEXT_FULL;
    }

    // KV-Cache neu beginnen; der Text-Cache ist danach ungültig
    llama_memory_clear(llama_get_memory(e->ctx), true);
    e->cached.clear();
    auto t0 = clk::now();
    llama_pos n_past = 0;
    rc = mtmd_helper_eval_chunks(e->vision, e->ctx, chunks, 0, 0, e->n_batch, true, &n_past);
    mtmd_input_chunks_free(chunks);
    e->prompt_ms     = ms_since(t0);
    e->prompt_new    = (int32_t) n_tok;
    e->prompt_reused = 0;
    if (rc != 0) {
        llama_memory_clear(llama_get_memory(e->ctx), true);
        if (e->stop.load()) { e->finished = true; e->active = true; return 0; }
        set_err(e, "Bild-Auswertung fehlgeschlagen");
        return AE_ERROR;
    }
    // Positionen belegen, Inhalt markieren als "nicht wiederverwendbar" (-1)
    e->cached.assign((size_t) n_past, (llama_token) -1);
    e->active = true;
    e->t_gen_start = clk::now();
    return 0;
}

void ae_stop(ae_engine * e) {
    if (e) e->stop.store(true);
}

void ae_stats(ae_engine * e, double * out) {
    if (!e || !out) return;
    out[0] = e->prompt_new;
    out[1] = e->prompt_ms;
    out[2] = e->gen_tokens;
    out[3] = e->gen_ms;
    out[4] = (double) e->cached.size();
    out[5] = e->n_ctx;
    out[6] = e->prompt_reused;
    out[7] = e->ttft_ms;
}

const char * ae_last_error(ae_engine * e) {
    if (!e) return "engine ist NULL";
    return e->last_error.c_str();
}

// ---------------------------------------------------------------------------
// Speicher
// ---------------------------------------------------------------------------

#if !defined(__APPLE__)
static int64_t meminfo_kb(const char * key) {
    FILE * f = fopen("/proc/meminfo", "r");
    if (!f) return -1;
    char line[256];
    int64_t val = -1;
    size_t klen = strlen(key);
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == ':') {
            val = atoll(line + klen + 1);
            break;
        }
    }
    fclose(f);
    return val;
}
#endif

int64_t ae_total_memory(void) {
#if defined(__APPLE__)
    int64_t mem = 0;
    size_t len = sizeof mem;
    if (sysctlbyname("hw.memsize", &mem, &len, nullptr, 0) == 0) return mem;
    return -1;
#else
    int64_t kb = meminfo_kb("MemTotal");
    return kb > 0 ? kb * 1024 : (int64_t) sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE);
#endif
}

int64_t ae_available_memory(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return (int64_t) os_proc_available_memory();
#elif defined(__APPLE__)
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    vm_statistics64_data_t vs;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t) &vs, &count) != KERN_SUCCESS) return -1;
    return (int64_t) (vs.free_count + vs.inactive_count + vs.purgeable_count) * (int64_t) page;
#else
    int64_t kb = meminfo_kb("MemAvailable");
    return kb > 0 ? kb * 1024 : -1;
#endif
}

int64_t ae_process_memory(void) {
#if defined(__APPLE__)
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) != KERN_SUCCESS) return -1;
    return (int64_t) info.phys_footprint;
#else
    FILE * f = fopen("/proc/self/statm", "r");
    if (!f) return -1;
    long size = 0, resident = 0;
    int n = fscanf(f, "%ld %ld", &size, &resident);
    fclose(f);
    if (n != 2) return -1;
    return (int64_t) resident * sysconf(_SC_PAGESIZE);
#endif
}

} // extern "C"
