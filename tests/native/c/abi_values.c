#include <stdint.h>

struct verona_pair_value { int32_t left; int32_t right; };
struct verona_i32x2 { int32_t elements[2]; };
struct verona_choice_value {
  int32_t tag;
  union { struct { int32_t value; } case1; struct { double value; } case2; } payload;
};

int32_t verona_pair_value_sum(struct verona_pair_value value) { return value.left + value.right; }
struct verona_pair_value verona_pair_value_make(int32_t left, int32_t right) {
  return (struct verona_pair_value){left, right};
}
int32_t verona_i32x2_sum(struct verona_i32x2 value) { return value.elements[0] + value.elements[1]; }
int32_t verona_choice_value_read(struct verona_choice_value value) {
  return value.tag == 1 ? value.payload.case1.value : 0;
}
int32_t verona_apply_i32(int32_t (*callback)(int32_t), int32_t value) { return callback(value); }
