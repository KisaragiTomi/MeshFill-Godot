#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(rgba32f, set = 1, binding = 0) restrict writeonly uniform image2D out_height_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float scale;
	float sentinel;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	vec4 px = texelFetch(height_tex, p, 0);
	if (px.r > params.sentinel) {
		px.r = min(px.r * params.scale, -0.01);
	}
	imageStore(out_height_img, p, px);
}
