#include <stdint.h>
#include "softfloat.h"
void sf_init(void) { softfloat_roundingMode = softfloat_round_near_even; softfloat_detectTininess = softfloat_tininess_afterRounding; }
uint16_t sf_fma(uint16_t a, uint16_t b, uint16_t c) { return f16_mulAdd((float16_t){a}, (float16_t){b}, (float16_t){c}).v; }
uint16_t sf_add(uint16_t a, uint16_t b) { return f16_add((float16_t){a}, (float16_t){b}).v; }
uint16_t sf_sub(uint16_t a, uint16_t b) { return f16_sub((float16_t){a}, (float16_t){b}).v; }
uint16_t sf_mul(uint16_t a, uint16_t b) { return f16_mul((float16_t){a}, (float16_t){b}).v; }
uint16_t sf_div(uint16_t a, uint16_t b) { return f16_div((float16_t){a}, (float16_t){b}).v; }
