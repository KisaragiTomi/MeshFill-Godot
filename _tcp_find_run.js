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

const NODE_PATH = '@EditorNode@18065/@Panel@14/@VBoxContainer@15/DockHSplitMain/@VBoxContainer@28/DockVSplitCenter/@VSplitContainer@70/@VBoxContainer@71/@EditorMainScreen@125/MainScreen/@CanvasItemEditor@9318/@VSplitContainer@9101/@HSplitContainer@9103/@HSplitContainer@9105/@Control@9106/@SubViewportContainer@9107/@SubViewport@9108/CoreScenePlacementActorDemo';

async function main() {
  // Baseline: verify call_method+has_method works on McpInteractionServer
  console.log('--- Baseline: McpInteractionServer custom method ---');
  try {
    const r = await sendCommand('call_method', { 
      node_path: 'McpInteractionServer', 
      method: 'has_method', 
      args: ['_handle_command'] 
    });
    console.log('McpInteractionServer has _handle_command:', JSON.stringify(r));
  } catch (e) { console.log('FAIL:', e.message); }
  
  await new Promise(r => setTimeout(r, 500));

  // Check if the SPA node's script is truly invalid
  try {
    const r = await sendCommand('call_method', { 
      node_path: NODE_PATH, 
      method: 'has_method', 
      args: ['_ready'] 
    });
    console.log('SPA has _ready:', JSON.stringify(r));
  } catch (e) { console.log('FAIL:', e.message); }

  await new Promise(r => setTimeout(r, 500));

  // Try DemoSetup child - it's a common_demo_setup.tscn instance
  // Check if DemoSetup has metadata set from the scene
  console.log('\n--- DemoSetup metadata ---');
  try {
    const r = await sendCommand('call_method', {
      node_path: NODE_PATH + '/DemoSetup',
      method: 'has_meta',
      args: ['source_doc']
    });
    console.log('DemoSetup has_meta(source_doc):', JSON.stringify(r));
  } catch (e) { console.log('FAIL:', e.message); }

  await new Promise(r => setTimeout(r, 500));

  // Check if editor_open_scene command exists now (after restart)
  console.log('\n--- Check editor_open_scene ---');
  try {
    const r = await sendCommand('editor_open_scene', { scene_path: 'test' });
    console.log('editor_open_scene response:', JSON.stringify(r));
  } catch (e) { console.log('FAIL:', e.message); }
}

main().catch(e => console.error('Error:', e.message));
