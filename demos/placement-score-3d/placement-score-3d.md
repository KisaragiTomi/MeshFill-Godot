# MeshFill 3D Object Volume Score：单物体体积采样评分

本文记录 3D placement score 阶段的设计契约：对单个候选物体，先按 asset footprint 预烘每个旋转角度的有效 sample records，再围绕 anchor 采样 `SV` 与 `TargetSV_B` 内容并评分。每个旋转槽只访问该槽实际会命中 footprint 的 sample，单槽 sample 数按 asset 尺寸裁剪并硬性限制在 `32^3` 以内。

> 状态：**已合并进生产放置管线（in-shader 旋转方案）**。3D 体积评分不再走独立两遍管线，而是并入 `VoxelPlacementGenerator` 的评分阶段：`shaders/score_voxel_tile.glsl` 现对每个候选原点在 shader 内扫 `rotation_slots`（默认 12）个 yaw，逐一用其完整物理模型（clearance/solid + runtime same-type avoidance + candidate route）评分并取最优槽写入 tile_topk 记录；`shaders/stamp_voxel_field.glsl` 按记录里的最优槽旋转 footprint 盖章；旋转经现有 record→`results_to_world_gpu`→实例 yaw 以同一 Godot `Basis(UP,θ)` 约定一致贯通，reduce 原样复用。生产路径（SPA → `run_multi_asset`）已在编辑器 Vulkan 下验证。
>
> 原独立两遍 demo 管线 `scripts/object_volume_score_gpu.gd`（`score_object_subtile.glsl` + `reduce_object_rotation_scores.glsl`）已**退役删除**，其评分并入 `VoxelPlacementGenerator`（VPG）。
>
> **当前实现：`demos/placement-score-3d/volume_score_demo.gd` 是一个 volume-score provider**，向同场景兄弟 `CoreSPADemo`（ScenePlacementActor）`register_volume_score_provider` 注册，接管编辑器工具栏「Anchors」「Score」按钮与 Anchor 模式点选：
> - **Anchors**：`VolumeScore3D.generate_anchors` 在场景场表面按 `anchor_spacing`（默认 = VPG `TILE_SIZE` = 8，1 锚点/tile）铺锚点。
> - **Score**：对每个 `AssetDescriptor` 资产用 `VPG.run_minimal`（`candidate_voxel_sparses` = 锚点所属 tile、`read_tile_topk`、in-shader 12 旋转）评分，读回每 tile 最佳 `{voxel, score, rotation}` 记录映射回锚点，得每锚点 × 每资产的 top-k 排名；点选锚点显示其排名与最优朝向。
> - 退役的 `ObjectVolumeScoreGpu.*`（build_anchor_asset_topk / best_asset_per_anchor / …）已在 provider 内以纯数据函数就地重写，不复活两遍管线。
>
> **放置的物体（每锚点胜出资产）一律实例化真实 `AssetDescriptor` 的 mesh（`get_mesh()`），绝不用占位方盒子**（见项目 `CLAUDE.md`「Placement / Score Demos: Render Real AssetDescriptor Assets」）：资产在 `.tscn` 里以 `ext_resource` 挂到 `@export Array[AssetDescriptor] placement_assets`（默认 `assets/vegetation/sm_test_leaf_test2_asset.tres`）；footprint（评分用）按 mesh AABB 比例导出，展示则把 mesh 缩放贴合 footprint、按最优 yaw 旋转、底面贴地。`AssetDescriptor` 已标 `@tool`，其 `get_mesh()` 等方法方能在编辑器 @tool demo 里运行。
>
> 同场景 `CoreSPADemo` 以 `spawn_autoobjects_on_start = false` 关闭默认 65536 autoobject 批量 spawn（该 provider 场景不需要 autoobject）；`selection_mode = 3`（Anchor）使锚点点选开箱即用。
>
> ⚠️ 下文「数据流 / Dispatch 布局 / Sample Record 预烘 / 12 旋转评分 / Reduce 汇总 / 输出记录」等章节描述的是**已删除的两遍原型设计**，仅作历史参考；当前实现见 `shaders/score_voxel_tile.glsl` 的 in-shader 旋转与 `scripts/voxel_placement_generator.gd`。

2.5D heightfield 路径已废弃移除。3D 路径只接替「物理 score」阶段，上游 probe prefilter 与候选路由契约不变。

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
| `rotation sample set` | 单个 asset 在某个 yaw slot 下实际会命中 footprint 的有效 sample records。 |
| `sample group` | `rotation sample set` 内的 512 条 sample records，一个 workgroup 拥有一个 group。 |
| `rotation slot` | 12 个待评测旋转角度之一；默认绕 Y 轴 yaw，步进 `30°`。 |

## 设计常量

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `MAX_VARIANT_AXIS` | `32` | 单轴 variant 估算上限。 |
| `MAX_VARIANTS_PER_ROTATION` | `32^3` | 每个 rotation slot 的有效 sample record 上限。 |
| `MIN_SAMPLE_EXTENT` | `1` | 极小物体 (<=10cm) 单体素检测。 |
| `OBJECT_SAMPLE_EXTENT` | **动态** | 调试/显示字段；真实评分使用 per-rotation 有效 sample records。 |
| `SAMPLE_GROUP_SIZE` | `8^3 = 512` | 一个 workgroup 处理的 sample record 数；对齐 `local_size`。 |
| `SAMPLE_GROUP_COUNT` | **动态** | `ceil(max_rotation_sample_count / 512)`；最大 `64`。 |
| `ROTATION_SLOTS` | `12` | 一次评测的旋转角度数。 |
| `LOCAL_SIZE` | `8 x 8 x 8 = 512` | 每个 sample-group workgroup 的线程数。 |

`ROTATION_SLOTS` / yaw 轴向通过 push constant 和 CPU 预烘 sample records 传入 shader。每 asset dispatch 使用独立的 sample group 参数。

## 数据流

```text
candidate object (anchor voxel + asset footprint + descriptor)
  -> CPU prebake valid sample records per rotation slot, capped to 32^3
  -> dispatch SAMPLE_GROUP_COUNT workgroups, one per 512 sample records
  -> Pass A: score_object_subtile.glsl
       for each of 12 rotation slots: sample only valid records for that slot
       write per-(sample_group, rotation) partial record
  -> barrier
  -> Pass B: reduce_object_rotation_scores.glsl
       sum sample-group partials per rotation slot
       pick best rotation slot for this object
  -> per-object score record (best score + best rotation + per-channel breakdown)
  -> feed into existing accepted-placement / commit path
```

每个候选物体对应一组 `SAMPLE_GROUP_COUNT` workgroups。多候选物体批处理时，dispatch 在 X 轴堆叠 sample group、用 `gl_WorkGroupID.y`（或 push constant base offset）选择候选物体，避免每物体单独提交。

## Dispatch 布局

| 维度 | 映射 | 说明 |
| --- | --- | --- |
| `gl_WorkGroupID.x` | sample group id | 每组 512 条预烘 sample records。 |
| `gl_WorkGroupID.y` | 候选物体 id | 批处理多个候选物体；单物体时为 `1`。 |
| `gl_LocalInvocationID.xyz` | group 内 sample lane `(8,8,8)` | 每线程负责一条 sample record。 |

sample 坐标解码：

```text
sample_index   = group_id * 512 + local_index
sample_record  = rotation_records[rotation_slot][sample_index]   # vec4: xyz=连续场景体素偏移, w=float(footprint props 索引)
sample_pos     = anchor + sample_record.xyz                      # 连续坐标，不取整到体素中心
# 在 sample_pos 处对 SV / TargetSV_B 做 8 邻三线性插值采样
```

三线性采样的 8 个邻居体素中，越界角点（`< 0` 或 `>= grid`）权重计 0，再按命中权重和 `wsum` 归一化，因此贴边 sample 不会被网格边缘错误变暗；整条 sample 仅在 8 邻全部越界（`wsum == 0`）时跳过，与 prefilter 越界规则一致。

## Sample Record 预烘

核心观察：**有效采样集合与 asset 旋转有关**。因此 CPU 侧对每个 asset footprint 预烘 `ROTATION_SLOTS` 份 sample records：

```text
# GPU 采样记录（frac_records）：连续偏移，供 8 邻三线性插值采样
sample_record = vec4(rotated_frac_offset.xyz, float(footprint_props_index))
# 整数记录（records）：上面偏移的量化版（x/z round、y floor），仅供 CPU 算 bounds 与去重键
```

每个 rotation slot 的 sample 取自 descriptor `voxel_profile.collision` 的体素位置（每个 occupied footprint voxel 烘成一条 collision sample），逐点做 局部体素 → 世界（`aabb_min + (coord+0.5)·cell_size`，相对 `pivot_local` 并按 yaw 旋转）→ ÷ 场景 `voxel_size` = 场景体素偏移。`voxel_profile.collision` 是唯一采样来源——缺失或无点采样时该 asset 视为无有效采样（`no_profile_samples`），不再维护或回退稠密 occupancy 网格。按旋转后的 offset 去重；如果某个 slot 的 sample 数超过 `32^3`，按稳定步长抽样保留覆盖。GPU Pass A 只读取这些 sample records，并对 scene 越界 sample 做 guard skip。

## 12 旋转评分

每个 workgroup 对 12 个 rotation slot 各算一份 partial：

```text
for slot in 0..11:
    yaw = slot * (360 / ROTATION_SLOTS)   # 默认 30° 步进
    partial[slot] = 0
    for each sample_record in sample_group:
        sample_pos = anchor + sample_record.xyz          # 连续坐标
        (s, t, wsum) = trilinear_sample(SV, TargetSV_B, sample_pos)
        if wsum > 0:                                     # 至少一个邻居在网格内
            partial[slot] += weighted_fit(asset, s, t)   # 采样值已按 wsum 归一化
```

`weighted_fit` 复用现有物理 + target fit 维度：target coverage、complexity fit、color fit、solid collision、clearance。具体权重沿用 `score_voxel_tile.glsl` 当前语义，本文不重新定义权重默认值。

footprint 旋转使用 forward 预烘：遍历 asset footprint voxel，按 yaw 旋转后写入 scene-relative sample offset。

## Reduce 汇总

Pass A 每个 workgroup 输出一条 partial 记录：`SAMPLE_GROUP_COUNT x ROTATION_SLOTS` 个 partial。

汇总避免 float `atomicAdd`，改用独立 reduce pass：

```text
partial_buffer[object_id][sample_group_id][slot]   # Pass A 写，slot 独占，无竞争
  -> reduce_object_rotation_scores.glsl
       每个 (object_id, slot) 求和 sample-group partial
       得到 object_rotation_score[object_id][slot]
  -> 组内比较 12 个 slot，选最大值
  -> object_score_record[object_id] = (best_score, best_slot, channel_breakdown)
```

写法约束：

- partial slot 由 `(sample_group_id, slot)` 唯一确定，Pass A 写入无需原子操作。
- 跨 sample group 求和放到 Pass B，按 `(object_id, slot)` 分组，可用一个 workgroup 处理一个 object 的 `12 x SAMPLE_GROUP_COUNT` 归约。
- 最优旋转选择在 Pass B 组内做 `12` 路 max-reduce，输出单条 per-object 记录。

## 输出记录

per-object score record 字段含义维护在对应 GDScript owner 的 readback 解码处（实现时补充）。计划字段：

```gdscript
{
	"object_id": 0,             # int, 候选物体 id
	"best_score": 0.0,          # float, 12 旋转中最高分
	"best_rotation_slot": 0,    # int, 0..11，最优 yaw slot
	"best_yaw_degrees": 0.0,    # float, best_rotation_slot * 步进角
	"channel_breakdown": [],    # per-channel fit，调试用，对齐 score_voxel_tile 通道
	"valid": true,              # bool, 是否有有效采样
}
```

## 契约边界

- 本路径只接替 placement **physical / target fit score** 阶段，不改 probe prefilter、候选路由、commit 契约。
- 上游候选仍由 `autoobject-probe-prefilter.md` 的 prefilter 提供；空候选仍直接 skip，不回退 full grid。
- score 不写 committed `SceneVoxel`；接受的 placement 由 VPG state-chain stamp 原位提交（`instance_stamp_writeback.accepted_placement_writeback_mode == "gpu_state_chain_stamp"`）。
- `TargetSV_B` 只作为 target / guidance 输入采样，不进入 committed source，越界 clamp 规则同 prefilter。
- score 不做 semantic dot / MLP / route rerank；语义重排仍是候选内 TODO。
- 不引入 float `atomicAdd`；跨 sample group 汇总只通过独立 reduce pass。

## Open Questions

- ~~是否对所有 asset 固定采样窗口。~~ **已解决**：每个 asset 按 occupied footprint 预烘 per-rotation sample records，单槽最多 `32^3` 条；GPU dispatch 使用实际 sample group count。
- 12 旋转是否只绕 Y，还是需要少量 pitch / roll slot 支持斜面贴合。
- sample-group partial buffer 在多候选物体批处理下的容量上限与回收策略（复用 `GodotComputeShaderBase` 的 scope GC）。
- ~~forward / inverse footprint 旋转哪种更适合当前路径。~~ **已选择 forward 预烘**：CPU 遍历 occupied footprint voxel → 按 yaw 旋转成 scene-relative sample offset → GPU 只采样有效 records。
- ~~与 `score_voxel_tile.glsl` 的 `8^3` 路径是并存还是完全替换，迁移期如何对账。~~ **已解决**：完全替换——`score_voxel_tile.glsl` 演化为 in-shader 12 旋转体积评分，成为唯一评分器；独立两遍管线取代待退役。
