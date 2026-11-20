// stt_engine.cpp — Spracherkennung mit whisper.cpp (siehe agent_engine.h).

#include "agent_engine.h"
#include "whisper.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/statvfs.h>

struct ae_stt {
    whisper_context * ctx = nullptr;
    std::atomic<bool> stop{false};
    std::string language = "";
    std::string last_error;
};

static void ae_whisper_log(enum ggml_log_level, const char *, void *) {}

static bool stt_abort(void * data) {
    return static_cast<ae_stt *>(data)->stop.load(std::memory_order_relaxed);
}

static int32_t stt_copy(const std::string & s, char * buf, int32_t len) {
    if (buf && len > 0) {
        size_t n = s.size() < (size_t) len - 1 ? s.size() : (size_t) len - 1;
        memcpy(buf, s.data(), n);
        buf[n] = '\0';
    }
    return (int32_t) s.size();
}

extern "C" {

ae_stt * ae_stt_create(const char * model_path, int32_t use_gpu, char * err, int32_t err_len) {
    if (!getenv("AE_VERBOSE")) whisper_log_set(ae_whisper_log, nullptr);
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = use_gpu != 0;
    cp.flash_attn = use_gpu != 0;
    whisper_context * ctx = whisper_init_from_file_with_params(model_path, cp);
    if (!ctx) {
        stt_copy("Whisper-Modell konnte nicht geladen werden", err, err_len);
        return nullptr;
    }
    auto * s = new ae_stt();
    s->ctx = ctx;
    stt_copy("", err, err_len);
    return s;
}

void ae_stt_destroy(ae_stt * s) {
    if (!s) return;
    if (s->ctx) whisper_free(s->ctx);
    delete s;
}

int32_t ae_stt_transcribe(ae_stt * s, const float * pcm, int32_t n_samples, const char * language,
                          int32_t n_threads, char * out, int32_t out_len) {
    if (!s || !pcm || n_samples <= 0) return -1;
    s->stop.store(false);
    s->last_error.clear();

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads        = n_threads > 0 ? n_threads : 4;
    p.language         = (language && *language) ? language : "auto";
    p.detect_language  = false;
    p.translate        = false;
    p.no_context       = true;
    p.single_segment   = false;
    p.print_progress   = false;
    p.print_realtime   = false;
    p.print_special    = false;
    p.print_timestamps = false;
    p.suppress_blank   = true;
    p.no_timestamps    = true;
    p.temperature_inc  = 0.0f;   // kein mehrfaches Neu-Dekodieren (schneller)
    // Kurze Aufnahmen: Encoder nur über die tatsächliche Länge statt immer 30 s rechnen
    // (bis zu 5× schneller). 1500 Positionen = 30 s → 50 pro Sekunde, plus Reserve.
    if (n_samples < 16000 * 28) {
        int ctx = (int) ((int64_t) n_samples * 50 / 16000) + 128;
        if (ctx < 384) ctx = 384;
        if (ctx < 1500) p.audio_ctx = ctx;
    }
    p.abort_callback   = stt_abort;
    p.abort_callback_user_data = s;

    int rc = whisper_full(s->ctx, p, pcm, n_samples);
    if (s->stop.load()) { s->last_error = "abgebrochen"; return -2; }
    if (rc != 0) { s->last_error = "Transkription fehlgeschlagen (" + std::to_string(rc) + ")"; return -1; }

    std::string text;
    const int n = whisper_full_n_segments(s->ctx);
    for (int i = 0; i < n; i++) {
        const char * seg = whisper_full_get_segment_text(s->ctx, i);
        if (seg) text += seg;
    }
    // führende Leerzeichen entfernen
    size_t b = text.find_first_not_of(" \t\n");
    text = b == std::string::npos ? "" : text.substr(b);
    const int lang = whisper_full_lang_id(s->ctx);
    const char * ls = lang >= 0 ? whisper_lang_str(lang) : nullptr;
    s->language = ls ? ls : "";
    return stt_copy(text, out, out_len);
}

const char * ae_stt_language(ae_stt * s) { return s ? s->language.c_str() : ""; }

void ae_stt_stop(ae_stt * s) { if (s) s->stop.store(true); }

const char * ae_stt_last_error(ae_stt * s) { return s ? s->last_error.c_str() : "stt ist NULL"; }

int64_t ae_free_disk(const char * path) {
    struct statvfs st;
    if (!path || statvfs(path, &st) != 0) return -1;
    return (int64_t) st.f_bavail * (int64_t) st.f_frsize;
}

} // extern "C"
