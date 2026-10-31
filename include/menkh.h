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
 * Material-handle calls have no renderer or file I/O. Whole-job entry points
 * below have explicit output/callback contracts. No machine kinematics or physics.
 */
typedef struct menkh_handle menkh_handle;
typedef enum menkh_status {
    MENKH_OK=0, MENKH_INVALID_ARGUMENT=1, MENKH_OUT_OF_MEMORY=2,
    MENKH_UNSUPPORTED=3, MENKH_INVALID_STATE=4, MENKH_BUFFER_TOO_SMALL=5,
    MENKH_RESOURCE_LIMIT=6, MENKH_IO_ERROR=7, MENKH_CANCELLED=8
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
/* Job callback runs synchronously on the calling thread. Return nonzero to cancel.
 * Phases: 0 stock, 1 target, 2 fixtures, 3 completed cut, 4 finalizing,
 * 5 complete (return ignored), 6 ready. completed/total are operation counts.
 * Initialization starts with total=0 before the job is parsed.
 * All paths must be absolute UTF-8; asset paths resolve against working_dir,
 * without changing the process working directory. Output uses the CLI formats.
 * Cancellation retains completed deltas/partial files, but publishes no final
 * result manifest. Output must be new/empty (viewer launch.json is allowed).
 * Existing material/history output is rejected without overwriting it.
 * Re-entry into another independent job is allowed; callbacks must not unwind.
 */
typedef uint32_t (*menkh_progress_v1)(void *context, uint32_t phase, uint64_t completed, uint64_t total);
/* Windows callers: reserve 16 MiB of stack for whole-job execution (the Zig
 * thread default). Nested filesystem calls can exceed MSVC's 1 MiB default. */
menkh_status menkh_run_job_v1(const char *job, const char *output, const char *working_dir, menkh_progress_v1 callback, void *context);
/* Copy the last successful cut's delta; own the returned bytes before the next cut.
 * Replay is transactional. A successful replay invalidates this handle's last delta.
 * A restored/compacted unrelated state must not receive old slot-index history. */
menkh_status menkh_history_write_v1(const menkh_handle *, void *, size_t capacity, size_t *written);
menkh_status menkh_history_apply_v1(menkh_handle *, const void *, size_t bytes, uint32_t forward);
#ifdef __cplusplus
}
#endif
#endif
