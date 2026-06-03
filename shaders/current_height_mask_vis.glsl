#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D current_height_tex;

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_color_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float generated_threshold;
	float ungenerated_threshold;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	vec4 current_px = texelFetch(current_height_tex, p, 0);
	bool generated = current_px.b > params.generated_threshold;
	bool ungenerated = current_px.g > params.ungenerated_threshold;
	if (generated && !ungenerated) {
		imageStore(out_color_img, p, vec4(0.2, 0.6, 1.0, 1.0));
	} else if (generated && ungenerated) {
		imageStore(out_color_img, p, vec4(1.0, 0.3, 0.0, 1.0));
	} else {
		imageStore(out_color_img, p, vec4(0.15, 0.15, 0.15, 1.0));
	}
}
