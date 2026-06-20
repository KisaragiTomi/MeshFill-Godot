const net = require('net');

function sendCommand(command, params, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: '127.0.0.1', port: 9090 }, () => {
      s.write(JSON.stringify({ command, params }) + '\n');
    });
    let buf = '';
    let resolved = false;
    s.on('data', d => {
      buf += d.toString();
      const nl = buf.indexOf('\n');
      if (nl >= 0 && !resolved) {
        resolved = true;
        s.destroy();
        try { resolve(JSON.parse(buf.substring(0, nl).trim())); }
        catch { resolve(buf.substring(0, nl).trim()); }
      }
    });
    s.on('error', e => { if (!resolved) { resolved = true; reject(e); } });
    setTimeout(() => { if (!resolved) { resolved = true; s.destroy(); reject(new Error('TIMEOUT')); } }, timeoutMs);
  });
}

function findNodes(tree, predicate, path = '') {
  const results = [];
  if (!tree) return results;
  const name = tree.name || '';
  const type = tree.type || '';
  const currentPath = path ? path + '/' + name : name;
  if (predicate(tree, currentPath)) results.push({ name, type, path: currentPath });
  for (const child of (tree.children || [])) {
    results.push(...findNodes(child, predicate, currentPath));
  }
  return results;
}

async function main() {
  const r = await sendCommand('get_scene_tree', {});
  if (!r.success || !r.tree) {
    console.log('Failed to get scene tree:', JSON.stringify(r));
    return;
  }

  // Find nodes with SPA-related names
  const spaNodes = findNodes(r.tree, (n) => {
    const name = (n.name || '').toLowerCase();
    return name.includes('placementactor') ||
           name.includes('spa') ||
           name.includes('coresceneplacementactor') ||
           name.includes('sceneplacement');
  });

  console.log('SPA-related nodes found:', spaNodes.length);
  for (const n of spaNodes) {
    console.log(`  ${n.path} [${n.type}]`);
  }

  // Also find edited scene root
  const editorNodes = findNodes(r.tree, (n) => {
    return (n.name || '').includes('EditorNode');
  });
  console.log('\nEditor nodes:', editorNodes.length);

  // Find top-level nodes with scripts
  const topNodes = (r.tree.children || []).map(c => ({
    name: c.name, type: c.type, children: (c.children || []).length
  }));
  console.log('\nTop-level nodes:');
  for (const n of topNodes) {
    console.log(`  ${n.name} [${n.type}] (${n.children} children)`);
  }
}

main().catch(e => console.error('Error:', e.message));
