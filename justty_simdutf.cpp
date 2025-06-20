#include <simdutf.h>
#include <hwy/highway.h>
#include <hwy/aligned_allocator.h>
#include <hwy/contrib/algo/find-inl.h>
#include <cstdint>
#include <cstring>
#include <cassert>
#include <algorithm> // For std::min



HWY_BEFORE_NAMESPACE();
namespace HWY_NAMESPACE {
namespace hn = hwy::HWY_NAMESPACE;

using D8 = hn::ScalableTag<uint8_t>;
HWY_ATTR size_t IndexOfCharImpl(const uint8_t* HWY_RESTRICT haystack, size_t haystack_len, uint8_t needle) { //from bun

    D8 d;
    const size_t pos = hn::Find<D8>(d, needle, haystack, haystack_len);
    return (pos < haystack_len) ? pos : haystack_len;
}

HWY_ATTR bool CompareImpl(const uint8_t* a, const uint8_t* b, size_t len) {
    D8 d;

    size_t i = 0;
    const size_t N = hn::Lanes(d);
    for (; i + N <= len; i += N) {
        auto va = hn::LoadN(d, a + i, N);
        auto vb = hn::LoadN(d, b + i, N);
        if (!hn::AllTrue(d, hn::Eq(va, vb))) return false;
    }
    for (; i < len; ++i) {
        if (a[i] != b[i]) return false;
    }
    return true;
}


HWY_ATTR size_t LastIndexOfByte(const uint8_t* data, size_t len, uint8_t value) {
    assert(len > 0);
    D8 d;
    const size_t lanes = hn::Lanes(d);

    size_t i = len;
    while (i >= lanes) {
        i -= lanes;
        const auto vec = hn::LoadU(d, data + i);
        const auto mask = vec == hn::Set(d, value); 
        intptr_t pos = hn::FindFirstTrue(d, mask); 
        if (pos >= 0) {
            return i + static_cast<size_t>(pos); 
        }
    }

    while (i > 0) {
        --i;
        if (data[i] == value) return i;
    }

    return 0; 
}
HWY_ATTR size_t IndexOfCsiStartImpl(const uint8_t* input, size_t len) {
    D8 d;
    const size_t N = hn::Lanes(d);
    const auto esc = hn::Set(d, 0x1B);
    const auto bracket = hn::Set(d, 0x5B);
    size_t i = 0;
    for (; i + N <= len; i += N) {
        auto v1 = hn::LoadN(d, input + i, N);
        auto v2 = hn::LoadN(d, input + i + 1, N);
        auto mask = hn::And(hn::Eq(v1, esc), hn::Eq(v2, bracket));
        intptr_t pos = hn::FindFirstTrue(d, mask);
        if (pos >= 0) return i + pos;
    }
    for (; i < len - 1; i++) {
        if (input[i] == 0x1B && input[i + 1] == 0x5B) return i;
    }
    return len;
}


HWY_ATTR size_t ExtractCsiSeqImpl(const uint8_t* input, size_t len, size_t start, size_t* end) {
    // Validate CSI prefix: ESC (0x1B) followed by '['
    if (start + 1 >= len || input[start] != 0x1B || input[start + 1] != '[') {
        return 0;
    }

    D8 d;
    const size_t N = hn::Lanes(d);
    const auto a = hn::Set(d, 'A');
    const auto z = hn::Set(d, 'z');
    size_t i = start + 2; // Skip ESC[
    for (; i + N <= len; i += N) {
        auto v = hn::LoadN(d, input + i, N);
        auto mask = hn::Or(hn::And(hn::Ge(v, a), hn::Le(v, hn::Set(d, 'Z'))),
                           hn::And(hn::Ge(v, hn::Set(d, 'a')), hn::Le(v, z)));
        intptr_t pos = hn::FindFirstTrue(d, mask);
        if (pos >= 0) {
            *end = i + pos + 1;
            return *end - start;
        }
    }
    for (; i < len; i++) {
        uint8_t c = input[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
            *end = i + 1;
            return *end - start;
        }
    }
    return 0;
}
size_t IndexOfSpaceOrNewlineOrNonASCIIImpl(const uint8_t* HWY_RESTRICT start_ptr, size_t search_len)
{
    assert(search_len > 0);

    D8 d;
    const size_t N = hn::Lanes(d);

    const uint8_t after_space = ' ' + 1;

    const auto vec_min_ascii_including_space = hn::Set(d, after_space);
    const auto vec_max_ascii = hn::Set(d, uint8_t { 127 });
    size_t simd_text_len = search_len - (search_len % N);

    size_t i = 0;
    for (; i < simd_text_len; i += N) {
        const auto vec = hn::LoadU(d, start_ptr + i);
        const auto mask_lt_min = hn::Lt(vec, vec_min_ascii_including_space);
        const auto mask_gt_max = hn::Gt(vec, vec_max_ascii);
        const auto found_mask = hn::Or(mask_gt_max, mask_lt_min);
        const intptr_t pos = hn::FindFirstTrue(d, found_mask);
        if (pos >= 0) {
            return i + pos;
        }
    }

    for (; i < search_len; ++i) {
        const uint8_t char_ = start_ptr[i];
        if (char_ <= ' ' || char_ > 127) {
            return i;
        }
    }

    return search_len;
}

bool ContainsNewlineOrNonASCIIOrQuoteImpl(const uint8_t* HWY_RESTRICT text, size_t text_len)
{
    assert(text_len > 0);

    D8 d;
    const size_t N = hn::Lanes(d);

    // SIMD constants
    const auto vec_max_ascii = hn::Set(d, uint8_t { 127 });
    const auto vec_min_ascii = hn::Set(d, uint8_t { 0x20 });
    const auto vec_quote = hn::Set(d, uint8_t { '"' });

    size_t i = 0;
    const size_t simd_text_len = text_len - (text_len % N);

    // Process full vectors
    for (; i < simd_text_len; i += N) {
        const auto vec = hn::LoadU(d, text + i);
        const auto mask_lt_min = hn::Lt(vec, vec_min_ascii);
        const auto mask_gt_max = hn::Gt(vec, vec_max_ascii);

        const auto mask_quote_eq = hn::Eq(vec, vec_quote);

        const auto found_mask = hn::Or(hn::Or(mask_gt_max, mask_lt_min), mask_quote_eq);

        if (!hn::AllFalse(d, found_mask)) {
            return true;
        }
    }

    // Scalar check for the remainder
    for (; i < text_len; ++i) {
        const uint8_t char_ = text[i];
        if (char_ > 127 || char_ < 0x20 || char_ == '"') {
            return true;
        }
    }

    return false;
}


HWY_ATTR void CopyBytesImpl(const uint8_t* src, uint8_t* dst, size_t len) {
    if (len == 0) return;
    D8 d;
    size_t i = 0;
    const size_t N = hn::Lanes(d);
    for (; i + N <= len; i += N) {
        auto v = hn::LoadN(d, src + i, N);
        hn::StoreN(v, d, dst + i, N);
    }
    for (; i < len; ++i) {
        dst[i] = src[i];
    }
}



HWY_ATTR void MoveBytesBackward(const uint8_t* src, uint8_t* dst, size_t len) {
    D8 d;
    size_t i = len;
    const size_t N = hn::Lanes(d);
    while (i >= N) {
        i -= N;
        auto v = hn::LoadN(d, src + i, N);
        hn::StoreN(v, d, dst + i, N);
    }
    while (i > 0) {
        i--;
        dst[i] = src[i];
    }
}

HWY_ATTR void MoveBytesImpl(const uint8_t* src, uint8_t* dst, size_t len) {
    if (len == 0) return;

    // check overlaps
    if (dst <= src || dst >= src + len) {
        CopyBytesImpl(src, dst, len); // full copy
    } else {
        MoveBytesBackward(src, dst, len);
    }
}



HWY_ATTR void ToUpperImpl(uint8_t* text, size_t len) {
    D8 d;
    const auto lower_a = hn::Set(d, uint8_t('a'));
    const auto lower_z = hn::Set(d, uint8_t('z'));
    const auto diff = hn::Set(d, uint8_t('A' - 'a'));
    size_t i = 0;
    const size_t N = hn::Lanes(d);
    for (; i + N <= len; i += N) {
        auto v = hn::LoadN(d, text + i, N);
        auto is_lower = hn::And(hn::Ge(v, lower_a), hn::Le(v, lower_z));
        v = hn::IfThenElse(is_lower, hn::Add(v, diff), v);
        hn::StoreN(v, d, text + i, N);
    }
    for (; i < len; ++i) {
        if (text[i] >= 'a' && text[i] <= 'z') {
            text[i] -= ('a' - 'A');
        }
    }
}
HWY_ATTR size_t IndexOfAnyCharImpl(const uint8_t* HWY_RESTRICT text, size_t text_len, const uint8_t* HWY_RESTRICT chars, size_t chars_len) { //from bun

    if (text_len == 0) return 0;
    D8 d;
    const size_t N = hn::Lanes(d);

    if (chars_len == 0) {
        return text_len; // No characters to find
    } else if (chars_len == 1) {
        return IndexOfCharImpl(text, text_len, chars[0]); // Delegate to single-char search
    } else if (chars_len == 2) {
        const auto vec_char1 = hn::Set(d, chars[0]);
        const auto vec_char2 = hn::Set(d, chars[1]);

        size_t i = 0;
        const size_t simd_text_len = text_len - (text_len % N);
        for (; i < simd_text_len; i += N) {
            const auto text_vec = hn::LoadN(d, text + i, N);
            const auto found_mask = hn::Or(hn::Eq(text_vec, vec_char1), hn::Eq(text_vec, vec_char2));

            const intptr_t pos = hn::FindFirstTrue(d, found_mask);
            if (pos >= 0) {
                return i + pos;
            }
        }

        for (; i < text_len; ++i) {
            const uint8_t text_char = text[i];
            if (text_char == chars[0] || text_char == chars[1]) {
                return i;
            }
        }
        return text_len;
    } else {
        // Limit to 16 characters to avoid excessive memory usage
        constexpr size_t kMaxPreloadedChars = 16;
        hn::Vec<D8> char_vecs[kMaxPreloadedChars];
        const size_t num_chars_to_preload = std::min(chars_len, kMaxPreloadedChars);
        for (size_t c = 0; c < num_chars_to_preload; ++c) {
            char_vecs[c] = hn::Set(d, chars[c]);
        }

        const size_t simd_text_len = text_len - (text_len % N);
        size_t i = 0;

        for (; i < simd_text_len; i += N) {
            const auto text_vec = hn::LoadN(d, text + i, N);
            auto found_mask = hn::MaskFalse(d);

            for (size_t c = 0; c < num_chars_to_preload; ++c) {
                found_mask = hn::Or(found_mask, hn::Eq(text_vec, char_vecs[c]));
            }
            if (chars_len > num_chars_to_preload) {
                for (size_t c = num_chars_to_preload; c < chars_len; ++c) {
                    found_mask = hn::Or(found_mask, hn::Eq(text_vec, hn::Set(d, chars[c])));
                }
            }

            const intptr_t pos = hn::FindFirstTrue(d, found_mask);
            if (pos >= 0) {
                return i + pos;
            }
        }

        for (; i < text_len; ++i) {
            const uint8_t text_char = text[i];
            for (size_t c = 0; c < chars_len; ++c) {
                if (text_char == chars[c]) {
                    return i;
                }
            }
        }
        return text_len;
    }
}
}  // namespace HWY_NAMESPACE
HWY_AFTER_NAMESPACE();



extern "C" {

HWY_EXPORT(LastIndexOfByte);
HWY_EXPORT(IndexOfCharImpl);
HWY_EXPORT(IndexOfAnyCharImpl);
HWY_EXPORT(CompareImpl);
HWY_EXPORT(CopyBytesImpl);
HWY_EXPORT(ToUpperImpl);
HWY_EXPORT(IndexOfSpaceOrNewlineOrNonASCIIImpl);
HWY_EXPORT(ContainsNewlineOrNonASCIIOrQuoteImpl);
HWY_EXPORT(IndexOfCsiStartImpl);
HWY_EXPORT(ExtractCsiSeqImpl);
HWY_EXPORT(MoveBytesImpl);






size_t simd_base64_max_length(const char* input, size_t length) {
    return simdutf::maximal_binary_length_from_base64(input, length);
}


bool simd_contains_newline_or_non_ascii_or_quote(const uint8_t* HWY_RESTRICT text, size_t text_len)
{
    return HWY_DYNAMIC_DISPATCH(ContainsNewlineOrNonASCIIOrQuoteImpl)(text, text_len);
}

size_t simd_index_of_csi_start(const uint8_t* input, size_t len) {
    return HWY_DYNAMIC_DISPATCH(IndexOfCsiStartImpl)(input, len);
}


size_t simd_extract_csi_sequence(const uint8_t* input, size_t len, size_t start, size_t* end) {
    return HWY_DYNAMIC_DISPATCH(ExtractCsiSeqImpl)(input, len, start, end);
}


size_t simd_last_index_of_byte(const uint8_t* input, size_t len,uint8_t value)
 {
     return HWY_DYNAMIC_DISPATCH(LastIndexOfByte)(input,len,value);
}



size_t simd_index_of_space_or_newline_or_non_ascii(const uint8_t* HWY_RESTRICT text, size_t text_len)
{
    return HWY_DYNAMIC_DISPATCH(IndexOfSpaceOrNewlineOrNonASCIIImpl)(text, text_len);
}

size_t simd_base64_decode(const char* input, size_t length, char* output) {
    simdutf::result r = simdutf::base64_to_binary(input, length, output);
    if (r.error) {
        return -1;
    }
    return r.count;
}

bool simd_validate_ascii(const char* buf, size_t len) {
    return simdutf::validate_ascii(buf, len);
}

bool simd_validate_utf8(const char* buf, size_t len) {
    return simdutf::validate_utf8(buf, len);
}

size_t simd_convert_utf8_to_utf32(const char* input, size_t length, char32_t* output) {
    return simdutf::convert_utf8_to_utf32(input, length, output);
}

size_t simd_utf32_len_from_utf8(const char* input, size_t length) {
    return simdutf::utf32_length_from_utf8(input, length);
}

size_t simd_convert_utf32_to_utf8(const char32_t* input, size_t len, char* output) {
    return simdutf::convert_utf32_to_utf8(input, len, output);
}

size_t simd_index_of_char(const uint8_t* haystack, size_t haystack_len, uint8_t needle) {
    return HWY_DYNAMIC_DISPATCH(IndexOfCharImpl)(haystack, haystack_len, needle);
}


size_t simd_index_of_any_char(const uint8_t* text, size_t text_len, const uint8_t* chars, size_t chars_len) {
    return HWY_DYNAMIC_DISPATCH(IndexOfAnyCharImpl)(text, text_len, chars, chars_len);
}


int simd_detect_encodings(const char* input, size_t length) {
    return static_cast<int>(simdutf::detect_encodings(input, length));
}



size_t simd_count_utf8(const char* input, size_t length) {
    return simdutf::count_utf8(input, length);
}


bool simd_compare(const uint8_t* a, size_t a_len, const uint8_t* b, size_t b_len) {
    if (a_len != b_len) return false;
    return HWY_DYNAMIC_DISPATCH(CompareImpl)(a, b, a_len);
}


void simd_copy_bytes(const uint8_t* src, uint8_t* dst, size_t len) {
        HWY_DYNAMIC_DISPATCH(CopyBytesImpl)(src, dst, len);
}

void move_bytes(const uint8_t* src, uint8_t* dst, size_t len) {
    HWY_DYNAMIC_DISPATCH(MoveBytesImpl)(src, dst, len);
}

void simd_to_upper(uint8_t* text, size_t len) {
        HWY_DYNAMIC_DISPATCH(ToUpperImpl)(text, len);
}

}  // extern "C"
