# probe rgba8 打包 ×2 语义分叉 — 裁决报告

对应《项目冗余与共有逻辑优化方案》2026-07-12 长尾复核中转 defer 的 "probe rgba8 ×2" 条目：`AutoObjectProbePrefilterGPU` 与 `AutoVoxelRuntimeProfileContainer` 各持一份 `_shader_rgba8_from_probe` + `_probe_metric_weights` + 32B 探针打包循环。本报告逐字对照两版、追踪打包字节到 GPU 读者、给出逐输入分歧表与三个裁决选项。**纯分析，未改任何代码。** 分叉自 `962aa42`（2026-06-03）起即存在，此后两版仅被 utils 收敛（`0cfe07b`）与 penalty-only checkpoint（`92ee35f`）机械触碰，非近期漂移。

## 两版函数逐字对照

`scripts/autoobject_probe_prefilter_gpu.gd:1421-1429`（prefilter 版）：

```gdscript
## 从探针字典中提取颜色和复杂度，转换为 GPU 所需的 RGBA8 uint32。
static func _shader_rgba8_from_probe(probe: Dictionary) -> int:
	if probe.has("expected_color") or probe.has("color") or probe.has("expected_complexity") or probe.has("complexity"):
		var color := VariantUtils.color_from_value(
			probe.get("expected_color", probe.get("color", Color.WHITE)),
			Color.WHITE
		)
		color.a = clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
		return BufferUtils.pack_shader_rgba8_word(color)
	return BufferUtils.semantic_to_shader_rgba8_word(int(probe.get("expected_rgba8", 0)))
```

`scripts/auto_voxel_runtime_profile_container.gd:837-843`（container 版）：

```gdscript
## 从 probe 推导 shader 用的 rgba8：优先用 expected_color/color（complexity 写入 alpha），否则回退由 expected_rgba8 解出的颜色，最终统一打包为 shader rgba8 布局。
static func _shader_rgba8_from_probe(probe: Dictionary) -> int:
	if probe.has("expected_color") or probe.has("color"):
		var color := VariantUtils.color_from_value(probe.get("expected_color", probe.get("color", Color.WHITE)), Color.WHITE)
		color.a = clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
		return BufferUtils.pack_shader_rgba8_word(color)
	var semantic_packed := int(probe.get("expected_rgba8", BufferUtils.pack_semantic_rgba8_word(Color.WHITE)))
	return BufferUtils.pack_shader_rgba8_word(BufferUtils.semantic_rgba8_word_to_color(semantic_packed))
```

`BufferUtils.semantic_to_shader_rgba8_word(w)` ≡ `pack_shader_rgba8_word(semantic_rgba8_word_to_color(w))`（`scripts/utils/buffer_utils.gd:156-157`），故语义回退分支的**函数组合完全相同**。两版真正的差异恰好两处：

1. **分支条件**：prefilter 版四键（`expected_color`/`color`/`expected_complexity`/`complexity`）任一命中即走 color 路径——"仅 complexity" 的探针也走白色 + alpha；container 版只认两个 color 键，complexity-only 探针落入语义回退。
2. **语义回退缺省**：键缺失时 prefilter 版取 `0`（→ 黑透明 `0x00000000`），container 版取 `pack_semantic_rgba8_word(Color.WHITE)`（→ `0xFFFFFFFF`）。

## 打包循环与 GPU 消费链

两个打包循环产出**同一 32B 记录布局**（container 侧常量 `PROBE_RECORD_STRIDE_BYTES := 32`，`auto_voxel_runtime_profile_container.gd:25`）：

```text
字节 0-15   vec4  (offset.xyz, w_collision)   # d0
字节 16-19  u32   shader rgba8                # GPU 端 floatBitsToUint 还原
字节 20-23  f32   expected_collision
字节 24-27  f32   w_color
字节 28-31  f32   w_complexity
```

prefilter 版循环 `scripts/autoobject_probe_prefilter_gpu.gd:656-673`（`_pack_all_probes` 内，仅 `runtime_profile_container == null` 的 transient 分支执行，:628-629 有容器时直接改走借用）：

```gdscript
	# Pack probe data: 2 vec4 per probe = 32 bytes
	# d0 = (offset.xyz, w_collision)
	# d1 = (rgba8_bits, expected_collision, w_color, w_complexity)
	var probe_bytes := PackedByteArray()
	probe_bytes.resize(maxi(all_probes.size(), 1) * 32)
	for i in range(all_probes.size()):
		var p: Dictionary = all_probes[i]
		var offset := _vec3_from(p.get("offset", Vector3.ZERO))
		var rgba8 := _shader_rgba8_from_probe(p)
		var e_coll := clampf(float(p.get("expected_collision", 0.0)), 0.0, 1.0)
		var wc := _probe_metric_weights(p)

		var base := i * 32
		BufferUtils.encode_vec4(probe_bytes, base + 0, offset, wc.z) # w_collision
		probe_bytes.encode_u32(base + 16, rgba8)        # floatBitsToUint on GPU side
		probe_bytes.encode_float(base + 20, e_coll)
		probe_bytes.encode_float(base + 24, wc.x)      # w_color
		probe_bytes.encode_float(base + 28, wc.y)      # w_complexity
```

container 版循环 `scripts/auto_voxel_runtime_profile_container.gd:675-692`（`_pack_probe_record_bytes`，`upload_profiles` 上传为常驻 `probe_records` buffer）：

```gdscript
## 将 staging probe 记录按 PROBE_RECORD_STRIDE_BYTES 打包为 GPU 字节流：每条编码 offset、shader rgba8、expected_collision 及 w_color/w_complexity/w_collision 度量权重。
func _pack_probe_record_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_staging_probe_records.size() * PROBE_RECORD_STRIDE_BYTES)
	for i in range(_staging_probe_records.size()):
		var probe: Dictionary = _staging_probe_records[i]
		var offset := VariantUtils.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		var weight := maxf(float(probe.get("weight", 1.0)), 0.0)
		var rgba8 := _shader_rgba8_from_probe(probe)
		var expected_collision := clampf(float(probe.get("expected_collision", 0.0)), 0.0, 1.0)
		var wc := _probe_metric_weights(probe)

		var base := i * PROBE_RECORD_STRIDE_BYTES
		BufferUtils.encode_vec4(bytes, base + 0, offset, wc.z) # w_collision
		bytes.encode_u32(base + 16, rgba8)
		bytes.encode_float(base + 20, expected_collision)
		bytes.encode_float(base + 24, wc.x)       # w_color
		bytes.encode_float(base + 28, wc.y)       # w_complexity
	return bytes
```

### 字节流的 GPU 读者

| 字节流 | 上传/绑定位置 | Shader 读者 | rgba8 字的用途 |
| --- | --- | --- | --- |
| prefilter transient `probe_bytes` | `autoobject_probe_prefilter_gpu.gd:224` `storage_buffer_from_bytes` → `ProbeData`（set 0 binding 2） | `shaders/score_anchor_asset_probes.glsl:32-34` 声明；`:180-194` 主循环 `d1.x` → `floatBitsToUint`（:185）→ `unpack_rgba8`（:85-92，R 在最高字节）→ `e_col` | `eval_probe`（:109-127）：`e_col.rgb` 驱动 `color_match`（:116）、`e_col.a` 驱动 `complexity_match`（:117），双极映射后按 `w_color`/`w_complexity` 加权进 anchor×asset 分（:126）→ top-K → 候选路由。**完全可观测** |
| container 常驻 `probe_records`（借用路径） | `autoobject_probe_prefilter_gpu.gd:706` `get_probe_buffer` 借出 → `:221-222` 作为同一 `probe_data_buf` | 与上行**同一个** `score_anchor_asset_probes.glsl` 绑定点 | 同上。生产路径（SPA `scene_placement_actor.gd:1660-1664`、`:1781-1785` 恒传 `_runtime_profile_container`）走的是这条 |
| container 常驻 `probe_records`（VPG 路径） | `voxel_placement_generator.gd:3075` 取 buffer → `:3091` 绑 binding 9 | `shaders/score_voxel_tile.glsl:134-137` `RuntimeProbeRecord{vec4 offset_weight; uvec4 expected_flags_kind}`；`:164-166` 声明；唯一读点 `touch_profile_side_buffers`（:414-428） | **只读 `offset_weight.w`**（:427，即 w_collision 槽位）做 debug 契约 atomicMax；`expected_flags_kind.x`（rgba8 字）**全 shader 零读取**——此消费链上分歧不可观测 |

**结构性结论**：走哪版函数由**路径**决定而非数据决定——生产（SPA）恒传容器 → 只有 container 版真正打包，prefilter 版随即借用其产物；prefilter 版自己的打包循环仅在 null-container 的 transient 路径执行，当前全仓唯一此类调用方是 `tools/test_autoobject_probe_prefilter.gd:84-97`。两版产物最终喂**同一个** `score_anchor_asset_probes.glsl`，因此同一探针字典若两条路径给出不同 rgba8，将直接造成"同数据、不同路径、不同评分"。

## 逐输入分歧表

设 complexity = 0.25（`quantize_unorm8(0.25)` = 0x40）；语义字示例取 `pack_semantic_rgba8_word(Color(0.1, 0.4, 0.7, 0.25))`。

| 探针输入 | prefilter 版输出（shader word） | container 版输出（shader word） | 一致? | 下游可观测点 |
| --- | --- | --- | --- | --- |
| 仅 `expected_rgba8` | `pack_shader(semantic→color(w))` | 同左（缺省差异不触发） | ✅ 逐位一致 | — |
| 含 `expected_color`/`color`（含任意组合附加键） | color 分支 | color 分支（同一表达式） | ✅ 逐位一致 | — |
| 仅 `expected_complexity`/`complexity`=0.25 | `0xFFFFFF40`（白 + complexity alpha） | `0xFFFFFFFF`（complexity **丢失**，alpha=1.0） | ❌ | `score_anchor_asset_probes.glsl:117` `complexity_match`（差 0.75 → `complexity_fit` 差 1.5×w_complexity/探针） |
| `complexity`=0.25 + `expected_rgba8`（无 color 键） | `0xFFFFFF40`（语义色**被丢弃**） | `0x1A66B340`（complexity 覆盖**被丢弃**） | ❌ 双通道都不同 | `:116-117` color_match + complexity_match 同时偏移 |
| 四键全无 | `0x00000000`（黑透明——对一切目标色投负票） | `0xFFFFFFFF`（白不透明） | ❌ | `:116-117` 全通道 |

可观测性的三层限定：

- **规范化探针永不分叉**：`SemanticProbeProfile.normalize_probe`/`make_probe`（`scripts/semantic_probe_profile.gd:589-621`）恒写 `expected_color` + `expected_complexity` + `expected_rgba8`，恒落表中第 2 行。两侧的探针源都过规范化——container 经 `normalize_descriptor` → descriptor `get_semantic_probes`（`asset_descriptor.gd:101-137` → `profile.get_probes()` 逐条 normalize，`semantic_probe_profile.gd:43`；或 `rebuild_from_mesh` → `probe_from_candidate` → normalize，`:581-586`）；prefilter transient 经 `auto_object.gd:712` normalize。**分歧行仅手写探针字典可达**（如 `test_autoobject_probe_prefilter.gd:60-68` 用 `make_probe`，也已规范化）。
- **生产路径只跑 container 版**（见上节），分歧行为要现身还需同时满足"transient 路径 + 非规范化探针"。
- **score_voxel_tile.glsl 消费链天然免疫**（rgba8 字零读取）。

即：分歧是**潜伏语义债**而非现行 bug——今天没有任何活路径产出不同字节，但任何绕过 normalize 的新调用方（或未来给 transient 路径加生产入口）会立刻踩上路径依赖的评分差。

## _probe_metric_weights 对照

审计称"逐字 identical"——**核实属实**（函数体逐字符一致，仅 doc 注释措辞不同）：

```gdscript
# scripts/autoobject_probe_prefilter_gpu.gd:1440-1445（container 版 :847-852 函数体逐字相同）
static func _probe_metric_weights(p: Dictionary) -> Vector3:
	return Vector3(
		float(p.get("w_color", 1.0)),
		float(p.get("w_complexity", 1.0)),
		float(p.get("w_collision", 1.0)),
	)
```

此对可随裁决结果一并收敛，无独立裁决必要。

## 顺带观察（非本裁决范围，记录备查）

- container 循环死局部量：`auto_voxel_runtime_profile_container.gd:681` 的 `weight` 算完从不编码——32B 布局里没有它的槽位；shader 侧 `offset_weight.w`（`score_voxel_tile.glsl:427`）实际装的是 `w_collision`。历史布局残留。
- `score_voxel_tile.glsl:136` 字段名 `expected_flags_kind` 已陈旧（`962aa42` 时代打包含 flags/kind，现为 rgba8/e_coll/w_color/w_complexity），因零读取无行为影响。
- 循环级非 rgba8 小差异：offset 转换 `_vec3_from`（严格版，别名清扫 keep-list 项）vs `VariantUtils.vector3_from_value`（宽容版）；缓冲最小尺寸 `maxi(n,1)*32`（至少 1 条零记录）vs 精确 `n*32`。合并打包循环时需一并裁决，本报告聚焦 rgba8 函数。

## 冻结约束

`tools/test_autoobject_probe_prefilter.gd:365`（及 `:369`）按符号引用 `Prefilter._shader_rgba8_from_probe`：

```gdscript
	var shader_from_color := Prefilter._shader_rgba8_from_probe({
		"expected_color": color,
		"expected_complexity": color.a,
	})
	var shader_from_semantic := Prefilter._shader_rgba8_from_probe({
		"expected_rgba8": semantic_packed,
	})
```

任何裁决都必须让 `AutoObjectProbePrefilterGPU` 上保留同名静态（薄委托即可），或同 commit 更新该测试。注意该测试的两个用例（含 color 键 / 仅语义字）恰好都落在**两版逐位一致**的行——无论 a/b 哪版胜出，测试断言本身不需要改。

## 裁决选项

### (a) prefilter 版为 canonical（四键条件）

合并函数取 prefilter 的分支条件；**建议同时吸收 container 的语义回退缺省 `pack_semantic(WHITE)`**（prefilter 的缺省 `0` 会让无键探针变黑透明、对一切目标色投负票，是两版中更差的缺省）。落位建议：并入 `SemanticProbeProfileScript`（探针 schema 的属主，`normalize_probe` 已在此）静态，两文件各留一行委托。

- 行为变化的调用位：`_pack_probe_record_bytes`（container，:682）——常驻 `probe_records` 字节的生产源。但因容器探针全部规范化，**实际生产字节零变化**；变的只是防御性回退语义。
- GPU 验证：`-e` 门禁 + 桥调 `CoreSPADemo.run_stamp_only_commit_check` / `run_resident_placement_writeback_check`（覆盖 SPA→prefilter 借用→`score_anchor_asset_probes` 与 VPG→`score_voxel_tile` 全链）；anchors 侧可用 `demos/placement-autoobject-probe-prefilter` 的 `debug_read_anchors`/top-K 读回或 core-sv-anchor-collection demo 抽查分数不变。
- 工作量：~30 行 diff（共享静态 + 两处委托 + `_probe_metric_weights` 顺带收敛）+ 验证 ≈ 0.5–1h。可加一次性 CPU 字节自证：同一批规范化探针分别过新旧函数比对逐位相等。

### (b) container 版为 canonical（两键条件 + WHITE 缺省）

prefilter 侧改用 container 语义（同样经共享静态 + 委托，冻结符号保住）。

- 行为变化的调用位：仅 `_pack_all_probes` transient 循环（:664）——当前只有测试走。complexity-only 手写探针在 transient 路径丢 alpha（表第 3 行右列行为扩散到左列）。
- GPU 验证：`-e` 门禁即可（生产字节完全不变）；如需行为兜底，被点名时跑 `tools/test_autoobject_probe_prefilter.gd`（非例行）。
- 工作量：与 (a) 相同 ≈ 0.5–1h。代价是把"信息丢弃"（complexity 覆盖被忽略）固化为 canonical 语义。

### (c) 双版本有意保留（改名 + 文档化分歧）

各自 doc 注释明写分歧表，container 版改名（如 `_shader_rgba8_from_probe_semantic_fallback`）以消除"同名同义"错觉；prefilter 版**不能改名**（冻结符号）。

- 行为变化：零。GPU 验证：无需。工作量：~0.5h。
- 代价：把"同一探针字典、两条路径、两种字节"固化为设计——但上文已证明该分叉不是有意的 per-context 语义（同一 shader 消费、同一记录布局、分歧只在防御性回退），保留等于给未来绕过 normalize 的调用方留暗雷，且本审计条目会在后续精简审计中反复出现。

## 推荐

**(a)**，且语义回退缺省采 container 侧的 `pack_semantic(WHITE)`。理由：

1. 两版对一切规范化探针（即全部现存生产数据）逐位等价，a/b 的生产风险同为零——裁决实质是选**防御性回退语义**，应选信息保全的一版：prefilter 的四键条件不丢 complexity-only 探针的 alpha；container 的 WHITE 缺省不产出"黑透明负票"探针。两者各取所长恰是逐输入分歧表中每行的无损上界。
2. 冻结符号天然落在 prefilter 侧，以其语义为 canonical 后测试 `:365` 语义与实现完全对齐（委托后仍按符号可达）。
3. (c) 已被消费链证据排除：同 shader、同布局、分歧无一被 GPU 分支利用，不构成"有意 per-context 语义"。

验证按 (a) 节路径执行；建议同 commit 顺带收敛 `_probe_metric_weights` 对（零风险），死局部量 `weight` 与 `expected_flags_kind` 陈旧名可另行小批处理。
