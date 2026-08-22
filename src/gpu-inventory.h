#ifndef SYSTEM_STATS_GPU_INVENTORY_H
#define SYSTEM_STATS_GPU_INVENTORY_H

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

enum {
  GPU_MAX_DEVICES = 32,
  GPU_STABLE_ID_SIZE = 128,
  GPU_LABEL_SIZE = 160,
  GPU_PCI_BDF_SIZE = 16,
  GPU_PRESENCE_PATH_SIZE = 4096
};

typedef enum { GPU_VENDOR_INTEL, GPU_VENDOR_AMD, GPU_VENDOR_NVIDIA } GpuVendor;

typedef enum {
  GPU_DISPLAY_NO,
  GPU_DISPLAY_YES,
  GPU_DISPLAY_UNKNOWN
} GpuDisplayRelation;

typedef struct {
  char stable_id[GPU_STABLE_ID_SIZE];
  char label[GPU_LABEL_SIZE];
  GpuVendor vendor;
  char pci_bdf[GPU_PCI_BDF_SIZE];
  GpuDisplayRelation display_relation;
  bool selectable;
  char presence_path[GPU_PRESENCE_PATH_SIZE];
} GpuDevice;

typedef struct {
  uint64_t revision;
  int64_t discovered_at_ms;
  size_t device_count;
  GpuDevice devices[GPU_MAX_DEVICES];
} GpuInventory;

typedef enum { GPU_SELECTION_AUTO, GPU_SELECTION_FIXED } GpuSelectionMode;

typedef enum {
  GPU_SELECTION_NONE,
  GPU_SELECTION_SELECTED,
  GPU_SELECTION_REQUIRED,
  GPU_SELECTION_MISSING
} GpuSelectionStatus;

typedef enum {
  GPU_DISCOVERY_SESSION_START,
  GPU_DISCOVERY_CONFIGURATION,
  GPU_DISCOVERY_PICKER,
  GPU_DISCOVERY_DISAPPEARANCE,
  GPU_DISCOVERY_RETRY
} GpuDiscoveryTrigger;

typedef struct {
  const char *fixture_inventory_path;
  const char *fixture_presence_path;
  const char *drm_root;
  const char *nvidia_root;
  const char *udev_data_root;
  long second_ms;
} GpuInventoryOptions;

typedef struct {
  GpuInventoryOptions options;
  GpuInventory inventory;
  GpuSelectionMode mode;
  GpuSelectionStatus status;
  char fixed_stable_id[GPU_STABLE_ID_SIZE];
  char selected_stable_id[GPU_STABLE_ID_SIZE];
  int fixed_retry_stage;
  bool retry_scheduled;
  struct timespec retry_at;
  const char *failure_code;
  char failure_stable_id[GPU_STABLE_ID_SIZE];
  int64_t failure_since_ms;
} GpuInventoryManager;

bool gpu_stable_id_valid(const char *stable_id);
void gpu_inventory_manager_init(GpuInventoryManager *manager,
                                const GpuInventoryOptions *options);
void gpu_inventory_reconcile(GpuInventoryManager *manager,
                             GpuDiscoveryTrigger trigger, struct timespec now);
bool gpu_inventory_set_selection(GpuInventoryManager *manager,
                                 GpuSelectionMode mode, const char *stable_id,
                                 struct timespec now);
void gpu_inventory_restore_session(
    GpuInventoryManager *manager, GpuSelectionMode mode,
    const char *fixed_stable_id, GpuSelectionStatus auto_status,
    const char *auto_stable_id, int fixed_retry_stage,
    int64_t fixed_retry_at_ms, struct timespec now);
bool gpu_inventory_selected_present(const GpuInventoryManager *manager);
bool gpu_inventory_retry_due(const GpuInventoryManager *manager,
                             struct timespec now);
int gpu_inventory_poll_timeout(const GpuInventoryManager *manager,
                               struct timespec now, int fallback_ms);
void gpu_inventory_emit(const GpuInventoryManager *manager,
                        uint64_t generation);
void gpu_inventory_emit_state(const GpuInventoryManager *manager);
void gpu_inventory_emit_snapshot_fields(GpuInventoryManager *manager,
                                        struct timespec now);
const char *gpu_selection_mode_name(GpuSelectionMode mode);

#endif
