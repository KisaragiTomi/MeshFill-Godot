"""
SPA UI 点击测试 — 按照 doc/ui-click-test-plan.md 的可自动化入口执行
"""
import socket, json, re, time, sys

# ⚠ 结果图标用的是 ✅/❌/⚠️/🔍，而 Windows 控制台默认 GBK 编不出它们：不加这一句，
# 第一次 print 就是 UnicodeEncodeError，整套在**第一个用例**上崩掉（不是失败，是崩）。
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HOST, PORT = "127.0.0.1", 6800
NODE = "SPA"

def send(method, params, timeout=15):
    with socket.create_connection((HOST, PORT), timeout=timeout) as s:
        req = json.dumps({"id": int(time.time()*1000), "method": method, "params": params}) + "\n"
        s.sendall(req.encode())
        buf = ""
        while "\n" not in buf:
            chunk = s.recv(4096).decode()
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.split("\n")[0])

def call(method, args=None):
    r = send("call_method", {"path": NODE, "method": method, "args": args or []})
    return r.get("result", r)

def gdparse(v):
    """Parse GDScript return strings: 'true'/'false', numeric, or raw."""
    if v is None:
        return None
    if v == "true":
        return True
    if v == "false":
        return False
    try:
        return int(v)
    except Exception:
        pass
    try:
        return float(v)
    except Exception:
        pass
    return v

PASS = "✅"
FAIL = "❌"
WARN = "⚠️"
PROBE = "🔍"

results = []

def check(test_id, description, actual, expect_fn, probe=False):
    ok = expect_fn(actual)
    icon = (PROBE if probe else PASS) if ok else FAIL
    results.append((icon, test_id, description, actual, ok))
    print(f"  {icon} [{test_id}] {description}")
    print(f"        got: {actual}")
    return ok

def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")

# ── UI-BOOT: 基础启动 ──────────────────────────────────────────

section("UI-BOOT — 基础启动")

# BOOT-01: 有场景打开，且场景里有 SPA 节点。
# ⚠ 旧判据写死场景名 "core-SPA-scene-placement-actor"，而那个场景已从工作区删除
#   ⇒ 本项恒红、整套随之无意义。改判**真正的前置条件**：后面每一项用例只要求 `SPA`
#   这个节点能解析并且挂着 ScenePlacementActor，与场景文件叫什么、放在哪无关。
#   这样换场景/改路径不会再让整套静默腐烂。
r = send("get_open_scene", {})
res = r.get("result", r)
r_node = send("get_node_info", {"path": NODE})
node_info = r_node.get("result", r_node)
check("BOOT-01", "有场景打开，且含挂 ScenePlacementActor 的 SPA 节点",
      {"scene": res.get("scene", ""), "spa_script": node_info.get("script", "")},
      lambda v: bool(v.get("scene")) and
                "scene_placement_actor.gd" in str(v.get("spa_script", "")))

# BOOT-02: SPA 节点存在，能响应查询。
# ⚠ 旧判据是 get_selection_mode 返回 "0".."5"；选择模式退役后该方法已不存在，
# 改用显示开关表——它现在是"哪些域可被点中"的唯一事实源。
r = call("get_voxel_display_state")
check("BOOT-02", "SPA 节点存在，get_voxel_display_state 返回显示开关表",
      r,
      lambda v: v.get("ok") and "anchor" in str(v.get("return", "")))

# ⚠ 这里曾有一段「选择模式切换 set_selection_mode / get_selection_mode」用例（Shift+0..5
# 六个模式各切一次再读回）。选择模式在 2026-08-07 整体退役，那两个方法早已不存在，本段
# 自那以后一直是**空跑的红**；2026-08-10 模式号（MODE_*）也一并退役后彻底没有对应物。
# 现在准入只看显示开关，对应的正向用例就是下面的 VD 开关段。

# ── VD 显示开关 ──────────────────────────────────────────────

section("VD 显示开关 set_voxel_display_visible / get_voxel_display_state")

def vd_state_is(raw, key, expected):
    """True iff the get_voxel_display_state string maps `key` to the expected bool.

    The bridge returns str(Dictionary), e.g. '{ "svtile": false, ... }'; match the
    specific key -> value pair instead of substring-scanning the whole blob."""
    want = "true" if expected else "false"
    return re.search(r'["\']%s["\']\s*[:=]\s*%s\b' % (re.escape(key), want), str(raw)) is not None

VD_KEYS = ["gpu_objects", "svtile", "anchor", "sv", "targetsv"]
for key in VD_KEYS:
    # 关闭
    r_off = call("set_voxel_display_visible", [key, False])
    time.sleep(0.05)
    r_state = call("get_voxel_display_state")
    raw = r_state.get("return", "")
    off_ok = vd_state_is(raw, key, False)
    check(f"VD-OFF-{key}", f"关闭 {key} → state 显示 false",
          {"ok": r_off.get("ok"), "off_ok": off_ok, "state": raw},
          lambda v: bool(v.get("ok")) and bool(v.get("off_ok")))

    # 恢复
    r_on = call("set_voxel_display_visible", [key, True])
    time.sleep(0.05)
    r_state_on = call("get_voxel_display_state")
    on_ok = vd_state_is(r_state_on.get("return", ""), key, True)
    check(f"VD-ON-{key}", f"恢复 {key} → ok 且 state 显示 true",
          {"ok": r_on.get("ok"), "on_ok": on_ok},
          lambda v: bool(v.get("ok")) and bool(v.get("on_ok")))

# ── 数据域直接选择 select_data_voxel ──────────────────────────

section("数据域直接选择 select_data_voxel")

# ⚠ 首参已从模式号（2 / 4）改为域名字符串（模式号 2026-08-10 整体退役）。
def returned_domain_is(raw, expected):
    """True iff 返回记录的 `domain` **恰好**是 expected。

    ⚠ 旧判据是 `"sv" in str(...)`——"sv" 是 "svtile" 的子串，所以 sv 域即使返回了
    svtile 记录也照样通过，这是一条永远不会红的假门。改为整体匹配 domain 键。"""
    return re.search(r'["\']domain["\']\s*:\s*["\']%s["\']' % re.escape(expected), str(raw)) is not None

r = call("select_data_voxel", ["svtile", 32, 0, 32])
check("DATA-SVTile", "select_data_voxel(svtile, 32,0,32) → domain=svtile",
      r,
      lambda v: bool(v.get("ok")) and returned_domain_is(v.get("return", ""), "svtile"))

r = call("select_data_voxel", ["sv", 32, 0, 32])
check("DATA-SV", "select_data_voxel(sv, 32,0,32) → domain=sv（不是 svtile）",
      r,
      lambda v: bool(v.get("ok")) and returned_domain_is(v.get("return", ""), "sv"))

# 负向：不存在的域名必须被拒，而不是静默落到某个域。
# 模式号时代这条测不了（任何 int 都是"合法"的域号，越界只会拿不到 Callable 而静默返回空）；
# 域名字符串在合同表里查不到就是 push_error + 明确失败，这里正是那条收益的门。
r = call("select_data_voxel", ["not_a_domain", 32, 0, 32])
check("DATA-BADDOMAIN", "select_data_voxel(不存在的域名) → 不构建记录",
      r,
      lambda v: not returned_domain_is(v.get("return", ""), "svtile") and
                "no_data_record" in str(v.get("return", "")))

# ── VD 关闭后的数据域选择（负向） ──────────────────────────────

section("负向: VD 关闭后 select_data_voxel 仍可构建记录（数据入口）")

call("set_voxel_display_visible", ["svtile", False])
time.sleep(0.05)
r = call("select_data_voxel", ["svtile", 32, 0, 32])
check("NEG-VD-DATA", "svtile 关闭时 select_data_voxel 仍能构建记录 (数据入口不受显示开关影响)",
      r,
      lambda v: True,  # 文档明确: 直接数据入口仍可构建记录
      probe=True)
# 恢复
call("set_voxel_display_visible", ["svtile", True])

# ── 滚轮 / 无选中时不崩溃 ──────────────────────────────────────

section("防御: 无选中时 refresh_volume_score_anchor_selection 不崩溃")

r = call("refresh_volume_score_anchor_selection")
check("NEG-SCROLL", "无 anchor 选中时 refresh_volume_score_anchor_selection 不报 ok=false 崩溃",
      r,
      lambda v: v.get("error") is None,
      probe=True)

# ⚠ 这里曾有「恢复默认模式 set_selection_mode(0)」收尾。没有模式可恢复了；
# 需要恢复的只有显示开关，上面的负向段自己已经改回去。

# ── 汇总 ─────────────────────────────────────────────────────

section("汇总")
passed = sum(1 for r in results if r[0] in (PASS, PROBE))
failed = sum(1 for r in results if r[0] == FAIL)
total  = len(results)
print(f"\n  总计 {total} 项 — ✅/🔍 {passed}  ❌ {failed}")

if failed:
    print("\n  失败项:")
    for icon, tid, desc, actual, ok in results:
        if not ok:
            print(f"    ❌ [{tid}] {desc}")
            print(f"         actual: {actual}")

sys.exit(0 if failed == 0 else 1)
