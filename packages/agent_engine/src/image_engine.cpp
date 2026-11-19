// image_engine.cpp — Bildgenerierung über stable-diffusion.cpp (C-API, siehe agent_engine.h).

#include "agent_engine.h"
#include "stable-diffusion.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

struct ae_image {
    sd_ctx_t * ctx = nullptr;
    std::string last_error;
};

static std::atomic<int> g_step{0};
static std::atomic<int> g_steps{0};
static std::mutex g_sd_log_mutex;
static std::string g_sd_last_log_error;

static void sd_log(enum sd_log_level_t level, const char * text, void *) {
    if (level == SD_LOG_ERROR && text) {
        std::lock_guard<std::mutex> lk(g_sd_log_mutex);
        g_sd_last_log_error = text;
        while (!g_sd_last_log_error.empty() && (g_sd_last_log_error.back() == '\n' || g_sd_last_log_error.back() == ' '))
            g_sd_last_log_error.pop_back();
    }
}

static void sd_progress(int step, int steps, float, void *) {
    g_step.store(step);
    g_steps.store(steps);
}

static std::string sd_error(const char * fallback) {
    const char * e = sd_get_last_error();
    std::string msg = (e && *e) ? e : fallback;
    std::lock_guard<std::mutex> lk(g_sd_log_mutex);
    if (!g_sd_last_log_error.empty() && msg.find(g_sd_last_log_error) == std::string::npos)
        msg += " (" + g_sd_last_log_error + ")";
    g_sd_last_log_error.clear();
    return msg;
}

static void copy_err(const std::string & s, char * buf, int32_t len) {
    if (!buf || len <= 0) return;
    size_t n = std::min<size_t>(s.size(), (size_t) len - 1);
    memcpy(buf, s.data(), n);
    buf[n] = 0;
}

ae_image * ae_img_create(const char * model_path, int32_t n_threads, int32_t vae_tiling, char * err, int32_t err_len) {
    sd_set_log_callback(sd_log, nullptr);
    sd_set_progress_callback(sd_progress, nullptr);
    sd_ctx_opt_t * o = sd_ctx_opt_create();
    if (!o) { copy_err("kein Speicher", err, err_len); return nullptr; }
    sd_ctx_t * ctx = nullptr;
    sd_status_t st = sd_opt_set_string(o, "model_path", model_path);
    if (st == SD_STATUS_OK && n_threads > 0) st = sd_opt_set_int(o, "n_threads", n_threads);
    if (st == SD_STATUS_OK) sd_opt_set_bool(o, "enable_mmap", true);  // optional, Fehler egal
    if (st == SD_STATUS_OK) st = sd_ctx_create(o, &ctx);
    sd_opt_free(o);
    if (st != SD_STATUS_OK || !ctx) {
        copy_err(sd_error("Bildmodell konnte nicht geladen werden"), err, err_len);
        return nullptr;
    }
    auto * im = new ae_image();
    im->ctx = ctx;
    (void) vae_tiling;
    copy_err("", err, err_len);
    return im;
}

void ae_img_destroy(ae_image * im) {
    if (!im) return;
    if (im->ctx) sd_ctx_free(im->ctx);
    delete im;
}

int32_t ae_img_generate(ae_image * im, const char * prompt, const char * negative, int32_t width, int32_t height,
                        int32_t steps, float cfg, int64_t seed, const char * method, int32_t vae_tiling,
                        uint8_t ** out_rgb, int32_t * out_w, int32_t * out_h) {
    if (!im || !im->ctx || !prompt || !out_rgb) return -1;
    *out_rgb = nullptr;
    g_step.store(0);
    g_steps.store(steps);
    sd_cancel_generation(im->ctx, SD_CANCEL_RESET);
    sd_img_gen_opt_t * o = sd_img_gen_opt_create();
    if (!o) { im->last_error = "kein Speicher"; return -1; }
    sd_status_t st = sd_opt_set_string(o, "prompt", prompt);
    if (st == SD_STATUS_OK && negative && *negative) st = sd_opt_set_string(o, "negative_prompt", negative);
    if (st == SD_STATUS_OK) st = sd_opt_set_int(o, "width", width);
    if (st == SD_STATUS_OK) st = sd_opt_set_int(o, "height", height);
    if (st == SD_STATUS_OK) st = sd_opt_set_int(o, "seed", seed);
    if (st == SD_STATUS_OK && steps > 0) st = sd_opt_set_int(o, "sample.steps", steps);
    if (st == SD_STATUS_OK && cfg > 0) st = sd_opt_set_float(o, "sample.guidance.txt_cfg", cfg);
    if (st == SD_STATUS_OK && method && *method) st = sd_opt_set_string(o, "sample.method", method);
    if (st == SD_STATUS_OK && vae_tiling) sd_opt_set_bool(o, "vae_tiling.enabled", true);
    sd_result_t * res = nullptr;
    if (st == SD_STATUS_OK) st = sd_generate_image(im->ctx, o, &res);
    sd_opt_free(o);
    if (st == SD_STATUS_CANCELLED) { sd_result_free(res); im->last_error = "abgebrochen"; return 1; }
    if (st != SD_STATUS_OK || !res || sd_result_get_image_count(res) == 0) {
        im->last_error = sd_error("Bildgenerierung fehlgeschlagen");
        sd_result_free(res);
        return -1;
    }
    const sd_tensor_t * t = sd_result_get_image(res, 0);
    // Layout: U8 [C, W, H] – Kanäle innen, also zeilenweise RGB
    int64_t c = sd_tensor_dim(t, 0), w = sd_tensor_dim(t, 1), h = sd_tensor_dim(t, 2);
    const uint8_t * data = (const uint8_t *) sd_tensor_data(t);
    if (!data || w <= 0 || h <= 0 || (c != 3 && c != 4)) {
        im->last_error = "unerwartetes Bildformat";
        sd_result_free(res);
        return -1;
    }
    uint8_t * buf = (uint8_t *) malloc((size_t) (w * h * 3));
    if (!buf) { sd_result_free(res); im->last_error = "kein Speicher"; return -1; }
    if (c == 3) {
        memcpy(buf, data, (size_t) (w * h * 3));
    } else {
        for (int64_t i = 0; i < w * h; i++) {
            buf[i * 3] = data[i * 4]; buf[i * 3 + 1] = data[i * 4 + 1]; buf[i * 3 + 2] = data[i * 4 + 2];
        }
    }
    sd_result_free(res);
    *out_rgb = buf;
    *out_w = (int32_t) w;
    *out_h = (int32_t) h;
    return 0;
}

void ae_img_cancel(ae_image * im) {
    if (im && im->ctx) sd_cancel_generation(im->ctx, SD_CANCEL_ALL);
}

void ae_img_progress(int32_t * step, int32_t * steps) {
    if (step) *step = g_step.load();
    if (steps) *steps = g_steps.load();
}

const char * ae_img_last_error(ae_image * im) { return im ? im->last_error.c_str() : ""; }

void ae_free(void * p) { free(p); }
