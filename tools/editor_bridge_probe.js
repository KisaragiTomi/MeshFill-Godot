// Minimal TCP client for the MeshFill editor bridge (port 6800).
// Usage: node tools/editor_bridge_probe.js '<method>' '<json-params>'
const net = require('net');

function sendRequest(method, params, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: '127.0.0.1', port: 6800 }, () => {
      s.write(JSON.stringify({ id: Date.now(), method, params: params || {} }) + '\n');
    });
    let buf = '';
    let done = false;
    const timer = setTimeout(() => { if (!done) { done = true; s.destroy(); reject(new Error('TIMEOUT')); } }, timeoutMs);
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

async function main() {
  const method = process.argv[2];
  const params = process.argv[3] ? JSON.parse(process.argv[3]) : {};
  try {
    const r = await sendRequest(method, params);
    console.log(JSON.stringify(r, null, 2));
  } catch (e) {
    console.error('ERROR:', e.message);
    process.exit(1);
  }
}
main();
