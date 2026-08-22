#define _GNU_SOURCE

#include "gpu-measurement.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/perf_event.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

enum {
  INTEL_MAX_CLIENTS = 256,
  INTEL_MAX_ENGINES = 16,
  INTEL_ENGINE_NAME_SIZE = 64,
  INTEL_MAX_PMU_EVENTS = 32
};

typedef enum {
  INTEL_DRIVER_UNKNOWN,
  INTEL_DRIVER_I915,
  INTEL_DRIVER_XE
} IntelDriver;

typedef enum {
  INTEL_SCAN_OK,
  INTEL_SCAN_PERMISSION_DENIED,
  INTEL_SCAN_UNREADABLE,
  INTEL_SCAN_UNKNOWN_ABI,
  INTEL_SCAN_INSUFFICIENT_VISIBILITY
} IntelScanResult;

typedef struct {
  char name[INTEL_ENGINE_NAME_SIZE];
  uint64_t busy;
  uint64_t total;
  unsigned int capacity;
  bool has_busy;
  bool has_total;
  bool has_engine_time;
  bool has_cycles;
} IntelEngineCounters;

typedef struct {
  uint64_t client_id;
  IntelDriver driver;
  size_t engine_count;
  IntelEngineCounters engines[INTEL_MAX_ENGINES];
} IntelClientCounters;

typedef struct {
  IntelDriver driver;
  bool saw_target;
  bool saw_engine_counter;
  size_t client_count;
  IntelClientCounters clients[INTEL_MAX_CLIENTS];
} IntelSnapshot;

typedef enum {
  INTEL_PATH_NONE,
  INTEL_PATH_I915_PMU,
  INTEL_PATH_I915_FDINFO,
  INTEL_PATH_XE_FDINFO
} IntelPath;

struct GpuMeasurement {
  GpuMeasurementOptions options;
  IntelPath path;
  IntelSnapshot baseline;
  struct timespec baseline_at;
  size_t pmu_event_count;
  int pmu_fds[INTEL_MAX_PMU_EVENTS];
  uint64_t pmu_baseline[INTEL_MAX_PMU_EVENTS];
  unsigned int next_fixture_frame;
  char selected_stable_id[GPU_STABLE_ID_SIZE];
  char selected_pci_bdf[GPU_PCI_BDF_SIZE];
  const char *failure_code;
  const char *failure_path;
  int64_t failure_since_ms;
};

static void close_pmu(GpuMeasurement *measurement) {
  for (size_t i = 0; i < measurement->pmu_event_count; i++) {
    if (measurement->pmu_fds[i] >= 0)
      close(measurement->pmu_fds[i]);
  }
  measurement->pmu_event_count = 0;
}

static int64_t monotonic_ms(struct timespec instant) {
  return (int64_t)instant.tv_sec * 1000 + instant.tv_nsec / 1000000;
}

static int64_t elapsed_ms(struct timespec before, struct timespec after) {
  return monotonic_ms(after) - monotonic_ms(before);
}

static struct timespec baseline_instant(const GpuMeasurement *measurement,
                                        struct timespec requested) {
  if (measurement->options.fixture_system)
    return requested;
  struct timespec observed;
  return clock_gettime(CLOCK_MONOTONIC, &observed) == 0 ? observed : requested;
}

static bool numeric_name(const char *name) {
  if (name[0] == '\0')
    return false;
  for (size_t i = 0; name[i] != '\0'; i++) {
    if (!isdigit((unsigned char)name[i]))
      return false;
  }
  return true;
}

static bool pci_bdf_name(const char *value) {
  if (strlen(value) != 12)
    return false;
  for (size_t i = 0; i < 12; i++) {
    if ((i == 4 || i == 7) && value[i] != ':')
      return false;
    if (i == 10 && value[i] != '.')
      return false;
    if (i != 4 && i != 7 && i != 10 && !isxdigit((unsigned char)value[i]))
      return false;
  }
  return true;
}

static void trim(char *value) {
  char *start = value;
  while (isspace((unsigned char)*start))
    start++;
  if (start != value)
    memmove(value, start, strlen(start) + 1);
  size_t length = strlen(value);
  while (length > 0 && isspace((unsigned char)value[length - 1]))
    value[--length] = '\0';
}

static bool parse_uint64(const char *value, uint64_t *parsed,
                         const char **suffix) {
  while (isspace((unsigned char)*value))
    value++;
  if (!isdigit((unsigned char)*value))
    return false;
  errno = 0;
  char *end = NULL;
  uintmax_t number = strtoumax(value, &end, 10);
  if (errno == ERANGE || end == value || number > UINT64_MAX)
    return false;
  while (isspace((unsigned char)*end))
    end++;
  *parsed = (uint64_t)number;
  *suffix = end;
  return true;
}

static IntelEngineCounters *find_engine(IntelClientCounters *client,
                                        const char *name, bool create) {
  for (size_t i = 0; i < client->engine_count; i++) {
    if (strcmp(client->engines[i].name, name) == 0)
      return &client->engines[i];
  }
  if (!create || client->engine_count >= INTEL_MAX_ENGINES || name[0] == '\0' ||
      strlen(name) >= INTEL_ENGINE_NAME_SIZE)
    return NULL;
  IntelEngineCounters *engine = &client->engines[client->engine_count++];
  *engine = (IntelEngineCounters){.capacity = 1};
  memcpy(engine->name, name, strlen(name) + 1);
  return engine;
}

static IntelDriver parse_driver(const char *value) {
  if (strcmp(value, "i915") == 0)
    return INTEL_DRIVER_I915;
  if (strcmp(value, "xe") == 0)
    return INTEL_DRIVER_XE;
  return INTEL_DRIVER_UNKNOWN;
}

static bool parse_fdinfo_file(const char *path, const char *selected_pci_bdf,
                              IntelClientCounters *client, bool *is_target,
                              bool *unknown_abi) {
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return false;

  char driver_text[32] = {0};
  char pci_bdf[GPU_PCI_BDF_SIZE] = {0};
  bool has_client_id = false;
  bool malformed = false;
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, stream) >= 0) {
    char *separator = strchr(line, ':');
    if (separator == NULL)
      continue;
    *separator = '\0';
    char *value = separator + 1;
    trim(line);
    trim(value);

    if (strcmp(line, "drm-driver") == 0) {
      if (strlen(value) >= sizeof(driver_text)) {
        malformed = true;
        break;
      }
      memcpy(driver_text, value, strlen(value) + 1);
    } else if (strcmp(line, "drm-pdev") == 0) {
      if (strlen(value) >= sizeof(pci_bdf)) {
        malformed = true;
        break;
      }
      memcpy(pci_bdf, value, strlen(value) + 1);
    } else if (strcmp(line, "drm-client-id") == 0) {
      const char *suffix = NULL;
      if (!parse_uint64(value, &client->client_id, &suffix) ||
          *suffix != '\0') {
        malformed = true;
        break;
      }
      has_client_id = true;
    } else if (strncmp(line, "drm-engine-capacity-", 20) == 0) {
      IntelEngineCounters *engine = find_engine(client, line + 20, true);
      uint64_t number = 0;
      const char *suffix = NULL;
      if (engine == NULL || !parse_uint64(value, &number, &suffix) ||
          *suffix != '\0' || number == 0 || number > UINT_MAX) {
        malformed = true;
        break;
      }
      engine->capacity = (unsigned int)number;
    } else if (strncmp(line, "drm-engine-", 11) == 0) {
      IntelEngineCounters *engine = find_engine(client, line + 11, true);
      uint64_t number = 0;
      const char *suffix = NULL;
      if (engine == NULL || !parse_uint64(value, &number, &suffix) ||
          strcmp(suffix, "ns") != 0 || engine->has_busy) {
        malformed = true;
        break;
      }
      engine->busy = number;
      engine->has_busy = true;
      engine->has_engine_time = true;
    } else if (strncmp(line, "drm-total-cycles-", 17) == 0) {
      IntelEngineCounters *engine = find_engine(client, line + 17, true);
      uint64_t number = 0;
      const char *suffix = NULL;
      if (engine == NULL || !parse_uint64(value, &number, &suffix) ||
          *suffix != '\0' || engine->has_total) {
        malformed = true;
        break;
      }
      engine->total = number;
      engine->has_total = true;
    } else if (strncmp(line, "drm-cycles-", 11) == 0) {
      IntelEngineCounters *engine = find_engine(client, line + 11, true);
      uint64_t number = 0;
      const char *suffix = NULL;
      if (engine == NULL || !parse_uint64(value, &number, &suffix) ||
          *suffix != '\0' || engine->has_busy) {
        malformed = true;
        break;
      }
      engine->busy = number;
      engine->has_busy = true;
      engine->has_cycles = true;
    }
  }
  free(line);
  fclose(stream);

  if (strcmp(pci_bdf, selected_pci_bdf) != 0)
    return true;
  *is_target = driver_text[0] != '\0';
  if (!*is_target)
    return true;
  client->driver = parse_driver(driver_text);
  if (malformed || client->driver == INTEL_DRIVER_UNKNOWN || !has_client_id)
    *unknown_abi = true;
  for (size_t i = 0; i < client->engine_count; i++) {
    const IntelEngineCounters *engine = &client->engines[i];
    if ((client->driver == INTEL_DRIVER_I915 &&
         (engine->has_cycles || engine->has_total)) ||
        (client->driver == INTEL_DRIVER_XE &&
         (engine->has_engine_time ||
          engine->has_cycles != engine->has_total))) {
      *unknown_abi = true;
    }
  }
  return true;
}

static IntelClientCounters *find_client(IntelSnapshot *snapshot,
                                        uint64_t client_id) {
  for (size_t i = 0; i < snapshot->client_count; i++) {
    if (snapshot->clients[i].client_id == client_id)
      return &snapshot->clients[i];
  }
  return NULL;
}

static const IntelClientCounters *
find_const_client(const IntelSnapshot *snapshot, uint64_t client_id) {
  for (size_t i = 0; i < snapshot->client_count; i++) {
    if (snapshot->clients[i].client_id == client_id)
      return &snapshot->clients[i];
  }
  return NULL;
}

static bool merge_client(IntelSnapshot *snapshot,
                         const IntelClientCounters *candidate) {
  IntelClientCounters *client = find_client(snapshot, candidate->client_id);
  if (client == NULL) {
    if (snapshot->client_count >= INTEL_MAX_CLIENTS)
      return false;
    snapshot->clients[snapshot->client_count++] = *candidate;
    return true;
  }
  if (client->driver != candidate->driver)
    return false;
  for (size_t i = 0; i < candidate->engine_count; i++) {
    const IntelEngineCounters *source = &candidate->engines[i];
    IntelEngineCounters *destination = find_engine(client, source->name, true);
    if (destination == NULL || destination->capacity != source->capacity)
      return false;
    if (source->has_busy &&
        (!destination->has_busy || source->busy > destination->busy)) {
      destination->busy = source->busy;
      destination->has_busy = true;
      destination->has_engine_time = source->has_engine_time;
      destination->has_cycles = source->has_cycles;
    }
    if (source->has_total &&
        (!destination->has_total || source->total > destination->total)) {
      destination->total = source->total;
      destination->has_total = true;
    }
  }
  return true;
}

static IntelScanResult visibility_override(const char *root) {
  char path[PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/.visibility", root) >= (int)sizeof(path))
    return INTEL_SCAN_UNREADABLE;
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return INTEL_SCAN_OK;
  char value[64] = {0};
  bool read = fgets(value, sizeof(value), stream) != NULL;
  fclose(stream);
  if (!read)
    return INTEL_SCAN_UNREADABLE;
  trim(value);
  if (strcmp(value, "complete") == 0)
    return INTEL_SCAN_OK;
  if (strcmp(value, "permissionDenied") == 0)
    return INTEL_SCAN_PERMISSION_DENIED;
  return strcmp(value, "insufficient") == 0 ? INTEL_SCAN_INSUFFICIENT_VISIBILITY
                                            : INTEL_SCAN_UNREADABLE;
}

static bool read_text_file(const char *path, char *buffer, size_t capacity) {
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return false;
  bool read = fgets(buffer, (int)capacity, stream) != NULL;
  fclose(stream);
  if (!read)
    return false;
  trim(buffer);
  return true;
}

static bool device_uses_driver(const char *pci_devices_root,
                               const char *pci_bdf, const char *driver) {
  char path[PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/%s/driver", pci_devices_root, pci_bdf) >=
      (int)sizeof(path))
    return false;
  char resolved[PATH_MAX];
  if (realpath(path, resolved) == NULL)
    return false;
  const char *name = strrchr(resolved, '/');
  name = name == NULL ? resolved : name + 1;
  return strcmp(name, driver) == 0;
}

static bool uniquely_bound_i915(const GpuMeasurement *measurement) {
  DIR *devices = opendir(measurement->options.pci_devices_root);
  if (devices == NULL)
    return false;
  size_t count = 0;
  bool selected_found = false;
  struct dirent *entry;
  while ((entry = readdir(devices)) != NULL) {
    if (!pci_bdf_name(entry->d_name) ||
        !device_uses_driver(measurement->options.pci_devices_root,
                            entry->d_name, "i915"))
      continue;
    count++;
    if (strcmp(entry->d_name, measurement->selected_pci_bdf) == 0)
      selected_found = true;
  }
  closedir(devices);
  return count == 1 && selected_found;
}

static bool suffix_matches(const char *value, const char *suffix) {
  size_t value_length = strlen(value);
  size_t suffix_length = strlen(suffix);
  return value_length > suffix_length &&
         strcmp(value + value_length - suffix_length, suffix) == 0;
}

static bool parse_config(const char *value, uint64_t *config) {
  static const char prefix[] = "config=";
  if (strncmp(value, prefix, sizeof(prefix) - 1) != 0)
    return false;
  errno = 0;
  char *end = NULL;
  uintmax_t parsed = strtoumax(value + sizeof(prefix) - 1, &end, 0);
  while (isspace((unsigned char)*end))
    end++;
  if (errno == ERANGE || end == value + sizeof(prefix) - 1 || *end != '\0' ||
      parsed > UINT64_MAX)
    return false;
  *config = (uint64_t)parsed;
  return true;
}

static int perf_event_open_counter(unsigned int type, uint64_t config,
                                   int cpu) {
  struct perf_event_attr attributes = {0};
  attributes.type = type;
  attributes.size = sizeof(attributes);
  attributes.config = config;
  return (int)syscall(SYS_perf_event_open, &attributes, -1, cpu, -1,
                      PERF_FLAG_FD_CLOEXEC);
}

typedef enum {
  PMU_OPEN_OK,
  PMU_OPEN_UNAVAILABLE,
  PMU_OPEN_PERMISSION_DENIED,
  PMU_OPEN_UNKNOWN_ABI
} PmuOpenResult;

static PmuOpenResult open_i915_pmu(GpuMeasurement *measurement,
                                   struct timespec now) {
  if (!uniquely_bound_i915(measurement))
    return PMU_OPEN_UNAVAILABLE;

  char root[PATH_MAX];
  char path[PATH_MAX];
  if (snprintf(root, sizeof(root), "%s/i915",
               measurement->options.event_source_root) >= (int)sizeof(root) ||
      snprintf(path, sizeof(path), "%s/type", root) >= (int)sizeof(path))
    return PMU_OPEN_UNAVAILABLE;
  char text[128] = {0};
  if (!read_text_file(path, text, sizeof(text)))
    return PMU_OPEN_UNAVAILABLE;
  uint64_t type_value = 0;
  const char *suffix = NULL;
  if (!parse_uint64(text, &type_value, &suffix) || *suffix != '\0' ||
      type_value > UINT_MAX)
    return PMU_OPEN_UNAVAILABLE;

  int cpu = 0;
  if (snprintf(path, sizeof(path), "%s/cpumask", root) < (int)sizeof(path) &&
      read_text_file(path, text, sizeof(text))) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(text, &end, 10);
    if (errno == 0 && end != text && parsed >= 0 && parsed <= INT_MAX)
      cpu = (int)parsed;
  }

  if (snprintf(path, sizeof(path), "%s/events", root) >= (int)sizeof(path))
    return PMU_OPEN_UNAVAILABLE;
  DIR *events = opendir(path);
  if (events == NULL)
    return PMU_OPEN_UNAVAILABLE;
  bool permission_denied = false;
  bool event_failed = false;
  size_t eligible_events = 0;
  struct dirent *entry;
  while ((entry = readdir(events)) != NULL) {
    if (!suffix_matches(entry->d_name, "-busy"))
      continue;
    eligible_events++;
    if (measurement->pmu_event_count >= INTEL_MAX_PMU_EVENTS) {
      event_failed = true;
      continue;
    }
    char unit_path[PATH_MAX];
    char event_path[PATH_MAX];
    if (snprintf(unit_path, sizeof(unit_path), "%s/%s.unit", path,
                 entry->d_name) >= (int)sizeof(unit_path) ||
        snprintf(event_path, sizeof(event_path), "%s/%s", path,
                 entry->d_name) >= (int)sizeof(event_path)) {
      event_failed = true;
      continue;
    }
    char unit[32] = {0};
    char config_text[128] = {0};
    uint64_t config = 0;
    if (!read_text_file(unit_path, unit, sizeof(unit)) ||
        strcmp(unit, "ns") != 0 ||
        !read_text_file(event_path, config_text, sizeof(config_text)) ||
        !parse_config(config_text, &config)) {
      event_failed = true;
      continue;
    }
    int descriptor =
        perf_event_open_counter((unsigned int)type_value, config, cpu);
    if (descriptor < 0) {
      if (errno == EACCES || errno == EPERM)
        permission_denied = true;
      event_failed = true;
      continue;
    }
    uint64_t baseline = 0;
    if (read(descriptor, &baseline, sizeof(baseline)) !=
        (ssize_t)sizeof(baseline)) {
      close(descriptor);
      event_failed = true;
      continue;
    }
    size_t index = measurement->pmu_event_count++;
    measurement->pmu_fds[index] = descriptor;
    measurement->pmu_baseline[index] = baseline;
  }
  closedir(events);

  if (eligible_events > 0 && !event_failed &&
      measurement->pmu_event_count == eligible_events) {
    measurement->path = INTEL_PATH_I915_PMU;
    measurement->baseline_at = baseline_instant(measurement, now);
    return PMU_OPEN_OK;
  }
  close_pmu(measurement);
  if (permission_denied)
    return PMU_OPEN_PERMISSION_DENIED;
  return event_failed ? PMU_OPEN_UNKNOWN_ABI : PMU_OPEN_UNAVAILABLE;
}

static IntelScanResult scan_proc(const char *root, const char *selected_pci_bdf,
                                 bool fixture, IntelSnapshot *snapshot) {
  *snapshot = (IntelSnapshot){0};
  IntelScanResult override =
      fixture ? visibility_override(root) : INTEL_SCAN_OK;
  if (override != INTEL_SCAN_OK)
    return override;

  DIR *processes = opendir(root);
  if (processes == NULL) {
    return errno == EACCES || errno == EPERM ? INTEL_SCAN_PERMISSION_DENIED
                                             : INTEL_SCAN_UNREADABLE;
  }

  bool visibility_incomplete = false;
  bool unknown_abi = false;
  struct dirent *process_entry;
  while ((process_entry = readdir(processes)) != NULL) {
    if (!numeric_name(process_entry->d_name))
      continue;
    char fdinfo_path[PATH_MAX];
    if (snprintf(fdinfo_path, sizeof(fdinfo_path), "%s/%s/fdinfo", root,
                 process_entry->d_name) >= (int)sizeof(fdinfo_path)) {
      unknown_abi = true;
      continue;
    }
    DIR *fdinfos = opendir(fdinfo_path);
    if (fdinfos == NULL) {
      if (!fixture && (errno == EACCES || errno == EPERM))
        visibility_incomplete = true;
      continue;
    }
    struct dirent *fd_entry;
    while ((fd_entry = readdir(fdinfos)) != NULL) {
      if (!numeric_name(fd_entry->d_name))
        continue;
      char path[PATH_MAX];
      if (snprintf(path, sizeof(path), "%s/%s", fdinfo_path,
                   fd_entry->d_name) >= (int)sizeof(path)) {
        unknown_abi = true;
        continue;
      }
      IntelClientCounters candidate = {0};
      bool is_target = false;
      if (!parse_fdinfo_file(path, selected_pci_bdf, &candidate, &is_target,
                             &unknown_abi)) {
        if (!fixture && (errno == EACCES || errno == EPERM))
          visibility_incomplete = true;
        continue;
      }
      if (!is_target)
        continue;
      snapshot->saw_target = true;
      if (candidate.driver == INTEL_DRIVER_UNKNOWN)
        continue;
      if (snapshot->driver == INTEL_DRIVER_UNKNOWN)
        snapshot->driver = candidate.driver;
      if (snapshot->driver != candidate.driver ||
          !merge_client(snapshot, &candidate)) {
        unknown_abi = true;
        continue;
      }
      for (size_t i = 0; i < candidate.engine_count; i++) {
        if ((candidate.driver == INTEL_DRIVER_I915 &&
             candidate.engines[i].has_engine_time) ||
            (candidate.driver == INTEL_DRIVER_XE &&
             candidate.engines[i].has_cycles &&
             candidate.engines[i].has_total)) {
          snapshot->saw_engine_counter = true;
        }
      }
    }
    closedir(fdinfos);
  }
  closedir(processes);

  if (unknown_abi)
    return INTEL_SCAN_UNKNOWN_ABI;
  if (visibility_incomplete)
    return INTEL_SCAN_INSUFFICIENT_VISIBILITY;
  return INTEL_SCAN_OK;
}

static const char *fixture_frame_root(GpuMeasurement *measurement,
                                      char path[PATH_MAX]) {
  const char *root = measurement->options.fixture_proc_frames_root;
  if (root == NULL)
    return measurement->options.proc_root;
  unsigned int frame = measurement->next_fixture_frame;
  if (snprintf(path, PATH_MAX, "%s/%u", root, frame) >= PATH_MAX)
    return NULL;
  DIR *directory = opendir(path);
  if (directory != NULL) {
    closedir(directory);
    measurement->next_fixture_frame++;
    return path;
  }
  if (frame == 0 ||
      snprintf(path, PATH_MAX, "%s/%u", root, frame - 1) >= PATH_MAX)
    return NULL;
  return path;
}

static IntelScanResult scan_next_frame(GpuMeasurement *measurement,
                                       IntelSnapshot *snapshot) {
  char frame_path[PATH_MAX];
  const char *root = fixture_frame_root(measurement, frame_path);
  if (root == NULL)
    return INTEL_SCAN_UNREADABLE;
  return scan_proc(root, measurement->selected_pci_bdf,
                   measurement->options.fixture_proc_frames_root != NULL,
                   snapshot);
}

static void record_failure(GpuMeasurement *measurement, const char *code,
                           const char *path, struct timespec now) {
  if (measurement->failure_code == NULL ||
      strcmp(measurement->failure_code, code) != 0 ||
      measurement->failure_path == NULL ||
      strcmp(measurement->failure_path, path) != 0) {
    measurement->failure_since_ms = monotonic_ms(now);
  }
  measurement->failure_code = code;
  measurement->failure_path = path;
}

static void prepare_fdinfo(GpuMeasurement *measurement, struct timespec now) {
  measurement->path = INTEL_PATH_NONE;
  IntelSnapshot baseline = {0};
  IntelScanResult result = scan_next_frame(measurement, &baseline);
  if (result == INTEL_SCAN_PERMISSION_DENIED) {
    record_failure(measurement, "permissionDenied", "intel-fdinfo", now);
  } else if (result == INTEL_SCAN_INSUFFICIENT_VISIBILITY) {
    record_failure(measurement, "insufficientVisibility", "intel-fdinfo", now);
  } else if (result == INTEL_SCAN_UNKNOWN_ABI ||
             (result == INTEL_SCAN_OK && baseline.saw_target &&
              !baseline.saw_engine_counter)) {
    record_failure(measurement, "unsupportedDevice", "intel-fdinfo", now);
  } else if (result != INTEL_SCAN_OK || !baseline.saw_target) {
    record_failure(measurement, "noTrueEnginePath", "intel-measurement", now);
  } else if (baseline.driver == INTEL_DRIVER_I915) {
    measurement->path = INTEL_PATH_I915_FDINFO;
    measurement->baseline = baseline;
    measurement->baseline_at = baseline_instant(measurement, now);
    measurement->failure_code = NULL;
    measurement->failure_path = NULL;
  } else if (baseline.driver == INTEL_DRIVER_XE) {
    measurement->path = INTEL_PATH_XE_FDINFO;
    measurement->baseline = baseline;
    measurement->baseline_at = baseline_instant(measurement, now);
    measurement->failure_code = NULL;
    measurement->failure_path = NULL;
  } else {
    record_failure(measurement, "unsupportedDevice", "intel-fdinfo", now);
  }
}

static void prepare_intel_path(GpuMeasurement *measurement,
                               struct timespec now) {
  if (measurement->options.fixture_proc_frames_root != NULL) {
    prepare_fdinfo(measurement, now);
    return;
  }
  if (measurement->options.fixture_system &&
      !measurement->options.fixture_pmu_system) {
    record_failure(measurement, "noTrueEnginePath", "intel-measurement", now);
    return;
  }

  PmuOpenResult pmu = open_i915_pmu(measurement, now);
  if (pmu == PMU_OPEN_OK)
    return;
  if (!measurement->options.fixture_system)
    prepare_fdinfo(measurement, now);
  if (measurement->path != INTEL_PATH_NONE)
    return;
  if (pmu == PMU_OPEN_PERMISSION_DENIED) {
    record_failure(measurement, "permissionDenied", "intel-i915-pmu", now);
  } else if (pmu == PMU_OPEN_UNKNOWN_ABI) {
    record_failure(measurement, "unsupportedDevice", "intel-i915-pmu", now);
  }
}

GpuMeasurement *gpu_measurement_create(const GpuMeasurementOptions *options) {
  GpuMeasurement *measurement = calloc(1, sizeof(*measurement));
  if (measurement != NULL)
    measurement->options = *options;
  return measurement;
}

void gpu_measurement_destroy(GpuMeasurement *measurement) {
  if (measurement == NULL)
    return;
  close_pmu(measurement);
  free(measurement);
}

void gpu_measurement_reconcile(GpuMeasurement *measurement,
                               const GpuDevice *selected, struct timespec now) {
  const char *stable_id = selected == NULL ? "" : selected->stable_id;
  if (strcmp(measurement->selected_stable_id, stable_id) == 0)
    return;

  close_pmu(measurement);
  measurement->path = INTEL_PATH_NONE;
  measurement->baseline = (IntelSnapshot){0};
  measurement->next_fixture_frame = 0;
  measurement->failure_code = NULL;
  measurement->failure_path = NULL;
  snprintf(measurement->selected_stable_id,
           sizeof(measurement->selected_stable_id), "%s", stable_id);
  snprintf(measurement->selected_pci_bdf, sizeof(measurement->selected_pci_bdf),
           "%s", selected == NULL ? "" : selected->pci_bdf);
  if (selected == NULL || selected->vendor != GPU_VENDOR_INTEL)
    return;
  prepare_intel_path(measurement, now);
}

void gpu_measurement_reset(GpuMeasurement *measurement,
                           const GpuDevice *selected, struct timespec now) {
  measurement->selected_stable_id[0] = '\0';
  gpu_measurement_reconcile(measurement, selected, now);
}

static const IntelEngineCounters *
const_engine(const IntelClientCounters *client, const char *name) {
  for (size_t i = 0; i < client->engine_count; i++) {
    if (strcmp(client->engines[i].name, name) == 0)
      return &client->engines[i];
  }
  return NULL;
}

typedef struct {
  char name[INTEL_ENGINE_NAME_SIZE];
  long double busy_delta;
  long double total_delta;
  unsigned int capacity;
} EngineDelta;

static EngineDelta *find_delta(EngineDelta deltas[INTEL_MAX_ENGINES],
                               size_t *count, const char *name) {
  for (size_t i = 0; i < *count; i++) {
    if (strcmp(deltas[i].name, name) == 0)
      return &deltas[i];
  }
  if (*count >= INTEL_MAX_ENGINES)
    return NULL;
  EngineDelta *delta = &deltas[(*count)++];
  *delta = (EngineDelta){.capacity = 1};
  memcpy(delta->name, name, strlen(name) + 1);
  return delta;
}

static bool i915_percent(const IntelSnapshot *before,
                         const IntelSnapshot *after, int64_t window_ms,
                         int *percent, bool *counter_reset) {
  EngineDelta deltas[INTEL_MAX_ENGINES] = {0};
  size_t delta_count = 0;
  bool compared = false;
  for (size_t i = 0; i < after->client_count; i++) {
    const IntelClientCounters *current = &after->clients[i];
    const IntelClientCounters *previous =
        find_const_client(before, current->client_id);
    if (previous == NULL)
      continue;
    for (size_t j = 0; j < current->engine_count; j++) {
      const IntelEngineCounters *engine = &current->engines[j];
      const IntelEngineCounters *old = const_engine(previous, engine->name);
      if (!engine->has_busy || old == NULL || !old->has_busy)
        continue;
      compared = true;
      if (engine->busy < old->busy) {
        *counter_reset = true;
        return false;
      }
      EngineDelta *delta = find_delta(deltas, &delta_count, engine->name);
      if (delta == NULL)
        return false;
      delta->busy_delta += (long double)(engine->busy - old->busy);
      if (engine->capacity > delta->capacity)
        delta->capacity = engine->capacity;
    }
  }
  if (!compared || window_ms <= 0)
    return false;

  long double maximum = 0.0L;
  for (size_t i = 0; i < delta_count; i++) {
    long double denominator =
        (long double)window_ms * 1000000.0L * deltas[i].capacity;
    long double value = deltas[i].busy_delta * 100.0L / denominator;
    if (value > maximum)
      maximum = value;
  }
  if (maximum > 100.0L)
    maximum = 100.0L;
  *percent = (int)floorl(maximum + 0.5L);
  return true;
}

static bool xe_percent(const IntelSnapshot *before, const IntelSnapshot *after,
                       int *percent, bool *counter_reset) {
  EngineDelta deltas[INTEL_MAX_ENGINES] = {0};
  size_t delta_count = 0;
  bool compared = false;
  for (size_t i = 0; i < after->client_count; i++) {
    const IntelClientCounters *current = &after->clients[i];
    const IntelClientCounters *previous =
        find_const_client(before, current->client_id);
    if (previous == NULL)
      continue;
    for (size_t j = 0; j < current->engine_count; j++) {
      const IntelEngineCounters *engine = &current->engines[j];
      const IntelEngineCounters *old = const_engine(previous, engine->name);
      if (!engine->has_busy || !engine->has_total || old == NULL ||
          !old->has_busy || !old->has_total)
        continue;
      compared = true;
      if (engine->busy < old->busy || engine->total < old->total) {
        *counter_reset = true;
        return false;
      }
      EngineDelta *delta = find_delta(deltas, &delta_count, engine->name);
      if (delta == NULL)
        return false;
      delta->busy_delta += (long double)(engine->busy - old->busy);
      long double total_delta = (long double)(engine->total - old->total);
      if (total_delta > delta->total_delta)
        delta->total_delta = total_delta;
      if (engine->capacity > delta->capacity)
        delta->capacity = engine->capacity;
    }
  }
  if (!compared)
    return false;

  long double maximum = 0.0L;
  bool has_window = false;
  for (size_t i = 0; i < delta_count; i++) {
    if (deltas[i].total_delta <= 0.0L)
      continue;
    has_window = true;
    long double value = deltas[i].busy_delta * 100.0L /
                        (deltas[i].total_delta * deltas[i].capacity);
    if (value > maximum)
      maximum = value;
  }
  if (!has_window)
    return false;
  if (maximum > 100.0L)
    maximum = 100.0L;
  *percent = (int)floorl(maximum + 0.5L);
  return true;
}

static GpuObservation unavailable_observation(GpuMeasurement *measurement,
                                              struct timespec now) {
  const char *code = measurement->failure_code == NULL
                         ? "noTrueEnginePath"
                         : measurement->failure_code;
  const char *path = measurement->failure_path == NULL
                         ? "intel-measurement"
                         : measurement->failure_path;
  record_failure(measurement, code, path, now);
  const char *diagnostic = "no documented Intel engine counter is available";
  if (strcmp(code, "permissionDenied") == 0)
    diagnostic =
        "Intel engine counters could not be read with current permissions";
  else if (strcmp(code, "insufficientVisibility") == 0)
    diagnostic =
        "process visibility is insufficient for a system-wide fdinfo value";
  else if (strcmp(code, "unsupportedDevice") == 0)
    diagnostic = "the selected Intel device exposes an unknown counter ABI";
  else if (strcmp(code, "counterReset") == 0)
    diagnostic = "Intel engine counters reset during the observation window";

  GpuObservation observation = {
      .handled = true,
      .available = false,
      .error_code = code,
      .retryability = strcmp(code, "unsupportedDevice") == 0 ||
                              strcmp(code, "noTrueEnginePath") == 0
                          ? "nonRetryable"
                          : "retryable",
      .diagnostic = diagnostic,
      .path = path,
      .evidence = "fixtureTested",
      .since_ms = measurement->failure_since_ms,
  };
  snprintf(observation.stable_id, sizeof(observation.stable_id), "%s",
           measurement->selected_stable_id);
  snprintf(observation.pci_bdf, sizeof(observation.pci_bdf), "%s",
           measurement->selected_pci_bdf);
  return observation;
}

GpuObservation gpu_measurement_observe(GpuMeasurement *measurement,
                                       const GpuDevice *selected,
                                       struct timespec now) {
  gpu_measurement_reconcile(measurement, selected, now);
  if (selected == NULL || selected->vendor != GPU_VENDOR_INTEL)
    return (GpuObservation){0};
  if (measurement->path == INTEL_PATH_NONE) {
    GpuObservation prior = unavailable_observation(measurement, now);
    bool retryable =
        measurement->failure_code == NULL ||
        (strcmp(measurement->failure_code, "unsupportedDevice") != 0 &&
         strcmp(measurement->failure_code, "noTrueEnginePath") != 0);
    if (retryable)
      prepare_intel_path(measurement, now);
    if (measurement->path != INTEL_PATH_NONE)
      return prior;
    return unavailable_observation(measurement, now);
  }

  if (measurement->path == INTEL_PATH_I915_PMU) {
    int64_t window_ms = elapsed_ms(measurement->baseline_at, now);
    long double maximum = 0.0L;
    bool counter_reset = false;
    const char *read_error = NULL;
    uint64_t current_values[INTEL_MAX_PMU_EVENTS] = {0};
    for (size_t i = 0; i < measurement->pmu_event_count; i++) {
      if (read(measurement->pmu_fds[i], &current_values[i],
               sizeof(current_values[i])) !=
          (ssize_t)sizeof(current_values[i])) {
        read_error = errno == EACCES || errno == EPERM ? "permissionDenied"
                     : errno == ENODEV || errno == ENXIO || errno == EIO
                         ? "deviceMissing"
                         : "noTrueEnginePath";
        continue;
      }
      if (current_values[i] < measurement->pmu_baseline[i]) {
        counter_reset = true;
      } else if (window_ms > 0) {
        long double value =
            (long double)(current_values[i] - measurement->pmu_baseline[i]) *
            100.0L / ((long double)window_ms * 1000000.0L);
        if (value > maximum)
          maximum = value;
      }
    }
    if (counter_reset || read_error != NULL || window_ms <= 0) {
      record_failure(measurement,
                     counter_reset ? "counterReset"
                                   : (read_error == NULL ? "noTrueEnginePath"
                                                         : read_error),
                     "intel-i915-pmu", now);
      return unavailable_observation(measurement, now);
    }
    for (size_t i = 0; i < measurement->pmu_event_count; i++)
      measurement->pmu_baseline[i] = current_values[i];
    measurement->baseline_at = now;
    if (maximum > 100.0L)
      maximum = 100.0L;
    measurement->failure_code = NULL;
    measurement->failure_path = NULL;
    GpuObservation observation = {
        .handled = true,
        .available = true,
        .percent = (int)floorl(maximum + 0.5L),
        .sampled_at_ms = monotonic_ms(now),
        .window_ms = window_ms,
        .path = "intel-i915-pmu",
        .evidence = "fixtureTested",
    };
    snprintf(observation.stable_id, sizeof(observation.stable_id), "%s",
             measurement->selected_stable_id);
    snprintf(observation.pci_bdf, sizeof(observation.pci_bdf), "%s",
             measurement->selected_pci_bdf);
    return observation;
  }

  IntelSnapshot current = {0};
  IntelScanResult scan = scan_next_frame(measurement, &current);
  IntelDriver expected_driver = measurement->path == INTEL_PATH_XE_FDINFO
                                    ? INTEL_DRIVER_XE
                                    : INTEL_DRIVER_I915;
  const char *path = measurement->path == INTEL_PATH_XE_FDINFO
                         ? "intel-xe-fdinfo"
                         : "intel-i915-fdinfo";
  if (scan != INTEL_SCAN_OK || current.driver != expected_driver ||
      !current.saw_engine_counter) {
    const char *code = scan == INTEL_SCAN_PERMISSION_DENIED ? "permissionDenied"
                       : scan == INTEL_SCAN_INSUFFICIENT_VISIBILITY
                           ? "insufficientVisibility"
                       : scan == INTEL_SCAN_UNKNOWN_ABI || current.saw_target
                           ? "unsupportedDevice"
                           : "noTrueEnginePath";
    record_failure(measurement, code, path, now);
    return unavailable_observation(measurement, now);
  }

  int64_t window_ms = elapsed_ms(measurement->baseline_at, now);
  int percent = 0;
  bool counter_reset = false;
  bool available = measurement->path == INTEL_PATH_XE_FDINFO
                       ? xe_percent(&measurement->baseline, &current, &percent,
                                    &counter_reset)
                       : i915_percent(&measurement->baseline, &current,
                                      window_ms, &percent, &counter_reset);
  if (!available) {
    record_failure(measurement,
                   counter_reset ? "counterReset" : "noTrueEnginePath", path,
                   now);
    if (!counter_reset) {
      measurement->baseline = current;
      measurement->baseline_at = now;
    }
    return unavailable_observation(measurement, now);
  }

  measurement->baseline = current;
  measurement->baseline_at = now;

  measurement->failure_code = NULL;
  measurement->failure_path = NULL;
  GpuObservation observation = {
      .handled = true,
      .available = true,
      .percent = percent,
      .sampled_at_ms = monotonic_ms(now),
      .window_ms = window_ms,
      .path = path,
      .evidence = "fixtureTested",
  };
  snprintf(observation.stable_id, sizeof(observation.stable_id), "%s",
           measurement->selected_stable_id);
  snprintf(observation.pci_bdf, sizeof(observation.pci_bdf), "%s",
           measurement->selected_pci_bdf);
  return observation;
}

static void emit_json_string(const char *value) {
  putchar('"');
  for (const unsigned char *cursor = (const unsigned char *)value;
       *cursor != '\0'; cursor++) {
    if (*cursor == '"' || *cursor == '\\') {
      putchar('\\');
      putchar(*cursor);
    } else if (*cursor >= 0x20) {
      putchar(*cursor);
    }
  }
  putchar('"');
}

void gpu_measurement_emit_snapshot_fields(const GpuObservation *observation,
                                          GpuInventoryManager *inventory,
                                          struct timespec now) {
  if (!observation->handled) {
    gpu_inventory_emit_snapshot_fields(inventory, now);
    return;
  }

  if (observation->available) {
    fputs(",\"gpu\":{\"status\":\"available\",\"value\":{\"percent\":", stdout);
    printf("%d", observation->percent);
    fputs(",\"device\":{\"stableId\":", stdout);
    emit_json_string(observation->stable_id);
    fputs(",\"pciBdf\":", stdout);
    emit_json_string(observation->pci_bdf);
    fputs("},\"semantics\":\"graphicsEngineBusy\",\"actualWindowMs\":", stdout);
    printf("%" PRId64, observation->window_ms);
    fputs("},\"sampledAtMs\":", stdout);
    printf("%" PRId64, observation->sampled_at_ms);
    fputs(",\"window\":{\"actualMs\":", stdout);
    printf("%" PRId64, observation->window_ms);
    fputs("},\"evidence\":", stdout);
    emit_json_string(observation->evidence);
    fputs(",\"path\":", stdout);
    emit_json_string(observation->path);
    putchar('}');
  } else {
    fputs(",\"gpu\":{\"status\":\"unavailable\",\"error\":{\"code\":", stdout);
    emit_json_string(observation->error_code);
    fputs(",\"scope\":\"gpu\",\"retryability\":", stdout);
    emit_json_string(observation->retryability);
    fputs(",\"stableId\":", stdout);
    emit_json_string(observation->stable_id);
    fputs(",\"pathId\":", stdout);
    emit_json_string(observation->path);
    fputs(",\"diagnostic\":", stdout);
    emit_json_string(observation->diagnostic);
    fputs("},\"since\":", stdout);
    printf("%" PRId64, observation->since_ms);
    fputs(",\"evidence\":", stdout);
    emit_json_string(observation->evidence);
    putchar('}');
  }
  gpu_inventory_emit_snapshot_state_fields(inventory);
}
