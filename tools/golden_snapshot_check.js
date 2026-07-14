// Golden-master consumer for the volume-score pipeline (统一Debug承载方案 step 6 consumer chain).
// Talks to the MeshFill editor bridge (127.0.0.1:6800), runs the deterministic scoring pass
// PlacementScore3DScene/VolumeScore.run_golden_snapshot() (debug_read_golden_snapshot=true,
// voxel channel section included via the demo's existing debug_read_voxel_channels=true),
// normalizes the returned text and compares it against the git-committed baseline
// goldens/volume_score_golden.approved.txt.
//
// Usage: node tools/golden_snapshot_check.js [--approve]
//   no baseline, no --approve -> prints "NO BASELINE", exit 1 (a gate must not
//                                self-approve; creating the baseline is explicit)
//   no baseline, --approve    -> writes it, prints "BASELINE CREATED", exit 0
//   identical       -> prints "GOLDEN PASS", exit 0
//   different       -> prints a unified diff, then "GOLDEN DIFF", exit 1
//                      (--approve does NOT overwrite an existing baseline)
//   bridge/runner failure -> "ERROR: ...", exit 2
// Requires a running editor (-e, vulkan) with the meshfill plugin bridge up.
const net = require('net');
const fs = require('fs');
const path = require('path');

const SCENE_PATH = 'res://demos/placement-score-3d/placement-score-3d.tscn';
const SCENE_ROOT = 'PlacementScore3DScene';
const RUNNER_NODE = 'VolumeScore';
const RUNNER_SCRIPT = 'volume_score_demo.gd';
const RUNNER_METHOD = 'run_golden_snapshot';
const GOLDEN_FILE = path.join(__dirname, '..', 'goldens', 'volume_score_golden.approved.txt');

function sendRequest(method, params, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: '127.0.0.1', port: 6800 }, () => {
      s.write(JSON.stringify({ id: Date.now(), method, params: params || {} }) + '\n');
    });
    let buf = '';
    let done = false;
    const timer = setTimeout(() => { if (!done) { done = true; s.destroy(); reject(new Error('TIMEOUT ' + method)); } }, timeoutMs);
    s.on('data', d => {
      buf += d.toString();
      const nl = buf.indexOf('\n');
      if (nl >= 0 && !done) {
        done = true;
        clearTimeout(timer);
        s.destroy();
        try { resolve(JSON.parse(buf.substring(0, nl).trim())); }
        catch { resolve(buf.substring(0, nl).trim()); }
      }
    });
    s.on('error', e => { if (!done) { done = true; clearTimeout(timer); reject(e); } });
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// Stable text form: LF only, no trailing whitespace, exactly one trailing newline.
function normalize(text) {
  const lines = String(text).replace(/\r\n?/g, '\n').split('\n').map(l => l.replace(/[ \t]+$/, ''));
  while (lines.length && lines[lines.length - 1] === '') lines.pop();
  return lines.join('\n') + '\n';
}

// Minimal unified diff (LCS over lines, 3 lines of context).
function unifiedDiff(aText, bText) {
  const a = aText.split('\n'); if (a[a.length - 1] === '') a.pop();
  const b = bText.split('\n'); if (b[b.length - 1] === '') b.pop();
  const n = a.length, m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const ops = []; // {t:' '|'-'|'+', line}
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push({ t: ' ', line: a[i] }); i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) { ops.push({ t: '-', line: a[i] }); i++; }
    else { ops.push({ t: '+', line: b[j] }); j++; }
  }
  while (i < n) { ops.push({ t: '-', line: a[i++] }); }
  while (j < m) { ops.push({ t: '+', line: b[j++] }); }

  const CTX = 3;
  const out = ['--- ' + path.relative(process.cwd(), GOLDEN_FILE), '+++ current'];
  let k = 0, aLine = 1, bLine = 1;
  while (k < ops.length) {
    if (ops[k].t === ' ') { k++; aLine++; bLine++; continue; }
    let start = k;
    let ctx = 0;
    while (start > 0 && ops[start - 1].t === ' ' && ctx < CTX) { start--; ctx++; }
    let end = k, run = 0;
    for (let p = k; p < ops.length; p++) {
      if (ops[p].t === ' ') { run++; if (run > CTX * 2) break; }
      else { run = 0; end = p; }
    }
    end = Math.min(ops.length - 1, end + CTX);
    const aStart = aLine - ctx, bStart = bLine - ctx;
    let aLen = 0, bLen = 0;
    const hunk = [];
    for (let p = start; p <= end; p++) {
      hunk.push(ops[p].t + ops[p].line);
      if (ops[p].t !== '+') aLen++;
      if (ops[p].t !== '-') bLen++;
    }
    out.push('@@ -' + aStart + ',' + aLen + ' +' + bStart + ',' + bLen + ' @@');
    out.push(...hunk);
    for (let p = k; p <= end; p++) {
      if (ops[p].t !== '+') aLine++;
      if (ops[p].t !== '-') bLine++;
    }
    k = end + 1;
  }
  return out.join('\n') + '\n';
}

function findByScript(node, suffix) {
  if (node.script && String(node.script).endsWith(suffix)) return node;
  for (const c of node.children || []) {
    const hit = findByScript(c, suffix);
    if (hit) return hit;
  }
  return null;
}

async function ensureScene() {
  let scene = (await sendRequest('get_open_scene')).result || {};
  if (scene.root_name === SCENE_ROOT) return;
  await sendRequest('open_scene', { path: SCENE_PATH }, 120000);
  for (let i = 0; i < 30; i++) {
    await sleep(500);
    scene = (await sendRequest('get_open_scene')).result || {};
    if (scene.root_name === SCENE_ROOT) return;
  }
  throw new Error('scene did not open: ' + JSON.stringify(scene));
}

async function callRunner(nodePath) {
  const resp = await sendRequest('call_method', { path: nodePath, method: RUNNER_METHOD }, 300000);
  if (resp.error) throw new Error('bridge: ' + resp.error);
  return resp.result || {};
}

async function fetchSnapshot() {
  let result = await callRunner(RUNNER_NODE);
  if (result.error && String(result.error).startsWith('node not found')) {
    const tree = ((await sendRequest('get_scene_tree', { max_depth: 6 })).result || {}).tree;
    const node = tree ? findByScript(tree, RUNNER_SCRIPT) : null;
    if (!node) throw new Error('no node with script ' + RUNNER_SCRIPT + ' in the open scene');
    const parts = String(node.path).split('/');
    const rootIdx = parts.indexOf(tree.name);
    result = await callRunner(parts.slice(rootIdx + 1).join('/') || '.');
  }
  if (result.error) throw new Error('call_method: ' + result.error);
  const snapshot = String(result.return || '');
  if (!snapshot || snapshot.startsWith('ERROR')) throw new Error('runner failed: ' + (snapshot || '(empty return)'));
  return snapshot;
}

async function main() {
  const approve = process.argv.slice(2).includes('--approve');
  await sendRequest('ping', {}, 5000);
  await ensureScene();
  const normalized = normalize(await fetchSnapshot());
  if (!fs.existsSync(GOLDEN_FILE)) {
    const rel = path.relative(process.cwd(), GOLDEN_FILE);
    if (!approve) {
      console.log('NO BASELINE ' + rel + ' (rerun with --approve to create it)');
      process.exitCode = 1;
      return;
    }
    fs.mkdirSync(path.dirname(GOLDEN_FILE), { recursive: true });
    fs.writeFileSync(GOLDEN_FILE, normalized, 'utf8');
    console.log('BASELINE CREATED ' + rel);
    return;
  }
  const approved = normalize(fs.readFileSync(GOLDEN_FILE, 'utf8'));
  if (approved === normalized) {
    console.log('GOLDEN PASS');
    return;
  }
  process.stdout.write(unifiedDiff(approved, normalized));
  console.log('GOLDEN DIFF');
  process.exitCode = 1;
}

main().catch(e => { console.error('ERROR:', e.message); process.exit(2); });
