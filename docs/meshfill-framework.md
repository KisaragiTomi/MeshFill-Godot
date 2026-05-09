# MeshFill Framework

鏈枃妗ｆ暣鐞嗗綋鍓?MeshFill-Godot 妗嗘灦鐨勪富鏁版嵁褰掑睘銆佺敓鎴愰樁娈靛拰杩愯鏃舵煡璇㈣矾寰勩€傜粏鑺傚瓧娈佃 `asset-properties.md`锛屼綋绱犲満鎻愪氦涓庣紦瀛樿鍒欒 `scene-voxel-field-system.md`锛屾琚?GPU 绠＄嚎瑙?`vegetation-pipeline.md`锛屽悓绫昏祫浜?fitting 绠＄嚎瑙?`meshfill-rock-placement-flow.md`锛宍AutoObject` probe 绮楃瓫瑙?`autoobject-probe-prefilter.md`銆?
![MeshFill 褰撳墠妗嗘灦鎬昏](graphs/meshfill_current_framework.svg)

## Ownership

| Layer | Owner | Responsibility |
| --- | --- | --- |
| Asset defaults | `AutoObject`銆乣AutoRock`銆乣AutoVegetation`銆乣AutoVegetationAsset`銆乣AutoVoxelDescriptor`銆乣AutoVoxelProfile` | 淇濆瓨瀵硅薄榛樿璇箟銆佷綋绱犻鑹层€佸鏉傚害銆乥and銆佺矖纰版挒浣撶礌銆乸ivot variants銆乻emantic probes 鍜屽彲閫?profile 鍥為€€ |
| Probe prefilter | `AutoObject.semantic_probes`銆乣SceneVoxel` / `TargetSV`銆乣autoobject-probe-prefilter.md` | 浠?SV 涓鍙栧彲鏀剧疆 anchor锛岀敤姣忎釜 `AutoObject` 鐨?probes 閲囨牱娴嬭瘯锛岃緭鍑?anchor 鈫?AutoObject top-K 鍜?`autoobject_candidate_tiles` |
| Placement fitting | `CliffGenerator.generate_placement()`銆乣generate_surface_placement()` | 閫氱敤鍚岀被璧勪骇 fitting producer锛涘綋鍓嶇被鍚嶄粛鏄巻鍙插悕绉帮紝浣嗚灞備笉鍙湇鍔″博鐭炽€傚畠璇诲彇鍙?fitted 鐨勮祫浜с€乭eight/normal/mask 杈撳叆锛岃緭鍑哄甫 `position`銆乣scale`銆乣rotation_mode`銆乣rotation_degrees` 鐨?placement results锛沗AutoObject` 瀹炰緥浼氬拷鐣?`scale` |
| Placement consumers | `main.gd`銆乣VegetationExclusion`銆乺ecord builders | 鎶?placement result 鎴?scatter result 瀹炰緥鍖栦负鍏蜂綋 `AutoObject` 瀛愮被锛屼緥濡?`AutoRock`銆乣AutoVegetation` 鎴栧悗缁叾浠栧璞＄被鍨嬶紝鍐嶅啓鍏?`voxel_record` |
| Runtime record | record builders銆乣voxel_record` | builders 缁熶竴鍒涘缓鎴栨洿鏂?`voxel_record`锛沗voxel_record` 淇濆瓨鏈瀹炰緥鐨勪笘鐣屼綅缃€佸儚绱犲潗鏍囥€乥and 鍐欏叆銆佺鎾炲啓鍏ャ€乻ource 璇箟鍜屽洖鏌?id |
| Query projection | metadata銆乣AutoObjectManager` | 鍙仛杩愯鏃剁储寮曞拰璋冭瘯鏌ヨ锛屼笉浣滀负榛樿鍊兼潵婧?|
| Source voxel | `AutoSceneVoxel`銆乣BrushSceneVoxel` | 琛ㄨ揪褰撳墠 tick 鐨勮嚜鍔ㄧ敓鎴愭垨涓诲姩缂栬緫 delta锛沗BrushSceneVoxel` 閲嶇偣璁板綍 `modified_voxels` 鍜?`auto_mix` |
| Final state | `blend_scene_voxels()`銆乣SceneVoxel`銆乿oxel volume | 缁熶竴娣峰悎骞舵彁浜ょ粰涓嬩竴 tick銆侀獙璇併€佹煡璇㈠拰棰勮 |
| Global cache | `GlobalVoxelField` | sparse tile occupancy cache锛屽熀浜庡凡鎻愪氦 `SceneVoxel` 鍜?`CollisionVoxel` 閲嶅缓锛屽苟璁板綍鏈 dirty tile/rect 鏇存柊瓒宠抗 |

## Runtime Flow

```text
SceneState[tick - 1]
  -> placement fitting / vegetation scatter / brush edit
  -> AutoSceneVoxelDelta[tick] or BrushSceneVoxelDelta[tick]
  -> blend_scene_voxels(tick)
  -> SceneVoxel[tick]
  -> dirty tile/rect invalidation
  -> rebuild_global_voxel_field(tick)
  -> GlobalVoxelField tiles
  -> AutoObject probe prefilter: SV anchors + semantic_probes -> candidate tiles
  -> VoxelPlacementGenerator physical score / reduce / stamp
  -> voxel volume / occupancy / validation / debug query
```

妗嗘灦鐨勬牳蹇冪害鏉熸槸锛氳祫浜у瓧娈靛洖绛斺€滄垜鏄粈涔堚€濓紝杩愯鏃惰褰曞洖绛斺€滄垜杩欐鏀惧湪鍝噷鈥濓紝鏉ユ簮浣撶礌鍥炵瓟鈥滄湰 tick 鎯冲啓浠€涔堚€濓紱鍏朵腑 `BrushSceneVoxel` 鍙弿杩拌鏀逛簡鍝簺浣撶礌锛屼互鍙婅繖浜涗綋绱犲拰 auto 鐨勬贩鍚堟瘮渚嬶紝鏈€缁?`SceneVoxel` 鍥炵瓟鈥滃凡缁忔彁浜ょ粰鍚庣画绯荤粺璇诲彇鐨勭粨鏋滄槸浠€涔堚€濄€?
## Current Modules

| Module | Main files | Notes |
| --- | --- | --- |
| Asset model | `scripts/auto_object.gd`銆乣scripts/auto_voxel_descriptor.gd`銆乣scripts/auto_rock.gd`銆乣scripts/auto_vegetation.gd`銆乣scripts/auto_vegetation_asset.gd` | `AutoObject` 鏄叡鍚屽熀绫伙紝`AutoVoxelDescriptor` 鏄璞′綋绱犺涔変笌 probes 鐨勪富璺緞锛宲rofile 鍙仛鍙€夊洖閫€ |
| Asset scripting | `scripts/auto_asset_factory.gd`銆乣tools/scaffold_auto_asset.gd` | 鐢熸垚 rock scene asset銆乿egetation resource銆乸rofile 鍜屽瓙绫昏剼鏈?|
| Placement fitting | `scripts/cliff_generator.gd`銆乣shaders/*.glsl` | 閫氱敤鍚岀被璧勪骇 fitting runtime銆俙generate_placement()` / `generate_surface_placement()` 鏄潰鍚戝瀵硅薄绫诲瀷鐨勫叆鍙ｏ紱`generate_cliff_vertical()` 鏄吋瀹规棫宀╃煶娴佺▼鐨?2.5D 鍏ュ彛 |
| AutoObject probe prefilter | `docs/autoobject-probe-prefilter.md`銆乣scripts/semantic_probe_profile.gd`銆乣scripts/auto_object.gd` | 璁捐涓殑绮楃瓫灞傦細璇诲彇 SV 鍙斁缃綋绱狅紝鐢ㄦ瘡涓?`AutoObject.semantic_probes` 閲囨牱 `TargetSV` / `SV`锛岃緭鍑?`AutoObject` top-K 鍜屽€欓€?tiles |
| 3D voxel placement | `scripts/voxel_placement_generator.gd`銆乣shaders/score_voxel_tile.glsl`銆乣shaders/reduce_voxel_tiles.glsl`銆乣shaders/stamp_voxel_field.glsl` | 鐗╃悊绮剧瓫灞傦細浣跨敤 collision footprint銆乻upport銆乧ollision銆乧learance銆乼arget occupancy/color 璇勫垎骞?stamp 鍥炰綋绱犲満 |
| Rock placement consumer | `scripts/main.gd`銆乣scripts/auto_asset_factory.gd` | 褰撳墠鎶?fitting result 瀹炰緥鍖栦负 `AutoRock` 瀛愮被锛屽苟鎸夊博鐭冲瓧娈垫淳鐢?`voxel_record`锛涜繖鏄€氱敤 fitting 鐨勪竴涓?consumer |
| Vegetation placement | `scripts/vegetation_exclusion.gd`銆乣scripts/vegetation_scatter.gd` | 浣跨敤 height-band occupancy銆乻ource delta銆乣blend_scene_voxels()`銆乣GlobalVoxelField` 鍜?voxel volume 楠岃瘉锛屽苟瀹炰緥鍖?`AutoVegetation` 瀛愮被 |
| Incremental editing | `scripts/pcg_pipeline.gd`銆乣scripts/pcg_layer.gd`銆乣scripts/nutrition_layer.gd`銆乣scripts/main.gd` | dirty rect銆乷verride銆乥rush commit 鍜屽眬閮ㄥ埛鏂?|
| Runtime indexing | `scripts/auto_object_manager.gd`銆乵etadata | 鎸?`auto_id` 涓?`instance_id` 鏌ユ壘杩愯鏃跺璞¤褰?|

## Maintenance Rules

- 鏂板璧勪骇瀛楁鏃讹紝鍏堝垽鏂畠灞炰簬璧勪骇榛樿鍊笺€佽繍琛屾椂璁板綍銆佹潵婧愪綋绱犺繕鏄渶缁堢姸鎬併€?- metadata 鍙兘鎸傜储寮曘€佽皟璇曞瓧娈靛拰 `voxel_record` handle锛屼笉鑳芥垚涓哄璞￠粯璁ゅ€肩殑涓绘潵婧愩€?- 鑷姩鐢熸垚鍜岀瑪鍒蜂慨鏀瑰彧鍐欐湰 tick delta锛屽悗缁郴缁熷彧璇?commit 鍚庣殑 `SceneVoxel`銆?- `GlobalVoxelField` 鍙仛绋€鐤?occupancy tile 缂撳瓨鍜?dirty 鏇存柊瓒宠抗锛屼笉鐩存帴鎵挎媴鏈€缁堢紪杈戣涔夈€?- `CollisionVoxel` 淇濇寔鐙珛浜掓枼灞傦紝涓嶆贩鍏ョ敓鎬?height-band 璇箟銆?- `AutoObject` 涓嶅簲鐢ㄨ繍琛屾椂缂╂斁锛歚configure_auto_object()` 寮哄埗 `scale = Vector3.ONE`锛宻emantic probes 涔熸寜 unscaled asset/local space 鐢熸垚鍜岄噰鏍枫€?- Probe 绮楃瓫鍙噺灏戝€欓€?`AutoObject` / tile锛屼笉鐩存帴鍐欐渶缁?`SceneVoxel`锛屾渶缁堢墿鐞嗗彲琛屾€т粛鐢?footprint scoring 鍐冲畾銆?- 鏂囨。璇诲彇鍜屽啓鍏ョ粺涓€浣跨敤 UTF-8锛岄伩鍏嶄腑鏂囧唴瀹瑰嚭鐜颁贡鐮併€?- 鏂囨。鍜?SVG 鐨勬洿鏂伴『搴忓缓璁负锛氬瓧娈靛彉鏇村厛鏇存柊 `asset-properties.md`锛屾祦绋嬪彉鏇村啀鏇存柊鏈枃妗ｅ拰 `graphs/meshfill_current_framework.svg`銆?
