# 双重 RID 漏洞：Committed Payload Buffer 释放-分配竞态

> 对应 `GPU_BUFFER_LIFECYCLE.md` L603 风险条目 3
>
> 分析日期：2026-06-07  
> 修复日期：2026-06-08（方案 A：原地复用）

---

## 一句话总结

`_release_committed_scene_voxel_payload_buffer()` 先调用 `release_rid()` 释放旧 GPU Buffer，然后**无条件**将成员变量清零。但 `release_rid()` 是 `void` 函数，调用方无法感知释放是否真的成功。如果释放静默失败，紧接着的 `storage_buffer_zero()` 会分配一个新 RID，此时一个逻辑 Buffer 同时占用了**两个 GPU 分配**。

---

## 涉及的函数栈

```
                                        godot_compute_shader_base.gd
scene_voxel_committer.gd                ─────────────────────────────
─────────────────────
_release_committed_scene_voxel_payload_buffer()
  ├─ release_rid(old_rid, false)      → release_rid()               [L207]
  │    ├─ _is_valid_rid？┄┄┄ 是 → 跳过       ├─ 在 _resources 中？  ├─ 是 → _free_entry()
  │    ├─ defer ？┄┄ false → 跳过             │                    │     ├─ _rd.free_rid(rid)
  │    └─ 在 _resources 中？                  │                    │     └─ 标记 alive=false
  │         ├─ 是 → _free_entry()              │                    └─ 否 → _rd.free_rid(rid)
  │         └─ 否 → _rd.free_rid(rid)          └─ return void ← 永远无返回值！
  ├─ _committed_scene_voxel_payload_buffer = RID()   ← 无条件清零
  └─ 清零 count / byte_count / tick / source

_try_resolve_scene_voxel_source_candidates_gpu()   ← 唯一高危路径
  ├─ _release_committed_scene_voxel_payload_buffer()   ← 释放旧 RID
  ├─ storage_buffer_zero(...)                          ← 创建新 RID
  └─ _committed_scene_voxel_payload_buffer = new_rid   ← 指向新 RID
```

---

## 正常路径 vs 失败路径

### 正常路径（释放成功）

```
时间线:   T0              T1              T2              T3
         │               │               │               │
成员变量: old_rid ──────→ RID() ────────→ RID() ────────→ new_rid
         │               │               │               │
GPU侧:   旧 Buffer 存活 ──→ 已释放 ───────→ (无) ─────────→ 新 Buffer
         │               │               │               │
引用计数: 1              0              0              1
```

### 失败路径（释放静默失败）

`release_rid()` 为 `void`，调用者**完全不知道**释放是否成功。一旦失败：

```
时间线:   T0              T1              T2              T3
         │               │               │               │
成员变量: old_rid ──────→ RID() ────────→ RID() ────────→ new_rid
         │               │               │               │
GPU侧:   旧 Buffer 存活 ──→ 旧 Buffer 仍存活！→ 旧 Buffer 仍存活！→ 新 Buffer
         │               │               │               │
引用计数: 1              1 ← 泄漏        1 ← 泄漏        2 ← 双重 RID
```

**此时：**
- `old_rid` 仍然占用 GPU 显存，但成员变量已经指向 `RID()`，再也找不到它 → **内存泄漏**
- `new_rid` 是新分配的 GPU Buffer → **重复分配**
- 一个逻辑角色（committed payload）对应两个物理 GPU Buffer → **双重 RID**

---

## 为什么 `release_rid` 会静默失败？

`release_rid()` 的设计决定了它永远是 `void`：

```gdscript
func release_rid(rid: RID, defer_if_busy: bool = true) -> void:
    if not _is_valid_rid(rid):
        return                              # 失败1: 无效 RID
    if _compute_list_active and defer_if_busy:
        ...                                 # 失败2: 延迟到后续帧释放（不是真的失败，但语义上"还没释放"）
        return
    for entry in _resources:
        if ... rid == rid:
            _free_entry(entry)
            return
    if _rd != null:
        _rd.free_rid(rid)                   # 失败3: _rd 已销毁，这行不会执行
                                            # 失败4: RID 不在 _resources 也不归 _rd 管，无声跳过
```

四种"释放未执行"的场景，全部被 `void` 返回值和 `return` 语句吞掉，无一产生 error 信号。

### 最危险的失败路径：RID 不在 `_resources` 中

```gdscript
for entry in _resources:           # 遍历内部跟踪列表
    if entry["rid"] == rid:
        _free_entry(entry)         # 找到了 → 释放
        return
# 没找到 → 走兜底
if _rd != null:
    _rd.free_rid(rid)              # ❓ _rd 可能为 null
# 如果 _rd == null，什么也不做，函数静默返回
```

Commit Payload Buffer 分配在 `SCOPE_PERSISTENT`，理论上已在 `_resources` 中被跟踪。但如果 `_compact_dead_resources()` 提前清理了该条目，或 RID 从未被正确 `track_rid()`，这个循环就不会找到它，然后走 `_rd.free_rid(rid)` 兜底。如果此时 `_rd` 恰好已销毁（例如 node 已从场景树移除），**最后一个释放机会也丢失了**。

---

## 四个调用点的风险对比

| 调用点 | 行号 | 所在函数 | 之后是否分配新 RID | 双重 RID 风险 | 泄漏风险 |
|--------|------|----------|-------------------|:---:|:---:|
| 1 | L563 | `_on_before_dispose()` | 否 | 无 | 有 |
| 2 | L5616 | `_clear_scene_voxel_source_streams()` | 间接（后续 commit 时） | 低 | 有 |
| 3 | ~~L6310~~ | `_try_resolve_scene_voxel_source_candidates_gpu()` | ~~是~~ → 已修复 | ~~高~~ → 已消除 | ~~有~~ → 已消除 |
| 4 | L7790 | `blend_scene_voxels()` resolve blocked | 否 | 无 | 有 |

---

## 已实施的修复：方案 A — 原地复用

### 思路

当 `output_byte_count` 与上次相同时，不释放旧 buffer，直接用 `_rd.buffer_update()` 清零复用。只在大小变化（或复用失败）时才走"释放 + 重新分配"路径。

### 修复前（高危路径）

```gdscript
_release_committed_scene_voxel_payload_buffer()                          # 释放（可能失败）
var committed_payload_buffer := storage_buffer_zero(...)                  # 立即分配新 RID
# → 失败时双重 RID + 泄漏
```

### 修复后（`scene_voxel_committer.gd` L6307-L6325）

```gdscript
var output_float_stride := SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE
var output_byte_count := source_key_count * output_float_stride * 4

var committed_payload_buffer: RID
var committed_payload_reused := false

if _committed_scene_voxel_payload_buffer.is_valid() and _committed_scene_voxel_payload_buffer_byte_count == output_byte_count:
    var zero_bytes := PackedByteArray()
    zero_bytes.resize(output_byte_count)
    if _rd.buffer_update(_committed_scene_voxel_payload_buffer, 0, output_byte_count, zero_bytes) == OK:
        committed_payload_buffer = _committed_scene_voxel_payload_buffer
        committed_payload_reused = true

if not committed_payload_reused:
    _release_committed_scene_voxel_payload_buffer()
    committed_payload_buffer = storage_buffer_zero(output_byte_count, SCOPE_PERSISTENT, "committed_scene_voxel_payloads")
    if not committed_payload_buffer.is_valid():
        gc_frame()
        return {}
```

### 复用时的状态机

```
T0: _committed_scene_voxel_payload_buffer = old_rid (含上次 commit 数据)
    _committed_scene_voxel_payload_buffer_byte_count = N

T1: output_byte_count == N → 触发复用路径
    _rd.buffer_update(old_rid, 0, N, zero_bytes)  → 原地清零
    committed_payload_buffer = old_rid             → 局部变量复用
    committed_payload_reused = true

T2: dispatch 成功
    _committed_scene_voxel_payload_buffer = old_rid   → 仍然是同一个 RID
    (成员变量本质上没变，只是数据被覆盖为新的 commit 结果)
```

### 错误路径处理

三个错误路径（candidate buffer 无效、uniform set 创建失败、dispatch 失败）均做了防护：

```gdscript
# 复用时不释放（buffer 仍有效，下次可继续复用）
if not committed_payload_reused:
    release_rid(committed_payload_buffer, false)
    _committed_scene_voxel_payload_buffer = RID()
gc_frame()
return {}
```

- **未复用**：释放刚分配的新 buffer，清零成员变量 → 与修复前行为一致
- **已复用**：仅清空成员变量（dispatch 失败路径下保持成员变量不变），buffer RID 存活供下次复用

### 为什么根治了问题

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 大小相同（最常见） | release + allocate → 双重 RID 风险 | `buffer_update` 原地清零 → 零分配零释放 |
| 大小变化 | release + allocate（不变） | release + allocate（不变） |
| buffer_update 失败 | N/A | 降级为 release + allocate（与修复前一致） |
| 错误路径 | release 失败 → 泄漏 | 复用路径下不释放，buffer 存活供下次使用 |

---

## 其他修复方向（未采用）

### 方向 B：释放失败时不覆盖成员变量

```gdscript
func _release_committed_scene_voxel_payload_buffer() -> void:
    if _committed_scene_voxel_payload_buffer.is_valid():
        release_rid(_committed_scene_voxel_payload_buffer, false)
        return   # 不在此清零
    # 仅在第二次调用时清零
    _release_committed_scene_voxel_key_coord_buffer()
    _committed_scene_voxel_payload_buffer = RID()
```

> 未采用原因：`RID.is_valid()` 在 `free_rid` 后不一定立即变 invalid，二次调用检测不可靠。

### 方向 C：让 `release_rid` 返回确认信息

> 未采用原因：`release_rid` 是基类 `godot_compute_shader_base.gd` 的公共方法，涉及面太广，改动风险高。
