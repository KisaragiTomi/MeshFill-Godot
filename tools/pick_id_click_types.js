// 逐**点击类型**的生产路径验证（经编辑器桥 127.0.0.1:6800）。
//
// pick_id_production_click_parity.js 回答的是"生产链忠实吗、与旧路的分歧能不能解释"，
// 它按**像素**采样，覆盖到哪些 drawable 取决于当时谁在画。
// 本脚本回答另一个问题：**每一种点击类型各自点下去会发生什么**，一种都不许漏。
// 覆盖不到的类型必须在结果表里如实写"未覆盖 + 为什么"，不许用探针缝的结果顶替。
//
// 全部经生产入口 `SPASelectionHost.simulate_viewport_click`（默认 entry="spa"，
// 即编辑器插件 `_forward_3d_gui_input` 唯一调用的那条链）。
// ⚠ 两处替身与 parity 脚本相同：探针相机 + 合成 InputEvent。
//
// 用法：node tools/pick_id_click_types.js
// 退出码：0 = 全部符合预期；1 = 有类型不符；2 = 环境/桥失败；
//        3 = 有类型未覆盖（INCONCLUSIVE，判据见下）。
//
// ⚠ **未覆盖必须是判据，不是附注**。此前收尾是 `exit(bad.length > 0 ? 1 : 0)`——
// UNCOVERED 只打印一行、退出码照给 0。而本脚本的覆盖面**随进场显示开关漂**：
// 别的脚本（或上一次异常退出的自己）把 `gpu_objects` / `anchor` 留在关闭状态，
// 对应的 drawable 就不进 ID pass，那几类全部记 null ⇒ 打印"未覆盖 3"、退出 0、
// 调用方读成绿。这正是本仓"空对空被误当成通过"的失效形状，与
// pick_id_production_click_parity.js 的 NO-COVERAGE ⇒ INCONCLUSIVE 同一条纪律。
// ⇒ 未覆盖单独占退出码 3（与"类型不符"的 1 区分：前者是没验到，后者是验到了不对）。

const net = require('net');

const HOST = '127.0.0.1';
const PORT = 6800;
const SCENE = 'res://demos/placement-score-3d/placement-score-3d.tscn';
const HOST_PATH = 'SPA/Interaction/SelectionHost';
const DEMO_PATH = 'SPA/Volumes/VolumeScore';
const VIEWPORT = [1440, 900];
const POSE = { pos: [200, 300, 200], look_at: [0, 60, 0] };
const KEY_H = 72;

function send(method, params, timeoutMs = 600000) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: HOST, port: PORT }, () => {
      s.write(JSON.stringify({ id: Date.now(), method, params: params || {} }) + '\n');
    });
    let buf = '', done = false;
    const timer = setTimeout(() => {
      if (!done) { done = true; s.destroy(); reject(new Error(`TIMEOUT ${method}`)); }
    }, timeoutMs);
    s.on('data', d => {
      buf += d.toString();
      const nl = buf.indexOf('\n');
      if (nl >= 0 && !done) {
        done = true; clearTimeout(timer); s.destroy();
        try { resolve(JSON.parse(buf.substring(0, nl).trim())); }
        catch (e) { reject(new Error(`BAD JSON from ${method}: ${buf.substring(0, 200)}`)); }
      }
    });
    s.on('error', e => { if (!done) { done = true; clearTimeout(timer); reject(e); } });
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function sendResilient(method, params) {
  let last = null;
  for (let i = 0; i < 4; i++) {
    try { return await send(method, params); }
    catch (e) {
      if (!/ECONNRESET|ECONNREFUSED|EPIPE|socket hang up/.test(String(e.message))) throw e;
      last = e; await sleep(150 * (i + 1));
    }
  }
  throw last;
}
async function raw(path, method, args = []) {
  const resp = await sendResilient('call_method', { path, method, args });
  const r = resp && resp.result;
  if (!r) throw new Error(`no result: ${JSON.stringify(resp).slice(0, 200)}`);
  if (r.error) throw new Error(`bridge error on ${path}.${method}: ${r.error}`);
  return r.return;
}
async function call(path, method, args = []) {
  const v = await raw(path, method, args);
  if (v === undefined || v === null) throw new Error(`${path}.${method} returned null`);
  return v;
}
const asJson = (v, label) => {
  try { return JSON.parse(v); }
  catch (e) { throw new Error(`${label} 返回的不是 JSON: ${String(v).slice(0, 200)}`); }
};

async function waitFrames() {
  for (let i = 0; i < 200; i++) {
    if (parseInt(await call(HOST_PATH, 'pick_id_frames_since_prepare', []), 10) >= 1) return;
    await sleep(50);
  }
  throw new Error('ID 目标 10s 内没有被画出来');
}

// 建一趟探针 pass，回来一张「节点名 → 该节点上的真实命中像素」的表。
// ⚠ 探针在这里只用来**找点**（哪些像素属于哪个 drawable），结论全部来自随后的生产点击。
async function pixelsByDrawable(perDrawable = 8) {
  const prep = asJson(await call(HOST_PATH, 'pick_id_prepare_at_camera_pose',
    [JSON.stringify({ pos: POSE.pos, look_at: POSE.look_at, viewport: VIEWPORT })]), 'prepare');
  if (!prep.ok) throw new Error(`prepare 失败: ${JSON.stringify(prep)}`);
  await waitFrames();
  const s = asJson(await call(HOST_PATH, 'pick_id_sample_hit_pixels_per_drawable',
    [perDrawable, 2]), 'sample');
  const byNode = {};
  for (const [sx, sy] of s.points) {
    const out = asJson(await call(HOST_PATH, 'pick_id_resolve_at_camera_pose',
      [JSON.stringify({ viewport: VIEWPORT, screen: [sx, sy] })]), 'resolve');
    const name = String(out.node_path || '').split('/').pop();
    if (!name) continue;
    (byNode[name] = byNode[name] || []).push({ sx, sy, domain: out.domain, idIndex: out.id_index,
      objectId: out.id_object_id, voxel: out.id_voxel });
  }
  return { byNode, ranges: s.ranges, drawables: prep.drawables };
}

// ID 图上**没有任何 drawable** 的像素（= 本轮"点空地/点空处"的候选点）。
async function emptyPixels(limit = 6) {
  const out = [];
  for (let r = 1; r <= 7 && out.length < limit; r++) {
    for (let c = 1; c <= 9 && out.length < limit; c++) {
      const sx = Math.round((c / 10) * VIEWPORT[0]);
      const sy = Math.round((r / 8) * VIEWPORT[1]);
      const res = asJson(await call(HOST_PATH, 'pick_id_resolve_at_camera_pose',
        [JSON.stringify({ viewport: VIEWPORT, screen: [sx, sy] })]), 'resolve');
      if (res.pick_id === 0) out.push({ sx, sy });
    }
  }
  return out;
}

// ⚠ 形参 `pickId` 已删：回退开关随旧路整体退役（2026-08-10，三角形 ID 唯一路），
// spec 的 `pick_id` 键不再有任何作用。
async function click(sx, sy, entry = 'spa') {
  return asJson(await call(HOST_PATH, 'simulate_viewport_click', [JSON.stringify({
    pos: POSE.pos, look_at: POSE.look_at, viewport: VIEWPORT,
    screen: [sx, sy], entry,
  })]), 'click');
}

const rows = [];
function record(type, path, evidence, expected, ok, note = '') {
  rows.push({ type, path, evidence, expected, ok, note });
  console.log(`  ${ok === true ? 'OK  ' : ok === null ? '??  ' : 'FAIL'} ${type} :: ${evidence}`);
}

// ⚠ 必须走 **SPA** 的 `set_voxel_display_visible`，不是 SelectionHost 的同名方法。
//
// ⚠ 这里原先写的理由是"后者只翻 host 的记账位"——**那是错的**，实测（2026-08-09，桥）：
// host 那条除了翻记账位，还会 `_apply_external_voxel_display_visibility()` 按显示组扫一遍
// `visible`，而 SceneSVVoxels / SVTileOctas 由 `PickableDomain.register_pick_drawable()`
// 加进了该组 ⇒ 对**已经建出来的**显示节点，host 路的关/开都真的生效
// （drawables 7→5→7）。真正的两处差别是：
//   ① 显示节点**还不存在**时，host 路开不出来（不会 rebuild_display），SPA 路会建
//      —— 这才是"开关打开了、什么都没画"的成因；
//   ② host 路不写卷自己的 `display_visible`，于是卷的记账与节点实况会分叉。实测：
//      SPA 关掉后再用 host 开，节点可见且可点中，而 `SceneSVVolume.is_display_visible()`
//      仍报 false —— 「看不见就选不中」的准入闸在这种状态下读出来是反的。
// ⇒ 统一走 SPA（`set_volume_display()` → 卷自己的 `set_display_visible()`，一个写入方）。
async function setDisplay(key, visible) {
  await raw('SPA', 'set_voxel_display_visible', [key, visible]);
}
// 本脚本会翻的显示开关 + 它们**进场时**的取值。
//
// ⚠ 收尾必须还原**进场快照**，不是一律置 true。一律置 true 会把用户本来关着的键
// 悄悄打开：下一个人看到的是"我明明关掉了 SV，怎么又开着"，而且没有任何痕迹指向本脚本。
// （同款纪律见 pick_id_production_click_parity.js 的 done()。）
// ⚠ 还原必须覆盖**所有**退出路径，异常退出尤其——旧实现只在 main() 走完时还原，
// 中途抛异常就把 sv/svtile 留在关闭状态，于是下一个门禁的覆盖面被这次崩溃悄悄削掉。
const TOUCHED_KEYS = ['sv', 'svtile', 'targetsv'];
// 显示键 → 拥有该显示的 PickableDomain 卷节点。**真值在卷上**，不在 host 的记账位。
const DOMAIN_VOLUME_PATH = {
  sv: 'SPA/Volumes/SceneSV',
  svtile: 'SPA/Volumes/SVTile',
  targetsv: 'SPA/Volumes/TargetSV',
};
let entrySnapshot = null;
let snapshotForReport = {};
let entryEffective = {};

// 「这个域到底画没画」。⚠ 不能读 `get_voxel_display_state()`：那是 host 的记账位，
// 与实况在 sv / svtile 上**从加载起就是脱钩的**。实测（2026-08-09，桥）：
//   刚开的编辑器 → host 记账位 sv=true svtile=true（`default_voxel_display_state()`
//   给每个键都填 true），而 SceneSVVolume._ready() / SVTileVolume._ready() 各自
//   `display_visible = false` ⇒ 两个显示节点根本不存在，prepare().drawables=5。
// 旧实现按 host 记账位快照，收尾 `setDisplay(k, true)` 于是**建出** SceneSVVoxels +
// SVTileOctas（实测 drawables 5→7）：本脚本自称"还原进场快照"，实际把编辑器留得比
// 进场更脏，而且脏的正好是会罩死 autoobject / anchor 的那两个域——
// pick_id_production_click_parity.js 之所以需要 --hide-volumes，成因就在这里。
async function effectiveVisible(key) {
  const path = DOMAIN_VOLUME_PATH[key];
  if (path) return String(await call(path, 'is_display_visible', [])).trim() === 'true';
  return String(await call(HOST_PATH, 'is_voxel_display_visible', [key])).trim() === 'true';
}

async function childNames(path) {
  const resp = await sendResilient('get_children', { path });
  const r = resp && resp.result;
  if (!r || r.error) throw new Error(`get_children ${path} 失败: ${JSON.stringify(r)}`);
  return (r.children || []).map(c => c.name);
}

// 「这个域为什么没在 ID 图上留下像素」——把此前混成一句问号的三种成因分开。
// 读者要据此决定修哪里，所以每一种都必须由一个**当场读到的事实**支撑，
// 而不是"是否有内容 / 显示是否打开？"这种把排查原样丢回去的措辞。
//
//   switch_off  显示开关（卷自己的 display_visible）是关的 ⇒ 不进 ID pass。修开关/调用顺序。
//   empty       开关是开的，但卷建不出显示节点 ⇒ 紧凑实例表为 0，该域**确实是空的**。
//               （SceneSVVolume._build_field_display() 对空表返回 null，不建节点。）
//   occluded    开关开着、显示节点也在，就是没有像素 ⇒ 被别的几何按深度压住。
async function volumeCoverageCause(key, nodeName) {
  const path = DOMAIN_VOLUME_PATH[key];
  if (!path) return { kind: 'unknown', text: `没有登记 ${key} 的卷节点路径，成因无法判定` };
  const on = await effectiveVisible(key);
  if (!on) {
    return { kind: 'switch_off',
      text: `${path}.is_display_visible()=false ⇒ 显示开关是关的，该域根本没进 ID pass` };
  }
  const kids = await childNames(path);
  if (!kids.includes(nodeName)) {
    return { kind: 'empty',
      text: `显示开关已打开，但 ${path} 名下没有 ${nodeName}（子节点=${JSON.stringify(kids)}）`
        + ' ⇒ 紧凑实例表为 0，该域确实是空的（正确行为，本类未覆盖）' };
  }
  return { kind: 'occluded',
    text: `显示开关已打开、${nodeName} 也在，但 ID 图上没有它的像素 ⇒ 被别的几何按深度压住` };
}
// 进场时**全部**显示开关的取值。TOUCHED_KEYS 之外的键本脚本不动，但它们决定覆盖面
// （`gpu_objects` / `anchor` 关着 = 对应 drawable 不进 ID pass = 那几类记 UNCOVERED），
// 所以 INCONCLUSIVE 时要把它们一并报出来——否则读者看不出"未覆盖"的成因在哪。
//
// ⚠ 键表向 `get_voxel_display_state()` 要，不在这里手抄一份：手抄的表**只会漏**
// （合同表新增一个域时没人会想起改这里），而漏掉的那个键恰恰就是下次"未覆盖"查不出成因的那个。
// 同一条理由见 spa_editor_contract.gd 里被删掉的 VOXEL_DISPLAY_KEYS。
async function snapshotDisplay() {
  const rawState = String(await call('SPA', 'get_voxel_display_state', []));
  // 桥把返回值 str() 掉了；GDScript 的 Dictionary str() 对 String→bool 恰好是合法 JSON。
  // 解不出来就判死：拿不到快照 = 后面每一条 UNCOVERED 都说不清成因。
  snapshotForReport = asJson(rawState, 'get_voxel_display_state');
  const snap = {};
  for (const k of TOUCHED_KEYS) {
    if (!(k in snapshotForReport)) {
      throw new Error(`显示开关表里没有 "${k}"，本脚本会翻它却不知道原值：${rawState}`);
    }
    // 记账位只进报告（UNCOVERED 时读者要看它），**还原按实况**（见 effectiveVisible）。
    snap[k] = await effectiveVisible(k);
  }
  entrySnapshot = snap;
  entryEffective = Object.assign({}, snap);
  console.log(`进场显示记账位: ${JSON.stringify(snapshotForReport)}`);
  console.log(`进场显示实况（卷节点自己报的，还原按这一份）: ${JSON.stringify(snap)}`);
  return snap;
}
async function restoreDisplay() {
  if (entrySnapshot === null) return;
  const snap = entrySnapshot;
  entrySnapshot = null;   // 二次调用（catch 之后再走 finally）不重复下发
  for (const k of TOUCHED_KEYS) await setDisplay(k, snap[k]);
  console.log(`还原进场显示实况: ${JSON.stringify(snap)}`);
}

async function main() {
  const scene = await send('get_open_scene', {});
  if (!(scene && scene.result && scene.result.scene === SCENE)) {
    console.error(`ERROR: 需要打开 ${SCENE}`);
    process.exit(2);
  }
  // ⚠ 这里曾打印 `is_pick_id_selection_enabled()`。开关已删 —— 只剩三角形 ID 一条路，没有可读的状态。

  // 先记快照，再动任何开关（收尾按它还原，见 restoreDisplay 的理由）。
  await snapshotDisplay();

  // ⚠ 进场先把 SV / SVTile 关掉，**本脚本的覆盖面才不随上一个脚本留下的显示状态漂**。
  // 实测：一个 SVTile 八面体是 32×16×32 m、900+ 个铺开就把 ID 图罩死，
  // AutoObject / TargetSV / Anchor 全部报 "没有像素" —— 那是**遮挡**，不是缺陷，
  // 但报出来长得和"drawable 掉了"一模一样。这两个域在下面的第 4 类里自己开自己验。
  // 门禁不能依赖调用顺序（同一条理由见 set_selection_mode 归 MIXED 那一段）。
  await setDisplay('sv', false);
  await setDisplay('svtile', false);

  // ── 阶段 1：放置态（PlacedBatch* + AnchorPoints + TargetSVVoxels 全部在画）──
  console.log('\n[阶段1] 评分 + 放置');
  await call(DEMO_PATH, 'calculate_voxel_scores', []);
  const placed = asJson(await call(DEMO_PATH, 'place_final_autoobjects', []), 'place');
  console.log(`  spawned=${placed.spawned}`);
  let px = await pixelsByDrawable(8);
  console.log(`  drawables=${px.drawables} 节点=${Object.keys(px.byNode).join(', ')}`);

  // 1) AutoObject
  const aoNode = Object.keys(px.byNode).find(n => n.startsWith('PlacedBatch'));
  if (!aoNode) {
    // ⚠ 这里原先写死"放置态下 AutoObject 被别的几何完全遮住"。那是**一个猜测被写成了结论**：
    // 实测（本轮反向对照）进场 `gpu_objects` 显示开关关着时也是这一行，而那根本不是遮挡，
    // 是这个域压根没进 ID pass。写死一个成因会让读者停止排查真正的那个。
    record('AutoObject', '-', 'ID 图里没有 PlacedBatch* 的像素', '选中点中的那个物体', null,
      `成因待查：gpu_objects 显示开关进场值=${snapshotForReport.gpu_objects}；`
      + '为 false ⇒ 该域没进 ID pass，为 true ⇒ 才可能是被别的几何遮住');
  } else {
    const p = px.byNode[aoNode][0];
    const c = await click(p.sx, p.sy);
    const ok = c.selected.domain === 'autoobject'
      && Number(c.selected.object_id) === Number(p.objectId)
      && c.selected.pick_backend === 'pick_id';
    record('AutoObject（已切 ID 路）', 'ID',
      `(${p.sx},${p.sy}) → ${c.selected.domain} object_id=${c.selected.object_id} `
      + `backend=${c.selected.pick_backend}（ID pass 参照 object_id=${p.objectId}）`,
      '选中点中的那个物体', ok);
  }

  // 2) TargetSV
  const tsvNode = Object.keys(px.byNode).find(n => n === 'TargetSVVoxels');
  if (!tsvNode) {
    record('TargetSV 体素', '-', 'ID 图里没有 TargetSVVoxels 的像素', '选中对应体素', null);
  } else {
    const p = px.byNode[tsvNode][0];
    const c = await click(p.sx, p.sy);
    const same = JSON.stringify(c.selected.voxel_coord) === JSON.stringify(p.voxel);
    const ok = c.selected.domain === 'targetsv' && same && c.selected.pick_backend === 'pick_id';
    record('TargetSV 体素（已切 ID 路）', 'ID',
      `(${p.sx},${p.sy}) → ${c.selected.domain} voxel=${JSON.stringify(c.selected.voxel_coord)} `
      + `backend=${c.selected.pick_backend}（ID pass 参照 ${JSON.stringify(p.voxel)}）`,
      '选中对应体素', ok);
  }

  // 3) 点"空处"（ID 图上确无几何的像素）
  const empties = await emptyPixels(4);
  if (empties.length === 0) {
    record('点空地/空处', '-', '这个位姿下 ID 图没有空像素（TargetSV 铺满）', '见 §10-5', null);
  } else {
    for (const e of empties.slice(0, 2)) {
      const c = await click(e.sx, e.sy);
      const pc = c.pick_id_click || {};
      const dom = c.selected.domain || '(无选中)';
      // 期望（2026-08-07 起的真实语义）：五个域全切之后 miss 就是**终态**——
      // 旧路兜底那一段还在，但 PICK_ID_SWITCHED_DATA_MODES 已覆盖
      // DATA_PICK_MODE_PREFERENCE 全部三项，它恒返回 {}。⇒ 点空处 = 什么都不选中。
      // ⚠ 这条断言此前写的是"未切换域（svtile/sv）的旧算法接手"，那是切换前的语义。
      const ok = pc.status === 'miss' && (c.selected.domain || '') === '';
      record('点空地/空处', `ID(miss) → 无选中`,
        `(${e.sx},${e.sy}) pick_id=${pc.pick_id} status=${pc.status} → 落地 ${dom} `
        + `id=${c.selected.id || '-'} backend=${c.selected.pick_backend || '-'}`,
        'ID 路无命中 ⇒ 这次点击没有答案（§10-5）', ok);
    }
  }

  // 4) SV / SVTile（2026-08-07 起也走 ID 路）
  // ⚠ 三个显示开关都要在这里显式摆好，本类才自洽：TargetSV 的 1048576 个体素盒会把
  // 这两个域压在下面；而 SV / SVTile 是进场时被我们关掉的（见 main() 开头的理由）。
  await setDisplay('targetsv', false);
  await setDisplay('sv', true);
  await setDisplay('svtile', true);
  const volPx = await pixelsByDrawable(8);
  for (const [nodeName, label, domain] of [
    ['SceneSVVoxels', 'SV 体素（已切 ID 路）', 'sv'],
    ['SVTileOctas', 'SVTile 砖（已切 ID 路）', 'svtile'],
  ]) {
    const pts = volPx.byNode[nodeName];
    if (!pts || pts.length === 0) {
      // ⚠ 这里原先只写一句"该域是否有内容 / 显示是否打开？"——两种成因（域是空的 /
      // 开关被关着）都落进同一条 UNCOVERED，读者分不出该修哪个，而两者的修法完全相反。
      const cause = await volumeCoverageCause(domain, nodeName);
      record(label, '-', `ID 图里没有 ${nodeName} 的像素 —— 成因：${cause.kind}`,
        `选中点中的那个${domain === 'sv' ? '格子' : '砖'}`, null, cause.text);
      continue;
    }
    const p = pts[0];
    const c = await click(p.sx, p.sy);
    // 身份口径：sv = 线性体素下标、svtile = tile_index，两者都由
    // _selection_state_identity() 落进 payload_index，与探针的 id_index 同源。
    const ok = c.selected.domain === domain
      && Number(c.selected.payload_index) === Number(p.idIndex)
      && c.selected.pick_backend === 'pick_id';
    record(label, 'ID',
      `(${p.sx},${p.sy}) → ${c.selected.domain} payload_index=${c.selected.payload_index} `
      + `backend=${c.selected.pick_backend}（ID pass 参照 ${p.idIndex}）`,
      `选中点中的那个${domain === 'sv' ? '格子' : '砖'}`, ok);
  }
  // 还原：TargetSV 开回来，SV / SVTile 关回去（阶段 2 要给 Anchor 的三个 drawable 让位）。
  await setDisplay('targetsv', true);
  await setDisplay('sv', false);
  await setDisplay('svtile', false);

  // ── 阶段 2：只评分（AnchorPoints + Winner_*）+ 关掉 TargetSV 显示 ──
  // 放置态下锚点小球/胜出 mesh 一个像素都抢不到（1048576 个 TargetSV 体素盒铺满地面），
  // 这是"看不到就选不中"的正常表现，不是缺陷。
  console.log('\n[阶段2] 只评分 + 关闭 TargetSV 显示（让 Anchor 的三个 drawable 露出来）');
  await call(DEMO_PATH, 'calculate_voxel_scores', []);
  await setDisplay('targetsv', false);
  px = await pixelsByDrawable(8);
  console.log(`  drawables=${px.drawables} 节点=${Object.keys(px.byNode).join(', ')}`);

  // 5) Anchor 小球
  let anchorForCtrlH = -1;
  if (!px.byNode['AnchorPoints']) {
    record('Anchor 小球', '-', 'ID 图里没有 AnchorPoints 的像素', '选中该锚点', null);
  } else {
    const p = px.byNode['AnchorPoints'][0];
    const c = await click(p.sx, p.sy);
    const ok = c.selected.domain === 'anchor' && Number(c.selected.payload_index) === Number(p.idIndex);
    record('Anchor 小球（已切 ID 路）', 'ID',
      `(${p.sx},${p.sy}) → ${c.selected.domain} anchor=${c.selected.payload_index} `
      + `（ID pass 参照 anchor=${p.idIndex}）`,   // ⚠ 原来还带 evidence.center_dist_px；那是旧路仲裁的产物，已删
      '选中该锚点', ok);
  }

  // 6) Anchor 胜出物体 mesh
  const winNode = Object.keys(px.byNode).find(n => n.startsWith('Winner_'));
  if (!winNode) {
    record('Anchor 胜出物体 mesh', '-', 'ID 图里没有 Winner_* 的像素', '选中对应锚点', null);
  } else {
    const p = px.byNode[winNode][0];
    const c = await click(p.sx, p.sy);
    const ok = c.selected.domain === 'anchor' && Number(c.selected.payload_index) === Number(p.idIndex);
    if (ok) anchorForCtrlH = Number(c.selected.payload_index);
    record('Anchor 胜出物体 mesh（已切 ID 路）', 'ID',
      `${winNode} (${p.sx},${p.sy}) → ${c.selected.domain} anchor=${c.selected.payload_index} `
      + `（参照 ${p.idIndex}）射线穿过胜出 AABB=${c.evidence.ray_in_winner_aabb}`,
      '选中对应锚点', ok);
  }

  // 7) WinnerVoxelProfile（Ctrl+H 观察态）—— 至今从未被触发过的那一条
  if (anchorForCtrlH < 0) {
    record('WinnerVoxelProfile (Ctrl+H)', '-', '没有拿到带胜出者的选中锚点，进不了观察态',
      '选中对应锚点', null);
  } else {
    const keyOut = asJson(await call(HOST_PATH, 'simulate_viewport_key', [JSON.stringify({
      keycode: KEY_H, ctrl: true, pos: POSE.pos, look_at: POSE.look_at, viewport: VIEWPORT,
    })]), 'key');
    const state = String(await call(DEMO_PATH, 'debug_winner_profile_state', []));
    const px2 = await pixelsByDrawable(8);
    const profNode = Object.keys(px2.byNode).find(n => n === 'WinnerVoxelProfile');
    if (!profNode) {
      record('WinnerVoxelProfile (Ctrl+H)', '-',
        `Ctrl+H consumed=${keyOut.consumed} state=${state}；ID 图里仍没有 WinnerVoxelProfile 像素`,
        '选中对应锚点', null, '观察态没建起来或被遮住');
    } else {
      const p = px2.byNode[profNode][0];
      const c = await click(p.sx, p.sy);
      const ok = c.selected.domain === 'anchor'
        && Number(c.selected.payload_index) === anchorForCtrlH;
      record('WinnerVoxelProfile (Ctrl+H，已切 ID 路)', 'ID',
        `Ctrl+H consumed=${keyOut.consumed} → (${p.sx},${p.sy}) → ${c.selected.domain} `
        + `anchor=${c.selected.payload_index}（进观察态前选中的是 ${anchorForCtrlH}）`,
        '选中对应锚点', ok);
    }
    // 退出观察态，恢复胜出 mesh 显示
    await call(HOST_PATH, 'simulate_viewport_key', [JSON.stringify({
      keycode: KEY_H, ctrl: true, pos: POSE.pos, look_at: POSE.look_at, viewport: VIEWPORT,
    })]);
  }

  // 8) BrushSV —— 2026-08-10 起是与其余五域同路的 ID 路可选域（可见性即准入）。
  //    本脚本不落笔（无 Vector2i 封送通道），所以本轮**没有任何笔刷体素被画出**：
  //    无笔迹 ⇒ 无 BrushTetraVoxels drawable ⇒ 进不了 ID pass ⇒ 点击不可能落出
  //    brush 记录。这里断言的是这条「可视化即拾取几何」的物理保证，
  //    不再是旧的"brush 本来就不是可选域"。
  const brushSeen = rows.some(r => String(r.evidence).includes('brush:'));
  record('BrushSV（无笔迹 ⇒ 无 drawable ⇒ 不可命中）', 'ID',
    `brush 已在 PICK_ID_DISPLAY_KEYS（2026-08-10 切换）；本轮未画任何笔刷体素；`
    + `全部点击中出现 brush 记录：${brushSeen}`,
    '无笔迹时点不出 brush（画不出来的进不了 pass）', brushSeen === false);

  await restoreDisplay();

  console.log('\n===== 逐类型结果 =====');
  for (const r of rows) {
    console.log(`${r.ok === true ? 'PASS' : r.ok === null ? 'UNCOVERED' : 'FAIL'} | ${r.type} | `
      + `路=${r.path} | ${r.evidence}${r.note ? ' | ' + r.note : ''}`);
  }
  const bad = rows.filter(r => r.ok === false);
  const uncovered = rows.filter(r => r.ok === null);
  console.log(`\n合计 ${rows.length} 类：通过 ${rows.length - bad.length - uncovered.length}，`
    + `不符 ${bad.length}，未覆盖 ${uncovered.length}`);
  if (bad.length > 0) {
    console.log(`CLICK TYPES FAIL — ${bad.length} 类落地与预期不符。`);
    process.exit(1);
  }
  if (uncovered.length > 0) {
    for (const r of uncovered) {
      console.log(`  UNCOVERED ${r.type} —— ${r.evidence}${r.note ? '（' + r.note + '）' : ''}`);
    }
    console.log(`CLICK TYPES INCONCLUSIVE — ${uncovered.length} 类一次都没验到（`
      + `进场记账位=${JSON.stringify(snapshotForReport)}；`
      + `进场实况=${JSON.stringify(entryEffective)}）。`
      + '\n  ⚠ 两份不一致是**已知事实**而非本次异常：host 的记账位对每个键默认 true，'
      + '而 SceneSV / SVTile 两个卷在 _ready() 里各自 display_visible=false。'
      + '判"这个域为什么没覆盖"看实况那一份，以及上面每条 UNCOVERED 自带的成因。');
    process.exit(3);
  }
  console.log('CLICK TYPES PASS — 每一种点击类型都验到了，且落地与预期一致。');
  process.exit(0);
}

main().catch(async e => {
  console.error('ERROR:', e.message);
  // 异常退出也要还原：把开关留在关闭状态，下一个门禁会静默少验几个域。
  try { await restoreDisplay(); } catch (e2) { console.error('还原显示开关失败:', e2.message); }
  process.exit(2);
});
