// 三角形 ID 拾取的输出材质：把 `pick_id = pick_id_base + INSTANCE_ID` 打成 RGB8 三通道。
//
// 上位设计见《点选重构-可视化即拾取几何.md》与《pick_id载体方案对比.md》（载体定案为
// 「B：INSTANCE_ID + 逐 drawable 基址 uniform」，改动面为零：不动任何 MultiMesh 的 stride）。
//
// ⚠ 三条必须成立的性质，任一破了就是「点 A 选中 B」这类最难查的缺陷：
//
// 1. **varying 必须 flat。** ID 一旦跨片元插值就会产生不存在的中间值，指向随机对象。
//    这里传的是已经算好的三通道颜色（而不是 int），因为 float varying 的 flat 支持面最广；
//    值本身仍然是逐实例常量，flat 保证它逐片元不变。
// 2. **必须 unshaded。** ID 不是颜色：任何光照/环境/雾项参与就等于把 ID 改写掉。
// 3. **必须抵消管线的 linear→sRGB。** SubViewport 的渲染目标是 R8G8B8A8_UNORM（非 sRGB
//    格式），于是 tonemap 出口会做一次 `linear_to_srgb`
//    （`renderer_scene_render_rd.cpp` 的 `tonemap.convert_to_srgb = !using_hdr`，
//    `effects/tonemap.glsl` 的 `linear_to_srgb`）。
//    我们在这里先做一次**同一条曲线**的逆变换，两者相消后回读到的字节 == 写入的码值。
//    `encode_srgb` 留作开关只为可实测对照（PickIdPass.self_test_codec 会两边都跑一遍），
//    **不是**给运行期"看着不对就关掉"用的。
//
// cull_disabled 与体素显示材质（voxel_display.gd 的 CULL_DISABLED）保持一致：
// 显示上从盒内/背面看得见什么，拾取上就能选中什么——不额外加正面过滤。

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// 本 drawable 的 pick_id 区间基址。0 保留为「无命中」，故分配器从 1 起。
uniform int pick_id_base = 0;
// true = 预补偿 sRGB（生产设置）；false = 直接写码值（仅用于实测对照）。
uniform bool encode_srgb = true;

varying flat vec3 v_pick_rgb;

// 与 `servers/rendering/renderer_rd/shaders/effects/tonemap.glsl` 的 srgb_to_linear
// 逐字同式（逐分量写法，避开 mix(vec3, vec3, bvec3) 的可用性差异）。
float pick_srgb_to_linear(float c) {
	if (c < 0.04045) {
		return c * (1.0 / 12.92);
	}
	return pow((c + 0.055) * (1.0 / 1.055), 2.4);
}

void vertex() {
	int id = pick_id_base + INSTANCE_ID;
	// 24 位打进 RGB8：R = 高 8 位，B = 低 8 位。解码方按同一规则还原（PickIdPass.decode_rgb8）。
	vec3 code = vec3(
		float((id >> 16) & 255),
		float((id >> 8) & 255),
		float(id & 255)) * (1.0 / 255.0);
	if (encode_srgb) {
		v_pick_rgb = vec3(
			pick_srgb_to_linear(code.r),
			pick_srgb_to_linear(code.g),
			pick_srgb_to_linear(code.b));
	} else {
		v_pick_rgb = code;
	}
}

void fragment() {
	ALBEDO = v_pick_rgb;
}
