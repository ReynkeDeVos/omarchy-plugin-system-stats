#define _XOPEN_SOURCE 700

#include "gpu-inventory.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int64_t monotonic_ms(struct timespec instant) {
  return (int64_t)instant.tv_sec * 1000 + instant.tv_nsec / 1000000;
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

static struct timespec timespec_from_ms(int64_t milliseconds) {
  return (struct timespec){
      .tv_sec = milliseconds / 1000,
      .tv_nsec = (milliseconds % 1000) * 1000000L,
  };
}

static int compare_timespec(struct timespec left, struct timespec right) {
  if (left.tv_sec != right.tv_sec)
    return left.tv_sec < right.tv_sec ? -1 : 1;
  if (left.tv_nsec == right.tv_nsec)
    return 0;
  return left.tv_nsec < right.tv_nsec ? -1 : 1;
}

static int milliseconds_until(struct timespec deadline, struct timespec now) {
  int64_t nanoseconds = (int64_t)(deadline.tv_sec - now.tv_sec) * 1000000000LL +
                        deadline.tv_nsec - now.tv_nsec;
  if (nanoseconds <= 0)
    return 0;
  int64_t milliseconds = (nanoseconds + 999999LL) / 1000000LL;
  return milliseconds > INT_MAX ? INT_MAX : (int)milliseconds;
}

static bool pci_bdf_valid(const char *value) {
  if (value == NULL || strlen(value) != 12)
    return false;
  for (size_t i = 0; i < 12; i++) {
    if (i == 4 || i == 7) {
      if (value[i] != ':')
        return false;
    } else if (i == 10) {
      if (value[i] != '.')
        return false;
    } else if (!isdigit((unsigned char)value[i]) &&
               (value[i] < 'a' || value[i] > 'f')) {
      return false;
    }
  }
  return true;
}

bool gpu_stable_id_valid(const char *stable_id) {
  if (stable_id == NULL)
    return false;
  if (strncmp(stable_id, "pci:", 4) == 0)
    return pci_bdf_valid(stable_id + 4);
  if (strncmp(stable_id, "nvidia:GPU-", 11) != 0)
    return false;
  size_t length = strlen(stable_id);
  if (length != 47)
    return false;
  for (size_t i = 11; i < length; i++) {
    bool hyphen = i == 19 || i == 24 || i == 29 || i == 34;
    if ((hyphen && stable_id[i] != '-') ||
        (!hyphen && !isxdigit((unsigned char)stable_id[i])))
      return false;
  }
  return true;
}

static const char *vendor_name(GpuVendor vendor) {
  if (vendor == GPU_VENDOR_INTEL)
    return "intel";
  if (vendor == GPU_VENDOR_AMD)
    return "amd";
  return "nvidia";
}

static bool parse_vendor(const char *value, GpuVendor *vendor) {
  if (strcmp(value, "intel") == 0) {
    *vendor = GPU_VENDOR_INTEL;
    return true;
  }
  if (strcmp(value, "amd") == 0) {
    *vendor = GPU_VENDOR_AMD;
    return true;
  }
  if (strcmp(value, "nvidia") == 0) {
    *vendor = GPU_VENDOR_NVIDIA;
    return true;
  }
  return false;
}

static const char *display_relation_name(GpuDisplayRelation relation) {
  if (relation == GPU_DISPLAY_YES)
    return "yes";
  if (relation == GPU_DISPLAY_NO)
    return "no";
  return "unknown";
}

static bool parse_display_relation(const char *value,
                                   GpuDisplayRelation *relation) {
  if (strcmp(value, "yes") == 0) {
    *relation = GPU_DISPLAY_YES;
    return true;
  }
  if (strcmp(value, "no") == 0) {
    *relation = GPU_DISPLAY_NO;
    return true;
  }
  if (strcmp(value, "unknown") == 0) {
    *relation = GPU_DISPLAY_UNKNOWN;
    return true;
  }
  return false;
}

static void trim_line(char *value) {
  size_t length = strlen(value);
  while (length > 0 && (value[length - 1] == '\n' || value[length - 1] == '\r'))
    value[--length] = '\0';
}

static bool copy_field(char *destination, size_t capacity, const char *source) {
  size_t length = strlen(source);
  if (length == 0 || length >= capacity)
    return false;
  memcpy(destination, source, length + 1);
  return true;
}

static bool inventory_contains(const GpuInventory *inventory,
                               const char *stable_id) {
  for (size_t i = 0; i < inventory->device_count; i++) {
    if (strcmp(inventory->devices[i].stable_id, stable_id) == 0)
      return true;
  }
  return false;
}

static bool add_device(GpuInventory *inventory, const GpuDevice *device) {
  if (inventory->device_count >= GPU_MAX_DEVICES ||
      inventory_contains(inventory, device->stable_id))
    return false;
  inventory->devices[inventory->device_count++] = *device;
  return true;
}

static int compare_devices(const void *left, const void *right) {
  const GpuDevice *left_device = left;
  const GpuDevice *right_device = right;
  return strcmp(left_device->stable_id, right_device->stable_id);
}

static void discover_fixture(const char *path, GpuInventory *inventory) {
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return;

  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, stream) >= 0) {
    trim_line(line);
    if (line[0] == '\0')
      continue;

    char *fields[6] = {0};
    char *save = NULL;
    size_t field_count = 0;
    for (char *field = strtok_r(line, "\t", &save);
         field != NULL && field_count < 6;
         field = strtok_r(NULL, "\t", &save)) {
      fields[field_count++] = field;
    }
    if (field_count != 6)
      continue;

    GpuDevice device = {0};
    if (!gpu_stable_id_valid(fields[0]) ||
        !copy_field(device.stable_id, sizeof(device.stable_id), fields[0]) ||
        !copy_field(device.label, sizeof(device.label), fields[1]) ||
        !parse_vendor(fields[2], &device.vendor) || !pci_bdf_valid(fields[3]) ||
        !copy_field(device.pci_bdf, sizeof(device.pci_bdf), fields[3]) ||
        !parse_display_relation(fields[4], &device.display_relation) ||
        (strcmp(fields[5], "0") != 0 && strcmp(fields[5], "1") != 0)) {
      continue;
    }
    device.selectable = strcmp(fields[5], "1") == 0;
    add_device(inventory, &device);
  }
  free(line);
  fclose(stream);
}

static bool read_text_file(const char *path, char *buffer, size_t capacity) {
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return false;
  bool read = fgets(buffer, (int)capacity, stream) != NULL;
  fclose(stream);
  if (!read)
    return false;
  trim_line(buffer);
  return true;
}

static bool read_hex_id(const char *path, unsigned int *value) {
  char text[32] = {0};
  if (!read_text_file(path, text, sizeof(text)))
    return false;
  char *end = NULL;
  errno = 0;
  unsigned long parsed = strtoul(text, &end, 0);
  if (errno != 0 || end == text || *end != '\0' || parsed > UINT_MAX)
    return false;
  *value = (unsigned int)parsed;
  return true;
}

static bool card_name(const char *name) {
  if (strncmp(name, "card", 4) != 0 || !isdigit((unsigned char)name[4]))
    return false;
  for (size_t i = 4; name[i] != '\0'; i++) {
    if (!isdigit((unsigned char)name[i]))
      return false;
  }
  return true;
}

static GpuDisplayRelation discover_display_relation(const char *drm_root,
                                                    const char *card) {
  DIR *directory = opendir(drm_root);
  if (directory == NULL)
    return GPU_DISPLAY_UNKNOWN;
  size_t prefix_length = strlen(card);
  bool disconnected = false;
  bool unknown = false;
  bool connected = false;
  struct dirent *entry;
  while ((entry = readdir(directory)) != NULL) {
    if (strncmp(entry->d_name, card, prefix_length) != 0 ||
        entry->d_name[prefix_length] != '-')
      continue;
    char status_path[PATH_MAX];
    if (snprintf(status_path, sizeof(status_path), "%s/%s/status", drm_root,
                 entry->d_name) >= (int)sizeof(status_path))
      continue;
    char status[32] = {0};
    if (!read_text_file(status_path, status, sizeof(status)))
      continue;
    if (strcmp(status, "connected") == 0) {
      connected = true;
      break;
    } else if (strcmp(status, "disconnected") == 0)
      disconnected = true;
    else
      unknown = true;
  }
  closedir(directory);
  if (connected)
    return GPU_DISPLAY_YES;
  if (unknown)
    return GPU_DISPLAY_UNKNOWN;
  return disconnected ? GPU_DISPLAY_NO : GPU_DISPLAY_UNKNOWN;
}

static bool nvidia_information(const char *nvidia_root, const char *pci_bdf,
                               char *model, size_t model_capacity, char *uuid,
                               size_t uuid_capacity) {
  char path[PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/%s/information", nvidia_root, pci_bdf) >=
      (int)sizeof(path))
    return false;
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return false;

  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, stream) >= 0) {
    char *separator = strchr(line, ':');
    if (separator == NULL)
      continue;
    *separator = '\0';
    char *value = separator + 1;
    while (isspace((unsigned char)*value))
      value++;
    trim_line(value);
    if (strcmp(line, "Model") == 0 && strlen(value) < model_capacity)
      strcpy(model, value);
    if (strcmp(line, "GPU UUID") == 0 && strlen(value) < uuid_capacity)
      strcpy(uuid, value);
  }
  free(line);
  fclose(stream);
  return uuid[0] != '\0';
}

static bool udev_model(const char *udev_data_root, const char *pci_bdf,
                       char *model, size_t model_capacity) {
  char path[PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/+pci:%s", udev_data_root, pci_bdf) >=
      (int)sizeof(path))
    return false;
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return false;

  static const char prefix[] = "E:ID_MODEL_FROM_DATABASE=";
  char *line = NULL;
  size_t capacity = 0;
  bool found = false;
  while (getline(&line, &capacity, stream) >= 0) {
    if (strncmp(line, prefix, sizeof(prefix) - 1) != 0)
      continue;
    char *value = line + sizeof(prefix) - 1;
    trim_line(value);
    found = copy_field(model, model_capacity, value);
    break;
  }
  free(line);
  fclose(stream);
  return found;
}

static void discover_linux(const GpuInventoryOptions *options,
                           GpuInventory *inventory) {
  DIR *directory = opendir(options->drm_root);
  if (directory == NULL)
    return;

  struct dirent *entry;
  while ((entry = readdir(directory)) != NULL) {
    if (!card_name(entry->d_name))
      continue;

    char device_link[PATH_MAX];
    if (snprintf(device_link, sizeof(device_link), "%s/%s/device",
                 options->drm_root, entry->d_name) >= (int)sizeof(device_link))
      continue;
    char resolved[PATH_MAX];
    if (realpath(device_link, resolved) == NULL)
      continue;
    const char *basename = strrchr(resolved, '/');
    basename = basename == NULL ? resolved : basename + 1;
    if (!pci_bdf_valid(basename))
      continue;

    char vendor_path[PATH_MAX];
    char device_path[PATH_MAX];
    if (snprintf(vendor_path, sizeof(vendor_path), "%s/vendor", resolved) >=
            (int)sizeof(vendor_path) ||
        snprintf(device_path, sizeof(device_path), "%s/device", resolved) >=
            (int)sizeof(device_path))
      continue;
    unsigned int vendor_id = 0;
    unsigned int device_id = 0;
    if (!read_hex_id(vendor_path, &vendor_id) ||
        !read_hex_id(device_path, &device_id))
      continue;

    GpuDevice device = {0};
    const char *vendor_label = NULL;
    if (vendor_id == 0x8086) {
      device.vendor = GPU_VENDOR_INTEL;
      vendor_label = "Intel";
    } else if (vendor_id == 0x1002) {
      device.vendor = GPU_VENDOR_AMD;
      vendor_label = "AMD Radeon";
    } else if (vendor_id == 0x10de) {
      device.vendor = GPU_VENDOR_NVIDIA;
      vendor_label = "NVIDIA";
    } else {
      continue;
    }

    memcpy(device.pci_bdf, basename, strlen(basename) + 1);
    memcpy(device.presence_path, resolved, strlen(resolved) + 1);
    device.display_relation =
        discover_display_relation(options->drm_root, entry->d_name);
    device.selectable = true;

    char model[GPU_LABEL_SIZE] = {0};
    char uuid[GPU_STABLE_ID_SIZE] = {0};
    bool has_nvidia_uuid =
        device.vendor == GPU_VENDOR_NVIDIA &&
        nvidia_information(options->nvidia_root, device.pci_bdf, model,
                           sizeof(model), uuid, sizeof(uuid));
    if (model[0] == '\0')
      udev_model(options->udev_data_root, device.pci_bdf, model, sizeof(model));
    if (has_nvidia_uuid) {
      snprintf(device.stable_id, sizeof(device.stable_id), "nvidia:%s", uuid);
      if (!gpu_stable_id_valid(device.stable_id))
        device.stable_id[0] = '\0';
    }
    if (device.stable_id[0] == '\0') {
      snprintf(device.stable_id, sizeof(device.stable_id), "pci:%s",
               device.pci_bdf);
    }
    if (!gpu_stable_id_valid(device.stable_id))
      continue;
    if (model[0] != '\0') {
      snprintf(device.label, sizeof(device.label), "%s", model);
    } else {
      snprintf(device.label, sizeof(device.label), "%s GPU [%04x:%04x]",
               vendor_label, vendor_id, device_id);
    }
    add_device(inventory, &device);
  }
  closedir(directory);
}

static void discover(const GpuInventoryOptions *options,
                     GpuInventory *inventory) {
  uint64_t revision = inventory->revision + 1;
  *inventory = (GpuInventory){
      .revision = revision,
  };
  if (options->fixture_inventory_path != NULL)
    discover_fixture(options->fixture_inventory_path, inventory);
  else
    discover_linux(options, inventory);
  qsort(inventory->devices, inventory->device_count,
        sizeof(inventory->devices[0]), compare_devices);
}

static const GpuDevice *find_device(const GpuInventory *inventory,
                                    const char *stable_id) {
  for (size_t i = 0; i < inventory->device_count; i++) {
    if (inventory->devices[i].selectable &&
        strcmp(inventory->devices[i].stable_id, stable_id) == 0)
      return &inventory->devices[i];
  }
  return NULL;
}

static void copy_stable_id(char destination[GPU_STABLE_ID_SIZE],
                           const char *source) {
  snprintf(destination, GPU_STABLE_ID_SIZE, "%s", source == NULL ? "" : source);
}

static void schedule_fixed_retry(GpuInventoryManager *manager,
                                 GpuDiscoveryTrigger trigger,
                                 struct timespec now) {
  static const long delays_seconds[] = {30, 300, 1800};
  if (trigger == GPU_DISCOVERY_RETRY)
    manager->fixed_retry_stage++;
  else
    manager->fixed_retry_stage = 0;
  if (manager->fixed_retry_stage >= 3) {
    manager->retry_scheduled = false;
    return;
  }
  long delay_ms =
      delays_seconds[manager->fixed_retry_stage] * manager->options.second_ms;
  manager->retry_at = add_ms(now, delay_ms);
  manager->retry_scheduled = true;
}

static void choose_selection(GpuInventoryManager *manager,
                             GpuDiscoveryTrigger trigger, struct timespec now) {
  if (manager->mode == GPU_SELECTION_FIXED) {
    const GpuDevice *fixed =
        find_device(&manager->inventory, manager->fixed_stable_id);
    copy_stable_id(manager->selected_stable_id,
                   fixed == NULL ? "" : fixed->stable_id);
    if (fixed != NULL) {
      manager->status = GPU_SELECTION_SELECTED;
      manager->retry_scheduled = false;
      manager->fixed_retry_stage = 0;
    } else {
      manager->status = GPU_SELECTION_MISSING;
      schedule_fixed_retry(manager, trigger, now);
    }
    return;
  }

  manager->retry_scheduled = false;
  if (manager->selected_stable_id[0] != '\0' &&
      find_device(&manager->inventory, manager->selected_stable_id) != NULL) {
    manager->status = GPU_SELECTION_SELECTED;
    return;
  }
  manager->selected_stable_id[0] = '\0';

  const GpuDevice *only = NULL;
  const GpuDevice *display = NULL;
  size_t selectable_count = 0;
  size_t display_count = 0;
  for (size_t i = 0; i < manager->inventory.device_count; i++) {
    const GpuDevice *device = &manager->inventory.devices[i];
    if (!device->selectable)
      continue;
    selectable_count++;
    only = device;
    if (device->display_relation == GPU_DISPLAY_YES) {
      display_count++;
      display = device;
    }
  }

  if (selectable_count == 1) {
    manager->status = GPU_SELECTION_SELECTED;
    copy_stable_id(manager->selected_stable_id, only->stable_id);
  } else if (selectable_count > 1 && display_count == 1) {
    manager->status = GPU_SELECTION_SELECTED;
    copy_stable_id(manager->selected_stable_id, display->stable_id);
  } else if (selectable_count > 1) {
    manager->status = GPU_SELECTION_REQUIRED;
  } else {
    manager->status = GPU_SELECTION_NONE;
  }
}

static void update_failure(GpuInventoryManager *manager, struct timespec now) {
  const char *code = "deviceMissing";
  const char *stable_id = "";
  if (manager->status == GPU_SELECTION_REQUIRED) {
    code = "selectionRequired";
  } else if (manager->status == GPU_SELECTION_SELECTED) {
    code = "noTrueEnginePath";
    stable_id = manager->selected_stable_id;
  } else if (manager->mode == GPU_SELECTION_FIXED) {
    stable_id = manager->fixed_stable_id;
  }

  if (manager->failure_code == NULL ||
      strcmp(manager->failure_code, code) != 0 ||
      strcmp(manager->failure_stable_id, stable_id) != 0) {
    manager->failure_code = code;
    copy_stable_id(manager->failure_stable_id, stable_id);
    manager->failure_since_ms = monotonic_ms(now);
  }
}

void gpu_inventory_manager_init(GpuInventoryManager *manager,
                                const GpuInventoryOptions *options) {
  *manager = (GpuInventoryManager){
      .options = *options,
      .mode = GPU_SELECTION_AUTO,
      .status = GPU_SELECTION_NONE,
  };
}

void gpu_inventory_reconcile(GpuInventoryManager *manager,
                             GpuDiscoveryTrigger trigger, struct timespec now) {
  discover(&manager->options, &manager->inventory);
  manager->inventory.discovered_at_ms = monotonic_ms(now);
  choose_selection(manager, trigger, now);
  update_failure(manager, now);
}

bool gpu_inventory_set_selection(GpuInventoryManager *manager,
                                 GpuSelectionMode mode, const char *stable_id,
                                 struct timespec now) {
  const char *fixed = mode == GPU_SELECTION_FIXED ? stable_id : "";
  if (manager->mode == mode && strcmp(manager->fixed_stable_id, fixed) == 0)
    return false;
  manager->mode = mode;
  copy_stable_id(manager->fixed_stable_id, fixed);
  manager->selected_stable_id[0] = '\0';
  choose_selection(manager, GPU_DISCOVERY_CONFIGURATION, now);
  update_failure(manager, now);
  return true;
}

void gpu_inventory_restore_session(
    GpuInventoryManager *manager, GpuSelectionMode mode,
    const char *fixed_stable_id, GpuSelectionStatus auto_status,
    const char *auto_stable_id, int fixed_retry_stage,
    int64_t fixed_retry_at_ms, struct timespec now) {
  manager->mode = mode;
  copy_stable_id(manager->fixed_stable_id,
                 mode == GPU_SELECTION_FIXED ? fixed_stable_id : "");
  manager->selected_stable_id[0] = '\0';
  manager->retry_scheduled = false;
  manager->fixed_retry_stage = 0;

  if (mode == GPU_SELECTION_AUTO) {
    if (auto_status == GPU_SELECTION_SELECTED && auto_stable_id != NULL &&
        auto_stable_id[0] != '\0' &&
        find_device(&manager->inventory, auto_stable_id) != NULL) {
      copy_stable_id(manager->selected_stable_id, auto_stable_id);
      manager->status = GPU_SELECTION_SELECTED;
    } else if (auto_status == GPU_SELECTION_NONE ||
               auto_status == GPU_SELECTION_REQUIRED) {
      manager->status = auto_status;
    } else {
      choose_selection(manager, GPU_DISCOVERY_DISAPPEARANCE, now);
    }
    update_failure(manager, now);
    return;
  }

  const GpuDevice *fixed =
      find_device(&manager->inventory, manager->fixed_stable_id);
  if (fixed != NULL) {
    copy_stable_id(manager->selected_stable_id, fixed->stable_id);
    manager->status = GPU_SELECTION_SELECTED;
  } else {
    manager->status = GPU_SELECTION_MISSING;
    if (fixed_retry_stage >= 3) {
      manager->fixed_retry_stage = 3;
    } else if (fixed_retry_at_ms >= 0) {
      manager->fixed_retry_stage = fixed_retry_stage;
      manager->retry_at = timespec_from_ms(fixed_retry_at_ms);
      manager->retry_scheduled = true;
    } else {
      schedule_fixed_retry(manager, GPU_DISCOVERY_CONFIGURATION, now);
    }
  }
  update_failure(manager, now);
}

static bool fixture_presence(const char *path, const char *stable_id) {
  FILE *stream = fopen(path, "re");
  if (stream == NULL)
    return false;
  char *line = NULL;
  size_t capacity = 0;
  bool present = false;
  while (getline(&line, &capacity, stream) >= 0) {
    trim_line(line);
    if (strcmp(line, stable_id) == 0) {
      present = true;
      break;
    }
  }
  free(line);
  fclose(stream);
  return present;
}

bool gpu_inventory_selected_present(const GpuInventoryManager *manager) {
  if (manager->status != GPU_SELECTION_SELECTED)
    return false;
  if (manager->options.fixture_presence_path != NULL) {
    return fixture_presence(manager->options.fixture_presence_path,
                            manager->selected_stable_id);
  }
  const GpuDevice *selected =
      find_device(&manager->inventory, manager->selected_stable_id);
  return selected != NULL && selected->presence_path[0] != '\0' &&
         access(selected->presence_path, F_OK) == 0;
}

const GpuDevice *
gpu_inventory_selected_device(const GpuInventoryManager *manager) {
  if (manager->status != GPU_SELECTION_SELECTED)
    return NULL;
  return find_device(&manager->inventory, manager->selected_stable_id);
}

bool gpu_inventory_retry_due(const GpuInventoryManager *manager,
                             struct timespec now) {
  return manager->retry_scheduled &&
         compare_timespec(now, manager->retry_at) >= 0;
}

int gpu_inventory_poll_timeout(const GpuInventoryManager *manager,
                               struct timespec now, int fallback_ms) {
  if (!manager->retry_scheduled)
    return fallback_ms;
  int retry_ms = milliseconds_until(manager->retry_at, now);
  return retry_ms < fallback_ms ? retry_ms : fallback_ms;
}

static void emit_json_string(const char *value) {
  putchar('"');
  for (const unsigned char *cursor = (const unsigned char *)value;
       *cursor != '\0'; cursor++) {
    if (*cursor == '"' || *cursor == '\\') {
      putchar('\\');
      putchar(*cursor);
    } else if (*cursor == '\n') {
      fputs("\\n", stdout);
    } else if (*cursor == '\r') {
      fputs("\\r", stdout);
    } else if (*cursor == '\t') {
      fputs("\\t", stdout);
    } else if (*cursor >= 0x20) {
      putchar(*cursor);
    }
  }
  putchar('"');
}

void gpu_inventory_emit(const GpuInventoryManager *manager,
                        uint64_t generation) {
  printf(
      "{\"type\":\"gpuInventory\",\"schemaVersion\":1,\"generation\":%" PRIu64
      ",\"revision\":%" PRIu64 ",\"discoveredAtMs\":%" PRId64 ",\"devices\":[",
      generation, manager->inventory.revision,
      manager->inventory.discovered_at_ms);
  for (size_t i = 0; i < manager->inventory.device_count; i++) {
    const GpuDevice *device = &manager->inventory.devices[i];
    if (i > 0)
      putchar(',');
    fputs("{\"stableId\":", stdout);
    emit_json_string(device->stable_id);
    fputs(",\"label\":", stdout);
    emit_json_string(device->label);
    fputs(",\"vendor\":", stdout);
    emit_json_string(vendor_name(device->vendor));
    fputs(",\"pciBdf\":", stdout);
    emit_json_string(device->pci_bdf);
    fputs(",\"displayRelation\":", stdout);
    emit_json_string(display_relation_name(device->display_relation));
    printf(",\"selectable\":%s}", device->selectable ? "true" : "false");
  }
  fputs("],\"gpuState\":", stdout);
  gpu_inventory_emit_state(manager);
  fputs("}\n", stdout);
  fflush(stdout);
}

const char *gpu_selection_mode_name(GpuSelectionMode mode) {
  return mode == GPU_SELECTION_FIXED ? "fixed" : "auto";
}

static const char *selection_status_name(GpuSelectionStatus status) {
  if (status == GPU_SELECTION_SELECTED)
    return "selected";
  if (status == GPU_SELECTION_REQUIRED)
    return "required";
  if (status == GPU_SELECTION_MISSING)
    return "missing";
  return "none";
}

void gpu_inventory_emit_state(const GpuInventoryManager *manager) {
  fputs("{\"selection\":{\"mode\":", stdout);
  emit_json_string(gpu_selection_mode_name(manager->mode));
  fputs(",\"status\":", stdout);
  emit_json_string(selection_status_name(manager->status));
  const char *selection_id = manager->mode == GPU_SELECTION_FIXED
                                 ? manager->fixed_stable_id
                                 : manager->selected_stable_id;
  if (selection_id[0] != '\0') {
    fputs(",\"stableId\":", stdout);
    emit_json_string(selection_id);
  }
  printf("},\"fixedRetryStage\":%d,\"fixedRetryAt\":%" PRId64 "}",
         manager->fixed_retry_stage,
         manager->retry_scheduled ? monotonic_ms(manager->retry_at) : -1);
}

void gpu_inventory_emit_snapshot_fields(GpuInventoryManager *manager,
                                        struct timespec now) {
  update_failure(manager, now);
  const char *path_id = "gpu-inventory";
  const char *diagnostic = "no selectable GPU was detected";
  if (manager->status == GPU_SELECTION_SELECTED) {
    path_id = "gpu-measurement";
    diagnostic = "no vendor measurement path is available";
  } else if (manager->status == GPU_SELECTION_REQUIRED) {
    path_id = "gpu-selection";
    diagnostic = "multiple GPUs require an explicit selection";
  } else if (manager->mode == GPU_SELECTION_FIXED) {
    diagnostic = "the fixed GPU is not present";
  }
  fputs(",\"gpu\":{\"status\":\"unavailable\",\"error\":{\"code\":", stdout);
  emit_json_string(manager->failure_code);
  fputs(",\"scope\":\"gpu\",\"retryability\":", stdout);
  emit_json_string(manager->status == GPU_SELECTION_MISSING ? "retryable"
                                                            : "nonRetryable");
  if (manager->failure_stable_id[0] != '\0') {
    fputs(",\"stableId\":", stdout);
    emit_json_string(manager->failure_stable_id);
  }
  fputs(",\"pathId\":", stdout);
  emit_json_string(path_id);
  fputs(",\"diagnostic\":", stdout);
  emit_json_string(diagnostic);
  fputs("},\"since\":", stdout);
  printf("%" PRId64, manager->failure_since_ms);
  if (manager->status == GPU_SELECTION_MISSING && manager->retry_scheduled)
    printf(",\"retryAt\":%" PRId64, monotonic_ms(manager->retry_at));
  putchar('}');
  gpu_inventory_emit_snapshot_state_fields(manager);
}

void gpu_inventory_emit_snapshot_state_fields(
    const GpuInventoryManager *manager) {
  fputs(",\"selection\":{\"mode\":", stdout);
  emit_json_string(gpu_selection_mode_name(manager->mode));
  fputs(",\"status\":", stdout);
  emit_json_string(selection_status_name(manager->status));
  const char *selection_id = manager->mode == GPU_SELECTION_FIXED
                                 ? manager->fixed_stable_id
                                 : manager->selected_stable_id;
  if (selection_id[0] != '\0') {
    fputs(",\"stableId\":", stdout);
    emit_json_string(selection_id);
  }
  fputs("},\"gpuState\":", stdout);
  gpu_inventory_emit_state(manager);
}
