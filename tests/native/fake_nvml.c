#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
  NVML_SUCCESS = 0,
  NVML_ERROR_INVALID_ARGUMENT = 2,
  NVML_ERROR_NOT_SUPPORTED = 3,
  NVML_ERROR_NOT_FOUND = 6,
  NVML_ERROR_DRIVER_NOT_LOADED = 9,
  NVML_ERROR_TIMEOUT = 10,
  NVML_ERROR_NOT_READY = 27
};

typedef struct {
  const char *uuid;
  const char *pci_bdf;
  unsigned int percent;
} FakeDevice;

typedef struct {
  unsigned int gpu;
  unsigned int memory;
} NvmlUtilization;

static FakeDevice devices[] = {
    {.uuid = "GPU-11111111-1111-1111-1111-111111111111",
     .pci_bdf = "00000000:02:00.0",
     .percent = 99},
    {.uuid = "GPU-22222222-2222-2222-2222-222222222222",
     .pci_bdf = "00000000:01:00.0",
     .percent = 47},
};

static const char *fixture_case(void) {
  const char *value = getenv("SYSTEM_STATS_NVML_CASE");
  return value == NULL ? "valid" : value;
}

static void log_api_call(const char *name) {
  const char *path = getenv("SYSTEM_STATS_NVML_API_LOG");
  if (path == NULL)
    return;
  FILE *stream = fopen(path, "ae");
  if (stream == NULL)
    return;
  fprintf(stream, "%s\n", name);
  fclose(stream);
}

int nvmlInit_v2(void) {
  log_api_call("init");
  return strcmp(fixture_case(), "driver-missing") == 0
             ? NVML_ERROR_DRIVER_NOT_LOADED
             : NVML_SUCCESS;
}

int nvmlShutdown(void) {
  if (strcmp(fixture_case(), "shutdown-hangs") == 0) {
    struct timespec duration = {.tv_sec = 10};
    nanosleep(&duration, NULL);
  }
  return NVML_SUCCESS;
}

int nvmlDeviceGetHandleByIndex_v2(unsigned int index, void **device) {
  const char *log_path = getenv("SYSTEM_STATS_NVML_INDEX_LOG");
  if (log_path != NULL) {
    FILE *stream = fopen(log_path, "ae");
    if (stream != NULL) {
      fputs("index lookup\n", stream);
      fclose(stream);
    }
  }
  if (device == NULL || index >= 2)
    return NVML_ERROR_INVALID_ARGUMENT;
  *device = &devices[index];
  return NVML_SUCCESS;
}

int nvmlDeviceGetHandleByUUID(const char *uuid, void **device) {
  log_api_call("uuid lookup");
  if (strcmp(fixture_case(), "device-missing") == 0)
    return NVML_ERROR_NOT_FOUND;
  if (uuid == NULL || device == NULL)
    return NVML_ERROR_INVALID_ARGUMENT;
  for (size_t i = 0; i < sizeof(devices) / sizeof(devices[0]); i++) {
    if (strcmp(devices[i].uuid, uuid) == 0) {
      *device = &devices[i];
      return NVML_SUCCESS;
    }
  }
  return NVML_ERROR_NOT_FOUND;
}

int nvmlDeviceGetHandleByPciBusId_v2(const char *pci_bdf, void **device) {
  log_api_call("PCI lookup");
  if (pci_bdf == NULL || device == NULL)
    return NVML_ERROR_INVALID_ARGUMENT;
  if (strcmp(fixture_case(), "relocated") == 0 &&
      strcmp(pci_bdf, devices[0].pci_bdf) == 0) {
    *device = &devices[1];
    return NVML_SUCCESS;
  }
  for (size_t i = 0; i < sizeof(devices) / sizeof(devices[0]); i++) {
    if (strcmp(devices[i].pci_bdf, pci_bdf) == 0) {
      *device = &devices[i];
      return NVML_SUCCESS;
    }
  }
  return NVML_ERROR_NOT_FOUND;
}

int nvmlDeviceGetUUID(void *device, char *uuid, unsigned int length) {
  log_api_call("UUID verification");
  if (device == NULL || uuid == NULL)
    return NVML_ERROR_INVALID_ARGUMENT;
  FakeDevice *selected = device;
  const char *value = strcmp(fixture_case(), "identity-mismatch") == 0
                          ? devices[0].uuid
                          : selected->uuid;
  if (strlen(value) + 1 > length)
    return NVML_ERROR_INVALID_ARGUMENT;
  memcpy(uuid, value, strlen(value) + 1);
  return NVML_SUCCESS;
}

int nvmlDeviceGetUtilizationRates(void *device, NvmlUtilization *utilization) {
  log_api_call("utilization");
  if (device == NULL || utilization == NULL)
    return NVML_ERROR_INVALID_ARGUMENT;
  const char *call_log_path = getenv("SYSTEM_STATS_NVML_CALL_LOG");
  if (call_log_path != NULL) {
    FILE *stream = fopen(call_log_path, "ae");
    if (stream != NULL) {
      fputs("utilization call\n", stream);
      fclose(stream);
    }
  }
  const char *test_case = fixture_case();
  if (strcmp(test_case, "nvml-timeout") == 0)
    return NVML_ERROR_TIMEOUT;
  if (strcmp(test_case, "hung-call") == 0 ||
      strcmp(test_case, "hung-reopen") == 0) {
    struct timespec duration = {.tv_nsec = 600000000};
    nanosleep(&duration, NULL);
  }
  if (strcmp(test_case, "mig-unavailable") == 0)
    return NVML_ERROR_NOT_SUPPORTED;
  if (strcmp(test_case, "suspended") == 0)
    return NVML_ERROR_NOT_READY;
  FakeDevice *selected = device;
  utilization->gpu =
      strcmp(test_case, "invalid-value") == 0 ? 101 : selected->percent;
  utilization->memory = 88;
  return NVML_SUCCESS;
}
