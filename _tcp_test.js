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

function waitForPort(host, port, maxWaitMs = 60000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tryConnect = () => {
      const s = net.createConnection({ host, port }, () => {
        s.destroy();
        resolve();
      });
      s.on('error', () => {
        if (Date.now() - start > maxWaitMs) {
          reject(new Error(`Port ${port} not available after ${maxWaitMs}ms`));
        } else {
          setTimeout(tryConnect, 2000);
        }
      });
    };
    tryConnect();
  });
}

async function main() {
  console.log('Waiting for Godot editor TCP 9090...');
  try {
    await waitForPort('127.0.0.1', 9090, 120000);
    console.log('TCP 9090 available!');
  } catch (e) {
    console.error(e.message);
    return;
  }

  // Wait extra for editor to fully initialize
  console.log('Waiting 5s for editor initialization...');
  await new Promise(r => setTimeout(r, 5000));

  // Step 1: Verify connection
  console.log('\n--- Verify connection ---');
  try {
    const r = await sendCommand('call_method', { node_path: 'McpInteractionServer', method: 'get_class' });
    console.log('Connection OK:', JSON.stringify(r));
  } catch (e) {
    console.log('FAIL:', e.message);
    return;
  }

  await new Promise(r => setTimeout(r, 500));

  // Step 2: Open SPA scene
  console.log('\n--- Opening SPA scene ---');
  try {
    const r = await sendCommand('editor_open_scene', {
      scene_path: 'res://demos/core-scene-placement-actor/core-scene-placement-actor.tscn'
    });
    console.log(JSON.stringify(r, null, 2));
    if (r.error) {
      console.log('editor_open_scene failed, command may not be loaded yet');
      return;
    }
  } catch (e) {
    console.log('FAIL:', e.message);
    return;
  }

  // Wait for scene to load and _ready() + run_all_tests.call_deferred() to complete
  console.log('Waiting 8s for scene load + tests to auto-run...');
  await new Promise(r => setTimeout(r, 8000));

  // Step 3: Get test results - try calling run_all_tests on the scene root
  console.log('\n--- Getting test results ---');
  try {
    // The scene root should be in the editor's viewport tree
    // First, find it
    const tree = await sendCommand('get_scene_tree', {});
    const treeStr = JSON.stringify(tree);
    
    // Look for CoreScenePlacementActorDemo
    const regex = /CoreScenePlacementActorDemo/;
    if (regex.test(treeStr)) {
      console.log('Found CoreScenePlacementActorDemo in tree!');
      
      await new Promise(r => setTimeout(r, 500));
      
      // Try calling run_all_tests
      const testResult = await sendCommand('call_method', {
        node_path: 'CoreScenePlacementActorDemo',
        method: 'run_all_tests'
      }, 30000);
      console.log('\nTest Results:');
      console.log(JSON.stringify(testResult, null, 2));
    } else {
      console.log('CoreScenePlacementActorDemo NOT found in tree');
      // Check what scene is currently edited
      const match = treeStr.match(/"name":"([^"]+Demo[^"]*)"/g);
      if (match) {
        console.log('Demo nodes found:', match.slice(0, 5));
      }
    }
  } catch (e) {
    console.log('FAIL:', e.message);
  }
}

main();
