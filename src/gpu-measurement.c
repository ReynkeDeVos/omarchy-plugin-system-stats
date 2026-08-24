#define _GNU_SOURCE

#include "gpu-measurement.h"

#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/perf_event.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

enum {
  DRM_MAX_CLIENTS = 256,
  DRM_MAX_ENGINES = 16,
  DRM_ENGINE_NAME_SIZE = 64,
  INTEL_MAX_PMU_EVENTS = 32,
  NVIDIA_UUID_SIZE = 96,
  NVIDIA_PCI_BDF_SIZE = 32,
  NVIDIA_CALL_TIMEOUT_MS = 250
};

typedef enum {
  DRM_DRIVER_UNKNOWN,
  DRM_DRIVER_I915,
  DRM_DRIVER_XE,
  DRM_DRIVER_AMDGPU
} DrmDriver;

typedef enum {
  DRM_SCAN_OK,
  DRM_SCAN_PERMISSION_DENIED,
  DRM_SCAN_UNREADABLE,
  DRM_SCAN_UNKNOWN_ABI,
  DRM_SCAN_INSUFFICIENT_VISIBILITY
} DrmScanResult;

typedef struct {
  char name[DRM_ENGINE_NAME_SIZE];
  uint64_t busy;
  uint64_t total;
  unsigned int capacity;
  bool has_busy;
  bool has_total;
  bool has_engine_time;
  bool has_cycles;
} DrmEngineCounters;

typedef struct {
  uint64_t client_id;
  DrmDriver driver;
  size_t engine_count;
  DrmEngineCounters engines[DRM_MAX_ENGINES];
} DrmClientCounters;

typedef struct {
  DrmDriver driver;
  bool saw_target;
  bool saw_engine_counter;
  size_t client_count;
  DrmClientCounters clients[DRM_MAX_CLIENTS];
} DrmSnapshot;

typedef enum {
  INTEL_PATH_NONE,
  INTEL_PATH_I915_PMU,
  INTEL_PATH_I915_FDINFO,
  INTEL_PATH_XE_FDINFO
} IntelPath;

typedef enum {
  AMD_PATH_NONE,
  AMD_PATH_GPU_BUSY_PERCENT,
  AMD_PATH_FDINFO
} AmdPath;

typedef enum {
  METRIC_ERROR_NONE,
  METRIC_ERROR_COUNTER_RESET,
  METRIC_ERROR_DEPENDENCY_MISSING,
  METRIC_ERROR_DEVICE_MISSING,
  METRIC_ERROR_DEVICE_SUSPENDED,
  METRIC_ERROR_INSUFFICIENT_VISIBILITY,
  METRIC_ERROR_MALFORMED_COUNTER,
  METRIC_ERROR_NO_TRUE_ENGINE_PATH,
  METRIC_ERROR_PERMISSION_DENIED,
  METRIC_ERROR_SAMPLE_TIMEOUT,
  METRIC_ERROR_SOURCE_UNREADABLE,
  METRIC_ERROR_UNSUPPORTED_DEVICE
} MetricErrorCode;

typedef struct {
  MetricErrorCode code;
  const char *path;
  int64_t since_ms;
} MetricError;

typedef struct {
  IntelPath path;
  DrmSnapshot baseline;
  struct timespec baseline_at;
  size_t pmu_event_count;
  int pmu_fds[INTEL_MAX_PMU_EVENTS];
  uint64_t pmu_baseline[INTEL_MAX_PMU_EVENTS];
  unsigned int next_fixture_frame;
} IntelReaderState;

typedef struct {
  AmdPath path;
  DrmSnapshot baseline;
  struct timespec baseline_at;
  unsigned int next_fixture_frame;
} AmdReaderState;

typedef int NvmlReturn;
typedef void *NvmlDevice;

enum {
  NVML_SUCCESS = 0,
  NVML_ERROR_INVALID_ARGUMENT = 2,
  NVML_ERROR_NOT_SUPPORTED = 3,
  NVML_ERROR_NO_PERMISSION = 4,
  NVML_ERROR_NOT_FOUND = 6,
  NVML_ERROR_INSUFFICIENT_POWER = 8,
  NVML_ERROR_DRIVER_NOT_LOADED = 9,
  NVML_ERROR_TIMEOUT = 10,
  NVML_ERROR_IRQ_ISSUE = 11,
  NVML_ERROR_LIBRARY_NOT_FOUND = 12,
  NVML_ERROR_FUNCTION_NOT_FOUND = 13,
  NVML_ERROR_GPU_IS_LOST = 15,
  NVML_ERROR_RESET_REQUIRED = 16,
  NVML_ERROR_OPERATING_SYSTEM = 17,
  NVML_ERROR_LIB_RM_VERSION_MISMATCH = 18,
  NVML_ERROR_NOT_READY = 27,
  NVML_ERROR_GPU_NOT_FOUND = 28
};

typedef struct {
  unsigned int gpu;
  unsigned int memory;
} NvmlUtilization;

typedef NvmlReturn (*NvmlInit)(void);
typedef NvmlReturn (*NvmlGetHandle)(const char *, NvmlDevice *);
typedef NvmlReturn (*NvmlGetUuid)(NvmlDevice, char *, unsigned int);
typedef NvmlReturn (*NvmlGetUtilization)(NvmlDevice, NvmlUtilization *);

typedef struct {
  NvmlInit init;
  NvmlGetHandle get_handle_by_uuid;
  NvmlGetHandle get_handle_by_pci_bdf;
  NvmlGetUuid get_uuid;
  NvmlGetUtilization get_utilization;
} NvmlApi;

typedef struct {
  NvmlDevice device;
  bool provider_available;
  bool timed_out;
  struct timespec baseline_at;
} NvidiaReaderState;

typedef struct {
  void *library;
  NvmlApi api;
  bool initialized;
} NvmlProvider;

typedef enum {
  NVIDIA_STAGE_NONE,
  NVIDIA_STAGE_INIT,
  NVIDIA_STAGE_UUID_LOOKUP,
  NVIDIA_STAGE_PCI_LOOKUP,
  NVIDIA_STAGE_PCI_UUID,
  NVIDIA_STAGE_IDENTITY,
  NVIDIA_STAGE_UTILIZATION
} NvidiaCallStage;

typedef struct {
  NvmlApi api;
  NvmlDevice device;
  bool initialized;
  bool identity_verified;
  char uuid[NVIDIA_UUID_SIZE];
  char pci_bdf[NVIDIA_PCI_BDF_SIZE];
  NvidiaCallStage stage;
  NvmlReturn result;
  unsigned int percent;
  atomic_uint references;
} NvidiaCall;

// NVML exposes no bounded shutdown operation. Keep one provider for the helper
// lifetime so reader changes neither block nor accumulate library references.
static NvmlProvider nvidia_provider = {0};
static bool nvidia_provider_quarantined = false;

typedef struct GpuReader GpuReader;

typedef struct {
  GpuVendor vendor;
  void (*open)(GpuReader *reader, struct timespec now);
  GpuObservation (*observe)(GpuReader *reader, struct timespec now);
  void (*close)(GpuReader *reader);
} GpuAdapter;

struct GpuReader {
  const GpuMeasurementOptions *options;
  const GpuAdapter *adapter;
  char selected_stable_id[GPU_STABLE_ID_SIZE];
  char selected_pci_bdf[GPU_PCI_BDF_SIZE];
  MetricError failure;
  union {
    IntelReaderState intel;
    AmdReaderState amd;
    NvidiaReaderState nvidia;
  } state;
};

struct GpuMeasurement {
  GpuMeasurementOptions options;
  GpuReader reader;
};

static void close_pmu(GpuReader *reader) {
  IntelReaderState *state = &reader->state.intel;
  for (size_t i = 0; i < state->pmu_event_count; i++) {
    if (state->pmu_fds[i] >= 0)
      close(state->pmu_fds[i]);
  }
  state->pmu_event_count = 0;
}

static int64_t monotonic_ms(struct timespec instant) {
  return (int64_t)instant.tv_sec * 1000 + instant.tv_nsec / 1000000;
}

static int64_t elapsed_ms(struct timespec before, struct timespec after) {
  return monotonic_ms(after) - monotonic_ms(before);
}

static struct timespec baseline_instant(const GpuReader *reader,
                                        struct timespec requested) {
  if (reader->options->fixture_system)
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

static DrmEngineCounters *find_engine(DrmClientCounters *client,
                                      const char *name, bool create) {
  for (size_t i = 0; i < client->engine_count; i++) {
    if (strcmp(client->engines[i].name, name) == 0)
      return &client->engines[i];
  }
  if (!create || client->engine_count >= DRM_MAX_ENGINES || name[0] == '\0' ||
      strlen(name) >= DRM_ENGINE_NAME_SIZE)
    return NULL;
  DrmEngineCounters *engine = &client->engines[client->engine_count++];
  *engine = (DrmEngineCounters){.capacity = 1};
  memcpy(engine->name, name, strlen(name) + 1);
  return engine;
}

static DrmDriver parse_driver(const char *value) {
  if (strcmp(value, "i915") == 0)
    return DRM_DRIVER_I915;
  if (strcmp(value, "xe") == 0)
    return DRM_DRIVER_XE;
  if (strcmp(value, "amdgpu") == 0)
    return DRM_DRIVER_AMDGPU;
  return DRM_DRIVER_UNKNOWN;
}

static bool parse_fdinfo_file(const char *path, const char *selected_pci_bdf,
                              DrmClientCounters *client, bool *is_target,
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
      DrmEngineCounters *engine = find_engine(client, line + 20, true);
      uint64_t number = 0;
      const char *suffix = NULL;
      if (engine == NULL || !parse_uint64(value, &number, &suffix) ||
          *suffix != '\0' || number == 0 || number > UINT_MAX) {
        malformed = true;
        break;
      }
      engine->capacity = (unsigned int)number;
    } else if (strncmp(line, "drm-engine-", 11) == 0) {
      DrmEngineCounters *engine = find_engine(client, line + 11, true);
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
      DrmEngineCounters *engine = find_engine(client, line + 17, true);
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
      DrmEngineCounters *engine = find_engine(client, line + 11, true);
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
  if (malformed || client->driver == DRM_DRIVER_UNKNOWN || !has_client_id)
    *unknown_abi = true;
  for (size_t i = 0; i < client->engine_count; i++) {
    const DrmEngineCounters *engine = &client->engines[i];
    if ((client->driver == DRM_DRIVER_I915 &&
         (engine->has_cycles || engine->has_total)) ||
        (client->driver == DRM_DRIVER_XE &&
         (engine->has_engine_time ||
          engine->has_cycles != engine->has_total)) ||
        (client->driver == DRM_DRIVER_AMDGPU &&
         (engine->has_cycles || engine->has_total))) {
      *unknown_abi = true;
    }
  }
  return true;
}

static DrmClientCounters *find_client(DrmSnapshot *snapshot,
                                      uint64_t client_id) {
  for (size_t i = 0; i < snapshot->client_count; i++) {
    if (snapshot->clients[i].client_id == client_id)
      return &snapshot->clients[i];
  }
  return NULL;
}

static const DrmClientCounters *find_const_client(const DrmSnapshot *snapshot,
                                                  uint64_t client_id) {
  for (size_t i = 0; i < snapshot->client_count; i++) {
    if (snapshot->clients[i].client_id == client_id)
      return &snapshot->clients[i];
  }
  return NULL;
}

static bool merge_client(DrmSnapshot *snapshot,
                         const DrmClientCounters *candidate) {
  DrmClientCounters *client = find_client(snapshot, candidate->client_id);
  if (client == NULL) {
    if (snapshot->client_count >= DRM_MAX_CLIENTS)
      return false;
    snapshot->clients[snapshot->client_count++] = *candidate;
    return true;
  }
  if (client->driver != candidate->driver)
    return false;
  for (size_t i = 0; i < candidate->engine_count; i++) {
    const DrmEngineCounters *source = &candidate->engines[i];
    DrmEngineCounters *destination = find_engine(client, source->name, true);
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

static DrmScanResult visibility_override(const char *root) {
  char path[PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/.visibility", root) >= (int)sizeof(path))
    return DRM_SCAN_UNREADABLE;
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return DRM_SCAN_OK;
  char value[64] = {0};
  bool read = fgets(value, sizeof(value), stream) != NULL;
  fclose(stream);
  if (!read)
    return DRM_SCAN_UNREADABLE;
  trim(value);
  if (strcmp(value, "complete") == 0)
    return DRM_SCAN_OK;
  if (strcmp(value, "permissionDenied") == 0)
    return DRM_SCAN_PERMISSION_DENIED;
  return strcmp(value, "insufficient") == 0 ? DRM_SCAN_INSUFFICIENT_VISIBILITY
                                            : DRM_SCAN_UNREADABLE;
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

static bool uniquely_bound_i915(const GpuReader *reader) {
  DIR *devices = opendir(reader->options->pci_devices_root);
  if (devices == NULL)
    return false;
  size_t count = 0;
  bool selected_found = false;
  struct dirent *entry;
  while ((entry = readdir(devices)) != NULL) {
    if (!pci_bdf_name(entry->d_name) ||
        !device_uses_driver(reader->options->pci_devices_root, entry->d_name,
                            "i915"))
      continue;
    count++;
    if (strcmp(entry->d_name, reader->selected_pci_bdf) == 0)
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

static PmuOpenResult open_i915_pmu(GpuReader *reader, struct timespec now) {
  IntelReaderState *state = &reader->state.intel;
  if (!uniquely_bound_i915(reader))
    return PMU_OPEN_UNAVAILABLE;

  char root[PATH_MAX];
  char path[PATH_MAX];
  if (snprintf(root, sizeof(root), "%s/i915",
               reader->options->event_source_root) >= (int)sizeof(root) ||
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
    if (state->pmu_event_count >= INTEL_MAX_PMU_EVENTS) {
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
    size_t index = state->pmu_event_count++;
    state->pmu_fds[index] = descriptor;
    state->pmu_baseline[index] = baseline;
  }
  closedir(events);

  if (eligible_events > 0 && !event_failed &&
      state->pmu_event_count == eligible_events) {
    state->path = INTEL_PATH_I915_PMU;
    state->baseline_at = baseline_instant(reader, now);
    return PMU_OPEN_OK;
  }
  close_pmu(reader);
  if (permission_denied)
    return PMU_OPEN_PERMISSION_DENIED;
  return event_failed ? PMU_OPEN_UNKNOWN_ABI : PMU_OPEN_UNAVAILABLE;
}

static DrmScanResult scan_drm_fdinfo(const char *root,
                                     const char *selected_pci_bdf, bool fixture,
                                     DrmSnapshot *snapshot) {
  *snapshot = (DrmSnapshot){0};
  DrmScanResult override = fixture ? visibility_override(root) : DRM_SCAN_OK;
  if (override != DRM_SCAN_OK)
    return override;

  DIR *processes = opendir(root);
  if (processes == NULL) {
    return errno == EACCES || errno == EPERM ? DRM_SCAN_PERMISSION_DENIED
                                             : DRM_SCAN_UNREADABLE;
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
      DrmClientCounters candidate = {0};
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
      if (candidate.driver == DRM_DRIVER_UNKNOWN)
        continue;
      if (snapshot->driver == DRM_DRIVER_UNKNOWN)
        snapshot->driver = candidate.driver;
      if (snapshot->driver != candidate.driver ||
          !merge_client(snapshot, &candidate)) {
        unknown_abi = true;
        continue;
      }
      for (size_t i = 0; i < candidate.engine_count; i++) {
        if ((candidate.driver == DRM_DRIVER_I915 &&
             candidate.engines[i].has_engine_time) ||
            (candidate.driver == DRM_DRIVER_AMDGPU &&
             candidate.engines[i].has_engine_time) ||
            (candidate.driver == DRM_DRIVER_XE &&
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
    return DRM_SCAN_UNKNOWN_ABI;
  if (visibility_incomplete)
    return DRM_SCAN_INSUFFICIENT_VISIBILITY;
  return DRM_SCAN_OK;
}

static const char *fixture_frame_root(const char *fixture_root,
                                      const char *live_root,
                                      unsigned int *next_frame,
                                      char path[PATH_MAX]) {
  if (fixture_root == NULL)
    return live_root;
  unsigned int frame = *next_frame;
  if (snprintf(path, PATH_MAX, "%s/%u", fixture_root, frame) >= PATH_MAX)
    return NULL;
  DIR *directory = opendir(path);
  if (directory != NULL) {
    closedir(directory);
    (*next_frame)++;
    return path;
  }
  if (frame == 0 ||
      snprintf(path, PATH_MAX, "%s/%u", fixture_root, frame - 1) >= PATH_MAX)
    return NULL;
  return path;
}

static DrmScanResult scan_next_frame(GpuReader *reader,
                                     const char *fixture_root,
                                     unsigned int *next_frame,
                                     DrmSnapshot *snapshot) {
  char frame_path[PATH_MAX];
  const char *root = fixture_frame_root(
      fixture_root, reader->options->proc_root, next_frame, frame_path);
  if (root == NULL)
    return DRM_SCAN_UNREADABLE;
  return scan_drm_fdinfo(root, reader->selected_pci_bdf, fixture_root != NULL,
                         snapshot);
}

static const char *metric_error_name(MetricErrorCode code) {
  switch (code) {
  case METRIC_ERROR_COUNTER_RESET:
    return "counterReset";
  case METRIC_ERROR_DEPENDENCY_MISSING:
    return "dependencyMissing";
  case METRIC_ERROR_DEVICE_MISSING:
    return "deviceMissing";
  case METRIC_ERROR_DEVICE_SUSPENDED:
    return "deviceSuspended";
  case METRIC_ERROR_INSUFFICIENT_VISIBILITY:
    return "insufficientVisibility";
  case METRIC_ERROR_MALFORMED_COUNTER:
    return "malformedCounter";
  case METRIC_ERROR_NO_TRUE_ENGINE_PATH:
    return "noTrueEnginePath";
  case METRIC_ERROR_PERMISSION_DENIED:
    return "permissionDenied";
  case METRIC_ERROR_SAMPLE_TIMEOUT:
    return "sampleTimeout";
  case METRIC_ERROR_SOURCE_UNREADABLE:
    return "sourceUnreadable";
  case METRIC_ERROR_UNSUPPORTED_DEVICE:
    return "unsupportedDevice";
  case METRIC_ERROR_NONE:
    return NULL;
  }
  return NULL;
}

static const char *metric_error_retryability(MetricErrorCode code) {
  return code == METRIC_ERROR_UNSUPPORTED_DEVICE ||
                 code == METRIC_ERROR_NO_TRUE_ENGINE_PATH
             ? "nonRetryable"
             : "retryable";
}

static void clear_failure(GpuReader *reader) {
  reader->failure = (MetricError){0};
}

static void record_failure(GpuReader *reader, MetricErrorCode code,
                           const char *path, struct timespec now) {
  if (reader->failure.code != code || reader->failure.path == NULL ||
      strcmp(reader->failure.path, path) != 0) {
    reader->failure.since_ms = monotonic_ms(now);
  }
  reader->failure.code = code;
  reader->failure.path = path;
}

static void copy_reader_identity(GpuObservation *observation,
                                 const GpuReader *reader) {
  snprintf(observation->stable_id, sizeof(observation->stable_id), "%s",
           reader->selected_stable_id);
  snprintf(observation->pci_bdf, sizeof(observation->pci_bdf), "%s",
           reader->selected_pci_bdf);
}

static GpuObservation available_observation(GpuReader *reader, int percent,
                                            struct timespec now,
                                            int64_t window_ms,
                                            const char *path) {
  GpuObservation observation = {
      .handled = true,
      .available = true,
      .percent = percent,
      .sampled_at_ms = monotonic_ms(now),
      .window_ms = window_ms,
      .path = path,
      .evidence = "fixtureTested",
  };
  copy_reader_identity(&observation, reader);
  return observation;
}

static GpuObservation unavailable_observation(GpuReader *reader,
                                              MetricErrorCode code,
                                              const char *path,
                                              const char *diagnostic,
                                              struct timespec now) {
  record_failure(reader, code, path, now);
  GpuObservation observation = {
      .handled = true,
      .available = false,
      .error_code = metric_error_name(code),
      .retryability = metric_error_retryability(code),
      .diagnostic = diagnostic,
      .path = path,
      .evidence = "fixtureTested",
      .since_ms = reader->failure.since_ms,
  };
  copy_reader_identity(&observation, reader);
  return observation;
}

static MetricErrorCode drm_scan_error(DrmScanResult result,
                                      MetricErrorCode unreadable_error) {
  switch (result) {
  case DRM_SCAN_PERMISSION_DENIED:
    return METRIC_ERROR_PERMISSION_DENIED;
  case DRM_SCAN_INSUFFICIENT_VISIBILITY:
    return METRIC_ERROR_INSUFFICIENT_VISIBILITY;
  case DRM_SCAN_UNKNOWN_ABI:
    return METRIC_ERROR_UNSUPPORTED_DEVICE;
  case DRM_SCAN_UNREADABLE:
    return unreadable_error;
  case DRM_SCAN_OK:
    return METRIC_ERROR_NONE;
  }
  return unreadable_error;
}

static const char *amd_diagnostic(MetricErrorCode code) {
  switch (code) {
  case METRIC_ERROR_DEVICE_MISSING:
    return "the selected AMD device is no longer present";
  case METRIC_ERROR_DEVICE_SUSPENDED:
    return "the selected AMD device is runtime-suspended";
  case METRIC_ERROR_PERMISSION_DENIED:
    return "AMD engine counters could not be read with current permissions";
  case METRIC_ERROR_INSUFFICIENT_VISIBILITY:
    return "process visibility is insufficient for a system-wide AMD fdinfo "
           "value";
  case METRIC_ERROR_UNSUPPORTED_DEVICE:
    return "the selected AMD device exposes an unknown counter ABI";
  case METRIC_ERROR_COUNTER_RESET:
    return "AMD engine counters decreased during the observation window";
  case METRIC_ERROR_SOURCE_UNREADABLE:
    return "AMD engine counters could not be read";
  case METRIC_ERROR_MALFORMED_COUNTER:
    return "the selected AMD GPU load sensor returned an invalid percentage";
  case METRIC_ERROR_DEPENDENCY_MISSING:
  case METRIC_ERROR_SAMPLE_TIMEOUT:
  case METRIC_ERROR_NO_TRUE_ENGINE_PATH:
  case METRIC_ERROR_NONE:
    return "no documented AMD engine counter is available";
  }
  return "no documented AMD engine counter is available";
}

static GpuObservation amd_unavailable_observation(GpuReader *reader,
                                                  MetricErrorCode code,
                                                  const char *path,
                                                  struct timespec now) {
  return unavailable_observation(reader, code, path, amd_diagnostic(code), now);
}

static GpuObservation amd_failure_observation(GpuReader *reader,
                                              struct timespec now) {
  MetricErrorCode code = reader->failure.code == METRIC_ERROR_NONE
                             ? METRIC_ERROR_NO_TRUE_ENGINE_PATH
                             : reader->failure.code;
  const char *path =
      reader->failure.path == NULL ? "amd-measurement" : reader->failure.path;
  return amd_unavailable_observation(reader, code, path, now);
}

static bool amd_runtime_suspended(GpuReader *reader) {
  char path[PATH_MAX];
  char status[32] = {0};
  if (snprintf(path, sizeof(path), "%s/%s/power/runtime_status",
               reader->options->pci_devices_root,
               reader->selected_pci_bdf) >= (int)sizeof(path) ||
      !read_text_file(path, status, sizeof(status))) {
    return false;
  }
  return strcmp(status, "suspended") == 0 || strcmp(status, "suspending") == 0;
}

static GpuObservation amd_sysfs_error_observation(GpuReader *reader,
                                                  int error_number,
                                                  struct timespec now) {
  if (error_number == EOPNOTSUPP) {
    return amd_unavailable_observation(reader, METRIC_ERROR_UNSUPPORTED_DEVICE,
                                       "amd-gpu-busy-percent", now);
  }
  if (error_number == EACCES) {
    return amd_unavailable_observation(reader, METRIC_ERROR_PERMISSION_DENIED,
                                       "amd-gpu-busy-percent", now);
  }
  if (error_number == EPERM) {
    if (amd_runtime_suspended(reader)) {
      return amd_unavailable_observation(reader, METRIC_ERROR_DEVICE_SUSPENDED,
                                         "amd-gpu-busy-percent", now);
    }
    return amd_unavailable_observation(reader, METRIC_ERROR_SOURCE_UNREADABLE,
                                       "amd-gpu-busy-percent", now);
  }
  if (error_number == ENOENT || error_number == ENODEV ||
      error_number == ENXIO || error_number == EIO) {
    return amd_unavailable_observation(reader, METRIC_ERROR_DEVICE_MISSING,
                                       "amd-gpu-busy-percent", now);
  }
  return amd_unavailable_observation(reader, METRIC_ERROR_SOURCE_UNREADABLE,
                                     "amd-gpu-busy-percent", now);
}

static int amd_fixture_error(const char *text) {
  if (strcmp(text, "error:EOPNOTSUPP") == 0 ||
      strcmp(text, "error:ENOTSUPP") == 0)
    return EOPNOTSUPP;
  if (strcmp(text, "error:EACCES") == 0)
    return EACCES;
  if (strcmp(text, "error:EPERM") == 0)
    return EPERM;
  if (strcmp(text, "error:ENODEV") == 0)
    return ENODEV;
  if (strcmp(text, "error:ENOENT") == 0)
    return ENOENT;
  return 0;
}

static GpuObservation observe_amd_sysfs(GpuReader *reader,
                                        struct timespec now) {
  AmdReaderState *state = &reader->state.amd;
  if (amd_runtime_suspended(reader)) {
    return amd_unavailable_observation(reader, METRIC_ERROR_DEVICE_SUSPENDED,
                                       "amd-gpu-busy-percent", now);
  }
  char path[PATH_MAX];
  char text[64] = {0};
  if (snprintf(path, sizeof(path), "%s/%s/gpu_busy_percent",
               reader->options->pci_devices_root,
               reader->selected_pci_bdf) >= (int)sizeof(path)) {
    return amd_sysfs_error_observation(reader, ENAMETOOLONG, now);
  }
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return amd_sysfs_error_observation(reader, errno, now);
  errno = 0;
  if (fgets(text, sizeof(text), stream) == NULL) {
    int read_error = errno == 0 ? EIO : errno;
    fclose(stream);
    return amd_sysfs_error_observation(reader, read_error, now);
  }
  fclose(stream);
  trim(text);

  int fixture_error =
      reader->options->fixture_system ? amd_fixture_error(text) : 0;
  if (fixture_error != 0)
    return amd_sysfs_error_observation(reader, fixture_error, now);

  uint64_t value = 0;
  const char *suffix = NULL;
  if (!parse_uint64(text, &value, &suffix) || *suffix != '\0' || value > 100) {
    return amd_unavailable_observation(reader, METRIC_ERROR_MALFORMED_COUNTER,
                                       "amd-gpu-busy-percent", now);
  }

  int64_t window_ms = elapsed_ms(state->baseline_at, now);
  state->baseline_at = now;
  clear_failure(reader);
  return available_observation(reader, (int)value, now, window_ms,
                               "amd-gpu-busy-percent");
}

static bool prepare_amd_fdinfo(GpuReader *reader, struct timespec now,
                               bool record_errors) {
  AmdReaderState *state = &reader->state.amd;
  state->path = AMD_PATH_NONE;
  DrmSnapshot baseline = {0};
  DrmScanResult result =
      scan_next_frame(reader, reader->options->fixture_amd_proc_frames_root,
                      &state->next_fixture_frame, &baseline);
  if (result == DRM_SCAN_OK && baseline.saw_target &&
      baseline.saw_engine_counter && baseline.driver == DRM_DRIVER_AMDGPU) {
    state->path = AMD_PATH_FDINFO;
    state->baseline = baseline;
    state->baseline_at = baseline_instant(reader, now);
    clear_failure(reader);
    return true;
  }
  if (!record_errors)
    return false;
  MetricErrorCode error =
      drm_scan_error(result, METRIC_ERROR_SOURCE_UNREADABLE);
  if (result == DRM_SCAN_OK)
    error = baseline.saw_target && baseline.driver != DRM_DRIVER_AMDGPU
                ? METRIC_ERROR_UNSUPPORTED_DEVICE
                : METRIC_ERROR_NO_TRUE_ENGINE_PATH;
  const char *path = error == METRIC_ERROR_NO_TRUE_ENGINE_PATH
                         ? "amd-measurement"
                         : "amd-fdinfo";
  record_failure(reader, error, path, now);
  return false;
}

static void open_amd_reader(GpuReader *reader, struct timespec now) {
  AmdReaderState *state = &reader->state.amd;
  char device_path[PATH_MAX];
  char busy_path[PATH_MAX];
  if (snprintf(device_path, sizeof(device_path), "%s/%s",
               reader->options->pci_devices_root,
               reader->selected_pci_bdf) >= (int)sizeof(device_path) ||
      snprintf(busy_path, sizeof(busy_path), "%s/gpu_busy_percent",
               device_path) >= (int)sizeof(busy_path)) {
    record_failure(reader, METRIC_ERROR_NO_TRUE_ENGINE_PATH, "amd-measurement",
                   now);
    return;
  }
  if (access(device_path, F_OK) != 0) {
    record_failure(reader, METRIC_ERROR_DEVICE_MISSING, "amd-gpu-busy-percent",
                   now);
    return;
  }
  if (access(busy_path, F_OK) == 0) {
    state->path = AMD_PATH_GPU_BUSY_PERCENT;
    state->baseline_at = baseline_instant(reader, now);
    return;
  }
  if (reader->options->fixture_system &&
      reader->options->fixture_amd_proc_frames_root == NULL) {
    record_failure(reader, METRIC_ERROR_NO_TRUE_ENGINE_PATH, "amd-measurement",
                   now);
    return;
  }
  prepare_amd_fdinfo(reader, now, true);
}

static bool load_nvml_symbol(void *library, const char *name, void *destination,
                             size_t destination_size) {
  void *symbol = dlsym(library, name);
  if (symbol == NULL || destination_size != sizeof(symbol))
    return false;
  memcpy(destination, &symbol, sizeof(symbol));
  return true;
}

static void open_nvidia_reader(GpuReader *reader, struct timespec now) {
  NvidiaReaderState *state = &reader->state.nvidia;
  state->baseline_at = baseline_instant(reader, now);
  if (strncmp(reader->selected_stable_id, "nvidia:GPU-", 11) != 0) {
    record_failure(reader, METRIC_ERROR_UNSUPPORTED_DEVICE, "nvidia-nvml", now);
    return;
  }
  if (nvidia_provider_quarantined) {
    state->timed_out = true;
    record_failure(reader, METRIC_ERROR_SAMPLE_TIMEOUT, "nvidia-nvml", now);
    return;
  }

  if (nvidia_provider.library == NULL) {
    nvidia_provider.library =
        dlopen(reader->options->nvml_library_path, RTLD_NOW | RTLD_LOCAL);
    if (nvidia_provider.library == NULL) {
      record_failure(reader, METRIC_ERROR_DEPENDENCY_MISSING, "nvidia-nvml",
                     now);
      return;
    }

    bool complete =
        load_nvml_symbol(nvidia_provider.library, "nvmlInit_v2",
                         &nvidia_provider.api.init,
                         sizeof(nvidia_provider.api.init)) &&
        load_nvml_symbol(nvidia_provider.library, "nvmlDeviceGetHandleByUUID",
                         &nvidia_provider.api.get_handle_by_uuid,
                         sizeof(nvidia_provider.api.get_handle_by_uuid)) &&
        load_nvml_symbol(nvidia_provider.library,
                         "nvmlDeviceGetHandleByPciBusId_v2",
                         &nvidia_provider.api.get_handle_by_pci_bdf,
                         sizeof(nvidia_provider.api.get_handle_by_pci_bdf)) &&
        load_nvml_symbol(nvidia_provider.library, "nvmlDeviceGetUUID",
                         &nvidia_provider.api.get_uuid,
                         sizeof(nvidia_provider.api.get_uuid)) &&
        load_nvml_symbol(nvidia_provider.library,
                         "nvmlDeviceGetUtilizationRates",
                         &nvidia_provider.api.get_utilization,
                         sizeof(nvidia_provider.api.get_utilization));
    if (!complete) {
      dlclose(nvidia_provider.library);
      nvidia_provider = (NvmlProvider){0};
      record_failure(reader, METRIC_ERROR_DEPENDENCY_MISSING, "nvidia-nvml",
                     now);
      return;
    }
  }
  state->provider_available = true;
}

static void release_nvidia_call(NvidiaCall *call) {
  if (atomic_fetch_sub_explicit(&call->references, 1, memory_order_acq_rel) ==
      1)
    free(call);
}

static void *run_nvidia_call(void *argument) {
  NvidiaCall *call = argument;
  if (!call->initialized) {
    call->stage = NVIDIA_STAGE_INIT;
    call->result = call->api.init();
    if (call->result != NVML_SUCCESS)
      goto finished;
    call->initialized = true;
  }

  if (call->device == NULL) {
    call->stage = NVIDIA_STAGE_UUID_LOOKUP;
    call->result = call->api.get_handle_by_uuid(call->uuid, &call->device);
    if (call->result != NVML_SUCCESS)
      goto finished;

    NvmlDevice pci_device = NULL;
    call->stage = NVIDIA_STAGE_PCI_LOOKUP;
    call->result = call->api.get_handle_by_pci_bdf(call->pci_bdf, &pci_device);
    if (call->result != NVML_SUCCESS)
      goto finished;

    char pci_uuid[NVIDIA_UUID_SIZE] = {0};
    call->stage = NVIDIA_STAGE_PCI_UUID;
    call->result = call->api.get_uuid(pci_device, pci_uuid, sizeof(pci_uuid));
    if (call->result != NVML_SUCCESS)
      goto finished;
    call->stage = NVIDIA_STAGE_IDENTITY;
    if (strcmp(pci_uuid, call->uuid) != 0)
      goto finished;
    call->identity_verified = true;
  } else {
    call->identity_verified = true;
  }

  NvmlUtilization utilization = {0};
  call->stage = NVIDIA_STAGE_UTILIZATION;
  call->result = call->api.get_utilization(call->device, &utilization);
  if (call->result == NVML_SUCCESS)
    call->percent = utilization.gpu;

finished:
  release_nvidia_call(call);
  return NULL;
}

static MetricErrorCode nvidia_error_code(NvidiaCallStage stage,
                                         NvmlReturn result) {
  if (stage == NVIDIA_STAGE_IDENTITY)
    return METRIC_ERROR_SOURCE_UNREADABLE;
  if (result == NVML_ERROR_NOT_FOUND || result == NVML_ERROR_GPU_NOT_FOUND ||
      result == NVML_ERROR_GPU_IS_LOST ||
      result == NVML_ERROR_INSUFFICIENT_POWER ||
      result == NVML_ERROR_IRQ_ISSUE || result == NVML_ERROR_RESET_REQUIRED) {
    return METRIC_ERROR_DEVICE_MISSING;
  }
  if (result == NVML_ERROR_DRIVER_NOT_LOADED ||
      result == NVML_ERROR_LIBRARY_NOT_FOUND ||
      result == NVML_ERROR_FUNCTION_NOT_FOUND ||
      result == NVML_ERROR_LIB_RM_VERSION_MISMATCH) {
    return METRIC_ERROR_DEPENDENCY_MISSING;
  }
  if (result == NVML_ERROR_NO_PERMISSION ||
      result == NVML_ERROR_OPERATING_SYSTEM) {
    return METRIC_ERROR_PERMISSION_DENIED;
  }
  if (result == NVML_ERROR_TIMEOUT)
    return METRIC_ERROR_SAMPLE_TIMEOUT;
  if (result == NVML_ERROR_NOT_READY)
    return METRIC_ERROR_DEVICE_SUSPENDED;
  if (result == NVML_ERROR_NOT_SUPPORTED)
    return METRIC_ERROR_UNSUPPORTED_DEVICE;
  return METRIC_ERROR_SOURCE_UNREADABLE;
}

static const char *nvidia_diagnostic(MetricErrorCode code,
                                     NvidiaCallStage stage) {
  switch (code) {
  case METRIC_ERROR_DEPENDENCY_MISSING:
    return stage == NVIDIA_STAGE_INIT
               ? "the NVIDIA driver or its NVML runtime is unavailable"
               : "the NVML library or a required NVML API is unavailable";
  case METRIC_ERROR_DEVICE_MISSING:
    return stage == NVIDIA_STAGE_IDENTITY
               ? "the selected Nvidia UUID does not match its expected PCI "
                 "device"
               : "the selected Nvidia UUID is no longer available";
  case METRIC_ERROR_DEVICE_SUSPENDED:
    return "the selected Nvidia device is not ready, likely runtime-suspended";
  case METRIC_ERROR_PERMISSION_DENIED:
    return "NVML cannot access the selected Nvidia device with current "
           "permissions";
  case METRIC_ERROR_SAMPLE_TIMEOUT:
    return "NVML did not return the selected Nvidia sample before its deadline";
  case METRIC_ERROR_UNSUPPORTED_DEVICE:
    return "NVML graphics utilization is unavailable for this device, "
           "including MIG mode";
  case METRIC_ERROR_MALFORMED_COUNTER:
    return "NVML returned a graphics utilization percentage outside 0 to 100";
  case METRIC_ERROR_SOURCE_UNREADABLE:
    return stage == NVIDIA_STAGE_IDENTITY
               ? "the selected Nvidia UUID does not match its expected PCI "
                 "device"
               : "NVML could not read graphics utilization for the selected "
                 "Nvidia device";
  default:
    return "NVML could not read graphics utilization for the selected Nvidia "
           "device";
  }
}

static GpuObservation nvidia_unavailable_observation(GpuReader *reader,
                                                     MetricErrorCode code,
                                                     NvidiaCallStage stage,
                                                     struct timespec now) {
  return unavailable_observation(reader, code, "nvidia-nvml",
                                 nvidia_diagnostic(code, stage), now);
}

static GpuObservation observe_nvidia_reader(GpuReader *reader,
                                            struct timespec now) {
  NvidiaReaderState *state = &reader->state.nvidia;
  if (!state->provider_available) {
    MetricErrorCode code = reader->failure.code == METRIC_ERROR_NONE
                               ? METRIC_ERROR_DEPENDENCY_MISSING
                               : reader->failure.code;
    return nvidia_unavailable_observation(reader, code, NVIDIA_STAGE_NONE, now);
  }
  if (state->timed_out) {
    return nvidia_unavailable_observation(reader, METRIC_ERROR_SAMPLE_TIMEOUT,
                                          NVIDIA_STAGE_UTILIZATION, now);
  }

  NvidiaCall *call = calloc(1, sizeof(*call));
  if (call == NULL) {
    return nvidia_unavailable_observation(
        reader, METRIC_ERROR_SOURCE_UNREADABLE, NVIDIA_STAGE_NONE, now);
  }
  call->api = nvidia_provider.api;
  call->device = state->device;
  call->initialized = nvidia_provider.initialized;
  atomic_init(&call->references, 2);
  snprintf(call->uuid, sizeof(call->uuid), "%s",
           reader->selected_stable_id + strlen("nvidia:"));
  snprintf(call->pci_bdf, sizeof(call->pci_bdf), "0000%s",
           reader->selected_pci_bdf);

  pthread_t worker;
  int create_result = pthread_create(&worker, NULL, run_nvidia_call, call);
  if (create_result != 0) {
    free(call);
    return nvidia_unavailable_observation(
        reader, METRIC_ERROR_SOURCE_UNREADABLE, NVIDIA_STAGE_NONE, now);
  }

  struct timespec timeout_at;
  if (clock_gettime(CLOCK_REALTIME, &timeout_at) != 0) {
    pthread_detach(worker);
    nvidia_provider_quarantined = true;
    state->timed_out = true;
    release_nvidia_call(call);
    return nvidia_unavailable_observation(reader, METRIC_ERROR_SAMPLE_TIMEOUT,
                                          NVIDIA_STAGE_NONE, now);
  }
  timeout_at.tv_nsec += NVIDIA_CALL_TIMEOUT_MS * 1000000L;
  timeout_at.tv_sec += timeout_at.tv_nsec / 1000000000L;
  timeout_at.tv_nsec %= 1000000000L;
  int join_result = pthread_timedjoin_np(worker, NULL, &timeout_at);
  if (join_result != 0) {
    pthread_detach(worker);
    nvidia_provider_quarantined = true;
    state->timed_out = true;
    release_nvidia_call(call);
    return nvidia_unavailable_observation(reader, METRIC_ERROR_SAMPLE_TIMEOUT,
                                          NVIDIA_STAGE_UTILIZATION, now);
  }

  nvidia_provider.initialized = call->initialized;
  if (call->identity_verified)
    state->device = call->device;
  int64_t window_ms = elapsed_ms(state->baseline_at, now);
  state->baseline_at = now;

  if (call->stage == NVIDIA_STAGE_IDENTITY) {
    release_nvidia_call(call);
    return nvidia_unavailable_observation(
        reader, nvidia_error_code(NVIDIA_STAGE_IDENTITY, NVML_SUCCESS),
        NVIDIA_STAGE_IDENTITY, now);
  }
  if (call->result != NVML_SUCCESS) {
    MetricErrorCode code = nvidia_error_code(call->stage, call->result);
    NvidiaCallStage stage = call->stage;
    release_nvidia_call(call);
    return nvidia_unavailable_observation(reader, code, stage, now);
  }
  if (call->percent > 100) {
    release_nvidia_call(call);
    return nvidia_unavailable_observation(
        reader, METRIC_ERROR_MALFORMED_COUNTER, NVIDIA_STAGE_UTILIZATION, now);
  }

  int percent = (int)call->percent;
  release_nvidia_call(call);
  clear_failure(reader);
  return available_observation(reader, percent, now, window_ms, "nvidia-nvml");
}

static void prepare_intel_fdinfo(GpuReader *reader, struct timespec now) {
  IntelReaderState *state = &reader->state.intel;
  state->path = INTEL_PATH_NONE;
  DrmSnapshot baseline = {0};
  DrmScanResult result =
      scan_next_frame(reader, reader->options->fixture_intel_proc_frames_root,
                      &state->next_fixture_frame, &baseline);
  if (result == DRM_SCAN_OK && baseline.saw_target &&
      baseline.driver == DRM_DRIVER_I915 && baseline.saw_engine_counter) {
    state->path = INTEL_PATH_I915_FDINFO;
    state->baseline = baseline;
    state->baseline_at = baseline_instant(reader, now);
    clear_failure(reader);
  } else if (result == DRM_SCAN_OK && baseline.saw_target &&
             baseline.driver == DRM_DRIVER_XE && baseline.saw_engine_counter) {
    state->path = INTEL_PATH_XE_FDINFO;
    state->baseline = baseline;
    state->baseline_at = baseline_instant(reader, now);
    clear_failure(reader);
  } else {
    MetricErrorCode error =
        drm_scan_error(result, METRIC_ERROR_NO_TRUE_ENGINE_PATH);
    if (result == DRM_SCAN_OK)
      error = baseline.saw_target ? METRIC_ERROR_UNSUPPORTED_DEVICE
                                  : METRIC_ERROR_NO_TRUE_ENGINE_PATH;
    const char *path = error == METRIC_ERROR_NO_TRUE_ENGINE_PATH
                           ? "intel-measurement"
                           : "intel-fdinfo";
    record_failure(reader, error, path, now);
  }
}

static void open_intel_reader(GpuReader *reader, struct timespec now) {
  IntelReaderState *state = &reader->state.intel;
  if (reader->options->fixture_intel_proc_frames_root != NULL) {
    prepare_intel_fdinfo(reader, now);
    return;
  }
  if (reader->options->fixture_system && !reader->options->fixture_pmu_system) {
    record_failure(reader, METRIC_ERROR_NO_TRUE_ENGINE_PATH,
                   "intel-measurement", now);
    return;
  }

  PmuOpenResult pmu = open_i915_pmu(reader, now);
  if (pmu == PMU_OPEN_OK)
    return;
  if (!reader->options->fixture_system)
    prepare_intel_fdinfo(reader, now);
  if (state->path != INTEL_PATH_NONE)
    return;
  if (pmu == PMU_OPEN_PERMISSION_DENIED) {
    record_failure(reader, METRIC_ERROR_PERMISSION_DENIED, "intel-i915-pmu",
                   now);
  } else if (pmu == PMU_OPEN_UNKNOWN_ABI) {
    record_failure(reader, METRIC_ERROR_UNSUPPORTED_DEVICE, "intel-i915-pmu",
                   now);
  }
}

static GpuObservation observe_intel_reader(GpuReader *reader,
                                           struct timespec now);
static GpuObservation observe_amd_reader(GpuReader *reader,
                                         struct timespec now);

static void close_intel_reader(GpuReader *reader) { close_pmu(reader); }

static const GpuAdapter GPU_ADAPTERS[] = {
    {.vendor = GPU_VENDOR_INTEL,
     .open = open_intel_reader,
     .observe = observe_intel_reader,
     .close = close_intel_reader},
    {.vendor = GPU_VENDOR_AMD,
     .open = open_amd_reader,
     .observe = observe_amd_reader,
     .close = NULL},
    {.vendor = GPU_VENDOR_NVIDIA,
     .open = open_nvidia_reader,
     .observe = observe_nvidia_reader,
     .close = NULL},
};

static const GpuAdapter *find_adapter(GpuVendor vendor) {
  for (size_t i = 0; i < sizeof(GPU_ADAPTERS) / sizeof(GPU_ADAPTERS[0]); i++) {
    if (GPU_ADAPTERS[i].vendor == vendor)
      return &GPU_ADAPTERS[i];
  }
  return NULL;
}

static void close_reader(GpuReader *reader) {
  if (reader->adapter != NULL && reader->adapter->close != NULL)
    reader->adapter->close(reader);
}

GpuMeasurement *gpu_measurement_create(const GpuMeasurementOptions *options) {
  GpuMeasurement *measurement = calloc(1, sizeof(*measurement));
  if (measurement != NULL) {
    measurement->options = *options;
    measurement->reader.options = &measurement->options;
  }
  return measurement;
}

void gpu_measurement_destroy(GpuMeasurement *measurement) {
  if (measurement == NULL)
    return;
  close_reader(&measurement->reader);
  free(measurement);
}

void gpu_measurement_reconcile(GpuMeasurement *measurement,
                               const GpuDevice *selected, struct timespec now) {
  GpuReader *reader = &measurement->reader;
  const char *stable_id = selected == NULL ? "" : selected->stable_id;
  const char *pci_bdf = selected == NULL ? "" : selected->pci_bdf;
  const GpuAdapter *adapter =
      selected == NULL ? NULL : find_adapter(selected->vendor);
  if (strcmp(reader->selected_stable_id, stable_id) == 0 &&
      strcmp(reader->selected_pci_bdf, pci_bdf) == 0 &&
      reader->adapter == adapter)
    return;

  close_reader(reader);
  *reader = (GpuReader){.options = &measurement->options};
  snprintf(reader->selected_stable_id, sizeof(reader->selected_stable_id), "%s",
           stable_id);
  snprintf(reader->selected_pci_bdf, sizeof(reader->selected_pci_bdf), "%s",
           pci_bdf);
  if (selected == NULL)
    return;
  reader->adapter = adapter;
  if (reader->adapter != NULL)
    reader->adapter->open(reader, now);
}

void gpu_measurement_reset(GpuMeasurement *measurement,
                           const GpuDevice *selected, struct timespec now) {
  measurement->reader.selected_stable_id[0] = '\0';
  gpu_measurement_reconcile(measurement, selected, now);
}

static const DrmEngineCounters *const_engine(const DrmClientCounters *client,
                                             const char *name) {
  for (size_t i = 0; i < client->engine_count; i++) {
    if (strcmp(client->engines[i].name, name) == 0)
      return &client->engines[i];
  }
  return NULL;
}

typedef struct {
  char name[DRM_ENGINE_NAME_SIZE];
  long double busy_delta;
  long double total_delta;
  unsigned int capacity;
} EngineDelta;

static EngineDelta *find_delta(EngineDelta deltas[DRM_MAX_ENGINES],
                               size_t *count, const char *name) {
  for (size_t i = 0; i < *count; i++) {
    if (strcmp(deltas[i].name, name) == 0)
      return &deltas[i];
  }
  if (*count >= DRM_MAX_ENGINES)
    return NULL;
  EngineDelta *delta = &deltas[(*count)++];
  *delta = (EngineDelta){.capacity = 1};
  memcpy(delta->name, name, strlen(name) + 1);
  return delta;
}

static bool engine_time_percent(const DrmSnapshot *before,
                                const DrmSnapshot *after, int64_t window_ms,
                                int *percent, bool *counter_reset) {
  EngineDelta deltas[DRM_MAX_ENGINES] = {0};
  size_t delta_count = 0;
  bool compared = false;
  for (size_t i = 0; i < after->client_count; i++) {
    const DrmClientCounters *current = &after->clients[i];
    const DrmClientCounters *previous =
        find_const_client(before, current->client_id);
    if (previous == NULL)
      continue;
    for (size_t j = 0; j < current->engine_count; j++) {
      const DrmEngineCounters *engine = &current->engines[j];
      const DrmEngineCounters *old = const_engine(previous, engine->name);
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

static bool xe_percent(const DrmSnapshot *before, const DrmSnapshot *after,
                       int *percent, bool *counter_reset) {
  EngineDelta deltas[DRM_MAX_ENGINES] = {0};
  size_t delta_count = 0;
  bool compared = false;
  for (size_t i = 0; i < after->client_count; i++) {
    const DrmClientCounters *current = &after->clients[i];
    const DrmClientCounters *previous =
        find_const_client(before, current->client_id);
    if (previous == NULL)
      continue;
    for (size_t j = 0; j < current->engine_count; j++) {
      const DrmEngineCounters *engine = &current->engines[j];
      const DrmEngineCounters *old = const_engine(previous, engine->name);
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

static const char *intel_diagnostic(MetricErrorCode code) {
  switch (code) {
  case METRIC_ERROR_PERMISSION_DENIED:
    return "Intel engine counters could not be read with current permissions";
  case METRIC_ERROR_INSUFFICIENT_VISIBILITY:
    return "process visibility is insufficient for a system-wide fdinfo value";
  case METRIC_ERROR_UNSUPPORTED_DEVICE:
    return "the selected Intel device exposes an unknown counter ABI";
  case METRIC_ERROR_COUNTER_RESET:
    return "Intel engine counters reset during the observation window";
  default:
    return "no documented Intel engine counter is available";
  }
}

static GpuObservation intel_unavailable_observation(GpuReader *reader,
                                                    struct timespec now) {
  MetricErrorCode code = reader->failure.code == METRIC_ERROR_NONE
                             ? METRIC_ERROR_NO_TRUE_ENGINE_PATH
                             : reader->failure.code;
  const char *path =
      reader->failure.path == NULL ? "intel-measurement" : reader->failure.path;
  return unavailable_observation(reader, code, path, intel_diagnostic(code),
                                 now);
}

static GpuObservation observe_amd_reader(GpuReader *reader,
                                         struct timespec now) {
  AmdReaderState *state = &reader->state.amd;
  if (state->path == AMD_PATH_GPU_BUSY_PERCENT) {
    GpuObservation observation = observe_amd_sysfs(reader, now);
    if (!observation.available &&
        reader->failure.code != METRIC_ERROR_DEVICE_SUSPENDED &&
        reader->failure.code != METRIC_ERROR_DEVICE_MISSING &&
        (!reader->options->fixture_system ||
         reader->options->fixture_amd_proc_frames_root != NULL)) {
      prepare_amd_fdinfo(reader, now, false);
    }
    return observation;
  }
  if (state->path == AMD_PATH_FDINFO) {
    DrmSnapshot current = {0};
    DrmScanResult scan =
        scan_next_frame(reader, reader->options->fixture_amd_proc_frames_root,
                        &state->next_fixture_frame, &current);
    if (scan != DRM_SCAN_OK) {
      record_failure(reader,
                     drm_scan_error(scan, METRIC_ERROR_SOURCE_UNREADABLE),
                     "amd-fdinfo", now);
      return amd_failure_observation(reader, now);
    }
    if (current.driver != DRM_DRIVER_AMDGPU || !current.saw_engine_counter) {
      record_failure(reader,
                     current.saw_target ? METRIC_ERROR_NO_TRUE_ENGINE_PATH
                                        : METRIC_ERROR_SOURCE_UNREADABLE,
                     "amd-fdinfo", now);
      return amd_failure_observation(reader, now);
    }
    int64_t window_ms = elapsed_ms(state->baseline_at, now);
    int percent = 0;
    bool counter_reset = false;
    bool available = engine_time_percent(&state->baseline, &current, window_ms,
                                         &percent, &counter_reset);
    if (!available) {
      record_failure(reader,
                     counter_reset ? METRIC_ERROR_COUNTER_RESET
                                   : METRIC_ERROR_NO_TRUE_ENGINE_PATH,
                     "amd-fdinfo", now);
      if (!counter_reset) {
        state->baseline = current;
        state->baseline_at = now;
      }
      return amd_failure_observation(reader, now);
    }
    state->baseline = current;
    state->baseline_at = now;
    clear_failure(reader);
    return available_observation(reader, percent, now, window_ms, "amd-fdinfo");
  }
  return amd_failure_observation(reader, now);
}

static GpuObservation observe_intel_reader(GpuReader *reader,
                                           struct timespec now) {
  IntelReaderState *state = &reader->state.intel;
  if (state->path == INTEL_PATH_NONE) {
    GpuObservation prior = intel_unavailable_observation(reader, now);
    bool retryable = reader->failure.code != METRIC_ERROR_UNSUPPORTED_DEVICE &&
                     reader->failure.code != METRIC_ERROR_NO_TRUE_ENGINE_PATH;
    if (retryable)
      open_intel_reader(reader, now);
    if (state->path != INTEL_PATH_NONE)
      return prior;
    return intel_unavailable_observation(reader, now);
  }

  if (state->path == INTEL_PATH_I915_PMU) {
    int64_t window_ms = elapsed_ms(state->baseline_at, now);
    long double maximum = 0.0L;
    bool counter_reset = false;
    MetricErrorCode read_error = METRIC_ERROR_NONE;
    uint64_t current_values[INTEL_MAX_PMU_EVENTS] = {0};
    for (size_t i = 0; i < state->pmu_event_count; i++) {
      if (read(state->pmu_fds[i], &current_values[i],
               sizeof(current_values[i])) !=
          (ssize_t)sizeof(current_values[i])) {
        read_error = errno == EACCES || errno == EPERM
                         ? METRIC_ERROR_PERMISSION_DENIED
                     : errno == ENODEV || errno == ENXIO || errno == EIO
                         ? METRIC_ERROR_DEVICE_MISSING
                         : METRIC_ERROR_NO_TRUE_ENGINE_PATH;
        continue;
      }
      if (current_values[i] < state->pmu_baseline[i]) {
        counter_reset = true;
      } else if (window_ms > 0) {
        long double value =
            (long double)(current_values[i] - state->pmu_baseline[i]) * 100.0L /
            ((long double)window_ms * 1000000.0L);
        if (value > maximum)
          maximum = value;
      }
    }
    if (counter_reset && read_error == METRIC_ERROR_NONE) {
      for (size_t i = 0; i < state->pmu_event_count; i++)
        state->pmu_baseline[i] = current_values[i];
      state->baseline_at = now;
    }
    if (counter_reset || read_error != METRIC_ERROR_NONE || window_ms <= 0) {
      record_failure(reader,
                     counter_reset ? METRIC_ERROR_COUNTER_RESET
                     : read_error == METRIC_ERROR_NONE
                         ? METRIC_ERROR_NO_TRUE_ENGINE_PATH
                         : read_error,
                     "intel-i915-pmu", now);
      return intel_unavailable_observation(reader, now);
    }
    for (size_t i = 0; i < state->pmu_event_count; i++)
      state->pmu_baseline[i] = current_values[i];
    state->baseline_at = now;
    if (maximum > 100.0L)
      maximum = 100.0L;
    clear_failure(reader);
    return available_observation(reader, (int)floorl(maximum + 0.5L), now,
                                 window_ms, "intel-i915-pmu");
  }

  DrmSnapshot current = {0};
  DrmScanResult scan =
      scan_next_frame(reader, reader->options->fixture_intel_proc_frames_root,
                      &state->next_fixture_frame, &current);
  DrmDriver expected_driver =
      state->path == INTEL_PATH_XE_FDINFO ? DRM_DRIVER_XE : DRM_DRIVER_I915;
  const char *path = state->path == INTEL_PATH_XE_FDINFO ? "intel-xe-fdinfo"
                                                         : "intel-i915-fdinfo";
  if (scan != DRM_SCAN_OK || current.driver != expected_driver ||
      !current.saw_engine_counter) {
    MetricErrorCode code =
        drm_scan_error(scan, METRIC_ERROR_NO_TRUE_ENGINE_PATH);
    if (scan == DRM_SCAN_OK)
      code = current.saw_target ? METRIC_ERROR_UNSUPPORTED_DEVICE
                                : METRIC_ERROR_NO_TRUE_ENGINE_PATH;
    record_failure(reader, code, path, now);
    return intel_unavailable_observation(reader, now);
  }

  int64_t window_ms = elapsed_ms(state->baseline_at, now);
  int percent = 0;
  bool counter_reset = false;
  bool available =
      state->path == INTEL_PATH_XE_FDINFO
          ? xe_percent(&state->baseline, &current, &percent, &counter_reset)
          : engine_time_percent(&state->baseline, &current, window_ms, &percent,
                                &counter_reset);
  if (!available) {
    record_failure(reader,
                   counter_reset ? METRIC_ERROR_COUNTER_RESET
                                 : METRIC_ERROR_NO_TRUE_ENGINE_PATH,
                   path, now);
    state->baseline = current;
    state->baseline_at = now;
    return intel_unavailable_observation(reader, now);
  }

  state->baseline = current;
  state->baseline_at = now;

  clear_failure(reader);
  return available_observation(reader, percent, now, window_ms, path);
}

GpuObservation gpu_measurement_observe(GpuMeasurement *measurement,
                                       const GpuDevice *selected,
                                       struct timespec now) {
  gpu_measurement_reconcile(measurement, selected, now);
  GpuReader *reader = &measurement->reader;
  if (reader->adapter == NULL)
    return (GpuObservation){0};

  const char *sample_log_path = getenv("SYSTEM_STATS_GPU_SAMPLE_LOG");
  if (reader->options->fixture_system && sample_log_path != NULL &&
      sample_log_path[0] != '\0') {
    FILE *sample_log = fopen(sample_log_path, "ae");
    if (sample_log != NULL) {
      const char *vendor = reader->adapter->vendor == GPU_VENDOR_INTEL ? "intel"
                           : reader->adapter->vendor == GPU_VENDOR_AMD
                               ? "amd"
                               : "nvidia";
      fprintf(sample_log, "%s\t%s\n", vendor, reader->selected_stable_id);
      fclose(sample_log);
    }
  }
  return reader->adapter->observe(reader, now);
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
