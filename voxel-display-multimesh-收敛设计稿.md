# voxel_display 三次 MultiMesh 构建块收敛设计稿

针对 2026-07-12 冗余审计延期项"`voxel_display` 三次 MultiMesh 构建块"（见《项目冗余与共有逻辑优化方案.md》批次 2 文件内重复条目）的设计草案。**本文档为设计稿，未实施任何代码改动。** 目标文件：`scripts/utils/voxel_display.gd`。

背景：三个 GPU 显示构建函数（`_build_gpu_instances` / `build_field_gpu` / `build_brush_tetra_gpu`）共享同一骨架——MultiMesh 分配 → 节点构建 → writer 三段守卫（`is_ready` / `bind_multimesh` / `write_*`）→ `tree_exiting` dispose 挂接 → writer meta——但 writer 类、写调用签名、告警前缀、meta 键各不相同，属"同形不同字"重复。注意：设备/管线/scratch/释放生命周期这块**大头重复已在此前抽入 `VoxelMultiMeshWriterGPU` 基类**（`scripts/utils/voxel_multimesh_writer_gpu.gd`），本条处理的是残余的编排层骨架。

## 现状解剖

行号以当前工作区为准（与审计时相比略有漂移，已按内容重新定位）。

### 块 A — `_build_gpu_instances`（`scripts/utils/voxel_display.gd:66-109`）

`build_colored` 与 `build_from_transforms` 的共同后端。

```gdscript
static func _build_gpu_instances(
	mesh: Mesh,
	transform_floats: PackedFloat32Array,
	color_floats: PackedFloat32Array,
	world_aabb: AABB,
	options: Dictionary
) -> MultiMeshInstance3D:
	var count := int(transform_floats.size() / VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS)
	if count <= 0:
		return null
	_apply_voxel_material(mesh, true, Color.WHITE, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.custom_aabb = world_aabb

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	var writer = VoxelInstanceDisplayGPUScript.new()
	if not writer.is_ready():
		push_warning("VoxelDisplay GPU instance build skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), count):
		push_warning("VoxelDisplay GPU instance build skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.write_instances(transform_floats, color_floats):
		push_error("VoxelDisplay GPU instance build failed: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	node.tree_exiting.connect(writer.dispose)
	node.set_meta("voxel_instance_writer", writer)
	return node
```

### 块 B — `build_field_gpu`（`scripts/utils/voxel_display.gd:213-267`）

```gdscript
static func build_field_gpu(
	voxel_count: int,
	cell_size: Vector3,
	world_aabb: AABB,
	fields: Dictionary,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	if voxel_count <= 0:
		return null

	var fill := float(options.get("fill", DEFAULT_FILL))
	var cell := BoxMesh.new()
	cell.size = cell_size * fill
	_apply_voxel_material(cell, true, Color.WHITE, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = cell
	mm.instance_count = voxel_count
	mm.custom_aabb = world_aabb

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	var writer = VoxelFieldDisplayGPUScript.new()
	if not writer.is_ready():
		push_warning("VoxelDisplay.build_field_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), voxel_count):
		push_warning("VoxelDisplay.build_field_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.write_field(fields, params):
		push_error("VoxelDisplay.build_field_gpu: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	# Free the writer's GPU resources while the node (and writer) are still alive,
	# on the render thread during a normal frame. Deferring this to the writer's
	# PREDELETE would bind a half-destructed object and leak.
	node.tree_exiting.connect(writer.dispose)

	# Keep the writer (and its GPU resources) alive for the node's lifetime.
	node.set_meta("voxel_field_writer", writer)
	node.set_meta("voxel_display_backend", "gpu")
	node.set_meta("voxel_display_reason", "ok")
	return node
```

### 块 C — `build_brush_tetra_gpu`（`scripts/utils/voxel_display.gd:281-327`）

```gdscript
static func build_brush_tetra_gpu(
	brush_voxels: PackedInt32Array,
	cell_size: Vector3,
	world_aabb: AABB,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	var instance_count := brush_voxels.size() / 4
	if instance_count <= 0:
		return null

	var fill := float(options.get("fill", DEFAULT_FILL))
	var mesh := _make_tetra_mesh(cell_size, fill)
	_apply_voxel_material(mesh, true, Color.WHITE, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = instance_count
	mm.custom_aabb = world_aabb

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	var writer = BrushVoxelDisplayGPUScript.new()
	if not writer.is_ready():
		push_warning("VoxelDisplay.build_brush_tetra_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), instance_count):
		push_warning("VoxelDisplay.build_brush_tetra_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.write_brush(brush_voxels, params):
		push_error("VoxelDisplay.build_brush_tetra_gpu: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	node.tree_exiting.connect(writer.dispose)
	node.set_meta("voxel_brush_writer", writer)
	return node
```

### 骨架 / 变体对照表

`＝` 表示三块逐字相同（仅局部变量名替换），其余单元格列出该块的差异内容。

| 骨架步骤 | A `_build_gpu_instances` | B `build_field_gpu` | C `build_brush_tetra_gpu` |
| --- | --- | --- | --- |
| 数量来源 + 空守卫 `return null` | `count = floats/12`，`count <= 0` | 形参 `voxel_count <= 0` | `instance_count = size/4`，`<= 0` |
| 网格 + 材质 | 网格由调用方传入；`_apply_voxel_material` 在函数体内 | `BoxMesh` × fill；材质在骨架前 | `_make_tetra_mesh` × fill；材质在骨架前 |
| MultiMesh 分配 6 行（`TRANSFORM_3D`/`use_colors`/`mesh`/`instance_count`/`custom_aabb`） | ＝ | ＝ | ＝ |
| 节点构建 4 行（`name`/`multimesh`/`custom_aabb`） | ＝ | ＝ | ＝ |
| writer 构造 | `VoxelInstanceDisplayGPUScript` | `VoxelFieldDisplayGPUScript` | `BrushVoxelDisplayGPUScript` |
| 守卫 1 `is_ready()` → `push_warning` | 前缀 `"VoxelDisplay GPU instance build skipped: %s"` | 前缀 `"VoxelDisplay.build_field_gpu skipped: %s"` | 前缀 `"VoxelDisplay.build_brush_tetra_gpu skipped: %s"` |
| 守卫 2 `bind_multimesh(mm.get_rid(), n)` → 同上 warning | ＝（n = `count`） | ＝（n = `voxel_count`） | ＝（n = `instance_count`） |
| 守卫 3 写调用 → `push_error` | `write_instances(transform_floats, color_floats)`；错误串带 `" failed: %s"` | `write_field(fields, params)`；错误串为 `": %s"`（**无** failed） | `write_brush(brush_voxels, params)`；错误串为 `": %s"` |
| 守卫失败三连 `writer.dispose()` / `node.free()` / `return null`（每块 ×3，共 9 处） | ＝ | ＝ | ＝ |
| `node.tree_exiting.connect(writer.dispose)` | ＝ | ＝（额外带 PREDELETE 解释注释） | ＝ |
| writer meta | `"voxel_instance_writer"` | `"voxel_field_writer"` + 额外 `"voxel_display_backend"="gpu"`、`"voxel_display_reason"="ok"` | `"voxel_brush_writer"` |
| `return node` | ＝ | ＝ | ＝ |

变体轴合计 6 条：数量来源、网格来源、writer 类、写调用签名、warning/error 格式串（注意 A 的 error 串比 B/C 多 `" failed"`）、meta 键（B 多两个额外键）。

## 收敛设计

### 共享构建器 `_build_writer_node`

writer 由调用方 `new` 好后传入，写步骤以已绑定数据的 `Callable` 传入（`writer.write_*.bind(...)` 形式）；变体轴全部参数化，格式串与 meta 键逐字下传。

```gdscript
# 三条 GPU 显示构建路径（instances / field / brush tetra）的共享骨架：
# MultiMesh 分配 -> 节点 -> writer 三段守卫（is_ready / bind_multimesh / write）
# -> tree_exiting dispose 挂接 -> writer meta。任一守卫失败：writer.dispose()
# + node.free() + 返回 null，与三处原语义逐字一致。
#
# 约束：write_call 必须绑定在传入的同一个 writer 实例上
# （形如 writer.write_field.bind(fields, params)）。骨架把 dispose 挂到形参
# writer 上；若 write_call 绑了另一个实例，dispose 与实际写入者会分家。
static func _build_writer_node(
	mesh: Mesh,                  # 已应用材质的单元网格（Box / tetra）
	instance_count: int,         # MultiMesh 实例数，调用方已保证 > 0
	world_aabb: AABB,            # 预计算的局部空间格界
	options: Dictionary,         # 仅读 "name"（材质相关键在调用方已消费）
	writer,                      # VoxelMultiMeshWriterGPU 子类实例（沿用现状鸭子类型）
	write_call: Callable,        # () -> bool，已 bind 数据的 writer.write_*
	warn_fmt: String,            # 守卫 1/2 失败的 push_warning 格式串（含一个 %s）
	fail_fmt: String,            # 守卫 3 失败的 push_error 格式串（含一个 %s）
	meta_key: String,            # writer 挂载的 meta 键，逐字保留
	extra_meta: Dictionary = {}  # 额外 meta（仅 build_field_gpu 使用）
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = instance_count
	mm.custom_aabb = world_aabb

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	if not writer.is_ready():
		push_warning(warn_fmt % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), instance_count):
		push_warning(warn_fmt % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not write_call.call():
		push_error(fail_fmt % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	# Free the writer's GPU resources while the node (and writer) are still alive,
	# on the render thread during a normal frame. Deferring this to the writer's
	# PREDELETE would bind a half-destructed object and leak.
	# (释放契约见 VoxelMultiMeshWriterGPU._release / _notification。)
	node.tree_exiting.connect(writer.dispose)

	# Keep the writer (and its GPU resources) alive for the node's lifetime.
	node.set_meta(meta_key, writer)
	for key in extra_meta:
		node.set_meta(key, extra_meta[key])
	return node
```

### 三处调用点改写（示意，未应用）

各函数保留自己的前置段（数量推导、空守卫、网格构建、材质应用）——早退语义与现状逐字一致；`build_field_gpu` / `build_brush_tetra_gpu` 节前的长注释原样保留，此处省略。

```gdscript
static func _build_gpu_instances(
	mesh: Mesh,
	transform_floats: PackedFloat32Array,
	color_floats: PackedFloat32Array,
	world_aabb: AABB,
	options: Dictionary
) -> MultiMeshInstance3D:
	var count := int(transform_floats.size() / VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS)
	if count <= 0:
		return null
	_apply_voxel_material(mesh, true, Color.WHITE, options)
	var writer = VoxelInstanceDisplayGPUScript.new()
	return _build_writer_node(
		mesh, count, world_aabb, options, writer,
		writer.write_instances.bind(transform_floats, color_floats),
		"VoxelDisplay GPU instance build skipped: %s",
		"VoxelDisplay GPU instance build failed: %s",
		"voxel_instance_writer"
	)
```

```gdscript
static func build_field_gpu(
	voxel_count: int,
	cell_size: Vector3,
	world_aabb: AABB,
	fields: Dictionary,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	if voxel_count <= 0:
		return null
	var fill := float(options.get("fill", DEFAULT_FILL))
	var cell := BoxMesh.new()
	cell.size = cell_size * fill
	_apply_voxel_material(cell, true, Color.WHITE, options)
	var writer = VoxelFieldDisplayGPUScript.new()
	return _build_writer_node(
		cell, voxel_count, world_aabb, options, writer,
		writer.write_field.bind(fields, params),
		"VoxelDisplay.build_field_gpu skipped: %s",
		"VoxelDisplay.build_field_gpu: %s",
		"voxel_field_writer",
		{ "voxel_display_backend": "gpu", "voxel_display_reason": "ok" }
	)
```

```gdscript
static func build_brush_tetra_gpu(
	brush_voxels: PackedInt32Array,
	cell_size: Vector3,
	world_aabb: AABB,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	var instance_count := brush_voxels.size() / 4
	if instance_count <= 0:
		return null
	var fill := float(options.get("fill", DEFAULT_FILL))
	var mesh := _make_tetra_mesh(cell_size, fill)
	_apply_voxel_material(mesh, true, Color.WHITE, options)
	var writer = BrushVoxelDisplayGPUScript.new()
	return _build_writer_node(
		mesh, instance_count, world_aabb, options, writer,
		writer.write_brush.bind(brush_voxels, params),
		"VoxelDisplay.build_brush_tetra_gpu skipped: %s",
		"VoxelDisplay.build_brush_tetra_gpu: %s",
		"voxel_brush_writer"
	)
```

### 保留语义清单

- **dispose 生命周期契约不变**：`node.tree_exiting.connect(writer.dispose)` 连接对象、时机、目标实例与现状完全一致；守卫失败路径保持 `writer.dispose()` → `node.free()` → `return null` 顺序（node 尚未入树，直接 `free()` 正确）。writer 内部的 PREDELETE 静态释放契约（`_release` 绑值不绑 self、`uniform_set_is_valid` 守卫）在基类，本改动不触碰。
- **warning/error 前缀逐字保留**（不统一）：三组前缀各自点名失败的公共入口（`GPU instance build` / `build_field_gpu` / `build_brush_tetra_gpu`），是排障时定位调用路径的唯一线索；A 的 error 串带 `" failed"` 而 B/C 不带，这一不一致也通过完整格式串下传原样保留——统一措辞收益为零、徒增日志 diff。
- **meta 键 byte-for-byte**：`"voxel_instance_writer"` 被本文件 `write_instance_color`（`voxel_display.gd:116-124`）读取；`"voxel_display_reason"` 被 `scripts/utils/target_sv_setup.gd:193` 读取；`"voxel_brush_writer"` 被 `tools/test_targetsv_brush_overlay.gd:120,189` 断言。三键 + B 的两个额外键全部经 `meta_key` / `extra_meta` 原样写入。
- **早退 / 回退语义不变**：三处 `<= 0` 空守卫（静默返回 null、不告警）留在各自函数；`build_colored` 的 `centers.is_empty()` 前置守卫不涉及。

### 备选变体（记录，不推荐为首选）

- **`callv` 变体**：签名改为 `writer + method: StringName + args: Array`，helper 内 `writer.callv(method, args)`。消除"write_call 绑错实例"这一双源风险，但方法名退化为字符串（拼错在运行时才爆、失去重命名工具可达性）。首选 `Callable` 形式 + 签名注释约束。
- **config Dictionary 变体**：把 5 个变体参数合并为一个 spec 字典。参数个数少了，但键名拼错静默失效（如 `meta_key` 拼错 → meta 丢失、`write_instance_color` 静默失灵），比显式形参风险高，不采用。

## 风险登记

| 风险 | 成因 | 缓解 |
| --- | --- | --- |
| dispose 与写入者分家 | `write_call` 绑定了与形参 `writer` 不同的实例（未来改动手滑） | 签名注释明文约束"必须同一实例"；调用点模式固定为 `new` 后紧跟 `writer.write_*.bind(...)`，两行相邻 |
| Callable 捕获陷阱 | GDScript bound `Callable` 持 writer（RefCounted）强引用 | 本设计中 `write_call` 在 helper 内**同步**调用后即随栈释放，不进入 render-thread 延迟调用、不涉及 PREDELETE 语境——与 dispose 规则冲突的"绑 self 进延迟 Callable"模式不存在。禁止后续把 `write_call.call()` 改成 `call_deferred`（写入会晚于返回，且 writer 生命周期被拖长）；禁止把 `writer.dispose` 换成 lambda 包裹（无收益、多一层闭包） |
| 守卫失败漏 `node.free()` | 提取时手误 | 失败三连收敛到 helper 内仅 3 处（原 9 处），review 面缩小；diff 只限 `voxel_display.gd` 单文件单 commit |
| 格式串变数据后 `%s` 个数错 | 格式串从字面量变实参，错配在**失败分支**才在运行时爆（平时不触发，潜伏） | 逐字拷贝现有串；可选在 helper 顶部 `assert(warn_fmt.contains("%s") and fail_fmt.contains("%s"))` |
| 热路径回归 | 本骨架是全部 demo + 编辑器刷子的显示入口 | 错误症状是"体素整批不显示/不改色"，高可见、-e 目检即暴露；按下节验证计划全三路径过一遍 |
| `write_call.call()` 返回非 bool | 写方法签名未来变更返回 Variant/null | `not null` 为真 → 按失败处理并报错，行为安全侧；三个 `write_*` 现均为 `-> bool` |

### 验证计划

golden 检查（`DebugBufferSet.golden_snapshot`，commit b0ff085）覆盖的是 VPG 输出缓冲诊断，**不覆盖 display 侧**——本项验证全靠 `-e` 目检。

按 CLAUDE.md 单实例流程：停掉现有编辑器 → 删陈旧 lock → 以 `-e --rendering-driver vulkan` 新开 → 控制台无脚本错误 + 桥 `127.0.0.1:6800` ping 通过（这是所有改动的统一 pass 门槛），随后逐路径目检：

| 路径 | 在编辑器内的触发点 | 目检项 |
| --- | --- | --- |
| A `_build_gpu_instances` | `demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd:1164,1178`（`build_from_transforms`）；`demos/core-sv-anchor-collection/sv_anchor_collection_demo.gd:386`、`demos/asset-descriptor-demo/asset_descriptor_demo.gd:968`（`build_colored`） | SPA demo 跑放置后彩色实例盒显示；**点击选中改色**走 `write_instance_color` → 验证 `"voxel_instance_writer"` meta 链路仍通 |
| B `build_field_gpu` | `addons/meshfill_editor/meshfill_brush.gd:198`、`scripts/utils/target_sv_setup.gd:165`（并读 `voxel_display_reason`）、`sv_anchor_collection_demo.gd:459` | 启用 meshfill 刷子 → TargetSV 场体素盒显示；sv-anchor demo 场显示正常 |
| C `build_brush_tetra_gpu` | `addons/meshfill_editor/meshfill_brush.gd:362` | 刷子涂刷 → 四面体 overlay 出现、擦除后消失 |

补充：`tools/test_voxel_writer_dispose.gd`（field 路径 dispose 专测）与 `tools/test_targetsv_brush_overlay.gd`（brush meta 断言）存在，但按项目规则测试套件非常规验证，仅在被要求时运行。视觉截图经桥抓取对比改动前后。

## 结论

行数账（函数体口径，不含节前注释）：现状 A 37 + B 47 + C 40 = 124 行；收敛后 helper 约 55 行（含签名与注释）+ 三处调用体约 45 行 = 约 100 行，**净省约 25 行（文件约 6%）**。真正的收益不在行数：9 处 `dispose/free/null` 守卫三连收敛为 3 处（消除"只在一块里修生命周期 bug"的漂移风险），且未来第四类显示 writer 可直接复用骨架。代价：错误格式串与 meta 键从字面量变实参、读单个 build 函数需多跳一层。

审计当时延期的原因是批次优先级（同批有更大头的提取项），而非本条危险——90% 的原始重复（设备/管线/释放生命周期）早已被 `VoxelMultiMeshWriterGPU` 基类吃掉，剩下的是纯机械骨架。

**判定：GO（附条件）。** 条件：单独 commit、diff 严格限定 `scripts/utils/voxel_display.gd` 单文件、格式串/meta 键逐字拷贝、按上节验证计划完成 `-e` 三路径目检（含 SPA 点击改色与刷子涂刷）。若当期不愿支付一次三路径 `-e` 验证成本，保持三块现状也完全站得住——届时应在审计清单将本条移入"确认存在但不建议做"，避免重报。
