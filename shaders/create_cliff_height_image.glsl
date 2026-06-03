#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) restrict writeonly uniform image2D out_height_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float box_height;
	float margin;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float u = float(p.x) / float(max(params.width - 1, 1));
	float v = float(p.y) / float(max(params.height - 1, 1));
	bool inside = u > params.margin && u < 1.0 - params.margin && v > params.margin && v < 1.0 - params.margin;
	float h = -20000.0;
	if (inside) {
		h = min(params.box_height * (1.0 - abs(u - 0.5) * 2.0) - params.box_height, -0.01);
	}
	imageStore(out_height_img, p, vec4(h, 0.0, 0.0, 1.0));
}
