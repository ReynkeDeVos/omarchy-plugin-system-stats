#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

enum { CPU_FIELD_COUNT = 8, MAX_COMMAND_BYTES = 65536 };

static const uint64_t MAX_SAFE_INTEGER = UINT64_C(9007199254740991);

typedef struct {
  uint64_t user;
  uint64_t nice;
  uint64_t system;
  uint64_t idle;
  uint64_t iowait;
  uint64_t irq;
  uint64_t softirq;
  uint64_t steal;
} CpuCounters;

typedef struct {
  const char *frames_path;
  const char *meminfo_frames_path;
  long interval_ms;
  long second_ms;
} Options;

typedef struct {
  uint64_t generation;
  uint64_t command_id;
  uint64_t config_revision;
  long interval_seconds;
} ConfigureCommand;

typedef struct {
  const char *code;
  int64_t since_ms;
} MetricFailureState;

typedef struct {
  uint64_t used_bytes;
  uint64_t total_bytes;
  int percent;
} MemoryUsage;

typedef enum {
  PARSE_OK,
  PARSE_MISSING_FIELD,
  PARSE_MALFORMED,
  PARSE_SOURCE_UNREADABLE
} ParseResult;

typedef struct {
  FILE *cpu_frames;
  FILE *meminfo_frames;
  CpuCounters previous_cpu;
  ParseResult previous_cpu_result;
  struct timespec baseline_at;
} HostSampler;

typedef struct {
  bool cpu_available;
  int cpu_percent;
  const char *cpu_error;
  bool ram_available;
  MemoryUsage ram;
  const char *ram_error;
  struct timespec sampled_at;
  int64_t window_ms;
} HostObservation;

static void fail(const char *message) {
  fprintf(stderr, "system-stats-helper: %s\n", message);
  exit(EXIT_FAILURE);
}

static Options parse_options(int argc, char **argv) {
  const char *frames_path = getenv("SYSTEM_STATS_FRAMES");
  const char *meminfo_frames_path = getenv("SYSTEM_STATS_MEMINFO_FRAMES");
  const char *interval_text = getenv("SYSTEM_STATS_INTERVAL_MS");
  const char *second_text = getenv("SYSTEM_STATS_SECOND_MS");
  Options options = {
      .frames_path =
          frames_path != NULL && *frames_path != '\0' ? frames_path : NULL,
      .meminfo_frames_path =
          meminfo_frames_path != NULL && *meminfo_frames_path != '\0'
              ? meminfo_frames_path
              : NULL,
      .interval_ms = 2000,
      .second_ms = 1000,
  };

  if (second_text != NULL && *second_text != '\0') {
    char *end = NULL;
    errno = 0;
    long value = strtol(second_text, &end, 10);
    if (errno != 0 || end == second_text || *end != '\0' || value <= 0 ||
        value > LONG_MAX / 10) {
      fail("SYSTEM_STATS_SECOND_MS must be a positive integer");
    }
    options.second_ms = value;
    options.interval_ms = 2 * value;
  }

  if (interval_text != NULL && *interval_text != '\0') {
    char *end = NULL;
    errno = 0;
    long value = strtol(interval_text, &end, 10);
    if (errno != 0 || end == interval_text || *end != '\0' || value <= 0) {
      fail("SYSTEM_STATS_INTERVAL_MS must be a positive integer");
    }
    options.interval_ms = value;
  }

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
      options.frames_path = argv[++i];
    } else if (strcmp(argv[i], "--meminfo-frames") == 0 && i + 1 < argc) {
      options.meminfo_frames_path = argv[++i];
    } else if (strcmp(argv[i], "--interval-ms") == 0 && i + 1 < argc) {
      char *end = NULL;
      errno = 0;
      long value = strtol(argv[++i], &end, 10);
      if (errno != 0 || end == argv[i] || *end != '\0' || value <= 0) {
        fail("--interval-ms must be a positive integer");
      }
      options.interval_ms = value;
    } else {
      fail("usage: system-stats-helper [--frames PATH] [--meminfo-frames PATH] "
           "[--interval-ms N]");
    }
  }

  return options;
}

static ParseResult parse_cpu_line(char *line, CpuCounters *counters) {
  char *cursor = line;
  while (isspace((unsigned char)*cursor))
    cursor++;
  if (strncmp(cursor, "cpu", 3) != 0 || !isspace((unsigned char)cursor[3])) {
    return PARSE_MALFORMED;
  }
  cursor += 3;

  uint64_t *fields[CPU_FIELD_COUNT] = {
      &counters->user,   &counters->nice, &counters->system,  &counters->idle,
      &counters->iowait, &counters->irq,  &counters->softirq, &counters->steal,
  };

  for (size_t i = 0; i < CPU_FIELD_COUNT; i++) {
    while (isspace((unsigned char)*cursor))
      cursor++;
    if (*cursor == '\0')
      return PARSE_MISSING_FIELD;
    if (!isdigit((unsigned char)*cursor))
      return PARSE_MALFORMED;

    errno = 0;
    char *end = NULL;
    uintmax_t value = strtoumax(cursor, &end, 10);
    if (errno == ERANGE || end == cursor || value > UINT64_MAX)
      return PARSE_MALFORMED;
    if (*end != '\0' && !isspace((unsigned char)*end))
      return PARSE_MALFORMED;

    *fields[i] = (uint64_t)value;
    cursor = end;
  }

  return PARSE_OK;
}

static ParseResult read_counters(FILE *frames, CpuCounters *counters) {
  FILE *stream = frames;
  if (stream == NULL) {
    stream = fopen("/proc/stat", "re");
    if (stream == NULL)
      return PARSE_SOURCE_UNREADABLE;
  }

  char *line = NULL;
  size_t capacity = 0;
  ssize_t length = getline(&line, &capacity, stream);
  ParseResult result =
      length < 0 ? PARSE_SOURCE_UNREADABLE : parse_cpu_line(line, counters);
  free(line);

  if (frames == NULL)
    fclose(stream);
  return result;
}

static ParseResult parse_memory_field(char *field, uint64_t *total_kb,
                                      bool *has_total, uint64_t *available_kb,
                                      bool *has_available) {
  char *cursor = field;
  while (isspace((unsigned char)*cursor))
    cursor++;

  uint64_t *destination = NULL;
  bool *seen = NULL;
  if (strncmp(cursor, "MemTotal:", 9) == 0) {
    cursor += 9;
    destination = total_kb;
    seen = has_total;
  } else if (strncmp(cursor, "MemAvailable:", 13) == 0) {
    cursor += 13;
    destination = available_kb;
    seen = has_available;
  } else {
    return PARSE_OK;
  }

  if (*seen)
    return PARSE_MALFORMED;
  while (isspace((unsigned char)*cursor))
    cursor++;
  if (!isdigit((unsigned char)*cursor))
    return PARSE_MALFORMED;

  errno = 0;
  char *end = NULL;
  uintmax_t value = strtoumax(cursor, &end, 10);
  if (errno == ERANGE || end == cursor || value > UINT64_MAX)
    return PARSE_MALFORMED;
  cursor = end;
  while (isspace((unsigned char)*cursor))
    cursor++;
  if (strncmp(cursor, "kB", 2) != 0)
    return PARSE_MALFORMED;
  cursor += 2;
  while (isspace((unsigned char)*cursor))
    cursor++;
  if (*cursor != '\0' && *cursor != '\n')
    return PARSE_MALFORMED;

  *destination = (uint64_t)value;
  *seen = true;
  return PARSE_OK;
}

static ParseResult read_memory(FILE *frames, MemoryUsage *usage) {
  FILE *stream = frames;
  if (stream == NULL) {
    stream = fopen("/proc/meminfo", "re");
    if (stream == NULL)
      return PARSE_SOURCE_UNREADABLE;
  }

  uint64_t total_kb = 0;
  uint64_t available_kb = 0;
  bool has_total = false;
  bool has_available = false;
  ParseResult result = PARSE_OK;
  char *line = NULL;
  size_t capacity = 0;

  if (frames != NULL) {
    ssize_t length = getline(&line, &capacity, stream);
    if (length < 0) {
      result = PARSE_SOURCE_UNREADABLE;
    } else {
      char *save = NULL;
      for (char *field = strtok_r(line, ";", &save); field != NULL;
           field = strtok_r(NULL, ";", &save)) {
        result = parse_memory_field(field, &total_kb, &has_total, &available_kb,
                                    &has_available);
        if (result != PARSE_OK)
          break;
      }
    }
  } else {
    while (getline(&line, &capacity, stream) >= 0) {
      result = parse_memory_field(line, &total_kb, &has_total, &available_kb,
                                  &has_available);
      if (result != PARSE_OK)
        break;
    }
    if (ferror(stream))
      result = PARSE_SOURCE_UNREADABLE;
  }

  free(line);
  if (frames == NULL)
    fclose(stream);
  if (result != PARSE_OK)
    return result;
  if (!has_total || !has_available)
    return PARSE_MISSING_FIELD;
  if (total_kb == 0 || available_kb > total_kb ||
      total_kb > MAX_SAFE_INTEGER / 1024)
    return PARSE_MALFORMED;

  usage->total_bytes = total_kb * 1024;
  usage->used_bytes = (total_kb - available_kb) * 1024;
  long double value =
      (long double)usage->used_bytes * 100.0L / (long double)usage->total_bytes;
  usage->percent = (int)floorl(value + 0.5L);
  return PARSE_OK;
}

static int64_t monotonic_ms(struct timespec instant) {
  return (int64_t)instant.tv_sec * 1000 + instant.tv_nsec / 1000000;
}

static uint64_t new_generation(void) {
  uint64_t entropy = 0;
  unsigned char *cursor = (unsigned char *)&entropy;
  size_t remaining = sizeof(entropy);
  while (remaining > 0) {
    ssize_t received = getrandom(cursor, remaining, 0);
    if (received < 0 && errno == EINTR)
      continue;
    if (received <= 0)
      fail("could not create helper generation");
    cursor += (size_t)received;
    remaining -= (size_t)received;
  }

  const uint64_t safe_integer_high_bit = UINT64_C(1) << 52;
  return safe_integer_high_bit | (entropy & (safe_integer_high_bit - 1));
}

static struct timespec add_ms(struct timespec instant, long milliseconds) {
  instant.tv_sec += milliseconds / 1000;
  instant.tv_nsec += (milliseconds % 1000) * 1000000L;
  if (instant.tv_nsec >= 1000000000L) {
    instant.tv_sec++;
    instant.tv_nsec -= 1000000000L;
  }
  return instant;
}

static int compare_timespec(struct timespec left, struct timespec right) {
  if (left.tv_sec != right.tv_sec)
    return left.tv_sec < right.tv_sec ? -1 : 1;
  if (left.tv_nsec == right.tv_nsec)
    return 0;
  return left.tv_nsec < right.tv_nsec ? -1 : 1;
}

static struct timespec monotonic_now(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    fail("could not read monotonic clock");
  return now;
}

static int milliseconds_until(struct timespec deadline, struct timespec now) {
  int64_t nanoseconds = (int64_t)(deadline.tv_sec - now.tv_sec) * 1000000000LL +
                        deadline.tv_nsec - now.tv_nsec;
  if (nanoseconds <= 0)
    return 0;
  int64_t milliseconds = (nanoseconds + 999999LL) / 1000000LL;
  return milliseconds > INT_MAX ? INT_MAX : (int)milliseconds;
}

static const char *parse_error(ParseResult result) {
  if (result == PARSE_SOURCE_UNREADABLE)
    return "sourceUnreadable";
  return result == PARSE_MISSING_FIELD ? "missingRequiredField"
                                       : "malformedCounter";
}

static bool cpu_percent(const CpuCounters *before, const CpuCounters *after,
                        int *percent, const char **error) {
  if (after->user < before->user || after->nice < before->nice ||
      after->system < before->system || after->idle < before->idle ||
      after->iowait < before->iowait || after->irq < before->irq ||
      after->softirq < before->softirq || after->steal < before->steal) {
    *error = "counterReset";
    return false;
  }

  uint64_t active =
      (after->user - before->user) + (after->nice - before->nice) +
      (after->system - before->system) + (after->irq - before->irq) +
      (after->softirq - before->softirq) + (after->steal - before->steal);
  uint64_t inactive =
      (after->idle - before->idle) + (after->iowait - before->iowait);
  uint64_t total = active + inactive;
  if (total == 0) {
    *error = "malformedCounter";
    return false;
  }

  long double value = (long double)active * 100.0L / (long double)total;
  *percent = (int)floorl(value + 0.5L);
  return true;
}

static HostSampler host_sampler_create(const Options *options) {
  HostSampler sampler = {
      .cpu_frames = options->frames_path == NULL
                        ? NULL
                        : fopen(options->frames_path, "re"),
      .meminfo_frames = options->meminfo_frames_path == NULL
                            ? NULL
                            : fopen(options->meminfo_frames_path, "re"),
  };
  if (options->frames_path != NULL && sampler.cpu_frames == NULL)
    fail("could not open fixture frames");
  if (options->meminfo_frames_path != NULL && sampler.meminfo_frames == NULL)
    fail("could not open memory fixture frames");

  sampler.previous_cpu_result =
      read_counters(sampler.cpu_frames, &sampler.previous_cpu);
  sampler.baseline_at = monotonic_now();
  return sampler;
}

static struct timespec host_sampler_reset(HostSampler *sampler) {
  sampler->previous_cpu_result =
      read_counters(sampler->cpu_frames, &sampler->previous_cpu);
  sampler->baseline_at = monotonic_now();
  return sampler->baseline_at;
}

static HostObservation host_sampler_observe(HostSampler *sampler) {
  CpuCounters current_cpu = {0};
  ParseResult current_cpu_result =
      read_counters(sampler->cpu_frames, &current_cpu);
  HostObservation observation = {0};
  ParseResult ram_result =
      read_memory(sampler->meminfo_frames, &observation.ram);
  observation.sampled_at = monotonic_now();
  observation.window_ms =
      monotonic_ms(observation.sampled_at) - monotonic_ms(sampler->baseline_at);

  if (sampler->previous_cpu_result != PARSE_OK) {
    observation.cpu_error = parse_error(sampler->previous_cpu_result);
  } else if (current_cpu_result != PARSE_OK) {
    observation.cpu_error = parse_error(current_cpu_result);
  } else {
    observation.cpu_available =
        cpu_percent(&sampler->previous_cpu, &current_cpu,
                    &observation.cpu_percent, &observation.cpu_error);
  }

  observation.ram_available = ram_result == PARSE_OK;
  if (!observation.ram_available)
    observation.ram_error = parse_error(ram_result);

  sampler->previous_cpu = current_cpu;
  sampler->previous_cpu_result = current_cpu_result;
  sampler->baseline_at = observation.sampled_at;
  return observation;
}

static bool host_sampler_fixture_exhausted(const HostSampler *sampler) {
  return sampler->cpu_frames != NULL && feof(sampler->cpu_frames);
}

static void emit_hello(uint64_t generation, int64_t published_at_ms) {
  printf("{\"type\":\"hello\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"publishedAtMs\":%" PRId64 "}\n",
         generation, published_at_ms);
  fflush(stdout);
}

static void emit_ack(uint64_t generation, const ConfigureCommand *command) {
  printf("{\"type\":\"ack\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"intervalSeconds\":%ld}\n",
         generation, command->command_id, command->config_revision,
         command->interval_seconds);
  fflush(stdout);
}

static void emit_reject(uint64_t generation, uint64_t command_id) {
  printf("{\"type\":\"reject\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"error\":\"invalidConfiguration\"}\n",
         generation, command_id);
  fflush(stdout);
}

static bool parse_configure(char *line, ConfigureCommand *command) {
  int consumed = 0;
  int matched =
      sscanf(line,
             "{\"type\":\"configure\",\"schemaVersion\":1,\"generation\":"
             "%" SCNu64 ",\"commandId\":%" SCNu64 ",\"configRevision\":%" SCNu64
             ",\"intervalSeconds\":%ld}%n",
             &command->generation, &command->command_id,
             &command->config_revision, &command->interval_seconds, &consumed);
  if (matched != 4)
    return false;
  while (isspace((unsigned char)line[consumed]))
    consumed++;
  return line[consumed] == '\0';
}

static void emit_unavailable_gpu(int64_t unavailable_since_ms) {
  printf(",\"gpu\":{\"status\":\"unavailable\","
         "\"error\":{\"code\":\"dependencyMissing\",\"scope\":\"gpu\","
         "\"retryability\":\"nonRetryable\","
         "\"diagnostic\":\"metric provider is outside the CPU and RAM "
         "slice\"},\"since\":%" PRId64 "},"
         "\"source\":{\"status\":\"running\"}}\n",
         unavailable_since_ms);
}

static void emit_initializing_snapshot(uint64_t generation, uint64_t sequence,
                                       uint64_t config_revision,
                                       int64_t initialized_at_ms,
                                       int64_t unavailable_since_ms) {
  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"phase\":\"initializing\",\"publishedAtMs\":%" PRId64
         ",\"cpu\":{\"status\":\"initializing\",\"since\":%" PRId64 "},"
         "\"ram\":{\"status\":\"initializing\",\"since\":%" PRId64 "}",
         generation, sequence, config_revision, initialized_at_ms,
         initialized_at_ms, initialized_at_ms);
  emit_unavailable_gpu(unavailable_since_ms);
  fflush(stdout);
}

static void emit_snapshot(uint64_t generation, uint64_t sequence,
                          uint64_t config_revision,
                          int64_t unavailable_since_ms,
                          const HostObservation *observation,
                          MetricFailureState *cpu_failure,
                          MetricFailureState *ram_failure) {
  int64_t sampled_at_ms = monotonic_ms(observation->sampled_at);
  if (observation->cpu_available) {
    cpu_failure->code = NULL;
  } else if (cpu_failure->code == NULL ||
             strcmp(cpu_failure->code, observation->cpu_error) != 0) {
    cpu_failure->code = observation->cpu_error;
    cpu_failure->since_ms = sampled_at_ms;
  }

  if (observation->ram_available) {
    ram_failure->code = NULL;
  } else if (ram_failure->code == NULL ||
             strcmp(ram_failure->code, observation->ram_error) != 0) {
    ram_failure->code = observation->ram_error;
    ram_failure->since_ms = sampled_at_ms;
  }

  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"phase\":\"%s\",\"publishedAtMs\":%" PRId64 ",\"cpu\":",
         generation, sequence, config_revision,
         observation->cpu_available && observation->ram_available ? "live"
                                                                  : "degraded",
         sampled_at_ms);
  if (observation->cpu_available) {
    printf("{\"status\":\"available\",\"value\":{\"percent\":%d,"
           "\"actualWindowMs\":%" PRId64 "},"
           "\"sampledAtMs\":%" PRId64 ",\"window\":{\"actualMs\":%" PRId64 "},"
           "\"evidence\":\"fixtureTested\",\"path\":\"proc-stat\"}",
           observation->cpu_percent, observation->window_ms, sampled_at_ms,
           observation->window_ms);
  } else {
    printf("{\"status\":\"unavailable\","
           "\"error\":{\"code\":\"%s\",\"scope\":\"cpu\","
           "\"retryability\":\"retryable\",\"pathId\":\"proc-stat\"},"
           "\"since\":%" PRId64 "}",
           observation->cpu_error, cpu_failure->since_ms);
  }
  if (observation->ram_available) {
    printf(",\"ram\":{\"status\":\"available\",\"value\":{\"percent\":%d,"
           "\"usedBytes\":%" PRIu64 ",\"totalBytes\":%" PRIu64 "},"
           "\"sampledAtMs\":%" PRId64 ",\"window\":{\"actualMs\":%" PRId64
           "},\"evidence\":\"fixtureTested\",\"path\":\"proc-meminfo\"}",
           observation->ram.percent, observation->ram.used_bytes,
           observation->ram.total_bytes, sampled_at_ms, observation->window_ms);
  } else {
    printf(",\"ram\":{\"status\":\"unavailable\","
           "\"error\":{\"code\":\"%s\",\"scope\":\"ram\","
           "\"retryability\":\"retryable\",\"pathId\":\"proc-meminfo\"},"
           "\"since\":%" PRId64 "}",
           observation->ram_error, ram_failure->since_ms);
  }
  emit_unavailable_gpu(unavailable_since_ms);
  fflush(stdout);
}

int main(int argc, char **argv) {
  Options options = parse_options(argc, argv);
  HostSampler host_sampler = host_sampler_create(&options);
  struct timespec deadline =
      add_ms(host_sampler.baseline_at, options.interval_ms);
  int64_t started_at_ms = monotonic_ms(host_sampler.baseline_at);
  uint64_t generation = new_generation();
  uint64_t sequence = 0;
  uint64_t config_revision = 0;
  MetricFailureState cpu_failure = {0};
  MetricFailureState ram_failure = {0};
  bool accepts_commands = true;

  emit_hello(generation, monotonic_ms(monotonic_now()));

  for (;;) {
    struct timespec now = monotonic_now();
    struct pollfd input = {
        .fd = accepts_commands ? STDIN_FILENO : -1,
        .events = POLLIN,
    };
    int poll_result;
    do {
      poll_result = poll(&input, 1, milliseconds_until(deadline, now));
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result < 0)
      fail("could not wait for sampler deadline");

    if (poll_result > 0 && (input.revents & POLLIN) != 0) {
      char *line = NULL;
      size_t capacity = 0;
      ssize_t length = getline(&line, &capacity, stdin);
      if (length < 0) {
        free(line);
        accepts_commands = false;
        continue;
      }

      ConfigureCommand command = {0};
      bool parsed =
          length <= MAX_COMMAND_BYTES && parse_configure(line, &command);
      if (!parsed || command.generation != generation ||
          command.command_id == 0 ||
          command.config_revision < config_revision ||
          command.interval_seconds < 2 || command.interval_seconds > 10 ||
          command.interval_seconds > LONG_MAX / options.second_ms ||
          (command.config_revision == config_revision &&
           command.interval_seconds * options.second_ms !=
               options.interval_ms)) {
        emit_reject(generation, command.command_id);
        free(line);
        continue;
      }

      if (command.config_revision == config_revision) {
        emit_ack(generation, &command);
        free(line);
        continue;
      }

      options.interval_ms = command.interval_seconds * options.second_ms;
      config_revision = command.config_revision;
      struct timespec initialized_at = host_sampler_reset(&host_sampler);
      deadline = add_ms(initialized_at, options.interval_ms);
      cpu_failure.code = NULL;
      ram_failure.code = NULL;
      emit_ack(generation, &command);
      emit_initializing_snapshot(generation, ++sequence, config_revision,
                                 monotonic_ms(initialized_at), started_at_ms);
      free(line);
      continue;
    }
    if (poll_result > 0 &&
        (input.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      accepts_commands = false;
      continue;
    }

    HostObservation observation = host_sampler_observe(&host_sampler);

    if (host_sampler_fixture_exhausted(&host_sampler)) {
      for (;;)
        pause();
    }

    emit_snapshot(generation, ++sequence, config_revision, started_at_ms,
                  &observation, &cpu_failure, &ram_failure);

    deadline = add_ms(deadline, options.interval_ms);
    if (compare_timespec(deadline, observation.sampled_at) <= 0)
      deadline = add_ms(observation.sampled_at, options.interval_ms);
  }
}
