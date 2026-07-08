#[compute]
#version 450

// Sums the scores of valid placement result records into a tiny control-scalar
// buffer so pivot-variant selection can compare runs without reading the full
// record buffer back to the CPU.
//
// Binding contract, set 0:
//   0  readonly  placement_result_vec4x4 records (same layout as reduce output)
//   1  readonly  uint result_count[1] (written by the reduce pass)
//   2  buffer    uint score_sum_out[2]; [0]=float-bits score sum, [1]=valid count
//
// Push constants:
//   counts.x = result_capacity (upper clamp for result_count)
//   counts.y = record stride in vec4 units (4)
//   counts.z / counts.w = reserved
//
// Dispatched as a single workgroup; threads stride over the record range and
// tree-reduce in shared memory. Thread 0 writes both outputs.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer ResultCount {
    uint result_count[];
};

layout(set = 0, binding = 2, std430) restrict buffer ScoreSumOut {
    uint score_sum_out[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;
};

shared float shared_score[256];
shared uint shared_valid[256];

void main() {
    uint thread_index = gl_LocalInvocationID.x;
    uint record_count = min(result_count[0], uint(max(counts.x, 0)));
    uint stride = uint(max(counts.y, 1));

    float local_score = 0.0;
    uint local_valid = 0u;
    for (uint i = thread_index; i < record_count; i += 256u) {
        uint base = i * stride;
        vec4 pose = placement_results[base + 0u];
        vec4 debug1 = placement_results[base + 3u];
        if (debug1.y > 0.5) {
            local_score += pose.w;
            local_valid += 1u;
        }
    }
    shared_score[thread_index] = local_score;
    shared_valid[thread_index] = local_valid;
    barrier();

    for (uint offset = 128u; offset > 0u; offset >>= 1u) {
        if (thread_index < offset) {
            shared_score[thread_index] += shared_score[thread_index + offset];
            shared_valid[thread_index] += shared_valid[thread_index + offset];
        }
        barrier();
    }

    if (thread_index == 0u) {
        score_sum_out[0] = floatBitsToUint(shared_score[0]);
        score_sum_out[1] = shared_valid[0];
    }
}
