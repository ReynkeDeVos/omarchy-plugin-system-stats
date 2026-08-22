#ifndef SYSTEM_STATS_GPU_MEASUREMENT_H
#define SYSTEM_STATS_GPU_MEASUREMENT_H

#include "gpu-inventory.h"

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

typedef struct {
  const char *proc_root;
  const char *fixture_proc_frames_root;
  const char *event_source_root;
  const char *pci_devices_root;
  bool fixture_system;
} GpuMeasurementOptions;

typedef struct GpuMeasurement GpuMeasurement;

typedef struct {
  bool handled;
  bool available;
  int percent;
  int64_t sampled_at_ms;
  int64_t window_ms;
  const char *path;
  const char *evidence;
  const char *error_code;
  const char *retryability;
  const char *diagnostic;
  int64_t since_ms;
  char stable_id[GPU_STABLE_ID_SIZE];
  char pci_bdf[GPU_PCI_BDF_SIZE];
} GpuObservation;

GpuMeasurement *gpu_measurement_create(const GpuMeasurementOptions *options);
void gpu_measurement_destroy(GpuMeasurement *measurement);
void gpu_measurement_reconcile(GpuMeasurement *measurement,
                               const GpuDevice *selected, struct timespec now);
void gpu_measurement_reset(GpuMeasurement *measurement,
                           const GpuDevice *selected, struct timespec now);
GpuObservation gpu_measurement_observe(GpuMeasurement *measurement,
                                       const GpuDevice *selected,
                                       struct timespec now);
void gpu_measurement_emit_snapshot_fields(const GpuObservation *observation,
                                          GpuInventoryManager *inventory,
                                          struct timespec now);

#endif
