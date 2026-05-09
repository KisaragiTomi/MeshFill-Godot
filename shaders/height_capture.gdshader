shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float max_height = 50.0;

varying float world_height;

void vertex() {
	world_height = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	float h = clamp(world_height / max_height, 0.0, 1.0);
	ALBEDO = vec3(h, h, h);
}
