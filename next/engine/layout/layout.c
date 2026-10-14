// Prints the size and every field offset of the whisper.cpp and parakeet structs the Rust engine
// mirrors, from the real headers. src/ffi.rs's layout test holds the same numbers.
//   cc -I/opt/homebrew/include layout.c -o /tmp/layout && /tmp/layout
#include <stdio.h>
#include <stddef.h>
#include "whisper.h"
#include "parakeet.h"

#define F(T, f) printf("%s.%s %zu\n", #T, #f, offsetof(struct T, f))
#define S(T) printf("%s %zu\n", #T, sizeof(struct T))

int main(void) {
    S(whisper_context_params);
    F(whisper_context_params, use_gpu); F(whisper_context_params, flash_attn); F(whisper_context_params, gpu_device);
    F(whisper_context_params, dtw_token_timestamps); F(whisper_context_params, dtw_aheads_preset); F(whisper_context_params, dtw_n_top);
    F(whisper_context_params, dtw_aheads); F(whisper_context_params, dtw_mem_size);
    S(whisper_vad_params);
    F(whisper_vad_params, threshold); F(whisper_vad_params, min_speech_duration_ms); F(whisper_vad_params, min_silence_duration_ms);
    F(whisper_vad_params, max_speech_duration_s); F(whisper_vad_params, speech_pad_ms); F(whisper_vad_params, samples_overlap);
    S(whisper_full_params);
    F(whisper_full_params, strategy); F(whisper_full_params, n_threads); F(whisper_full_params, n_max_text_ctx); F(whisper_full_params, offset_ms);
    F(whisper_full_params, duration_ms); F(whisper_full_params, translate); F(whisper_full_params, no_context); F(whisper_full_params, no_timestamps);
    F(whisper_full_params, single_segment); F(whisper_full_params, print_special); F(whisper_full_params, print_progress); F(whisper_full_params, print_realtime);
    F(whisper_full_params, print_timestamps); F(whisper_full_params, token_timestamps); F(whisper_full_params, thold_pt); F(whisper_full_params, thold_ptsum);
    F(whisper_full_params, max_len); F(whisper_full_params, split_on_word); F(whisper_full_params, max_tokens); F(whisper_full_params, debug_mode);
    F(whisper_full_params, audio_ctx); F(whisper_full_params, tdrz_enable); F(whisper_full_params, suppress_regex); F(whisper_full_params, initial_prompt);
    F(whisper_full_params, carry_initial_prompt); F(whisper_full_params, prompt_tokens); F(whisper_full_params, prompt_n_tokens); F(whisper_full_params, language);
    F(whisper_full_params, detect_language); F(whisper_full_params, suppress_blank); F(whisper_full_params, suppress_nst); F(whisper_full_params, temperature);
    F(whisper_full_params, max_initial_ts); F(whisper_full_params, length_penalty); F(whisper_full_params, temperature_inc); F(whisper_full_params, entropy_thold);
    F(whisper_full_params, logprob_thold); F(whisper_full_params, no_speech_thold); F(whisper_full_params, greedy); F(whisper_full_params, beam_search);
    F(whisper_full_params, new_segment_callback); F(whisper_full_params, new_segment_callback_user_data); F(whisper_full_params, progress_callback);
    F(whisper_full_params, progress_callback_user_data); F(whisper_full_params, encoder_begin_callback); F(whisper_full_params, encoder_begin_callback_user_data);
    F(whisper_full_params, abort_callback); F(whisper_full_params, abort_callback_user_data); F(whisper_full_params, logits_filter_callback);
    F(whisper_full_params, logits_filter_callback_user_data); F(whisper_full_params, grammar_rules); F(whisper_full_params, n_grammar_rules);
    F(whisper_full_params, i_start_rule); F(whisper_full_params, grammar_penalty); F(whisper_full_params, vad); F(whisper_full_params, vad_model_path);
    F(whisper_full_params, vad_params);
    S(parakeet_context_params);
    F(parakeet_context_params, use_gpu); F(parakeet_context_params, gpu_device);
    S(parakeet_full_params);
    F(parakeet_full_params, strategy); F(parakeet_full_params, n_threads); F(parakeet_full_params, offset_ms); F(parakeet_full_params, duration_ms);
    F(parakeet_full_params, no_context); F(parakeet_full_params, audio_ctx); F(parakeet_full_params, new_segment_callback);
    F(parakeet_full_params, new_segment_callback_user_data); F(parakeet_full_params, new_token_callback); F(parakeet_full_params, new_token_callback_user_data);
    F(parakeet_full_params, progress_callback); F(parakeet_full_params, progress_callback_user_data); F(parakeet_full_params, encoder_begin_callback);
    F(parakeet_full_params, encoder_begin_callback_user_data); F(parakeet_full_params, abort_callback); F(parakeet_full_params, abort_callback_user_data);
    return 0;
}
