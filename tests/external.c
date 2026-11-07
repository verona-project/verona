#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef struct { int32_t value; bool flag; } Record;
typedef struct { float x, y; } Floats;
typedef struct { double a, b, c, d; } Quad;
typedef struct { float elements[3]; } FloatArray;
typedef struct { double x; int64_t y; } Mixed;
typedef struct { int64_t elements[3]; } Large;
typedef struct { int16_t elements[3]; } Array3;
typedef struct {
  int32_t tag;
  union {
    struct { uint8_t value; bool flag; } small;
    struct { double value; } real;
    struct { Record value; } record;
  } payload;
} Choice;
typedef struct { Record record; Array3 array; bool flag; } Nested;
typedef struct {} Empty;
typedef struct {
  int32_t tag;
  union { struct { Large value; } big; } payload;
} BigChoice;

Record fixture_record(Record value) {
  value.value += 2;
  value.flag = !value.flag;
  return value;
}
int64_t fixture_mutate_record(Record *value) {
  value->value += 2;
  value->flag = !value->flag;
  return sizeof(*value);
}
Floats fixture_floats(Floats value) {
  value.x += 1.0f;
  value.y += 2.0f;
  return value;
}
Quad fixture_quad(Quad value) { value.a += 2.0; return value; }
FloatArray fixture_float_array(FloatArray value) {
  value.elements[2] += 2.0f;
  return value;
}
double fixture_float(double a, float b) { return a + b; }
BigChoice fixture_big_choice(BigChoice value) {
  if (value.tag == 0) value.payload.big.value.elements[2] += 39;
  return value;
}
Mixed fixture_mixed(Mixed value) {
  value.x += 1.5;
  value.y += 2;
  return value;
}
Large fixture_large(Large value) {
  for (int i = 0; i < 3; ++i) value.elements[i] += i + 1;
  return value;
}
Array3 fixture_array(Array3 value) {
  for (int i = 0; i < 3; ++i) ++value.elements[i];
  return value;
}
Choice fixture_choice(Choice value) {
  switch (value.tag) {
    case 0: value.payload.small.value += 2;
            value.payload.small.flag = !value.payload.small.flag;
            break;
    case 1: value.payload.real.value += 1.25; break;
    case 2: value.payload.record.value.value += 2; break;
  }
  return value;
}
Nested fixture_nested(Nested value) {
  value.record = fixture_record(value.record);
  value.array = fixture_array(value.array);
  value.flag = !value.flag;
  return value;
}
int8_t fixture_narrow(int8_t a, int16_t b, uint8_t c, uint16_t d) {
  return a + b + c + d;
}
Record fixture_record_callback(Record (*callback)(Record), Record value) {
  value = callback(value);
  ++value.value;
  return value;
}
Large fixture_large_callback(Large (*callback)(Large), Large value) {
  return callback(value);
}
Choice fixture_choice_callback(Choice (*callback)(Choice), Choice value) {
  return callback(value);
}
bool fixture_bool_callback(bool (*callback)(bool), bool value) {
  return callback(value);
}
Quad fixture_quad_callback(Quad (*callback)(Quad), Quad value) {
  value = callback(value);
  value.a += 1.0;
  return value;
}
Record (*fixture_get_record(void))(Record) { return fixture_record; }
Record fixture_crowded(int64_t a, int64_t b, int64_t c, int64_t d,
                       int64_t e, int64_t f, Record value) {
  value.value += a + b + c + d + e + f;
  return value;
}
Empty fixture_empty(Empty value) { return value; }

int32_t fixture_arguments(int32_t count, uint8_t **values) {
  if (count != 4 || !values || !values[0] || !values[0][0] || values[count])
    return 1;
  if (strcmp((char *)values[1], "space value") ||
      strcmp((char *)values[2], "") ||
      strcmp((char *)values[3], "omega"))
    return 2;
  return 42;
}

static int64_t match_calls;
int64_t fixture_match_next(void) { return ++match_calls; }
int64_t fixture_match_count(void) { return match_calls; }

static int64_t sequence_trace;
int64_t fixture_sequence_step(int64_t marker) {
  sequence_trace = sequence_trace * 10 + marker;
  return marker;
}
int64_t fixture_sequence_trace(void) { return sequence_trace; }
