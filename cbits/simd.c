#include "simd.h"

#include <immintrin.h>
#include <mmintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>

typedef uint8_t v32si __attribute__ ((vector_size (32)));
typedef uint8_t v16si __attribute__ ((vector_size (16)));

void print_bits_16(uint16_t word) {
  putc('|', stdout);
  for (size_t i = 0; i < 16; ++i) {
    putc((word & (1L << i)) ? '1' : '0', stdout);
  }
  printf("|\n");
}

void system_memcpy(
    char *target,
    char *source,
    size_t len) {
  memcpy(target, source, len);
}

#if defined(AVX2_ENABLED)
void avx2_memcpy(
    uint8_t *target,
    uint8_t *source,
    size_t len) {
  size_t aligned_len    = (len / 32) * 32;
  size_t remaining_len  = len - aligned_len;

  for (size_t i = 0; i < aligned_len; i += 32) {
    __m128i v0 = *(__m128i*)(source + i     );
    __m128i v1 = *(__m128i*)(source + i + 16);

    *(__m128i*)(target + i      ) = v0;
    *(__m128i*)(target + i + 16 ) = v1;
  }

  memcpy(target + aligned_len, source + aligned_len, remaining_len);
}

void avx2_cmpeq8(
    uint8_t byte,
    uint64_t *target,
    size_t target_length,
    uint8_t *source) {
  uint16_t *target16 = (uint16_t *)target;

  __m128i v_comparand = _mm_set1_epi8(byte);

  uint16_t *out_mask = (uint16_t*)target;

  for (size_t i = 0; i < target_length * 4; ++i) {
    __m128i v_data_a = *(__m128i*)(source + (i * 16));
    __m128i v_results_a = _mm_cmpeq_epi8(v_data_a, v_comparand);
    uint16_t mask = (uint16_t)_mm_movemask_epi8(v_results_a);
    target16[i] = mask;
  }
}

#endif

int example_main() {
  uint8_t source[32] = "01234567890123456789012345678901";
  uint8_t target[33];
  avx2_memcpy(target, source, 32);
  target[32] = 0;
  printf("%s\n", target);

  // uint8_t source2[64] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  // uint64_t target2[1] = {0};
  // avx2_cmpeq8('0', target2, 1, source2);
  // printf("%llu\n", target2[0]);

  return 0;
}
