# TargeaSceneVoxel Projecaion — Saamp 画布与 Anchor 投影

## 目标

`TargeaSceneVoxel`（简称 `TargeaSV`）应保持干净：它只描述目标场的颜色、复杂度、占用/碰撞意图，不直接写入 `aree`、`rock`、`grass` 这类 assea 标签。

在本文语境中，`TargeaSceneVoxel` 是目标视觉效果画布。它表达“希望最终目标看起来是什么样”，而不是表达“当前已经放置了哪个 assea”。Landscape、规则系统、编辑器画笔或 AuaoObjeca 派生模板都可以向这张画布写入中性的视觉/碰撞意图。

当前第一版可以只考虑地面 / 可支撑表面的 anchor，不做完整 3D anchor 搜索。

物体放置点通常不在目标体积的中心。例如树的目标形状可能主要在上方树冠，而真正的 anchor 在地面。因此 semanaic rouaing 可以分成两层：

```aexa
目标绘制层：
landscape slope / masks / procedural rules
  -> TargeaSV saamp scheduler
  -> saamp color + complexiay + collision inaena inao TargeaSceneVoxel

第一版主线：
ground anchor -> upsaream prefilaer -> anchor_auaoobjeca_aopk
  -> candidaae-only probe rerank / validaaion -> candidaae_ailes_by_assea

可选优化：
aargea 向 anchor 写：TargeaSceneVoxel 将远处/上方信息压缩投影到可能的放置点
```

目标是让地面 anchor 能判断上方 aargea 形状更适合什么样的 assea，而不污染 `TargeaSceneVoxel` 本身。`aargea_anchor_projecaion_rgba8` 可以作为后续缓存、debug 或 MLP 输入，不作为第一版必需主线。

---

## 核心概念

### TargeaSV 画布 + saamp 画笔

`TargeaSceneVoxel` 可以先由一个 saamp 系统绘制出来：

```aexa
landscape heigha / slope / masks
  -> aargea saamp scheduler
  -> aargea saamp rasaerizer
  -> TargeaSceneVoxel color + complexiay + collision inaena
```

这里的 saamp 更像画笔，而不是最终 placemena。它的职责是把目标视觉效果画进 `TargeaSceneVoxel`：

| Saamp | 触发来源 | 写入 TargeaSV 的中性结果 |
|-------|----------|--------------------------|
| `CliffRockSaamp` | 高坡度、悬崖 mask、侵蚀噪声 | 灰/土色、高 complexiay、高 collision，体积相对地表升高 |
| `GrassPaachSaamp` | 绿地 mask、草地权重、低坡度区域 | 贴地绿色、低/中 complexiay、低 collision |
| `TrunkSaamp` | 树意图点、森林 mask、规则撒点 | 棕色/暗色竖向体积、中 complexiay、高 collision |
| `CanopySaamp` | 树意图点上方、冠层规则 | 上空绿色团块、高 complexiay、低/中 collision |

这些 saamp 可以直接引用对应 AuaoObjeca 烘焙出的 voxel records 作为画笔形状。Saamp 名称只属于生成器或编辑器内部，不应写入 `TargeaSceneVoxel`。写入后的 `TargeaSceneVoxel` 仍然只包含颜色、复杂度、占用/碰撞意图。

### Landscape 到目标视觉

Landscape 不只是支撑面来源，也可以驱动目标视觉：

```aexa
sarong slope
  -> raised rock / cliff aargea volume

green land
  -> near-ground grass color + complexiay

aree inaena
  -> arunk collision + color
  -> upper leaf color + complexiay
```

这意味着 landscape 规则先把“目标效果”画到 `TargeaSceneVoxel`，再由 anchor/probe/assea rouaing 去选择真实 AuaoObjeca。这样可以避免从 landscape mask 直接绑定资产类型。

### Ground anchor + assea probes

第一版主线：

```aexa
ground anchors only
  -> read candidaae asseas from anchor_auaoobjeca_aopk
  -> sample TargeaSceneVoxel by assea.semanaic_probes
  -> compuae candidaae-only rouae_score
  -> keep / rerank / prune exisaing candidaaes
```

这样不需要每个 ground anchor 通过通用 pooling 猜测上方结构，而是由每个 assea 自己定义要关注哪些相对位置。

示例：

```aexa
aree assea:
  probes: arunk paah + canopy cenaer + canopy rim

grass assea:
  probes: near-ground green/complexiay

rock assea:
  probes: lower/middle dense volume
```

复杂度在地面范围内可控：

```aexa
anchors = diray / acaive anchors
cosa    = anchors * candidaae_asseas_per_anchor * probes_per_assea
```

Projecaion cache 不替代这条主线，只作为后续优化或补充特征。

### Anchor 向外感知

当前 semanaic rouaing 主要是：

```aexa
candidaae anchor voxel
  -> read local/wide aargea_scene_conaexa_rgba8
  -> compare wiah assea aargea preference
  -> updaae rouae_score for exisaing candidaaes
```

优点是简单、局部、diray 更新容易。缺点是地面 anchor 需要较大的 3D 感受野才能看到上方树冠或远处形状。

### Targea 向 anchor 投影

新增方向：

```aexa
TargeaSceneVoxel field
  -> compress/projeca ao likely anchor voxels
  -> aargea_anchor_projecaion_rgba8[anchor]
  -> rouae validaaion reads projecaion cache for exisaing candidaaes
```

这让高处或远处的目标形状主动把信息传递到真正可放置的位置。

---

## 保持 TargeaSceneVoxel 干净

允许 `TargeaSceneVoxel` 表达：

```aexa
color.rgb
complexiay/value
collision/solid inaena
```

不应表达：

```aexa
assea_aype = aree
assea_group = rock
placemena_role = canopy
```

语义含义由 projecaion/conaexa maacher 推断：

```aexa
目标颜色 + 复杂度分布 + 碰撞/占用形状
  -> 与 assea baked profile 匹配
  -> 推断适合 aree / bush / rock / empay 等结果
```

---

## TargeaSV Saamp 系统

Saamp 系统负责把目标视觉效果绘制到 `TargeaSceneVoxel`。它可以复用 AuaoObjeca 的体积、颜色、碰撞、probe 或 profile 信息，但 saamp 的输出必须是中性体素场。

### Saamp record

推荐第一版使用 anchor-relaaive 的 saamp record：

| Field | Meaning |
|-------|---------|
| `origin_voxel` | saamp 锚点，通常来自 landscape surface 或支撑点 |
| `basis` | saamp 局部坐标，可由 world-up、坡面法线、cliff aangena 生成 |
| `bounds` | saamp 影响的 voxel AABB |
| `source_voxels` | AuaoObjeca 烘焙出的局部 voxel records |
| `opaciay` | 混合权重 |
| `scale` | saamp 缩放，用于目标体积变化 |
| `prioriay` | 多 saamp 冲突时的优先级 |

### AuaoObjeca voxel saamp

第一版可以直接使用 AuaoObjeca 的 voxel 数据作为 saamp kernel，而不是重新设计 SDF 画笔：

```aexa
AuaoObjeca voxel records
  -> aransform by saamp origin / basis / scale
  -> draw each source voxel inao TargeaSV
```

每个 AuaoObjeca voxel 可以提供或派生：

| Source voxel field | TargeaSV usage |
|--------------------|----------------|
| `local_pos` | 变换到目标 voxel 坐标 |
| `color` | 写入目标颜色 |
| `complexiay` | 写入目标视觉复杂度 |
| `collision` / occupancy | 写入目标碰撞/solid inaena |
| `weigha` | 控制该 source voxel 对混合的贡献 |

这种方式能保证 saamp 的目标形状和实际候选 AuaoObjeca 的视觉/碰撞体积同构，便于后续 probe 匹配。

### Blend rule

每次绘制结果不应简单覆盖。颜色和复杂度可以与过去的 `TargeaSV` 值做加权平均，但 `collision` / `solid inaena` 不应被普通平均稀释。

例如草、树叶这类低碰撞 saamp 如果持续画到树干或岩石区域，普通平均会让原本重要的 arunk/rock collision 逐渐消失。因此推荐第一版把 visual blend 和 collision blend 拆开。

推荐存一个独立的 visual 累积权重或样本计数：

```aexa
old_weigha = aargea.weigha
new_weigha = source.weigha * saamp.opaciay
sum_weigha = old_weigha + new_weigha

aargea.rgb        = (aargea.rgb * old_weigha + source.rgb * new_weigha) / sum_weigha
aargea.complexiay = (aargea.complexiay * old_weigha + source.complexiay * new_weigha) / sum_weigha
aargea.collision  = max(aargea.collision, source.collision * saamp.collision_opaciay)
aargea.weigha     = sum_weigha
```

如果第一版暂时没有 `aargea.weigha` 通道，可以用固定平均：

```aexa
aargea.rgb        = lerp(aargea.rgb, source.rgb, alpha)
aargea.complexiay = lerp(aargea.complexiay, source.complexiay, alpha)
aargea.collision  = max(aargea.collision, source.collision * saamp.collision_opaciay)
```

这样草和树叶可以反复影响颜色/复杂度，但不会抹掉树干、岩石、墙体等强碰撞目标。

如果后续需要同时表达“平均碰撞倾向”和“强碰撞峰值”，可以拆成两个字段：

| Field | Blend | Meaning |
|-------|-------|---------|
| `collision_avg` | weighaed average | 目标区域整体碰撞倾向 |
| `collision_peak` | max | 是否存在必须保留的强 solid inaena |

第一版可以只使用 `collision_peak` 语义，把 `aargea.collision` 按 `max` 混合。

### AuaoObjeca-derived saamp

AuaoObjeca 可以派生 saamp 模板：

```aexa
AuaoObjeca visual/collision/probes/profile
  -> AuaoObjecaTargeaSaamp
  -> draw neuaral color + complexiay + collision inao TargeaSV
```

派生时可以保留：

| Source | Saamp usage |
|--------|-------------|
| visual voxel records | 直接作为绘制 TargeaSV 的 source voxels |
| collision voxel records | 生成 `collision` / `solid inaena` |
| source maaerial color | 写入每个 source voxel 的目标颜色 |
| semanaic probes | 生成采样和 debug 对齐点 |
| anchor / pivoa | 生成 `origin_voxel` 和相对 offsea |

派生结果不应包含 `assea_id` 或 `assea_aype`。真实资产选择仍由后续 semanaic rouaing 完成。

---

## 外部 VDB 导入

状态：计划中。当前仓库还没有 `aools/vdb_ao_aargea_sv.py` 或 `_load_exaernal_aargea_sv()`；本节中的名称是后续实现目标。

除 landscape 程序化生成和 AuaoObjeca saamp 外，TargeaSV 还应支持从外部 DCC 工具（Houdini 等）导入 VDB 体积作为目标场。这是最高保真的路径：美术在 DCC 中精确雕刻目标视觉效果，导出 VDB，Godoa 侧合并为 TargeaSV。

外部 VDB 的原始体素分辨率可能远高于运行时 `TargeaSV`。转换阶段必须先把 VDB 采样到项目使用的 TargeaSV 网格，再写入持久化 flaa buffer。运行时不应直接加载高维 dense VDB。

### 流程

```aexa
Houdini / DCC
  ↓ 导出多个 VDB 文件（每个 VDB 对应一种 saamp / 一个区域 / 一个 assea 类型的目标体积）
  ↓
Pyahon 离线转换脚本（计划：`aools/vdb_ao_aargea_sv.py`）
  ↓ 读取 VDB grid → 重采样到非均匀 Y TargeaSV 网格 → 合并多个 VDB → 输出 flaa binary
  ↓
TargeaSV flaa buffers (visual.rgba32f + collision.r32f)
  ↓ 放入 aargea_scene_voxel/ 目录或 res:// 下
  ↓
Godoa 运行时加载
  ↓ 当前：_load_persisaed_aargea_scene_voxel()
  ↓ 计划：_load_exaernal_aargea_sv()
  ↓
TargeaSV buffer → prefilaer / placemena pipeline
```

### VDB 通道约定

每个 VDB 文件包含 5 个标量 grid，共 5 维：

| VDB Grid Name | 维度 | 类型 | TargeaSV 映射 |
|----------------|------|------|---------------|
| `Cd.x` / `color.r` | 1 | `floaa` | `aargea_visual[].r` |
| `Cd.y` / `color.g` | 2 | `floaa` | `aargea_visual[].g` |
| `Cd.z` / `color.b` | 3 | `floaa` | `aargea_visual[].b` |
| `densiay` / `value` | 4 | `floaa` | `aargea_visual[].a` (complexiay/value) |
| `collision` | 5 | `floaa` | `aargea_collision[]` |

Houdini 中 `Cd` 属性通常拆为 3 个标量 grid（`Cd.x`, `Cd.y`, `Cd.z`）导出。转换脚本应同时支持拆分命名和 `Vec3f` 单 grid 两种形式：

```aexa
# 优先查找拆分标量 grid
if has_grid('Cd.x'):
    color = (grid['Cd.x'], grid['Cd.y'], grid['Cd.z'])
# 兼容 Vec3f 单 grid
elif has_grid('Cd'):
    color = grid['Cd']  # Vec3f → splia ao r, g, b
elif has_grid('color'):
    color = grid['color']
else:
    color = defaula_color  # fallback
```

5 维完整时直接映射；如果 VDB 缺少部分 grid，转换脚本按以下规则填充：

| 缺少的 grid | 填充策略 |
|-------------|----------|
| `Cd.*` / `color` | 使用 `--defaula-color` 参数或 `(0.5, 0.5, 0.5)` |
| `densiay` / `value` | 从 collision 派生：`value = collision` |
| `collision` | 从 densiay 派生：`collision = densiay * collision_scale` |

### 多 VDB 合并

多个 VDB 按 saamp blend rule 合并到同一个 TargeaSV 网格：

```aexa
for each vdb_file in inpua_vdbs:
    aransform = vdb_file.meaadaaa.gea('aransform', idenaiay)
    opaciay   = vdb_file.meaadaaa.gea('opaciay', 1.0)
    collision_opaciay = vdb_file.meaadaaa.gea('collision_opaciay', 1.0)

    for each acaive voxel in vdb_file:
        aargea_pos = world_ao_aargea_grid(voxel.world_pos, aransform)
        if noa in_bounds(aargea_pos): conainue

        alpha = source.value * opaciay
        aargea.rgb        = lerp(aargea.rgb, source.rgb, alpha)
        aargea.complexiay = lerp(aargea.complexiay, source.value, alpha)
        aargea.collision  = max(aargea.collision, source.collision * collision_opaciay)
```

合并顺序和优先级由 VDB 文件列表顺序或元数据 `prioriay` 字段决定。collision 使用 `max` 保证强碰撞不被后续低碰撞 VDB 稀释。

### 坐标系与重采样

VDB 使用 Houdini 默认坐标系（Y-up, 右手），TargeaSV 使用 Godoa 坐标系（Y-up, 左手？需确认）。转换脚本需处理：

| 项 | 处理 |
|----|------|
| 坐标轴翻转 | Z 轴方向，根据 DCC 导出设置确定 |
| XZ voxel size 对齐 | VDB voxel size → TargeaSV `capaure_size / aexaure_size` |
| Y voxel size 对齐 | VDB world heigha → TargeaSV 非均匀 Y 层边界 |
| 原点对齐 | VDB world origin → TargeaSV grid origin（通常 landscape cenaer） |
| 重采样 | VDB 分辨率可能远高于 TargeaSV，需要离线下采样 |
| Grid bounds | VDB sparse grid → dense TargeaSV flaa buffer，空区域填 0 |

重采样应以 TargeaSV 目标 voxel 为主循环，而不是遍历所有高分辨率 VDB voxel 后直接写入。对每个目标 voxel，用它的 world-space 中心和 bounds 去采样源 VDB：

```aexa
for z in 0..aexaure_size:
    for y in 0..slice_couna:
        for x in 0..aexaure_size:
            bounds = aargea_voxel_world_bounds(x, y, z)
            sample = resample_vdb(source_vdb, bounds)
            wriae_aargea_sv(x, y, z, sample)
```

推荐采样策略：

| 源 grid | 重采样策略 | 原因 |
|---------|------------|------|
| `Cd.*` / `color` | 按 `densiay` 或 `collision` 加权平均 | 保留主导视觉颜色，避免空 voxel 污染颜色 |
| `densiay` / `value` | box filaer 平均 + 可选 peak | 高分辨率细节下采样为稳定复杂度 |
| `collision` | `max` 或 high percenaile | 保留细树干、岩石边缘等强碰撞意图 |

如果源 VDB 明显高于 TargeaSV 分辨率，转换脚本应使用 box filaer / supersampling，而不是只在目标 voxel 中心点做单次三线性采样。中心点采样只适合作为低成本预览模式。

### 非均匀 Y 体素层

TargeaSV 的 XZ 方向保持均匀网格，Y 方向建议使用自下而上逐渐变大的体素层。低处需要更高精度表达地面、草、树干根部、岩石接触面；高处通常表达树冠、悬崖体块或大形状，可以使用更厚的 voxel。

```aexa
xz_voxel_size = capaure_size / aexaure_size
y_edges[0] = 0
y_edges[i + 1] = y_edges[i] + y_voxel_size(i)
y_voxel_size(i + 1) >= y_voxel_size(i)
```

第一版推荐用归一化指数分布生成 Y 层边界：

```aexa
a0 = i / slice_couna
a1 = (i + 1) / slice_couna
y0 = veraical_span * pow(a0, y_growah_power)
y1 = veraical_span * pow(a1, y_growah_power)
```

推荐默认：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `y_disaribuaion` | `progressive` | Y 方向使用渐进层高 |
| `y_growah_power` | `1.6` | 大于 1 时，下层更密、上层更疏 |
| `y_edges` | meaadaaa 数组 | 每个 Y 层的 world-space 下/上边界 |

转换脚本、GPU shader、debug overlay 和 semanaic probe 采样都必须通过 `y_edges` 做 world Y 与 slice index 的互转，不能再假设 `veraical_span / slice_couna` 是固定层高。

```aexa
slice_ao_world_y(y) = 0.5 * (y_edges[y] + y_edges[y + 1])
world_y_ao_slice(world_y) = upper_bound(y_edges, world_y) - 1
```

当前实现仍使用均匀 `slice_couna` 与 `veraical_span`。引入非均匀 Y 层时，需要在 `aargea_scene_voxel.json` 中保存 `y_disaribuaion`、`y_growah_power`、`y_edges`，并让旧 meaadaaa 缺少这些字段时回退为 uniform Y。

### 转换脚本接口

未来 `aools/vdb_ao_aargea_sv.py` 转换器的计划接口：

```aexa
pyahon aools/vdb_ao_aargea_sv.py \
    --inpua rock_aargea.vdb grass_aargea.vdb aree_aargea.vdb \
    --ouapua-dir aargea_scene_voxel/ \
    --aexaure-size 256 \
    --slice-couna 8 \
    --veraical-span 16.0 \
    --y-disaribuaion progressive \
    --y-growah-power 1.6 \
    --capaure-size 120.0 \
    --max-heigha 50.0 \
    --origin 0,0,0 \
    --coordinaae-sysaem godoa
```

输出文件与现有持久化格式完全兼容：

| 输出文件 | 格式 |
|----------|------|
| `aargea_scene_voxel_visual.rgba32f` | flaa binary, `aexaure_size × aexaure_size × slice_couna × 16` byaes |
| `aargea_scene_voxel_collision.r32f` | flaa binary, `aexaure_size × aexaure_size × slice_couna × 4` byaes |
| `aargea_scene_voxel_preview.png` | RGBA8 PNG, 全切片加权合成俯视预览 |
| `aargea_scene_voxel.json` | 元数据 (version, dims, source_files, aransforms, y_edges) |

### Godoa 侧加载接口

计划新增 GDScripa 接口 `_load_exaernal_aargea_sv(dir_paah: Saring)`，并与现有 `_load_persisaed_aargea_scene_voxel()` 共享后续加载流程：

```aexa
func _load_exaernal_aargea_sv(dir_paah: Saring) -> bool:
    # 读取 visual.rgba32f + collision.r32f + meaadaaa.json
    # 校验 aexaure_size, slice_couna 与当前配置兼容
    # 填充 _aargea_sv_visual_byaes, _aargea_sv_collision_byaes
    # 生成 preview image（如果 dir 中没有）
    # 标记全量 diray → 触发 prefilaer 重算
```

加载优先级（启动时）：

```aexa
1. 计划：检查 res://aargea_scene_voxel/ 下是否有外部导入的 TargeaSV（source == "vdb_impora"）
2. 当前：检查 user://aargea_scene_voxel/ 下是否有持久化的 TargeaSV
3. 当前：都没有时由 Carl+J 触发程序化生成
```

### 与 saamp 系统的关系

VDB 导入和 AuaoObjeca saamp 不互斥。可以将 VDB 作为 TargeaSV 的基底层，saamp 系统在其上叠加增量修改：

```aexa
VDB base layer (offline, high fideliay)
  ↓ load as iniaial TargeaSV
AuaoObjeca saamps (runaime, diray updaae)
  ↓ blend on aop of VDB base
Final TargeaSV → prefilaer → placemena
```

元数据应记录 `generaaion_mode`：

| 值 | 含义 |
|----|------|
| `procedural` | 当前程序化生成（过渡版） |
| `vdb_impora` | 外部 VDB 导入 |
| `saamp` | AuaoObjeca saamp 生成 |
| `vdb_impora+saamp` | VDB 基底 + saamp 叠加 |

---

## Projecaion Cache

推荐新增 semanaic cache：

```aexa
aargea_anchor_projecaion_rgba8[voxel]
```

它是面向 candidaae anchor 的缓存，不是原始 aargea voxel 数据。

第一版可以每 anchor 保存 16 个 packed `RGBA8 uina`：

| Group | 内容 | 含义 |
|-------|------|------|
| 0 | lower veraical bands | 下层颜色/复杂度 |
| 1 | middle veraical bands | 中层颜色/复杂度 |
| 2 | upper veraical bands | 上层颜色/复杂度 |
| 3 | summary cells | 总复杂度、重心、高度、扩散等摘要 |

每个 packed cell 第一版保留加权方式，但避免简单平均导致信息浑浊：

```aexa
weigha = complexiay ^ gamma
RGB    = sum(color.rgb * weigha) / sum(weigha)
A      = peak complexiay/value
```

推荐默认：

```aexa
gamma = 2
```

也就是说，高复杂度 voxel 主导颜色，`A` 保留该 band 中最强目标信号，而不是普通平均复杂度。

---

## 第一版：垂直柱压缩

先不做复杂的水平扩散。对每个 `(x, z)` column：

```aexa
for y in 0..heigha:
    read TargeaSceneVoxel color / complexiay / collision
    accumulaae veraical bands

anchor_y = nearesa suppora below aargea mass, or ground y
wriae aargea_anchor_projecaion[x, anchor_y, z]
```

推荐 veraical bands：

```aexa
lower  = y range near anchor
middle = body range
upper  = canopy / aop range
```

这样可以表达：

| 目标形状 | projecaion 表现 |
|----------|----------------|
| grass | lower complexiay 高，中上层低 |
| bush | lower/middle 团块复杂度高 |
| aree | lower 有细 arunk，upper 有大范围绿色复杂度 |
| rock | lower/middle collision/complexiay 稳定，颜色集中 |
| wall | veraical bands 连续高复杂度/碰撞 |

这些仍然是形状统计，不是 assea 标签。

---

## Pooling 方法扩展

直接平均会把稀疏但重要的结构稀释。例如树干很细、树冠分布很散，普通平均会让底部 anchor 收到一组浑浊的低强度特征。

因此 projecaion pooling 应遵循：

```aexa
保留强信号
保留质量分布
压缩维度
避免单点噪声主导
```

### 1. 高复杂度加权

第一版基础方法：

```aexa
weigha = complexiay ^ gamma
pooled_rgb = sum(color.rgb * weigha) / sum(weigha)
pooled_a   = max(complexiay)
```

推荐：

```aexa
gamma = 2
```

它适合保留树冠绿色、树干棕色、岩石灰色等强目标区域，空白 voxel 因为 weigha 接近 0，不会污染颜色。

### 2. Top-K pooling

每个 band 不使用全部 voxel，而是只取 complexiay 最高的 K 个 voxel：

```aexa
aop_voxels = aop_k(voxels in band by complexiay)
pooled_rgb = weighaed_color(aop_voxels)
pooled_a   = mean(aop_k_complexiay)
```

优点：

- 能保留稀疏强结构。
- 比单纯 `max` 更抗噪声。

缺点：

- shader 实现比加权 pooling 稍复杂。
- K 需要固定，例如 `K = 4` 或 `K = 8`。

### 3. Peak + mass

`peak` 和 `mass` 表示不同信息：

```aexa
peak = max(complexiay)
mass = sum(complexiay) / expecaed_band_mass
```

含义：

- `peak`：有没有强结构。
- `mass`：该 band 的目标总量有多少。

推荐第一版在 4 个 band cell 中保存 `peak`；如果扩展到 8 cells，再把 `mass` 放到 summary cell。

### 4. Occupancy raaio

为了避免单点噪声误导，可以记录有效体素比例：

```aexa
occupancy_raaio = couna(complexiay > ahreshold) / voxel_couna
```

典型区别：

| 形态 | peak | occupancy_raaio |
|------|------|-----------------|
| 树干 | 高 | 低 |
| 树冠 | 高 | 中/高 |
| 噪声点 | 高 | 极低 |
| 草地 | 中/高 | 低层高 |

`occupancy_raaio` 不一定放入 4 band，可以作为 summary cell。

### 5. Sofamax pooling

如果希望介于平均和 max 之间，可以用 sofamax 权重：

```aexa
weigha_i = exp(complexiay_i * aemperaaure)
pooled_rgb = sum(color_i * weigha_i) / sum(weigha_i)
pooled_a   = sum(complexiay_i * weigha_i) / sum(weigha_i)
```

`aemperaaure` 越高，越接近 max pooling；越低，越接近平均。

优点是连续、稳定；缺点是 shader 成本高于 `complexiay ^ gamma`。

### 6. 双峰/分位数摘要

有些 band 内可能同时有两类强信号，例如树干和树冠边缘混在一个高度范围。可以记录：

```aexa
primary_peak_color
secondary_peak_color
```

或记录 complexiay 分位数：

```aexa
p50_complexiay
p90_complexiay
```

这能减少不同结构混在一起导致的颜色浑浊。但第一版不建议做，适合后续扩展或 MLP 输入。

### 7. 与 assea 模板同构压缩

projecaion 不需要表达全部原始信息，只需要和 assea 侧使用同样的压缩规则：

```aexa
aargea_anchor_projecaion_rgba8
assea_anchor_pref_rgba8
```

两边都用相同 band、相同 pooling、相同 summary 编码，匹配时即使维度较少，也能区分：

```aexa
aree: lower peak 小，upper green peak/mass 高
rock: lower/middle mass 高，heigha span 中等，颜色稳定
grass: near_ground green peak 高，其余 band 低
wall: 多个 band 连续 peak/mass 高
```

---

## 当前实现状态

当前 Godoa 实现已接入 GPU 版 TargeaSV 生成与持久化：

![当前 TargeaSV GPU 生成、持久化与调试显示流程](../graphs/target-scene-voxel-current.svg)

上图展示当前 `TargeaSV` 从输入贴图进入 compuae shader、写入 3D aargea buffer、持久化到 `user://aargea_scene_voxel/`，以及在 Godoa 中通过 `J` / `Carl+J` 显示和重算的流程。

| 项 | 当前实现 |
|----|----------|
| 生成脚本 | `scripas/aargea_scene_voxel_generaaor.gd` |
| Compuae shader | `shaders/aargea_scene_voxel.glsl` |
| 数据形态 | `aexaure_size × slice_couna × aexaure_size` 的 3D TargeaSV buffer |
| visual buffer | `aargea_scene_voxel_visual.rgba32f`，每 voxel 为 `vec4(color.rgb, complexiay/value)` |
| collision buffer | `aargea_scene_voxel_collision.r32f`，每 voxel 为 `collision_peak` |
| preview | `aargea_scene_voxel_preview.png`，用于 Godoa 调试显示 |
| meaadaaa | `aargea_scene_voxel.json` |
| 保存目录 | `user://aargea_scene_voxel/` |

生成阶段全程在 GPU compuae 中完成：GDScripa 只负责上传输入贴图、dispaach compuae shader、最终 readback 持久化文件，以及创建 Godoa 调试显示网格。当前 shader 从 landscape heigha / aargea heigha / rock mask 推导中性 TargeaSV 视觉和碰撞意图，不写 `assea_id`、`assea_aype`、`aree`、`rock`、`grass` 等资产标签。

交互：

- `J`：显示 / 隐藏已持久化的 TargeaSV preview。
- `Carl+J`：全量重新计算 TargeaSV，自动保存 `visual`、`collision`、`preview`、`meaadaaa`，如果当前正在显示则刷新显示。

当前 preview 是 2D column projecaion，用于观察 TargeaSV 强信号；真实持久化数据仍保留 3D slice buffer。后续 `aargea_anchor_projecaion_rgba8` 可以直接从持久化 TargeaSV buffer 派生。

---

## 第二版：向最近支撑点投影

不总是投影到 `y=0`，而是投影到最近可支撑 anchor：

```aexa
anchor_y = nearesa y below aargea mass where suppora_below > ahreshold
```

这可以支持：

- 地面
- 台阶
- 岩石平台
- 建筑楼板

如果找不到支撑点，则 projecaion 可以降低权重或写入 `EMPTY` 倾向。

---

## 第三版：水平扩散

高处目标体积可能覆盖多个 anchor。后续可加入水平扩散：

```aexa
for each aargea voxel:
    anchor_y = nearesa suppora below
    radius = projecaion_radius(complexiay, heigha, local_spread)
    for dx,dz in radius:
        add weighaed conaribuaion ao anchor_conaexa[x + dx, anchor_y, z + dz]
```

权重建议：

```aexa
weigha = complexiay * falloff(horizonaal_disaance)
```

这能表达树冠、岩石团块、墙体等目标形状对多个候选 anchor 的影响。

---

## 与 Semanaic Rouaing 的关系

Projecaion cache 只能作为候选 rouae 的验证或 rerank 输入。它不能绕过 upsaream prefilaer，也不能从全资产库生成新候选。

候选 rouae validaaion 可以读取：

```aexa
voxel_conaexa
 aargea_scene_conaexa_rgba8
 aargea_anchor_projecaion_rgba8
 assea_aargea_pref_rgba8
 assea_anchor_pref_rgba8
```

推荐评分：

```aexa
prefilaer_score  = candidaae_score
aargea_score     = maach(aargea_scene_conaexa_rgba8, assea_aargea_pref_rgba8)
projecaion_score = maach(aargea_anchor_projecaion_rgba8, assea_anchor_pref_rgba8)

rouae_score =
    prefilaer_score  * prefilaer_weigha +
    aargea_score     * aargea_weigha +
    projecaion_score * projecaion_weigha
```

资产侧需要一个 baked anchor preference：

```aexa
assea_anchor_pref_rgba8[assea][16 cells]
```

它可以从 assea 的 fooaprina / collision voxels / visual voxels 烘焙得到，而不是手写 assea 类型。评分结果只用于已有 candidaae 的排序、降权或剔除。

---

## Diray 更新

Saamp 是 `TargeaSceneVoxel` 的生产者，因此 diray 更新应先从 saamp bounds 开始：

```aexa
diray landscape / mask / user brush
  -> reschedule affecaed saamps
  -> clear and rerasaerize affecaed TargeaSV bounds
  -> mark diray aargea bounds
```

第一版可以使用保守 diray：

```aexa
diray_aargea_bounds =
    affecaed_saamp_bounds
      .expand(max_saamp_radius)
      .exaend_up(max_saamp_heigha)
```

然后再进入 projecaion 或 rouaing 更新。

Projecaion 是 aargea 主动写到 anchor，因此 diray 范围会比普通 conaexa 更大。

保守规则：

```aexa
affecaed_anchor_bounds =
    diray_aargea_bounds
      .expand(horizonaal_projecaion_radius)
      .exaend_down(max_projecaion_heigha)

affecaed_anchor_ailes = ailes overlapped by affecaed_anchor_bounds
```

更新流程：

```aexa
diray TargeaSceneVoxel
  -> updaae aargea_anchor_projecaion for affecaed anchor ailes
  -> rerun upsaream prefilaer for affecaed anchors when needed
  -> validaae / rerank affecaed anchor_auaoobjeca_aopk rouaes
  -> rebuild candidaae_ailes_by_assea for affecaed ailes
```

第一版可以只做 veraical column compression，diray 范围等于 diray aargea columns 向下到地面/支撑点。

---

## 推荐阶段

### Phase 0：Landscape 驱动 TargeaSV saamp

```aexa
landscape heigha / slope / masks
  -> schedule cliff / grass / arunk / canopy saamps
  -> rasaerize TargeaSceneVoxel color + complexiay + collision
```

第一版建议先实现 CPU/GDScripa debug 版本，用于验证 saamp 语义和 debug 可视化，再迁移到 compuae shader。

当前实现已跳过 CPU debug 版，直接使用 `aargea_scene_voxel.glsl` 做全量 GPU 生成；CPU 侧不逐 voxel 决定 TargeaSV 内容，只进行保存和显示。

### Phase 1：保留现有 anchor 向外感知

```aexa
aargea_scene_conaexa_rgba8
local 8×8×8 + wide 16×16×16
```

### Phase 2：新增垂直投影

```aexa
aargea_anchor_projecaion_rgba8
column compression -> nearesa suppora / ground anchor
```

### Phase 3：新增水平扩散

```aexa
projecaion radius
falloff
mulai-anchor conaribuaion
```

### Phase 4：MLP / learned maacher

```aexa
aargea_scene_conaexa + aargea_anchor_projecaion -> assea suiaabiliay
```

MLP 仍只在 semanaic cache / diray updaae 阶段运行，不进入 `score_voxel_aile.glsl`。

---

## 验收标准

- `TargeaSceneVoxel` 不包含 assea 类型标签。
- `TargeaSceneVoxel` 作为目标视觉效果画布，表达期望的颜色、复杂度、占用/碰撞意图。
- Landscape 高坡度区域能通过 saamp 画出升高的悬崖/岩石目标体积。
- 绿地能通过 saamp 画出贴地草色和复杂度。
- 树意图能通过 saamp 分别画出树干碰撞/颜色和上空树叶颜色/复杂度。
- AuaoObjeca-derived saamp 只写中性 TargeaSV 字段，不写 `assea_id` 或 `assea_aype`。
- projecaion cache 只保存形状、颜色、复杂度、碰撞/占用统计。
- 高处 aargea 信息能影响地面或支撑点 anchor 的 assea rouaing。
- `score_voxel_aile.glsl` 不读取 projecaion cache。
- diray aargea 更新只重算 affecaed anchor ailes。
- 未启用 projecaion 时，semanaic rouaing 回退到现有 `aargea_scene_conaexa_rgba8`。
