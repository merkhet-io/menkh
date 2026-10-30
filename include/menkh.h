#ifndef MENKH_H
#define MENKH_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* v1 synchronous geometric API. All distances mm; right-handed workpiece frame.
 * Calls on the same handle must be serialized. Different handles are independent.
 * The library owns its handle/grid allocations; destroy them with this library.
 * Input/output buffers belong to the caller and are never retained.
 * On cut failure material remains unchanged; scratch capacity may have grown.
 * No renderer, file I/O, callbacks, machine kinematics or physical time model.
 * Cancellation/progress: the host schedules individual atomic operation calls.
 */
typedef struct menkh_handle menkh_handle;
typedef enum menkh_status {
    MENKH_OK=0, MENKH_INVALID_ARGUMENT=1, MENKH_OUT_OF_MEMORY=2,
    MENKH_UNSUPPORTED=3, MENKH_INVALID_STATE=4, MENKH_BUFFER_TOO_SMALL=5,
    MENKH_RESOURCE_LIMIT=6
} menkh_status;
typedef struct menkh_box { double origin[3], size[3], voxel_mm; } menkh_box;
/* kind: 0 finite flat cylinder, 1 complete ball end mill. Others unsupported. */
typedef struct menkh_tool { uint32_t kind; double radius_mm, length_mm; } menkh_tool;
typedef struct menkh_pose { double position[3], axis[3]; } menkh_pose;
/* XYZAC position is wheel CENTER, unlike lower-face line poses. Degrees unwrapped. */
typedef struct menkh_xyzac { double position[3], a_deg, c_deg; } menkh_xyzac;
typedef struct menkh_cut_report {
    uint64_t removed_voxels, remaining_voxels;
    double removed_volume_mm3, motion_over_removal_bound_mm;
    uint64_t sweep_pieces;
} menkh_cut_report;
uint32_t menkh_abi_version(void);
const char *menkh_status_message(menkh_status status);
menkh_status menkh_create_box_v1(const menkh_box *, menkh_handle **out);
void menkh_destroy_v1(menkh_handle *);
menkh_status menkh_cut_line_v1(menkh_handle *, const menkh_tool *, const menkh_pose *, const menkh_pose *, double tolerance_mm, menkh_cut_report *);
menkh_status menkh_cut_xyzac_v1(menkh_handle *, const menkh_tool *, const menkh_xyzac *, const menkh_xyzac *, double tolerance_mm, menkh_cut_report *);
menkh_status menkh_query_v1(const menkh_handle *, const double position[3], uint32_t *occupied);
menkh_status menkh_count_v1(const menkh_handle *, uint64_t *occupied);
/* Write existing MENKHST1 format. written receives required bytes, also when too small.
 * Pass NULL,0 to query size. Insufficient buffers are not written. */
menkh_status menkh_state_write_v1(const menkh_handle *, void *buffer, size_t capacity, size_t *written);
menkh_status menkh_state_read_v1(const void *buffer, size_t bytes, menkh_handle **out);
#ifdef __cplusplus
}
#endif
#endif
