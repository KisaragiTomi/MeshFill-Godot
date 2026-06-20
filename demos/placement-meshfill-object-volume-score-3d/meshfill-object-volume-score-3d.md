# MeshFill 3D Object Volume Score：单物体体积采样评分

本文记录 3D placement score 阶段的设计契约：对单个候选物体，在以 anchor 为中心的 `50^3` voxel 采样窗口内，对齐 12 个旋转角度，采样 `SV` 与 `TargetSV_B` 内容并评分。窗口被拆成多个 subtile workgroup 并行收集 partial，再 reduce 汇总到该物体的评分。

> 状态：**实现中（GPU compute + stress test demo）**。两阶段 compute shader 已落地：`shaders/score_object_subtile.glsl`（Pass A: 343 subtile × 12 rotation partial 累加）、`shaders/reduce_object_rotation_scores.glsl`（Pass B: 跨 subtile reduce + best rotation pick）。GPU 编排由 `scripts/object_volume_score_gpu.gd` 管理。压力测试场景 `demos/placement-meshfill-object-volume-score-3d/` 会在默认地形的每个 anchor 上对所有 geo 物体逐一评分比较。当前 in-tree 的 tile 粒度评分 `shaders/score_voxel_tile.glsl`（`TILE_SIZE = 8`）仍并存。

2.5D heightfield 路径已标记暂停，见 [`meshfill-rock-placement-flow2.5d(暂停开发).md`((meshfill-rock-placement-flow2.5d(暂停开发).md)。3D 路径只接替「物理 score」阶段，上游 probe prefilter 与候选路由契约不变。

## 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。脚本在编辑器视口中实时运行，R 重算和 [/] 调间距均在视口内操作。
> F6（Run Current Scene）和 F5（Run Project）被 `core_demo_contract_fixture.gd` 守卫代码禁止。

## 术语

| 术语 | 含义 |
| --- | --- |
| `volume` | 整个 voxel data domain / buffer；不是单个元素。 |
| `voxel` | `volume` 中的单个 `(x, y, z)` cell。 |
| `sampling volume` | 单个候选物体的评分窗口，固定 `50^3` voxel，中心在候选 anchor。 |
| `subtile` | `sampling volume` 内的 `8^3` 子块，一个 workgroup 拥有一个 subtile。 |
| `rotation slot` | 12 个待评测旋转角度之一；默认绕 Y 轴 yaw，步进 `30°`。 |

## 设计常量

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `MAX_SAMPLE_EXTENT` | `50` | sampling volume 每轴 voxel 数上限。 |
| `MIN_SAMPLE_EXTENT` | `1` | 极小物体 (<=10cm) 单体素检测。 |
| `OBJECT_SAMPLE_EXTENT` | **动态** | 按 AABB 最长轴从 1 线性映射到 50：`<=10cm→1`, `>=5m→50`。见 `compute_extent_params()`。 |
| `SUBTILE_SIZE` | `8` | subtile 每轴 voxel 数；对齐 `local_size`。 |
| `SUBTILES_PER_AXIS` | **动态** | `ceil(extent / 8)`；从 1 到 7。 |
| `SUBTILE_COUNT` | **动态** | `spa^3`；从 1 (极小物体) 到 343 (5m+)。 |
| `ROTATION_SLOTS` | `12` | 一次评测的旋转角度数。 |
| `LOCAL_SIZE` | `8 x 8 x 8 = 512` | 每个 subtile workgroup 的线程数。 |

`OBJECT_SAMPLE_EXTENT` / `ROTATION_SLOTS` / yaw 轴向通过 push constant 传入 shader，不硬编码。每 asset dispatch 使用独立的 extent/subtile 参数。

## 数据流

```text
candidate object (anchor voxel + asset footprint + descriptor)
  -> dispatch SUBTILE_COUNT (343) workgroups, one per 8^3 subtile
  -> Pass A: score_object_subtile.glsl
       load subtile SV + TargetSV_B into shared memory once
       for each of 12 rotation slots: accumulate partial fit over subtile voxels
       write per-(subtile, rotation) partial record
  -> barrier
  -> Pass B: reduce_object_rotation_scores.glsl
       sum 343 subtile partials per rotation slot
       pick best rotation slot for this object
  -> per-object score record (best score + best rotation + per-channel breakdown)
  -> feed into existing accepted-placement / commit path
```

每个候选物体对应一组 `SUBTILE_COUNT` workgroups。多候选物体批处理时，dispatch 在 X 轴堆叠 subtile、用 `gl_WorkGroupID.y`（或 push constant base offset）选择候选物体，避免每物体单独提交。

## Dispatch 布局

| 维度 | 映射 | 说明 |
| --- | --- | --- |
| `gl_WorkGroupID.x` | subtile linear id `0..342` | 解码为 subtile 坐标 `(sx, sy, sz)`。 |
| `gl_WorkGroupID.y` | 候选物体 id | 批处理多个候选物体；单物体时为 `1`。 |
| `gl_LocalInvocationID.xyz` | subtile 内 voxel `(8,8,8)` | 每线程负责一个 subtile-local voxel。 |

subtile 坐标解码：

```text
sx = wid % 7
sy = (wid / 7) % 7
sz = wid / 49
voxel_origin = anchor - 25 + ivec3(sx, sy, sz) * 8 + local_id
```

`anchor - 25` 把 `50^3` 窗口居中到 anchor（`50 / 2 = 25`）。越界 voxel（`< 0` 或 `>= grid`）在采样前 clamp 到有效范围或按 guard 跳过，不直接当作空白，与 prefilter 越界规则一致。

## 共享内存优化

核心观察：**场景体素内容与候选旋转无关**。一个 subtile 内的 `SV` / `TargetSV_B` voxel 对 12 个旋转角度是同一份数据，旋转改变的只是 asset footprint 反向映射到哪个 voxel。因此每个 workgroup 只需把本 subtile 的体素加载进 shared memory **一次**，12 个旋转复用，避免 12 倍重复 global memory 读取。

每个 subtile 缓存 `8^3 = 512` voxel。建议缓存压缩后的字段，而不是原始多 buffer：

| shared 数组 | 元素 | 字节 | 来源 |
| --- | --- | --- | --- |
| `s_scene` | `512 x vec2` | `4096` | `complexity_field` + `collision_field` 打包成 `vec2`。 |
| `s_target` | `512 x vec2` | `4096` | `target_completely` + packed `target_color`（`uint` 位塞进 `float` slot 或并行数组）。 |

合计约 `8 KB`，在 Vulkan 保证的 `16 KB`/workgroup 下安全。若需同时缓存更多通道，应缩小 `SUBTILE_SIZE` 或拆分采样字段，而不是超出 16 KB。

加载阶段：512 线程每线程加载一个 subtile voxel 进 shared，`barrier()` 后进入评分循环。评分循环中所有读取走 `s_scene` / `s_target`，不再触碰 global field buffer。

## 12 旋转评分

加载并 barrier 后，每个 workgroup 对 12 个 rotation slot 各算一份 partial：

```text
for slot in 0..11:
    yaw = slot * (360 / ROTATION_SLOTS)   # 默认 30° 步进
    R = rotation_y(yaw)
    partial[slot( = 0
    for each footprint voxel f assigned to this subtile:
        world_v = anchor + round(R * (f - footprint_pivot))
        if world_v 落在本 subtile:
            s = s_scene[local_index(world_v)(
            t = s_target[local_index(world_v)(
            partial[slot( += weighted_fit(asset, s, t)
```

`weighted_fit` 复用现有物理 + target fit 维度：target coverage、complexity fit、color fit、support、solid collision、clearance。具体权重沿用 `score_voxel_tile.glsl` 当前语义，本文不重新定义权重默认值。

footprint 反向旋转的实现可选两种，按测试结果择一，不在本文锁定：

- forward：遍历 asset footprint voxel，正向旋转后落到场景 voxel。
- inverse：遍历 subtile 场景 voxel，反向旋转回 asset local 判断是否命中 footprint。

## Reduce 汇总

Pass A 每个 workgroup 输出一条 partial 记录：`SUBTILE_COUNT x ROTATION_SLOTS` 个 partial（每候选物体 `343 x 12`）。

汇总避免 float `atomicAdd`，改用独立 reduce pass：

```text
partial_buffer[object_id([subtile_id([slot(   # Pass A 写，slot 独占，无竞争
  -> reduce_object_rotation_scores.glsl
       每个 (object_id, slot) 求和 343 个 subtile partial
       得到 object_rotation_score[object_id([slot(
  -> 组内比较 12 个 slot，选最大值
  -> object_score_record[object_id( = (best_score, best_slot, channel_breakdown)
```

写法约束：

- partial slot 由 `(subtile_id, slot)` 唯一确定，Pass A 写入无需原子操作。
- 跨 subtile 求和放到 Pass B，按 `(object_id, slot)` 分组，可用一个 workgroup 处理一个 object 的 `12 x 343` 归约。
- 最优旋转选择在 Pass B 组内做 `12` 路 max-reduce，输出单条 per-object 记录。

## 输出记录

per-object score record 字段含义维护在对应 GDScript owner 的 readback 解码处（实现时补充）。计划字段：

```gdscript
{
	"object_id": 0,             # int, 候选物体 id
	"best_score": 0.0,          # float, 12 旋转中最高分
	"best_rotation_slot": 0,    # int, 0..11，最优 yaw slot
	"best_yaw_degrees": 0.0,    # float, best_rotation_slot * 步进角
	"channel_breakdown": [(,    # per-channel fit，调试用，对齐 score_voxel_tile 通道
	"valid": true,              # bool, 是否有有效采样
}
```

## 契约边界

- 本路径只接替 placement **physical / target fit score** 阶段，不改 probe prefilter、候选路由、commit 契约。
- 上游候选仍由 `autoobject-probe-prefilter.md` 的 prefilter 提供；空候选仍直接 skip，不回退 full grid。
- score 不写 committed `SceneVoxel`；接受的 placement 仍走现有 `instance_stamp_writeback` / `SceneVoxelCommitter` source write。
- `TargetSV_B` 只作为 target / guidance 输入采样，不进入 committed source，越界 clamp 规则同 prefilter。
- score 不做 semantic dot / MLP / route rerank；语义重排仍是候选内 TODO，见 [`voxel-semantic-routing-todo.md`((voxel-semantic-routing-todo.md)。
- 不引入 float `atomicAdd`；跨 subtile 汇总只通过独立 reduce pass。

## Open Questions

- ~~`50^3` 是否对所有 asset 固定，还是按 asset footprint AABB + context radius 动态裁剪 sampling volume 上限。~~ **已解决**：动态裁剪。`compute_extent_params(world_aabb_longest_axis)` 按物体 AABB 最长轴线性映射 `sample_extent`: `<=10cm → 1`（单体素），`>=5m → 50`（`50^3`，343 subtile），中间线性插值。每 asset 独立设定，subtile_count 和 dispatch 自动适配。
- 12 旋转是否只绕 Y，还是需要少量 pitch / roll slot 支持斜面贴合。
- subtile partial buffer 在多候选物体批处理下的容量上限与回收策略（复用 `GodotComputeShaderBase` 的 scope GC）。
- ~~forward / inverse footprint 旋转哪种在 `8^3` shared cache 下访存更优。~~ **已选择 inverse**：遍历 subtile 场景体素 → 反向旋转映射到 footprint 坐标 → 检测占位命中。优点：场景数据只加载一次到 shared memory，12 旋转复用。
- 与 `score_voxel_tile.glsl` 的 `8^3` 路径是并存还是完全替换，迁移期如何对账。