#define _POSIX_C_SOURCE 200809L

#include "gpu-inventory.h"
#include "gpu-measurement.h"

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
  const char *gpu_inventory_path;
  const char *gpu_presence_path;
  const char *drm_root;
  const char *nvidia_root;
  const char *udev_data_root;
  const char *proc_root;
  const char *intel_proc_frames_root;
  const char *amd_proc_frames_root;
  const char *event_source_root;
  const char *pci_devices_root;
  const char *nvml_library_path;
  bool fixture_system;
  bool fixture_pmu_system;
  long interval_ms;
  long second_ms;
} Options;

typedef struct {
  uint64_t generation;
  uint64_t command_id;
  uint64_t config_revision;
  long interval_seconds;
  GpuSelectionMode gpu_selection_mode;
  char gpu_stable_id[GPU_STABLE_ID_SIZE];
  bool resumes_gpu_session;
  GpuSelectionStatus resume_auto_status;
  char resume_auto_stable_id[GPU_STABLE_ID_SIZE];
  int resume_fixed_retry_stage;
  int64_t resume_fixed_retry_at_ms;
} ConfigureCommand;

typedef struct {
  uint64_t generation;
  uint64_t command_id;
} RefreshGpuInventoryCommand;

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
  const char *gpu_inventory_path = getenv("SYSTEM_STATS_GPU_INVENTORY_FILE");
  const char *gpu_presence_path = getenv("SYSTEM_STATS_GPU_PRESENCE_FILE");
  const char *drm_root = getenv("SYSTEM_STATS_DRM_ROOT");
  const char *nvidia_root = getenv("SYSTEM_STATS_NVIDIA_ROOT");
  const char *udev_data_root = getenv("SYSTEM_STATS_UDEV_DATA_ROOT");
  const char *proc_root = getenv("SYSTEM_STATS_PROC_ROOT");
  const char *intel_proc_frames_root = getenv("SYSTEM_STATS_INTEL_PROC_FRAMES");
  const char *amd_proc_frames_root = getenv("SYSTEM_STATS_AMD_PROC_FRAMES");
  const char *event_source_root = getenv("SYSTEM_STATS_EVENT_SOURCE_ROOT");
  const char *pci_devices_root = getenv("SYSTEM_STATS_PCI_DEVICES_ROOT");
  const char *nvml_library_path = getenv("SYSTEM_STATS_NVML_LIBRARY");
  const char *interval_text = getenv("SYSTEM_STATS_INTERVAL_MS");
  const char *second_text = getenv("SYSTEM_STATS_SECOND_MS");
  Options options = {
      .frames_path =
          frames_path != NULL && *frames_path != '\0' ? frames_path : NULL,
      .meminfo_frames_path =
          meminfo_frames_path != NULL && *meminfo_frames_path != '\0'
              ? meminfo_frames_path
              : NULL,
      .gpu_inventory_path =
          gpu_inventory_path != NULL && *gpu_inventory_path != '\0'
              ? gpu_inventory_path
              : NULL,
      .gpu_presence_path =
          gpu_presence_path != NULL && *gpu_presence_path != '\0'
              ? gpu_presence_path
              : NULL,
      .drm_root =
          drm_root != NULL && *drm_root != '\0' ? drm_root : "/sys/class/drm",
      .nvidia_root = nvidia_root != NULL && *nvidia_root != '\0'
                         ? nvidia_root
                         : "/proc/driver/nvidia/gpus",
      .udev_data_root = udev_data_root != NULL && *udev_data_root != '\0'
                            ? udev_data_root
                            : "/run/udev/data",
      .proc_root =
          proc_root != NULL && *proc_root != '\0' ? proc_root : "/proc",
      .intel_proc_frames_root =
          intel_proc_frames_root != NULL && *intel_proc_frames_root != '\0'
              ? intel_proc_frames_root
              : NULL,
      .amd_proc_frames_root =
          amd_proc_frames_root != NULL && *amd_proc_frames_root != '\0'
              ? amd_proc_frames_root
              : NULL,
      .event_source_root =
          event_source_root != NULL && *event_source_root != '\0'
              ? event_source_root
              : "/sys/bus/event_source/devices",
      .pci_devices_root = pci_devices_root != NULL && *pci_devices_root != '\0'
                              ? pci_devices_root
                              : "/sys/bus/pci/devices",
      .nvml_library_path =
          nvml_library_path != NULL && *nvml_library_path != '\0'
              ? nvml_library_path
              : "libnvidia-ml.so.1",
      .fixture_system = gpu_inventory_path != NULL || drm_root != NULL ||
                        nvidia_root != NULL || udev_data_root != NULL ||
                        proc_root != NULL || intel_proc_frames_root != NULL ||
                        amd_proc_frames_root != NULL ||
                        event_source_root != NULL || pci_devices_root != NULL ||
                        nvml_library_path != NULL,
      .fixture_pmu_system =
          event_source_root != NULL && *event_source_root != '\0' &&
          pci_devices_root != NULL && *pci_devices_root != '\0',
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

static struct timespec host_sampler_start(HostSampler *sampler,
                                          const Options *options) {
  *sampler = (HostSampler){
      .cpu_frames = options->frames_path == NULL
                        ? NULL
                        : fopen(options->frames_path, "re"),
      .meminfo_frames = options->meminfo_frames_path == NULL
                            ? NULL
                            : fopen(options->meminfo_frames_path, "re"),
  };
  if (options->frames_path != NULL && sampler->cpu_frames == NULL)
    fail("could not open fixture frames");
  if (options->meminfo_frames_path != NULL && sampler->meminfo_frames == NULL)
    fail("could not open memory fixture frames");

  sampler->previous_cpu_result =
      read_counters(sampler->cpu_frames, &sampler->previous_cpu);
  sampler->baseline_at = monotonic_now();
  return sampler->baseline_at;
}

static struct timespec host_sampler_reset(HostSampler *sampler) {
  sampler->previous_cpu_result =
      read_counters(sampler->cpu_frames, &sampler->previous_cpu);
  sampler->baseline_at = monotonic_now();
  return sampler->baseline_at;
}

static HostObservation host_sampler_observe(HostSampler *sampler,
                                            struct timespec deadline) {
  if (compare_timespec(deadline, sampler->baseline_at) <= 0)
    fail("host sampler deadline must follow its CPU baseline");

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

static void emit_configure_ack(uint64_t generation,
                               const ConfigureCommand *command,
                               const GpuInventoryManager *gpu_inventory) {
  printf("{\"type\":\"ack\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"intervalSeconds\":%ld,\"gpuSelection\":{\"mode\":\"%s\"",
         generation, command->command_id, command->config_revision,
         command->interval_seconds,
         gpu_selection_mode_name(command->gpu_selection_mode));
  if (command->gpu_selection_mode == GPU_SELECTION_FIXED)
    printf(",\"stableId\":\"%s\"", command->gpu_stable_id);
  fputs("},\"gpuState\":", stdout);
  gpu_inventory_emit_state(gpu_inventory);
  fputs("}\n", stdout);
  fflush(stdout);
}

static void emit_refresh_ack(uint64_t generation,
                             const RefreshGpuInventoryCommand *command) {
  printf("{\"type\":\"ack\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"command\":\"refreshGpuInventory\"}\n",
         generation, command->command_id);
  fflush(stdout);
}

static void emit_reject(uint64_t generation, uint64_t command_id) {
  printf("{\"type\":\"reject\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"error\":\"invalidConfiguration\"}\n",
         generation, command_id);
  fflush(stdout);
}

static bool parse_configure(char *line, ConfigureCommand *command) {
  char mode[16] = {0};
  char auto_status[16] = {0};
  char stable_id[GPU_STABLE_ID_SIZE] = {0};
  int consumed = 0;
  int matched =
      sscanf(line,
             "{\"type\":\"configure\",\"schemaVersion\":1,\"generation\":"
             "%" SCNu64 ",\"commandId\":%" SCNu64 ",\"configRevision\":%" SCNu64
             ",\"intervalSeconds\":%ld,\"gpuSelection\":{\"mode\":\"%15[a-z]"
             "\",\"stableId\":\"%127[0-9A-Za-z:.-]\"},\"gpuResume\":{"
             "\"fixedRetryStage\":%d,\"fixedRetryAt\":%" SCNd64 "}}%n",
             &command->generation, &command->command_id,
             &command->config_revision, &command->interval_seconds, mode,
             stable_id, &command->resume_fixed_retry_stage,
             &command->resume_fixed_retry_at_ms, &consumed);
  bool fixed_resume_valid = matched == 8 && strcmp(mode, "fixed") == 0 &&
                            gpu_stable_id_valid(stable_id) &&
                            command->resume_fixed_retry_stage >= 0 &&
                            command->resume_fixed_retry_stage <= 3 &&
                            ((command->resume_fixed_retry_stage == 3 &&
                              command->resume_fixed_retry_at_ms == -1) ||
                             (command->resume_fixed_retry_stage == 0 &&
                              command->resume_fixed_retry_at_ms == -1) ||
                             (command->resume_fixed_retry_stage < 3 &&
                              command->resume_fixed_retry_at_ms >= 0));
  if (fixed_resume_valid) {
    command->gpu_selection_mode = GPU_SELECTION_FIXED;
    command->resumes_gpu_session = true;
    snprintf(command->gpu_stable_id, sizeof(command->gpu_stable_id), "%s",
             stable_id);
  } else {
    *command = (ConfigureCommand){0};
    memset(mode, 0, sizeof(mode));
    memset(stable_id, 0, sizeof(stable_id));
    consumed = 0;
    matched = sscanf(
        line,
        "{\"type\":\"configure\",\"schemaVersion\":1,\"generation\":"
        "%" SCNu64 ",\"commandId\":%" SCNu64 ",\"configRevision\":%" SCNu64
        ",\"intervalSeconds\":%ld,\"gpuSelection\":{\"mode\":\"%15[a-z]"
        "\"},\"gpuResume\":{\"autoStatus\":\"%15[a-z]\","
        "\"stableId\":\"%127[0-9A-Za-z:.-]\"}}%n",
        &command->generation, &command->command_id, &command->config_revision,
        &command->interval_seconds, mode, auto_status, stable_id, &consumed);
    if (matched == 7 && strcmp(mode, "auto") == 0 &&
        strcmp(auto_status, "selected") == 0 &&
        gpu_stable_id_valid(stable_id)) {
      command->gpu_selection_mode = GPU_SELECTION_AUTO;
      command->resumes_gpu_session = true;
      command->resume_auto_status = GPU_SELECTION_SELECTED;
      snprintf(command->resume_auto_stable_id,
               sizeof(command->resume_auto_stable_id), "%s", stable_id);
    } else {
      *command = (ConfigureCommand){0};
      memset(mode, 0, sizeof(mode));
      memset(auto_status, 0, sizeof(auto_status));
      memset(stable_id, 0, sizeof(stable_id));
      consumed = 0;
      matched = sscanf(
          line,
          "{\"type\":\"configure\",\"schemaVersion\":1,\"generation\":"
          "%" SCNu64 ",\"commandId\":%" SCNu64 ",\"configRevision\":%" SCNu64
          ",\"intervalSeconds\":%ld,\"gpuSelection\":{\"mode\":\"%15[a-z]"
          "\"},\"gpuResume\":{\"autoStatus\":\"%15[a-z]\"}}%n",
          &command->generation, &command->command_id, &command->config_revision,
          &command->interval_seconds, mode, auto_status, &consumed);
      bool empty_auto_resume = matched == 6 && strcmp(mode, "auto") == 0 &&
                               (strcmp(auto_status, "none") == 0 ||
                                strcmp(auto_status, "required") == 0);
      if (empty_auto_resume) {
        command->gpu_selection_mode = GPU_SELECTION_AUTO;
        command->resumes_gpu_session = true;
        command->resume_auto_status = strcmp(auto_status, "required") == 0
                                          ? GPU_SELECTION_REQUIRED
                                          : GPU_SELECTION_NONE;
      } else {
        *command = (ConfigureCommand){0};
        memset(mode, 0, sizeof(mode));
        memset(stable_id, 0, sizeof(stable_id));
        consumed = 0;
        matched = sscanf(
            line,
            "{\"type\":\"configure\",\"schemaVersion\":1,\"generation\":"
            "%" SCNu64 ",\"commandId\":%" SCNu64 ",\"configRevision\":%" SCNu64
            ",\"intervalSeconds\":%ld,\"gpuSelection\":{\"mode\":\"%15[a-z]"
            "\",\"stableId\":\"%127[0-9A-Za-z:.-]\"}}%n",
            &command->generation, &command->command_id,
            &command->config_revision, &command->interval_seconds, mode,
            stable_id, &consumed);
        if (matched == 6 && strcmp(mode, "fixed") == 0 &&
            gpu_stable_id_valid(stable_id)) {
          command->gpu_selection_mode = GPU_SELECTION_FIXED;
          snprintf(command->gpu_stable_id, sizeof(command->gpu_stable_id), "%s",
                   stable_id);
        } else {
          *command = (ConfigureCommand){0};
          memset(mode, 0, sizeof(mode));
          consumed = 0;
          matched =
              sscanf(line,
                     "{\"type\":\"configure\",\"schemaVersion\":1,"
                     "\"generation\":%" SCNu64 ",\"commandId\":%" SCNu64
                     ",\"configRevision\":%" SCNu64
                     ",\"intervalSeconds\":%ld,\"gpuSelection\":{\"mode\":"
                     "\"%15[a-z]\"}}%n",
                     &command->generation, &command->command_id,
                     &command->config_revision, &command->interval_seconds,
                     mode, &consumed);
          if (matched != 5 || strcmp(mode, "auto") != 0)
            return false;
          command->gpu_selection_mode = GPU_SELECTION_AUTO;
        }
      }
    }
  }
  while (isspace((unsigned char)line[consumed]))
    consumed++;
  return line[consumed] == '\0';
}

static bool parse_refresh_gpu_inventory(char *line,
                                        RefreshGpuInventoryCommand *command) {
  int consumed = 0;
  int matched =
      sscanf(line,
             "{\"type\":\"refreshGpuInventory\",\"schemaVersion\":1,"
             "\"generation\":%" SCNu64 ",\"commandId\":%" SCNu64 "}%n",
             &command->generation, &command->command_id, &consumed);
  if (matched != 2)
    return false;
  while (isspace((unsigned char)line[consumed]))
    consumed++;
  return line[consumed] == '\0';
}

static void emit_initializing_snapshot(uint64_t generation, uint64_t sequence,
                                       uint64_t config_revision,
                                       int64_t initialized_at_ms,
                                       GpuInventoryManager *gpu_inventory,
                                       struct timespec now) {
  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"phase\":\"initializing\",\"publishedAtMs\":%" PRId64
         ",\"cpu\":{\"status\":\"initializing\",\"since\":%" PRId64 "},"
         "\"ram\":{\"status\":\"initializing\",\"since\":%" PRId64 "}",
         generation, sequence, config_revision, initialized_at_ms,
         initialized_at_ms, initialized_at_ms);
  gpu_inventory_emit_snapshot_fields(gpu_inventory, now);
  fputs(",\"source\":{\"status\":\"running\"}}\n", stdout);
  fflush(stdout);
}

static void emit_snapshot(uint64_t generation, uint64_t sequence,
                          uint64_t config_revision,
                          const HostObservation *observation,
                          MetricFailureState *cpu_failure,
                          MetricFailureState *ram_failure,
                          GpuInventoryManager *gpu_inventory,
                          const GpuObservation *gpu_observation) {
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
         observation->cpu_available && observation->ram_available &&
                 gpu_observation->available
             ? "live"
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
  gpu_measurement_emit_snapshot_fields(gpu_observation, gpu_inventory,
                                       observation->sampled_at);
  fputs(",\"source\":{\"status\":\"running\"}}\n", stdout);
  fflush(stdout);
}

int main(int argc, char **argv) {
  if (setvbuf(stdin, NULL, _IONBF, 0) != 0)
    fail("could not configure command input");
  Options options = parse_options(argc, argv);
  HostSampler host_sampler = {0};
  struct timespec initialized_at = host_sampler_start(&host_sampler, &options);
  struct timespec deadline = add_ms(initialized_at, options.interval_ms);
  uint64_t generation = new_generation();
  uint64_t sequence = 0;
  uint64_t config_revision = 0;
  MetricFailureState cpu_failure = {0};
  MetricFailureState ram_failure = {0};
  GpuInventoryManager gpu_inventory = {0};
  GpuMeasurement *gpu_measurement = NULL;
  bool accepts_commands = true;

  GpuInventoryOptions gpu_options = {
      .fixture_inventory_path = options.gpu_inventory_path,
      .fixture_presence_path = options.gpu_presence_path,
      .drm_root = options.drm_root,
      .nvidia_root = options.nvidia_root,
      .udev_data_root = options.udev_data_root,
      .second_ms = options.second_ms,
  };
  gpu_inventory_manager_init(&gpu_inventory, &gpu_options);
  struct timespec inventory_started_at = monotonic_now();
  gpu_inventory_reconcile(&gpu_inventory, GPU_DISCOVERY_SESSION_START,
                          inventory_started_at);
  GpuMeasurementOptions measurement_options = {
      .proc_root = options.proc_root,
      .fixture_intel_proc_frames_root = options.intel_proc_frames_root,
      .fixture_amd_proc_frames_root = options.amd_proc_frames_root,
      .event_source_root = options.event_source_root,
      .pci_devices_root = options.pci_devices_root,
      .nvml_library_path = options.nvml_library_path,
      .fixture_system = options.fixture_system,
      .fixture_pmu_system = options.fixture_pmu_system,
  };
  gpu_measurement = gpu_measurement_create(&measurement_options);
  if (gpu_measurement == NULL)
    fail("could not allocate GPU measurement state");
  gpu_measurement_reconcile(gpu_measurement,
                            gpu_inventory_selected_device(&gpu_inventory),
                            inventory_started_at);

  emit_hello(generation, monotonic_ms(monotonic_now()));
  gpu_inventory_emit(&gpu_inventory, generation);

  for (;;) {
    struct timespec now = monotonic_now();
    struct pollfd input = {
        .fd = accepts_commands ? STDIN_FILENO : -1,
        .events = POLLIN,
    };
    int poll_result;
    do {
      int timeout = milliseconds_until(deadline, now);
      timeout = gpu_inventory_poll_timeout(&gpu_inventory, now, timeout);
      poll_result = poll(&input, 1, timeout);
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

      RefreshGpuInventoryCommand refresh = {0};
      bool refresh_parsed = length <= MAX_COMMAND_BYTES &&
                            parse_refresh_gpu_inventory(line, &refresh);
      if (refresh_parsed) {
        if (refresh.generation != generation || refresh.command_id == 0) {
          emit_reject(generation, refresh.command_id);
        } else {
          struct timespec refreshed_at = monotonic_now();
          gpu_inventory_reconcile(&gpu_inventory, GPU_DISCOVERY_PICKER,
                                  refreshed_at);
          gpu_measurement_reconcile(
              gpu_measurement, gpu_inventory_selected_device(&gpu_inventory),
              refreshed_at);
          gpu_inventory_emit(&gpu_inventory, generation);
          emit_refresh_ack(generation, &refresh);
        }
        free(line);
        continue;
      }

      ConfigureCommand command = {0};
      bool parsed =
          length <= MAX_COMMAND_BYTES && parse_configure(line, &command);
      bool same_selection =
          command.gpu_selection_mode == gpu_inventory.mode &&
          (command.gpu_selection_mode == GPU_SELECTION_AUTO ||
           strcmp(command.gpu_stable_id, gpu_inventory.fixed_stable_id) == 0);
      if (!parsed || command.generation != generation ||
          command.command_id == 0 ||
          command.config_revision < config_revision ||
          command.interval_seconds < 2 || command.interval_seconds > 10 ||
          command.interval_seconds > LONG_MAX / options.second_ms ||
          (command.config_revision == config_revision &&
           (command.interval_seconds * options.second_ms !=
                options.interval_ms ||
            !same_selection))) {
        emit_reject(generation, command.command_id);
        free(line);
        continue;
      }

      if (command.config_revision == config_revision) {
        if (command.resumes_gpu_session) {
          gpu_inventory_restore_session(
              &gpu_inventory, command.gpu_selection_mode, command.gpu_stable_id,
              command.resume_auto_status, command.resume_auto_stable_id,
              command.resume_fixed_retry_stage,
              command.resume_fixed_retry_at_ms, monotonic_now());
        }
        emit_configure_ack(generation, &command, &gpu_inventory);
        free(line);
        continue;
      }

      bool interval_changed =
          command.interval_seconds * options.second_ms != options.interval_ms;
      bool inventory_refreshed = false;
      if (command.resumes_gpu_session) {
        gpu_inventory_restore_session(
            &gpu_inventory, command.gpu_selection_mode, command.gpu_stable_id,
            command.resume_auto_status, command.resume_auto_stable_id,
            command.resume_fixed_retry_stage, command.resume_fixed_retry_at_ms,
            monotonic_now());
      } else {
        struct timespec configured_at = monotonic_now();
        bool selection_changed = gpu_inventory_set_selection(
            &gpu_inventory, command.gpu_selection_mode, command.gpu_stable_id,
            configured_at);
        if (selection_changed &&
            command.gpu_selection_mode == GPU_SELECTION_FIXED &&
            gpu_inventory.status == GPU_SELECTION_MISSING) {
          gpu_inventory_reconcile(&gpu_inventory, GPU_DISCOVERY_CONFIGURATION,
                                  configured_at);
          inventory_refreshed = true;
        }
      }
      gpu_measurement_reconcile(gpu_measurement,
                                gpu_inventory_selected_device(&gpu_inventory),
                                monotonic_now());
      config_revision = command.config_revision;
      if (inventory_refreshed)
        gpu_inventory_emit(&gpu_inventory, generation);
      emit_configure_ack(generation, &command, &gpu_inventory);
      if (interval_changed) {
        options.interval_ms = command.interval_seconds * options.second_ms;
        struct timespec reset_at = host_sampler_reset(&host_sampler);
        deadline = add_ms(reset_at, options.interval_ms);
        cpu_failure.code = NULL;
        ram_failure.code = NULL;
        emit_initializing_snapshot(generation, ++sequence, config_revision,
                                   monotonic_ms(reset_at), &gpu_inventory,
                                   reset_at);
        gpu_measurement_reset(gpu_measurement,
                              gpu_inventory_selected_device(&gpu_inventory),
                              monotonic_now());
      }
      free(line);
      continue;
    }
    if (poll_result > 0 &&
        (input.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      accepts_commands = false;
      continue;
    }

    now = monotonic_now();
    if (gpu_inventory_retry_due(&gpu_inventory, now)) {
      gpu_inventory_reconcile(&gpu_inventory, GPU_DISCOVERY_RETRY, now);
      gpu_measurement_reconcile(
          gpu_measurement, gpu_inventory_selected_device(&gpu_inventory), now);
      gpu_inventory_emit(&gpu_inventory, generation);
      continue;
    }

    if (gpu_inventory.status == GPU_SELECTION_SELECTED &&
        !gpu_inventory_selected_present(&gpu_inventory)) {
      gpu_inventory_reconcile(&gpu_inventory, GPU_DISCOVERY_DISAPPEARANCE, now);
      gpu_measurement_reconcile(
          gpu_measurement, gpu_inventory_selected_device(&gpu_inventory), now);
      gpu_inventory_emit(&gpu_inventory, generation);
    }

    HostObservation observation = host_sampler_observe(&host_sampler, deadline);
    GpuObservation gpu_observation = gpu_measurement_observe(
        gpu_measurement, gpu_inventory_selected_device(&gpu_inventory),
        observation.sampled_at);

    if (host_sampler_fixture_exhausted(&host_sampler)) {
      for (;;)
        pause();
    }

    emit_snapshot(generation, ++sequence, config_revision, &observation,
                  &cpu_failure, &ram_failure, &gpu_inventory, &gpu_observation);

    deadline = add_ms(deadline, options.interval_ms);
    if (compare_timespec(deadline, observation.sampled_at) <= 0)
      deadline = add_ms(observation.sampled_at, options.interval_ms);
  }
}
