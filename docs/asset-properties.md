# Asset Properties

鏈枃妗ｅ睍绀哄綋鍓?MeshFill-Godot 椤圭洰閲屽博鐭炽€佹琚拰閫氱敤鑷姩鐗╀綋鐨勮祫浜у睘鎬с€傞噸鐐规槸鈥滆祫浜ц惤鍒板満鏅悗搴旇甯﹀摢浜涙暟鎹€濓紝鑰屼笉鏄敓鎴愮畻娉曟湰韬€?
妗嗘灦灞傞潰鐨勬暟鎹綊灞炪€乼ick 娴佺▼鍜屾柊 SVG 鎬昏瑙?`meshfill-framework.md`銆?
## 1. 璧勪骇灞傜骇

```text
Runtime nodes
AutoObject
鈹溾攢 AutoRock
鈹? 鈹斺攢 AutoCliffRock
鈹斺攢 AutoVegetation
   鈹溾攢 AutoCanopyTree
   鈹溾攢 AutoMidstoryTree
   鈹溾攢 AutoBush
   鈹斺攢 AutoGrass

Persistent resources / helpers
鈹溾攢 AutoVoxelProfile
鈹溾攢 AutoRock / AutoCliffRock scene asset
鈹溾攢 AutoVegetationAsset
鈹斺攢 AutoAssetFactory
```

| 绫?/ 璧勬簮 | 绫诲瀷鎴栫户鎵?| 鐢ㄩ€?|
|---|---|---|
| `AutoObject` | `MeshInstance3D` | 鎵€鏈夎嚜鍔ㄧ敓鎴愮墿浣撶殑鍏叡鍩虹被 |
| `AutoRock` | `AutoObject` | 宀╃煶绫诲叕鍏卞熀绫?|
| `AutoCliffRock` | `AutoRock` | 褰撳墠鎮礀/宀╃煶濉厖鐢熸垚鐨勫叿浣撳博鐭?|
| `AutoVegetation` | `AutoObject` | 妞嶈绫诲叕鍏卞熀绫?|
| `AutoCanopyTree` | `AutoVegetation` | 鍐犲眰鏍?|
| `AutoMidstoryTree` | `AutoVegetation` | 涓眰鏍?|
| `AutoBush` | `AutoVegetation` | 鐏屾湪 |
| `AutoGrass` | `AutoVegetation` | 鑽夊湴 |
| `AutoVoxelProfile` | `Resource` | 鍙€夊叡浜綋绱犻璁撅紝淇濆瓨骞冲潎 `color`銆乣complexity`銆乣affected_bands` 鍜屽彲閫?`collision_voxels` |
| `AutoRock` scene asset | `PackedScene` root `AutoRock` | 鎸佷箙鍖栧博鐭?mesh銆乭eight texture銆丟PU fitting 灏哄銆侀殢鏈哄弬鏁板拰瀵硅薄浣撶礌瀛楁锛涚敓鎴愭椂涔熶綔涓鸿繍琛屾椂瀵硅薄瀛愮被鍘熷瀷 |
| `AutoVegetationAsset` | `Resource` | 鎸佷箙鍖栨琚璞′綋绱犲瓧娈点€佸彲閫?profile銆乵esh 鏉ユ簮銆乻catter 鍙傛暟銆乿isual layer 鍜?group |
| `AutoAssetFactory` | `RefCounted` helper | 鑴氭湰鍖栧垱寤鸿祫浜ц祫婧愩€佸彲閫?profile 棰勮銆佸瓙绫昏剼鏈拰 object-field-derived `voxel_record` |

## 2. 閫氱敤瀵硅薄灞炴€?
杩欎簺灞炴€ч€傚悎宀╃煶鍜屾琚叡鐢紝鏀惧湪 `AutoObject`銆?
浣撶礌榛樿鍊肩殑涓诲綊灞炰篃鍦?`AutoObject`锛歚voxel_color`銆乣voxel_complexity`銆乣affected_bands`銆乣collision_voxels` 鍙互鐩存帴闅忓璞″師鍨嬫寔涔呭寲銆俙AutoVoxelProfile` 鍙槸鍙€夊叡浜璁撅紱褰撳璞″瓧娈典负绌烘垨淇濇寔榛樿鍊兼椂锛岃繍琛屾椂鎵嶄粠 profile 璇诲彇鍥為€€鍊笺€?
| 灞炴€?| 绫诲瀷 | 璇存槑 |
|---|---|---|
| `auto_id` | `String` | 杩愯鏃跺敮涓€ id锛岄€氬父鍜岃妭鐐瑰悕涓€鑷?|
| `instance_id` | `int` | Godot 杩愯鏃跺疄渚?id锛屾潵鑷?`get_instance_id()` |
| `auto_source` | `String` | 鏉ユ簮鏍囪锛屼緥濡?`meshfill`銆乣scatter`銆乣brush` |
| `object_type` | `String` | 澶х被锛屼緥濡?`rock`銆乣vegetation`銆乣terrain` |
| `object_subtype` | `String` | 瀛愮被锛屼緥濡?`cliff`銆乣canopy_tree`銆乣bush` |
| `mesh` | `Mesh` | 鍙缃戞牸锛岀户鎵胯嚜 `MeshInstance3D` |
| `position` | `Vector3` | 涓栫晫浣嶇疆 |
| `rotation_mode` | `String` | 鏃嬭浆妯″紡鏋氫妇锛歚Y` 鍙娇鐢?Y 杞达紝`XYZ` 浣跨敤瀹屾暣娆ф媺瑙?|
| `rotation_degrees` | `Vector3` | 鏃嬭浆瑙掑害锛沗Y` 妯″紡鍙鍙?`.y`锛宍XYZ` 妯″紡璇诲彇 `.x/.y/.z` |
| `scale` | `Vector3` | 涓栫晫缂╂斁 |
| `bound_min_length` | `float` | 鐗╀綋 mesh bound 缁忚繃 scale 鍚庣殑鏈€灏忚酱鍚戦暱搴?|
| `min_spacing` | `float` | 鐗╀綋杞翠腑蹇冪殑鏈€灏忛棿闅斿崐寰勶紝榛樿 `bound_min_length * 0.5` |
| `visual_layer` | `int` | 娓叉煋灞傦紝鐢ㄤ簬璋冭瘯鍜屽彲瑙佹€ф帶鍒?|
| `material_override` | `Material` | 鍗曞疄渚嬫潗璐ㄨ鐩?|
| `voxel_color` | `Color` | 鐗╀綋绾у钩鍧?voxel/debug 棰滆壊锛宍alpha` 鍚屾骞冲潎澶嶆潅搴?|
| `voxel_complexity` | `float` | 鐗╀綋绾у钩鍧囧鏉傚害鎴栧崰鐢ㄥ己搴︼紝鑼冨洿 `0.0-1.0` |
| `affected_bands` | `Array[Dictionary]` | 璇ョ墿浣撳奖鍝嶅摢浜涢珮搴︽尝娈?|
| `collision_voxels` | `Array[Dictionary]` | 璇ョ墿浣撳啓鍏ユ渶缁堢鎾炰簰鏂ュ眰鐨勭矖浣撶礌锛涜崏銆佹爲鍙跺拰缁嗘灊閫氬父涓虹┖ |
| `voxel_record` | `Dictionary` | 鐗╀綋鍐欏叆 voxel/occupancy 绯荤粺鐨勮繍琛屾椂璁板綍锛涘厛娲剧敓鏉ユ簮 voxel锛屽啀娣峰悎涓烘渶缁?`SceneVoxel` |

閫氱敤 metadata锛?
| Meta key | 璇存槑 |
|---|---|
| `auto_id` | 瀵硅薄 id |
| `auto_instance_id` | `AutoObject.instance_id`锛岀敤浜庤繍琛屾椂鎸夊疄渚嬫煡鎵?|
| `instance_id` | 涓?`auto_instance_id` 鍚屾簮锛屽啓鍏?`voxel_record` 鏃朵篃浼氳褰?|
| `instance_mesh_id` | 瀹為檯闄勫甫鐨?`MeshInstance3D.get_instance_id()` |
| `auto_source` | 瀵硅薄鏉ユ簮锛岀瑪鍒锋琚浐瀹氭爣璁颁负 `brush` |
| `auto_object_type` | 瀵硅薄澶х被 |
| `auto_object_subtype` | 瀵硅薄瀛愮被 |
| `voxel_record` | 瀹屾暣 voxel record锛屽寘鍚潵婧?voxel 鍜屾渶缁?`SceneVoxel` 鎵€闇€鐨勫璞＄紪鍙枫€乵esh instance id |

metadata 鏄寕鍦?Godot `Node/Object` 涓婄殑杩愯鏃堕敭鍊兼暟鎹€傝繖閲屾弿杩扮殑鏄?`AutoObject` 閫氱敤 metadata锛氬畠涓嶆槸鏇夸唬绫诲睘鎬э紝涔熶笉鏄浜屽鐘舵€佺郴缁燂紱鍙繚瀛樿繍琛屾椂绱㈠紩鍜?`voxel_record` 鎸傝浇鐐癸紝鏂逛究璋冭瘯銆侀€夋嫨宸ュ叿銆佸閮ㄨ剼鏈垨 MCP 鏌ヨ蹇€熷畾浣嶅璞°€傛祴璇曟爣璁般€乼errain debug cache 杩欑被涓存椂宸ュ叿 metadata 鍙互瀛樺湪锛屼絾涓嶈兘浣滀负瀵硅薄榛樿鍊兼潵婧愩€?
瀵硅薄鐘舵€佸彧璇昏繖浜涗富鏁版嵁婧愶細

| 鏁版嵁 | 涓讳綅缃?|
|---|---|
| 璧勪骇榛樿鍊?/ 瀹炰緥瑕嗙洊 | `AutoObject` 瀛楁鎴栧紩鐢ㄧ殑 `Resource` |
| 鍦烘櫙钀界偣銆佸儚绱犮€乻lice銆侀鑹层€乥and銆乧ollision | `voxel_record` |
| 鏈€缁堟贩鍚堢姸鎬?| `VegetationExclusion` / scene voxel volume |

褰撳墠鍚屾鍏崇郴锛?
| 鏉ユ簮 | Metadata | 璇存槑 |
|---|---|---|
| `AutoObject.auto_id` | `auto_id` | 缁熶竴鏌ヨ id |
| `AutoObject.instance_id` | `auto_instance_id` / `instance_id` | 缁熶竴鏌ヨ杩愯鏃跺疄渚?|
| `MeshInstance3D.get_instance_id()` | `instance_mesh_id` | 鏈€缁?`SceneVoxel` 鍥炴煡瀹為檯娓叉煋瀹炰緥 |
| `AutoObject.auto_source` | `auto_source` | 缁熶竴鏌ヨ鏉ユ簮锛涚瑪鍒锋斁缃殑妞嶈涓?`brush` |
| `AutoObject.object_type` | `auto_object_type` | 鐢ㄤ簬蹇€熷尯鍒嗗博鐭炽€佹琚€佸湴褰㈢瓑澶х被 |
| `AutoObject.object_subtype` | `auto_object_subtype` | 鐢ㄤ簬蹇€熷尯鍒?`cliff`銆乣bush`銆乣canopy_tree` 绛夊叿浣撶被鍨?|
| `AutoObject.voxel_record` | `voxel_record` | 瀹屾暣 voxel 鍐欏叆鏁版嵁锛屽寘鍚潵婧?voxel 绫诲瀷銆佹贩鍚堝瓧娈靛拰姣忓眰 `SenceLayerVoxel` |

闂撮殧瑙勫垯锛歚min_spacing` 榛樿绛変簬 `bound_min_length * 0.5`銆傚垽鏂袱涓墿浣撴槸鍚﹀お杩戞椂锛岀敤 XZ 杞翠腑蹇冭窛绂绘瘮杈?`a.min_spacing + b.min_spacing`锛涘悓灏哄鐗╀綋榛樿灏辩瓑浠蜂簬杞翠腑蹇冭嚦灏戠浉璺濅竴涓?bound 鏈€灏忛暱搴︺€?
宀╃煶绀轰緥锛?
| 椤?| 绀轰緥鍊兼垨瀛楁 | 璇存槑 |
|---|---|---|
| 鑺傜偣 | `AutoCliffRock` / `"Cliff_s1_0_m0"` | 鎮礀宀╃煶瀹炰緥 |
| `auto_id` | `"Cliff_s1_0_m0"` | 瀵硅薄绋冲畾 id |
| `auto_instance_id` | `AutoObject.instance_id` | 杩愯鏃跺璞″疄渚?id |
| `instance_mesh_id` | `MeshInstance3D.get_instance_id()` | 瀹為檯娓叉煋瀹炰緥 id |
| `auto_source` | `"meshfill"` | 鏉ユ簮绯荤粺 |
| `auto_object_type` / `auto_object_subtype` | `"rock"` / `"cliff"` | 澶х被鍜屽瓙绫?|
| `voxel_record` | `color`銆乣complexity`銆乣affected_bands`銆乣collision_voxels`銆乣auto_object_id`銆乣instance_mesh_id`銆乣type`銆乣SenceLayerVoxel` | 鍦烘櫙 voxel 鍐欏叆鍜屽洖鏌ュ瓧娈?|

妞嶈绀轰緥锛?
| 椤?| 绀轰緥鍊兼垨瀛楁 | 璇存槑 |
|---|---|---|
| 鑺傜偣 | `AutoBush` / `"Bush_12"` | 鐏屾湪瀹炰緥 |
| `auto_id` | `"Bush_12"` | 瀵硅薄绋冲畾 id |
| `auto_instance_id` | `AutoObject.instance_id` | 杩愯鏃跺璞″疄渚?id |
| `instance_mesh_id` | `MeshInstance3D.get_instance_id()` | 瀹為檯娓叉煋瀹炰緥 id |
| `auto_source` | `"brush"` 鎴?`"scatter"` | 绗斿埛鎴栨暎甯冩潵婧?|
| `auto_object_type` / `auto_object_subtype` | `"vegetation"` / `"bush"` | 澶х被鍜屽瓙绫?|
| `voxel_record` | `color`銆乣complexity`銆乣affected_bands`銆乣collision_voxels`銆乣auto_object_id`銆乣instance_mesh_id`銆乣type`銆乣SenceLayerVoxel` | 鍦烘櫙 voxel 鍐欏叆鍜屽洖鏌ュ瓧娈?|

閫氱敤鏌ヨ绀轰緥锛?
```gdscript
func print_auto_object_summary(node: Node) -> void:
	if not node.has_meta("auto_id"):
		return

	var record: Dictionary = node.get_meta("voxel_record", {})
	print("id=%s iid=%d source=%s type=%s/%s color=%s complexity=%.2f" % [
		node.get_meta("auto_id"),
		int(node.get_meta("auto_instance_id")),
		node.get_meta("auto_source"),
		node.get_meta("auto_object_type"),
		node.get_meta("auto_object_subtype"),
		record.get("color", Color.WHITE),
		float(record.get("complexity", 1.0)),
	])
```

### 鎸佷箙鍖栧璞′綋绱犲瓧娈典笌鍦烘櫙 voxel record

姣忎釜璧勪骇搴旇鏈夎嚜宸辩殑鎸佷箙鍖栦綋绱犳暟鎹紝杩愯鏃跺啀鏍规嵁杩欎簺鎸佷箙鍖栨暟鎹幓褰卞搷鍦烘櫙浣撶礌鏁版嵁銆傚綋鍓嶄富鏁版嵁鏀惧湪 `AutoObject` 鎴?`AutoVegetationAsset` 鐨勫璞″瓧娈典笂锛沗AutoVoxelProfile` 鍙綔涓哄彲閫夊叡浜璁撅紝閫傚悎澶氫釜璧勪骇澶嶇敤鍚屼竴缁勯粯璁ゅ€笺€備篃灏辨槸璇达細

```text
Asset persistent object voxel fields
  -> optional AutoVoxelProfile preset fallback
  -> placed AutoObject instance
  -> runtime voxel_record
  -> SceneVoxelBase fields
  -> AutoSceneVoxel / BrushSceneVoxel
  -> blend_scene_voxels()
  -> SceneVoxel
  -> GlobalVoxelField sparse occupancy tiles
  -> scene occupancy / voxel volume

collision_voxels
  -> CollisionVoxel
  -> collision occupancy
```

杩欓噷鐨?`SceneVoxelBase` 鏄帹鑽愮殑鍏卞悓 schema銆傚綋鍓嶄唬鐮佷富瑕佺敤 `Dictionary` 浼犻€掕褰曪紱builder 浼氬啓鍏?`source_voxel_type`銆乣source_kind`銆乣producer_stage`锛宍apply_mesh_voxel_record()` 鍜?`blend_scene_voxels()` 鍐嶈ˉ榻?tick 鍜?commit 瀛楁銆傚鏋滃悗缁敼鎴?Godot class/resource锛屼篃搴旇鏉ユ簮浣撶礌鍜屾渶缁堜綋绱犵户鎵垮悓涓€濂楀叕鍏卞瓧娈点€?
```text
SceneVoxelBase
鈹溾攢 SourceSceneVoxel
鈹? 鈹溾攢 AutoSceneVoxel
鈹? 鈹斺攢 BrushSceneVoxel
鈹斺攢 SceneVoxel

CollisionVoxel  # 鐙珛鏈€缁堜簰鏂ュ眰锛屼笉缁ф壙 SceneVoxelBase
```

`AutoSceneVoxel` 鍜?`BrushSceneVoxel` 涓嶅缓璁洿鎺ョ户鎵库€滄渶缁堢姸鎬佲€濈殑 `SceneVoxel` 璇箟锛涙洿閫傚悎缁ф壙鍏卞悓鐖剁骇 `SceneVoxelBase`銆傝繖鏍锋潵婧愪綋绱犲彲浠ュ拰鏈€缁堜綋绱犱繚鎸佸瓧娈典竴鑷达紝鍚屾椂淇濈暀 `SceneVoxel` 鍙〃绀哄凡娣峰悎銆佸凡鎻愪氦缁撴灉鐨勫惈涔夈€?
杩欎簺鏁版嵁灞傜殑鑱岃矗涓嶅悓锛?
| 灞?| 鏄惁鎸佷箙鍖?| 鍐呭 | 涓嶅寘鍚?|
|---|---|---|---|
| `AutoObject` voxel fields | 鏄?| 璧勪骇鎴栧師鍨嬫湰韬殑骞冲潎 `color`銆佸钩鍧?`complexity`銆佸奖鍝嶅摢浜?`affected_bands`銆佸彲閫?`collision_voxels` | 涓栫晫浣嶇疆銆佽妭鐐硅矾寰勩€佸満鏅儚绱犲潗鏍?|
| `AutoVoxelProfile` | 鍙€?| 鍙鐢ㄧ殑浣撶礌棰勮锛岀敤浜庣粰澶氫釜瀵硅薄鎻愪緵鐩稿悓榛樿鍊?| 鏈鏀剧疆浣嶇疆銆佽繍琛屾椂瀹炰緥 id銆佸璞″敮涓€韬唤 |
| `AutoRock` scene asset | 鏄?| 宀╃煶 mesh銆乭eight texture銆乣mesh_size`銆侀殢鏈哄弬鏁般€佸璞′綋绱犲瓧娈靛拰鍙€?`voxel_profile` 寮曠敤 | 鏈鏀剧疆浣嶇疆銆佽繍琛屾椂瀹炰緥 id |
| `AutoVegetationAsset` | 鏄?| 妞嶈 subtype銆乥and銆佸璞′綋绱犲瓧娈点€佸彲閫?profile銆乵esh 鏉ユ簮銆乻catter 鍙傛暟銆乿isual layer 鍜?group | 鏈鏁ｅ竷浣嶇疆銆佽繍琛屾椂瀹炰緥 id |
| `voxel_record` | 鍚︼紝杩愯鏃舵淳鐢?| 鏈瀹炰緥鏀剧疆鍚庣殑 `position`銆乣scale`銆乣base_pixel`銆乣SenceLayerVoxel`銆乻ource 瀛楁锛屽苟娲剧敓 `SceneVoxelBase` 鍏叡瀛楁 | 璧勪骇婧愭暟鎹殑鍞竴鏉ユ簮 |
| `SceneVoxelBase` | 鍚︼紝鍏卞悓 schema | 鏉ユ簮浣撶礌鍜屾渶缁堜綋绱犻兘蹇呴』淇濇寔涓€鑷寸殑鍏叡瀛楁 | 鏉ユ簮涓撳睘瀛楁銆佹渶缁堟贩鍚堝瓧娈?|
| `AutoSceneVoxel` | 鍚︼紝杩愯鏃舵淳鐢?| 鑷姩鐢熸垚绯荤粺杈撳嚭鐨勬潵婧愪綋绱狅紝渚嬪 `meshfill`銆乣scatter`銆佺▼搴忓寲妞嶈鍜岃嚜鍔ㄥ博鐭?| 绗斿埛瑕嗙洊銆佷汉宸ュ垹闄ゃ€佷富鍔ㄤ慨鏀?|
| `BrushSceneVoxel` | 鍚︼紝杩愯鏃舵淳鐢?| 绗斿埛鍜屼富鍔ㄤ慨鏀硅緭鍑虹殑鏉ユ簮浣撶礌锛岃褰曡淇敼鐨勪綋绱犻泦鍚堝拰涓?auto 鐨勬贩鍚堟瘮渚?| 鑷姩鐢熸垚鍊欓€夊拰鑷姩鏁ｅ竷鍐崇瓥 |
| `SceneVoxel` | 鍚︼紝娣峰悎鍚庢淳鐢?| `AutoSceneVoxel` 涓?`BrushSceneVoxel` 鐨勬渶缁堟贩鍚堢粨鏋滐紝渚?occupancy銆乿oxel volume銆侀獙璇佸拰鏌ヨ璇诲彇 | 鍗曚竴鏉ユ簮鐨勭紪杈戞剰鍥?|
| `GlobalVoxelField` | 鍚︼紝鎻愪氦鍚庢淳鐢?| committed `SceneVoxel` 鐨?sparse occupancy tile cache锛屼繚瀛?tile銆乥ounds銆乨irty 鏇存柊瓒宠抗鍜岀粺璁?| 璧勪骇榛樿鍊笺€佺紪杈戞剰鍥俱€乻igned distance 缁嗚妭 |
| `CollisionVoxel` | 鍚︼紝鏈€缁堜簰鏂ュ眰 | 绮楃暐鍒氫綋鍗犵敤锛屼緥濡傜矖鏍戝共鎴栧ぇ宀╃煶锛涙斁缃椂璇诲彇骞朵簰鏂?| 鑽夈€佹爲鍙躲€佺粏鏋濈瓑鍙┛鎻掓垨鏌旀€ч儴鍒?|

### Generation tick 瑙ｈ€︽ā鍨?
`generation_tick` 鏄敓鎴愯皟搴﹀櫒鐨勫崟璋冮€掑鐗堟湰鍙枫€傛瘡涓郴缁熷彧璇诲彇宸茬粡鎻愪氦鐨勬棫 tick锛屽彧鍐欏叆褰撳墠 tick 鐨?delta锛屾渶鍚庣敱缁熶竴 commit 闃舵鍙戝竷鏂扮殑 `SceneVoxel`銆傝繖鏍风煶澶淬€佹斁缃〃闈€佹琚€佺瑪鍒峰拰楠岃瘉涔嬮棿鍙€氳繃蹇収閫氫俊锛屼笉閫氳繃鍗虫椂鍓綔鐢ㄩ€氫俊銆?
```text
SceneState[tick - 1]  # 鍙锛氫笂涓€杞凡鎻愪氦鐨?surfaces / occupancy / SceneVoxel
  -> system writes AutoSceneVoxelDelta[tick] or BrushSceneVoxelDelta[tick]
  -> blend_scene_voxels(tick)
  -> SceneState[tick]  # 鍙湪 commit 鍚庡叕寮€缁欎笅涓€杞鍙?```

tick 瀛楁绾﹀畾锛?
| 瀛楁 | 鍚箟 |
|---|---|
| `generation_tick` | 璇ヨ褰曟墍灞炵殑鐢熸垚 tick锛岄€氬父绛変簬 `write_tick` |
| `read_tick` | 鏈郴缁熻鍙栫殑绋冲畾杈撳叆 tick锛岄粯璁ゆ槸 `generation_tick - 1` |
| `write_tick` | 鏈郴缁熷啓鍏?delta 鐨?tick |
| `commit_tick` | `SceneVoxel` 娣峰悎瀹屾垚骞跺叕寮€鐨?tick |
| `producer_stage` | 浜х敓璇ヨ褰曠殑闃舵锛屼緥濡?`terrain_surface`銆乣placement_fitting`銆乣rock_placement`銆乣surface_build`銆乣vegetation_scatter`銆乣brush_edit`銆乣blend` |

瑙ｈ€﹁鍒欙細

1. 鑷姩绯荤粺鍙 `SceneState[read_tick]`锛屽彧鍐?`AutoSceneVoxelDelta[write_tick]`銆?2. 绗斿埛鍜屼富鍔ㄤ慨鏀瑰彧鍐?`BrushSceneVoxelDelta[write_tick]`銆?3. `blend_scene_voxels(write_tick)` 鏄敮涓€鍏佽鎶?`AutoSceneVoxel`銆乣BrushSceneVoxel` 鍜屼笂涓€杞?`SceneVoxel` 鍚堟垚涓烘柊鐘舵€佺殑鍦版柟銆?4. 楠岃瘉鍙互璇诲彇鏈?tick 鐨?`SceneVoxel` candidate锛屼絾涓嶈兘淇敼宸叉彁浜ょ姸鎬侊紱commit 鍚庣殑 occupancy銆乿oxel volume銆佹煡璇㈠拰鍚庣画绯荤粺鍙 `SceneVoxel[commit_tick]`銆?5. 濡傛灉鏌愪釜绯荤粺闇€瑕佽鍙栧彟涓€涓郴缁熷垰鍐欏嚭鐨勭粨鏋滐紝蹇呴』鎺掑埌涓嬩竴涓?`generation_tick`锛岃€屼笉鏄湪鍚屼竴涓?tick 鍐呯洿鎺ヨ鍙栥€?6. 鏃?`voxel_record` 琚噸澶嶅簲鐢ㄦ椂锛宍apply_mesh_voxel_record()` 浼氭妸 `generation_tick` 鍜?`write_tick` 閲嶆柊缁戝畾鍒版湰娆″啓鍏?tick锛涙寔涔呭寲璁板綍涓嶈兘鎶婃棫 tick 鍐欏洖 source delta銆?
鍏稿瀷 tick 椤哄簭锛?
| Tick | 璇诲彇 | 鍐欏叆 | 缁撴灉 |
|---:|---|---|---|
| `0` | 鍒濆 terrain 鏁版嵁 | terrain surface / base `SceneVoxel` | 寤虹珛鍒濆鍙斁缃〃闈?|
| `1` | `SceneState[0]` | 宀╃煶 `AutoSceneVoxel`銆乺ock occupancy銆乺ock top surface delta | 鐭冲ご鍜屾柊琛ㄩ潰鍦?commit 鍚庡彲瑙?|
| `2` | `SceneState[1]` | 鑽?鐏屾湪/鏍戠殑 `AutoSceneVoxel` | 妞嶈璇诲彇宸叉彁浜ょ殑鐭冲ご闃绘尅鍜岀煶澶磋〃闈?|
| `3+` | `SceneState[tick - 1]` | `BrushSceneVoxel` 鎴栧閲忚嚜鍔ㄧ敓鎴愮粨鏋?| 涓诲姩淇敼鍜屽眬閮ㄩ噸鐢熸垚閫氳繃娣峰悎闃舵杩涘叆鏈€缁堢姸鎬?|

鎸佷箙鍖栧璞′綋绱犲瓧娈?/ profile 棰勮绀轰緥锛?
| 璧勪骇 | 鍒涘缓鏂瑰紡 | 鍙傛暟 | 缁撴灉 |
|---|---|---|---|
| 宀╃煶 | `AutoRock.voxel_color` + `AutoRock.affected_bands` | `Color(0.55, 0.50, 0.45, 1.0)`銆乣1.0` | 浣跨敤宀╃煶骞冲潎浣撶礌棰滆壊鍜屽鏉傚害锛岄粯璁ら樆鎸″叏閮ㄦ琚?band |
| 鐏屾湪 | `AutoVegetation.affected_bands` | `understory`銆乣1.0`銆乣Color(0.8, 0.6, 0.2, 0.7)`銆乣0.7` | 鍙奖鍝?understory band锛屽崐寰勪负 `1.0` 涓栫晫鍗曚綅 |
| 鑺?| `AutoVegetationAsset` 瀵硅薄浣撶礌瀛楁 + 鍙€?`AutoVoxelProfile` | `ground`銆乣0.25`銆乣Color(0.9, 0.35, 0.5, 0.7)` | 鎸佷箙鍖栧璞′綋绱犲瓧娈点€乵esh 鏉ユ簮鍜?scatter 鍙傛暟锛屾暎甯冩椂鍒涘缓 `AutoFlower` |

杩愯鏃舵淳鐢熺ず渚嬶細

| 娲剧敓瀛楁 | 鏉ユ簮 | 鐢ㄩ€?|
|---|---|---|
| `asset_voxel_fields` | `asset.voxel_color` / `asset.affected_bands` / `asset.collision_voxels` | 璇诲彇璧勪骇鎸佷箙鍖栧璞′綋绱犲瓧娈?|
| `scene_radius` | `placed_mesh_radius` | 鎸夋湰娆″満鏅缉鏀惧緱鍒板奖鍝嶅崐寰?|
| `affected_bands` | `asset.get_affected_bands(scene_radius)` | 鐢熸垚楂樺眰娉㈡澹版槑锛涘繀瑕佹椂鍥為€€鍒?profile 棰勮 |
| `collision_voxels` | `asset.get_collision_voxels(scene_radius)` 鎴栬繍琛屾椂浼犲叆 | 鐢熸垚鏈€缁堢鎾炰簰鏂ュ眰鐨勭矖浣撶礌澹版槑 |
| `id` / `type` | `node.name` / 瀵硅薄绫诲瀷 | 鏍囪瘑鏈鍦烘櫙瀵硅薄 |
| `position` / `scale` | `node.position` / `node.scale` | 璁板綍鏈瀹炰緥鐨勪笘鐣屽彉鎹?|
| `color` / `complexity` | `asset.get_voxel_color()` / `asset.get_voxel_complexity()` | 鍐欏叆璧勪骇骞冲潎浣撶礌棰滆壊鍜屽崰鐢ㄥ己搴?|
| `source_voxel_type` / `source_kind` | `AutoSceneVoxel` / `auto` | 鏍囨槑鑷姩鐢熸垚鏉ユ簮锛涚瑪鍒锋垨涓诲姩淇敼鏀逛负 `BrushSceneVoxel` |
| `generation_tick` / `read_tick` / `write_tick` | 鐢熸垚璋冨害鍣?| 璁板綍蹇収璇诲彇鍜?delta 鍐欏叆椤哄簭 |
| `producer_stage` | 渚嬪 `placement_fitting` 鎴?`rock_placement` | 鏍囨槑浜х敓璇ヨ褰曠殑绯荤粺闃舵锛涢€氱敤 fitting 鍙互琚博鐭虫垨鍏朵粬瀵硅薄 consumer 澶嶇敤 |
| `SenceLayerVoxel` | 鍦烘櫙 band銆乣base_pixel`銆乿oxel volume | 娲剧敓姣忓眰鍏蜂綋鍐欏叆鏁版嵁 |
| `CollisionVoxel` | `collision_voxels`銆乣base_pixel`銆乿oxel volume | 娲剧敓鏈€缁堢鎾炰簰鏂ュ眰鍐欏叆鏁版嵁 |

鍏抽敭鍘熷垯锛氳祫浜ц礋璐ｄ繚瀛樷€滄垜鏄粈涔堜綋绱犲舰鐘?棰滆壊/澶嶆潅搴︹€濓紝鍦烘櫙璐熻矗璁＄畻鈥滄垜杩欐鏀惧湪鍝噷銆佸啓鍏ュ摢浜涘儚绱犲拰 voxel slice鈥濄€傝嚜鍔ㄧ敓鎴愬拰绗斿埛淇敼涓嶇洿鎺ヨ鐩栧郊姝わ紱瀹冧滑鍒嗗埆鍦ㄨ嚜宸辩殑 `generation_tick` 鍐欏叆 `AutoSceneVoxel` 涓?`BrushSceneVoxel` delta锛屾渶鍚庣敱娣峰悎闃舵浜у嚭鍙緵涓嬩竴 tick 璇诲彇鐨?`SceneVoxel`銆?
## 3. 鏁版嵁璧勪骇锛歚AutoRock` 鍦烘櫙璧勪骇涓?`AutoVegetationAsset`

`AutoRock` / `AutoCliffRock` 鍦烘櫙璧勪骇鏄綋鍓嶅博鐭?consumer 浣跨敤鐨?mesh 鏁版嵁鍘熷瀷锛岃礋璐ｆ弿杩扳€滃彲琚斁缃殑宀╃煶璧勪骇鈥濄€傞€氱敤 placement fitting 灞傝鍙栧彲 fitted 璧勪骇鐨?mesh銆侀珮搴﹀浘銆佸昂瀵稿拰闅忔満鍙傛暟锛涘叿浣?consumer 鍐嶅喅瀹氭妸缁撴灉瀹炰緥鍖栨垚 `AutoRock`銆佹琚垨鍚庣画鍏朵粬 `AutoObject` 瀛愮被銆?
鍦ㄦ鏋跺浘閲岋紝`CliffGenerator.generate_placement()` / `generate_surface_placement()` 琚彁鍗囦负鐙珛鐨?placement fitting 灞傘€傚博鐭宠矾寰勫彧鏄 fitting 缁撴灉鐨勫綋鍓?consumer锛氬畠杈撳嚭 `AutoRock` / `AutoCliffRock` 瀹炰緥锛涙琚?scatter 浠嶇敱 `VegetationExclusion` 璐熻矗鍗犵敤妫€鏌ュ苟杈撳嚭 `AutoVegetation` 瀛愮被銆俙CliffGenerator` 涓?`VegetationExclusion` 鏄疄鐜扮郴缁燂紝涓嶆槸 `AutoObject` 瀛愮被锛涚湡姝ｇ殑鍦烘櫙瀵硅薄鎵嶇户鎵?`AutoObject`銆?
| 灞炴€?| 绫诲瀷 | 榛樿鍊?| 璇存槑 |
|---|---|---|---|
| `mesh` | `Mesh` | `null` | 瀹為檯宀╃煶缃戞牸 |
| `mesh_height_texture` | `Texture2D` | `null` | 瀵瑰簲璇?mesh 鐨勯珮搴﹀浘 |
| `mesh_size` | `float` | `1.0` | 鍙備笌 GPU fitting 鐨勮祫浜у昂瀵?|
| `voxel_color` | `Color` | `(0.55, 0.50, 0.45, 1.0)` | 涓讳綋绱犻鑹诧紱`alpha` 鍚屾 `voxel_complexity` |
| `voxel_complexity` | `float` | `1.0` | 涓讳綋绱犲鏉傚害鎴栧崰鐢ㄥ己搴?|
| `affected_bands` | `Array[Dictionary]` | all bands fallback | 涓诲彈褰卞搷楂樺害 band |
| `collision_voxels` | `Array[Dictionary]` | `[]` | 鍙€夌矖纰版挒浣撶礌锛岀敤浜庢渶缁堢鎾炰簰鏂ュ眰 |
| `voxel_profile` | `AutoVoxelProfile` | `null` | 鍙€夊叡浜綋绱犻璁撅紱瀵硅薄瀛楁涓虹┖鎴栭粯璁ゆ椂鐢ㄤ簬鍥為€€ |
| `random_rotate` | `Vector2` | `(0.0, 0.0)` | 闅忔満鏃嬭浆鑼冨洿 |
| `random_scale` | `Vector2` | `(1.0, 1.0)` | 闅忔満缂╂斁鑼冨洿 |
| `random_height_offset` | `Vector2` | `(0.0, 0.0)` | 闅忔満楂樺害鍋忕Щ鑼冨洿 |

宀╃煶鍔犺浇璺緞锛?
| 鏉ユ簮 | 璇存槑 |
|---|---|
| `Main.rock_asset_paths` | 鏄惧紡鍒楀嚭鐨?`AutoRock` 鍦烘櫙璧勪骇锛涙棫 `MeshDataAsset` 浼氬吋瀹硅浆鎹?|
| `Main.rock_asset_dir` | 榛樿鎵弿 `res://assets/rocks` 涓嬬殑 `.tscn` / `.scn` / `.tres` / `.res` |
| `geo/cliff_01.FBX` + `geo/cliff_01_height.raw` | 鍐呯疆澶栭儴瀵煎叆鎮礀璧勪骇 |
| `geo/cliff_02.FBX` + `geo/cliff_02_height.raw` | 鍐呯疆澶栭儴瀵煎叆鎮礀璧勪骇 |
| procedural fallback | 缂哄皯 FBX/height 鏃剁敓鎴?BoxMesh 宀╃煶 |

`AutoVegetationAsset` 鏄剼鏈寲妞嶈璧勪骇璧勬簮锛岃礋璐ｆ妸鈥滄煇绉嶆琚槸浠€涔堚€濆拰鈥滃浣曟暎甯冣€濇斁鍒板彲淇濆瓨璧勬簮閲屻€傛憜鏀鹃樁娈典細瀹炰緥鍖栧畠鎸囧畾鐨?`AutoVegetation` 瀛愮被锛岃€屼笉鏄８ `MeshInstance3D`銆?
| 灞炴€?| 绫诲瀷 | 榛樿鍊?| 璇存槑 |
|---|---|---|---|
| `asset_id` | `String` | `""` | 璧勪骇绋冲畾 id |
| `object_subtype` | `String` | `"vegetation"` | 妞嶈瀛愮被鍚嶏紝渚嬪 `flower` |
| `vegetation_band` | `String` | `"ground"` | 榛樿楂樺害 band |
| `voxel_color` | `Color` | `Color.WHITE` | 涓讳綋绱犻鑹诧紱`alpha` 鍚屾 `voxel_complexity` |
| `voxel_complexity` | `float` | `1.0` | 涓讳綋绱犲鏉傚害鎴栧崰鐢ㄥ己搴?|
| `affected_bands` | `Array[Dictionary]` | band fallback | 涓诲彈褰卞搷楂樺害 band锛涗负绌烘椂鍙寜 `vegetation_band` 鑷姩鐢熸垚鍗?band |
| `collision_voxels` | `Array[Dictionary]` | `[]` | 鍙€夌矖纰版挒浣撶礌锛涜崏銆佸彾銆佺粏鏋濋€氬父涓虹┖ |
| `voxel_profile` | `AutoVoxelProfile` | `null` | 鍙€夊崟 band 鎴栧 band 鍏变韩棰勮 |
| `mesh` | `Mesh` | `null` | 澶栭儴鎴栧凡鍒涘缓 mesh |
| `vegetation_script` | `Script` | `null` | 鍏蜂綋 `AutoVegetation` 瀛愮被鑴氭湰锛屼緥濡?`AutoFlower` |
| `mesh_create_method` | `String` | `""` | 绋嬪簭鍖?mesh 鍒涘缓鍑芥暟鍚?|
| `scatter_min_distance` | `float` | `1.0` | scatter Poisson 鏈€灏忛棿璺?|
| `scatter_max_count` | `int` | `500` | scatter 鏈€澶ф暟閲?|
| `scatter_max_scale` | `float` | `1.0` | scatter 鏈€澶х缉鏀?|
| `visual_layer` | `int` | `0` | 娓叉煋灞?|
| `group` | `String` | `""` | 鏀剧疆鍚庡姞鍏ョ殑 group |
| `material` | `Material` | `null` | 鍙€夋潗璐ㄨ鐩?|

妞嶈鍔犺浇璺緞锛?
| 鏉ユ簮 | 璇存槑 |
|---|---|
| `Main.vegetation_asset_paths` | 鏄惧紡鍒楀嚭鐨?`AutoVegetationAsset` 璧勬簮 |
| `Main.vegetation_asset_dir` | 榛樿鎵弿 `res://assets/vegetation` 涓嬬殑 `.tres` / `.res` |

`mesh_create_method` 褰撳墠鏀寔 `create_tree_mesh`銆乣create_midstory_mesh`銆乣create_bush_mesh`銆乣create_flower_mesh`銆傚鏋滈」鐩凡鏈夊閮ㄦā鍨嬶紝浼樺厛鐩存帴璁剧疆 `mesh`銆?
## 4. 宀╃煶璧勪骇灞炴€?
| 灞炴€?| 鏉ユ簮 | 璇存槑 |
|---|---|---|
| `object_type` | `AutoRock` | 鍥哄畾涓?`rock` |
| `object_subtype` | `AutoCliffRock` | 鍥哄畾涓?`cliff` |
| `mesh_index` | `CliffGenerator` result | 浣跨敤鍝釜 `AutoRock` 鍘熷瀷 |
| `affected_bands` | `AutoRock` | 璧勪骇鎸佷箙鍖栧彈褰卞搷 band锛涗负绌烘椂鍙敱榛樿 all-band 鎴?profile 鍥為€€鐢熸垚 |
| `collision_voxels` | `AutoRock` | 鍙€夌矖纰版挒浣撶礌 |
| `voxel_profile` | `AutoRock` | 鍙€夊叡浜綋绱犻璁?|
| `position` | `CliffGenerator` result | GPU 閫夊嚭鐨勬斁缃綅缃?|
| `rotation_mode` / `rotation_degrees` | `CliffGenerator` result | GPU 閫夊嚭鐨勯殢鏈烘棆杞紱褰撳墠宀╃煶榛樿 `Y` 妯″紡 |
| `scale` | result + `fbx_unit_scale` + `mesh_height_scale` | 鍙缂╂斁 |
| `visual_layer` | `ROCK_VISUAL_LAYER` | 褰撳墠涓?`10` |
| `group` | runtime | `placed_rocks` |
| `voxel_color` | `AutoRock` | 褰撳墠榛樿宀╃煶鑹?`(0.55, 0.50, 0.45, 1.0)` |
| `voxel_complexity` | `AutoRock` | 褰撳墠榛樿 `1.0` |

宀╃煶浼氶樆鎸″叏閮ㄦ琚珮搴︽尝娈碉細

| Band | Channel | 浣滅敤 |
|---|---:|---|
| `ground` | `0` | 闃绘尅鑽夊湴 |
| `understory` | `1` | 闃绘尅鐏屾湪 |
| `midstory` | `2` | 闃绘尅涓眰鏍?|
| `canopy` | `3` | 闃绘尅鍐犲眰鏍?|

## 5. 妞嶈璧勪骇灞炴€?
| 妞嶈绫?| Band | Channel | Height | Layer | Group | Profile radius | Scatter |
|---|---|---:|---|---:|---|---:|---|
| `AutoGrass` | `ground` | `0 / R` | `0.0-0.3m` | `14` | `placed_grass` | `0.2m` | min `0.5m`, max `2000` |
| `AutoBush` | `understory` | `1 / G` | `0.3-2.0m` | `12` | `placed_bushes` | `1.0m` | min `1.5m`, max `500` |
| `AutoMidstoryTree` | `midstory` | `2 / B` | `2.0-6.0m` | `13` | `placed_midstory_trees` | `2.0m` | min `2.0m`, max `400` |
| `AutoCanopyTree` | `canopy` | `3 / A` | `6.0-99.0m` | `11` | `placed_canopy_trees` | `3.0m` | min `3.0m`, max `300` |

妞嶈鐨勯珮搴?band 鍙〃杈炬爲鍐犮€佺亴鏈ㄣ€佽崏鍦扮瓑鐢熸€佸眰鍗犵敤銆傜矖澹爲骞茶繖绫讳笉鑳戒簰绌跨殑鍒氫綋閮ㄥ垎鍐欏叆鐙珛 `collision_voxels`锛屽湪鏈€缁堢鎾炰簰鏂ュ眰涓鏌ワ細

| 妞嶈绫?| `affected_bands` | `collision_voxels` | 缁撴灉 |
|---|---|---|---|
| `AutoCanopyTree` | `canopy` | 绮楁爲骞?cylinder | 鍐犲眰鍙笌涓眰涓婁笅鍏卞瓨锛屼絾鏍戝共涓嶈兘鍚屼綅 |
| `AutoMidstoryTree` | `midstory` | 杈冪粏鏍戝共 cylinder | 涓眰鏍戝啝鐙珛锛屾爲骞插弬涓庝簰鏂?|
| `AutoBush` | `understory` | 閫氬父涓虹┖ | 鐏屾湪鎸?understory band 浜掓枼锛屼笉鍙備笌鏍戝共鍒氫綋灞?|
| `AutoGrass` | `ground` | 绌?| 鑽変笉鍐欑鎾炰綋绱?|

闄ゅ唴缃?`AutoCanopyTree`銆乣AutoMidstoryTree`銆乣AutoBush`銆乣AutoGrass` 澶栵紝鏂扮殑鑺便€佽崏鏈垨鑷畾涔夌亴鏈ㄥ彲浠ヤ綔涓?`AutoVegetationAsset` 鍔犲叆鑷姩鏁ｅ竷銆傝祫婧愮敱 `AutoVegetationAsset` 鐨勫璞′綋绱犲瓧娈垫弿杩?band/radius/color/complexity/collision锛岀敱鍙€?`AutoVoxelProfile` 澶嶇敤棰勮锛屽苟鐢卞悓涓€璧勬簮鎻忚堪 scatter銆乵esh銆乿isual layer 鍜?group銆?
| 鏉ユ簮 | 璧勪骇 | 鏀剧疆鏂瑰紡 |
|---|---|---|
| 鍐呯疆 scatter | 纭紪鐮?profile + 绋嬪簭鍖?mesh | `main.gd` 鍒涘缓瀵瑰簲 `Auto*` 瀛愮被 |
| 鑴氭湰鍖?scatter | `AutoVegetationAsset` | `main.gd` 鎵弿璧勬簮锛岃皟鐢?`instantiate_vegetation()` 鍒涘缓鍏蜂綋瀛愮被 |
| 绗斿埛 / 涓诲姩缂栬緫 | `AutoVegetation` 瀛愮被 + 瀵硅薄浣撶礌瀛楁 | `register_brush_vegetation()` 娉ㄥ唽涓?`brush` 鏉ユ簮 |

鎵嬪埛妞嶈鎴栦富鍔ㄧ紪杈戞琚埛鍒板満鏅悗娉ㄥ唽杩?`AutoObject` 绠＄悊锛屽苟璁剧疆锛?
| 瀛楁 | 鍊?| 璇存槑 |
|---|---|---|
| `auto_source` | `brush` | 鏍囪涓虹瑪鍒锋垨涓诲姩缂栬緫鏉ユ簮 |

绗斿埛妞嶈娉ㄥ唽鍏ュ彛锛?
| 鍙傛暟 | 绫诲瀷鎴栨潵婧?| 璇存槑 |
|---|---|---|
| `vegetation_node` | `Node` / `MeshInstance3D` | 鍒峰埌鍦烘櫙涓殑妞嶈鑺傜偣 |
| `voxel_color` / `affected_bands` / `collision_voxels` | `brush_asset` 鎴?`AutoVegetation` 瀛愮被 | 绗斿埛璧勪骇鐨勪富鎸佷箙鍖栦綋绱犲瓧娈碉紱`voxel_profile` 浠呬綔鍙€夐璁?|

娉ㄥ唽鍚庝細锛?
| 椤?| 缁撴灉 |
|---|---|
| 鑺傜偣绫诲瀷 | `AutoVegetation` 鎴栧叾瀛愮被 |
| 绠＄悊鍣?| 鑻ュ満鏅噷娌℃湁 `AutoObjectManager`锛屼細鑷姩鍒涘缓 |
| Metadata | `auto_source = "brush"` |
| Instance id | `AutoObject.instance_id` / `auto_instance_id` / `voxel_record.instance_id` |
| Group | `placed_brush_vegetation` |
| 绠＄悊琛?| 鍐欏叆 `_mesh_voxel_records` |
| 鍦烘櫙褰卞搷 | 鍚庣画 `_apply_scene_mesh_voxels_to_vegetation_buffers()` 浼氭妸 `brush` 璁板綍娲剧敓涓?`BrushSceneVoxel`锛屽啀鍙備笌鏈€缁?`SceneVoxel` 娣峰悎 |

`AutoObjectManager` 璐熻矗鎸夊璞?id 鍜?`instance_id` 绠＄悊杩愯鏃跺璞¤褰曪細

| 鏌ヨ | 鐢ㄩ€?|
|---|---|
| `get_record_by_id(auto_id)` | 鎸夌ǔ瀹氬璞?id 鎵捐褰?|
| `get_record_by_instance_id(instance_id)` | 鎸?Godot 杩愯鏃跺疄渚?id 鎵捐褰?|
| `get_all_records()` | 瀵煎嚭褰撳墠鎵€鏈?AutoObject 绠＄悊璁板綍 |

妞嶈閫氱敤灞炴€э細

| 灞炴€?| 绫诲瀷 | 璇存槑 |
|---|---|---|
| `vegetation_band` | `String` | 妞嶈鍗犵敤鐨勯珮搴︽尝娈?|
| `color` | `Color` | 鍙楀奖鍝?band color 鐨勫钩鍧囧€硷紝RGB 鐢ㄤ簬 debug/鏉愯川 |
| `complexity` | `float` | 鍙楀奖鍝?band complexity 鐨勫钩鍧囧€?|
| `affected_bands` | `Array[Dictionary]` | 涓€鑸彧鏈変竴涓?band |
| `voxel_record` | `Dictionary` | 鐢?`VegetationExclusion.scatter()` 閫氳繃 record builder 鍒涘缓鎴栨洿鏂?|

褰撳墠妞嶈 band 閰嶇疆锛?
| Band | Height | Resolution | Channel | Color | Complexity |
|---|---|---:|---|---|---:|
| `ground` | `0.0-0.3m` | `256` | `R / 0` | `(0.2, 0.8, 0.2)` | `1.0` |
| `understory` | `0.3-2.0m` | `128` | `G / 1` | `(0.8, 0.6, 0.2)` | `0.7` |
| `midstory` | `2.0-6.0m` | `128` | `B / 2` | `(0.2, 0.5, 0.8)` | `0.4` |
| `canopy` | `6.0-99.0m` | `64` | `A / 3` | `(0.8, 0.2, 0.2)` | `0.2` |

娉ㄦ剰锛氬綋鍓?`grass` 鏆傛椂澶嶇敤 bush mesh 骞跺湪鎽嗘斁鏃堕澶栦箻 `0.3` 缂╂斁锛屽悗缁彲浠ユ浛鎹㈡垚鐙珛鑽?mesh銆?
## 6. `affected_bands` 缁撴瀯

姣忎釜鐗╀綋浼氬０鏄庡畠褰卞搷鍝簺妞嶈楂樺害娉㈡銆?
| 瀛楁 | 绫诲瀷 | 绀轰緥 | 璇存槑 |
|---|---|---|---|
| `band` | `String` | `canopy` | 娉㈡鍚?|
| `channel` | `int` | `3` | RGBA channel index |
| `radius` | `float` | `3.0` | 涓栫晫鍗曚綅鍗婂緞 |
| `color` | `Color` | `Color(0.8, 0.2, 0.2, 0.2)` | debug 棰滆壊 |
| `complexity` | `float` | `0.2` | 鍐欏叆 occupancy 鐨勫€?|

## 7. `collision_voxels` 缁撴瀯

`collision_voxels` 鏄渶缁堢鎾炰簰鏂ュ眰鐨勭矖浣撶礌鎻忚堪銆傚畠鍙褰曚笉鑳戒簰绌跨殑鍒氫綋閮ㄥ垎锛屼緥濡傜矖鏍戝共锛涜崏銆佹爲鍙跺拰缁嗘灊閫氬父涓嶅啓鍏ヨ繖涓€灞傘€?
| 瀛楁 | 绫诲瀷 | 绀轰緥 | 璇存槑 |
|---|---|---|---|
| `shape` | `String` | `cylinder` | 褰撳墠鎸?XZ 鍦嗘煴 footprint 澶勭悊 |
| `radius` | `float` | `0.45` | 鍘熷涓栫晫鍗曚綅鍗婂緞 |
| `y_min` / `y_max` | `float` | `0.0` / `2.2` | 纰版挒浣撶礌瑕嗙洊鐨勯珮搴﹁寖鍥达紝鐢ㄤ簬璁板綍鍜屽悗缁?3D 鏌ヨ |
| `erosion_radius` | `float` | `0.04` | 鍏堜镜铓€锛涘崐寰勫皬浜庣瓑浜庤鍊肩殑缁嗚妭浼氳鎺掗櫎 |
| `dilation_radius` | `float` | `0.08` | 渚佃殌鍚庡啀鎵╁紶锛屽緱鍒颁繚瀹堜簰鏂ヨ寖鍥?|
| `effective_radius` | `float` | `0.49` | 杩愯鏃舵淳鐢熺殑瀹為檯鍐欏叆鍗婂緞 |
| `base_pixel` / `voxel_xz` | `Vector2i` | `Vector2i(128, 128)` | 鍩虹璐村浘鍜?voxel volume 鍧愭爣 |
| `value` | `float` | `1.0` | 鍐欏叆纰版挒灞傜殑浜掓枼寮哄害 |

## 8. `voxel_record` 缁撴瀯

`voxel_record` 鏄繍琛屾椂瀵硅薄鍜?occupancy/voxel volume 涔嬮棿鐨勬ˉ銆傚畠涓嶅啀鐩存帴绛変环浜庢渶缁堜綋绱狅紝鑰屾槸鍏堟淳鐢?`SceneVoxelBase` 鍏叡瀛楁锛屽啀鐢熸垚鏉ユ簮浣撶礌銆傚綋鍓?builder 浼氭妸鑷姩鐢熸垚鍐欐垚 `AutoSceneVoxel` source锛屾妸 brush / erase / lock 鍐欐垚 `BrushSceneVoxel` source锛沗blend_scene_voxels()` 鎵嶅彂甯冩渶缁?`SceneVoxel`銆?
| 鏉ユ簮浣撶礌 | 浜х敓鑰?| 鐢ㄩ€?|
|---|---|---|
| `AutoSceneVoxel` | 鑷姩鐢熸垚娴佺▼锛屼緥濡?meshfill銆乻catter銆佺▼搴忓寲鏀剧疆 | 琛ㄧず绯荤粺鑷姩鎺ㄥ鍑虹殑鍗犵敤銆侀樆鎸°€佽〃闈㈡垨妞嶈缁撴灉 |
| `BrushSceneVoxel` | 绗斿埛鍜屼富鍔ㄤ慨鏀?| 璁板綍鐢ㄦ埛鎴栧伐鍏蜂慨鏀逛簡鍝簺浣撶礌锛屼互鍙婅繖浜涗綋绱犱笌 auto 缁撴灉鐨勬贩鍚堟瘮渚?|
| `SceneVoxel` | 娣峰悎闃舵 | `AutoSceneVoxel` 涓?`BrushSceneVoxel` 鐨勬渶缁堝悎鎴愮粨鏋滐紝渚?occupancy/voxel volume/楠岃瘉璇诲彇 |

榛樿娣峰悎鍘熷垯锛歚AutoSceneVoxel` 璐熻矗缁欏嚭鑷姩鐢熸垚鍩虹嚎锛宍BrushSceneVoxel` 鍙褰曡淇敼鐨勪綋绱犻泦鍚堝拰 `auto_mix`銆傛贩鍚堥樁娈垫寜 `generation_tick` 鍏堢‘瀹氳緭鍏ュ揩鐓э紝鍐嶅 `BrushSceneVoxel.modified_voxels` 鍐呯殑浣撶礌搴旂敤 `auto_mix`锛涢粯璁?`auto_mix = 0.0`锛岃〃绀哄畬鍏ㄩ噰鐢?brush 鍊硷紝涓嶆贩鍚?auto銆傛渶缁堝彧鎶婂凡鎻愪氦鐨?`SceneVoxel` 鏆撮湶缁欏悗缁煡璇€侀獙璇佸拰 `GlobalVoxelField` sparse tile cache銆?
### 8.1 绫诲瀷鍏崇郴

褰撳墠瀹炵幇鍙互缁х画浣跨敤 `Dictionary`锛屼絾瀛楁缁勭粐鎸変笅闈㈢殑绫诲叧绯绘暣鐞嗭細

| 绫诲瀷 | 鐖剁骇 / schema | 鑱岃矗 |
|---|---|---|
| `SceneVoxelBase` | common schema | 瀹氫箟鏉ユ簮浣撶礌鍜屾渶缁堜綋绱犻兘蹇呴』鎸佹湁鐨勫叕鍏卞睘鎬?|
| `SourceSceneVoxel` | `SceneVoxelBase` | 琛ㄧず灏氭湭娣峰悎鎻愪氦鐨勫€欓€変綋绱?|
| `AutoSceneVoxel` | `SourceSceneVoxel` | 鑷姩鐢熸垚鏉ユ簮 |
| `BrushSceneVoxel` | `SourceSceneVoxel` | 绗斿埛鎴栦富鍔ㄧ紪杈戞潵婧?|
| `SceneVoxel` | `SceneVoxelBase` | 娣峰悎鍚庢彁浜ょ殑鏈€缁堜綋绱?|

`AutoSceneVoxel` / `BrushSceneVoxel` 鍜?`SceneVoxel` 鐨勫叕鍏卞瓧娈靛繀椤诲悓鍚嶃€佸悓绫诲瀷銆佸悓璇箟锛涘樊寮傚彧鏀惧湪鏉ユ簮瀛楁鎴栨贩鍚堝瓧娈甸噷銆?
### 8.2 鍏叡瀛楁

杩欎簺瀛楁灞炰簬 `SceneVoxelBase`锛屾潵婧愪綋绱犲拰鏈€缁?`SceneVoxel` 閮借淇濇寔涓€鑷达細

| 瀛楁缁?| 浠ｈ〃瀛楁 | 鐢ㄩ€?|
|---|---|---|
| 瀵硅薄韬唤 | `id`銆乣auto_object_id`銆乣auto_instance_id`銆乣instance_mesh_id`銆乣node_path` | 浠庢渶缁?`SceneVoxel` 鍥炴煡鍦烘櫙瀵硅薄鍜屾覆鏌撳疄渚?|
| 绌洪棿鏄犲皠 | `position`銆乣rotation_mode`銆乣rotation_degrees`銆乣scale`銆乣base_pixel`銆乣voxel_xz`銆乣volume_xz_resolution` | 鎶婂璞¤惤鐐规槧灏勫埌鍩虹璐村浘鍜?voxel volume |
| 闂撮殧绾︽潫 | `bound_min_length`銆乣min_spacing`銆乣min_spacing_auto` | 鎻忚堪缂╂斁鍚庣殑鐗╀綋鍗犲湴鍜岃酱涓績鏈€灏忛棿闅?|
| 浣撶礌寮哄害 | `color`銆乣complexity`銆乣affected_bands`銆乣SenceLayerVoxel` | 鎻忚堪棰滆壊銆佸崰鐢ㄥ己搴﹀拰姣忎釜楂樺害灞傜殑鍐欏叆鑼冨洿 |
| 纰版挒浜掓枼 | `collision_voxels`銆乣CollisionVoxel`銆乣collision_buffer_applied` | 鎻忚堪鏈€缁堢鎾炰簰鏂ュ眰涓殑绮楀垰浣撳崰鐢?|
| 鐢熷懡鍛ㄦ湡 | `generation_tick`銆乣read_tick`銆乣write_tick`銆乣commit_tick` | 淇濇寔蹇収璇诲啓鍜屾彁浜ら『搴忔竻鏅?|

### 8.3 绫诲瀷涓撳睘瀛楁

绫诲瀷涓撳睘瀛楁鍙兘闄勫姞璇箟锛屼笉鑳芥敼鍙樺叕鍏卞瓧娈电殑鍚箟锛?
| 绫诲瀷 | 涓撳睘瀛楁 | 鐢ㄩ€?|
|---|---|---|
| `AutoSceneVoxel` | `source_voxel_type`銆乣source_kind`銆乣producer_stage` | 鏍囨槑鑷姩鏉ユ簮锛屼緥濡?`meshfill`銆乣placement_fitting`銆乣scatter`銆乣rock_placement` |
| `BrushSceneVoxel` | `source_voxel_type`銆乣source_kind`銆乣producer_stage`銆乣brush_stroke_id`銆乣modified_voxels`銆乣auto_mix` | 璁板綍涓诲姩淇敼浣撶礌闆嗗悎鍜?auto 娣峰悎姣斾緥锛沗source_kind` 浠呮爣鏄?brush銆乪rase銆乴ock 绛夋爣绛?|
| `SceneVoxel` | `source_voxel_types`銆乣dominant_source_type`銆乣blend_mode`銆乣commit_tick` | 璁板綍鍙備笌娣峰悎鐨勬潵婧愩€佹渶缁堜富瀵兼潵婧愬拰鎻愪氦 tick |
| `CollisionVoxel` | `shape`銆乣radius`銆乣effective_radius`銆乣y_min`銆乣y_max`銆乣value` | 鐙珛纰版挒浜掓枼灞傚瓧娈碉紝涓嶅弬涓?`SceneVoxelBase` 缁ф壙 |

### 8.4 娣峰悎瀛楁

娣峰悎瀛楁鍙互鍑虹幇鍦ㄦ潵婧愪綋绱犱腑浣滀负鍊欓€夋剰鍥撅紝涔熷彲浠ヤ繚鐣欏埌鏈€缁?`SceneVoxel` 浣滀负缁撴灉璇存槑锛?
| 瀛楁 | 鏉ユ簮浣撶礌鍚箟 | 鏈€缁?`SceneVoxel` 鍚箟 |
|---|---|---|
| `source_voxel_type` | 褰撳墠鏉ユ簮绫诲瀷锛屼緥濡?`AutoSceneVoxel` 鎴?`BrushSceneVoxel` | 涓嶅啀浣跨敤鍗曞€硷紱鏀圭敱 `source_voxel_types` 璁板綍鍙備笌鏉ユ簮 |
| `source_kind` | 缁嗗垎鏉ユ簮锛屼緥濡?`meshfill`銆乣scatter`銆乣brush` | 鍙€変繚鐣欎富瀵兼潵婧愶紝鎴栧啓鍏?contributors 鍒楄〃 |
| `modified_voxels` | `BrushSceneVoxel` 淇敼杩囩殑鍍忕礌銆佷綋绱犳垨 stamp 鑼冨洿 | 璁板綍鏈 brush 鐪熸鎺ョ鐨勮寖鍥?|
| `auto_mix` | 涓?auto 缁撴灉鐨勬贩鍚堟瘮渚嬶紝榛樿 `0.0` | `0.0` 涓哄畬鍏?brush锛宍1.0` 涓哄畬鍏?auto锛屼腑闂村€间负灞€閮ㄨ蒋娣峰悎 |
| `blend_mode` | 鍙€夊吋瀹瑰瓧娈碉紱榛樿鐢?`auto_mix` 琛ㄨ揪 brush/auto 娣峰悎 | 瀹為檯閲囩敤鐨勬贩鍚堢瓥鐣?|
| `priority` | 鍚屼綅缃啿绐佹椂鐨勫€欓€変紭鍏堢骇 | 琚渶缁堢粨鏋滈噰绾虫垨璁板綍鐨勪紭鍏堢骇 |
| `producer_stage` | 鍐欏叆璇ユ潵婧愪綋绱犵殑绯荤粺闃舵 | 鏈€缁堥€氬父涓?`blend`锛屾垨淇濈暀涓诲鏉ユ簮闃舵 |

`BrushSceneVoxel` 鐨勯粯璁ゅ悎鎴愬叕寮忥細

```text
final_voxel = brush_voxel * (1.0 - auto_mix) + auto_voxel * auto_mix
```

`erase`銆乣lock` 鍜?`manual_edit` 涓嶅啀闇€瑕佺嫭绔嬫贩鍚堥€昏緫锛涘畠浠彧鏄?`source_kind` 鏍囩鍜屼笉鍚岀殑 `brush_voxel` 鍊笺€傛湭鍑虹幇鍦?`modified_voxels` 涓殑浣撶礌涓嶅彈鏈 `BrushSceneVoxel` 褰卞搷锛岀户缁娇鐢ㄨ嚜鍔ㄧ敓鎴愭垨涓婁竴杞彁浜ょ姸鎬併€?
鏉ユ簮浣撶礌鏍稿績宸紓锛?
| 鏉ユ簮浣撶礌 | 榛樿鏉ユ簮 | 榛樿娣峰悎 | 鍏稿瀷鍥炴煡 |
|---|---|---|---|
| `AutoSceneVoxel` | `meshfill`銆乣scatter`銆佺▼搴忓寲鏀剧疆 | `max`锛屼紭鍏堢骇浣庝簬涓诲姩淇敼 | `auto_object_id`銆乣auto_instance_id`銆乣instance_mesh_id` |
| `BrushSceneVoxel` | `brush`銆乣manual_edit`銆乣erase`銆乣lock` | 鍙慨鏀?`modified_voxels`锛涢粯璁?`auto_mix = 0.0`锛屽畬鍏ㄤ笉娣峰悎 auto | `brush_stroke_id`锛屽彲閫?`auto_object_id` / `instance_mesh_id` |
| `SceneVoxel` | `blend_scene_voxels()` | 宸叉彁浜ょ殑鏈€缁堢粨鏋?| `source_voxel_types`銆乣dominant_source_type`銆乣commit_tick` |

`SenceLayerVoxel` 鍗曢」锛?
| 瀛楁 | 绫诲瀷 | 鐢ㄩ€?|
|---|---|---|
| `band` | `String` | 娉㈡鍚嶏紝渚嬪 `midstory` |
| `channel` | `int` | RGBA channel index |
| `base_pixel` | `Vector2i` | 瀵瑰簲 256x256 鍩虹璐村浘鍍忕礌 |
| `voxel_xz` | `Vector2i` | 瀵瑰簲 voxel volume 鐨?XZ 鍧愭爣 |
| `radius` | `float` | 涓栫晫鍗曚綅鍗婂緞 |
| `radius_px` | `int` | 鍩虹璐村浘涓婄殑 stamp 鍗婂緞 |
| `y_min` / `y_max` | `float` | 璇ュ眰鏈€浣庡拰鏈€楂橀珮搴?|
| `color` | `Color` | debug 棰滆壊锛宎lpha 鍚屾 `complexity` |
| `complexity` | `float` | 鍐欏叆 occupancy 鐨勫€?|
| `slice_indices` | `Array[int]` | 鍐欏叆鐨?voxel volume Y slice |
| `height_buffer_applied` | `bool` | 鏄惁宸插悓姝ュ埌 height-band buffer |

## 9. 鏂板璧勪骇鏃惰濉粈涔?
鎺ㄨ崘鐢?`tools/scaffold_auto_asset.gd` 鎶婃柊澧炲博鐭冲拰妞嶈鑴氭湰鍖栥€傛墜宸ユ祦绋嬩粛鐒舵湁鏁堬紝浣嗛粯璁ゅ簲璁╄剼鏈敓鎴愯祫婧愩€佸璞′綋绱犲瓧娈点€佸彲閫?profile 棰勮鍜屽叿浣撳瓙绫伙紝鍑忓皯閬楁紡瀛楁銆?
```bash
godot --headless --path . --script tools/scaffold_auto_asset.gd -- --config res://tools/my_asset.json
```

濡傛灉鏈満 Godot 鍛戒护涓嶆槸 `godot`锛屾浛鎹㈡垚瀹為檯 Godot 4.6 鍙墽琛屾枃浠躲€傛洿瀹屾暣绀轰緥瑙?`auto-asset-scripting.md`銆?
鏂板宀╃煶鐨勮剼鏈寲杈撳叆锛?
| 瀛楁 | 鍐欏叆浣嶇疆 | 璇存槑 |
|---|---|---|
| `asset_path` | `AutoRock` scene asset | 杈撳嚭 `.tscn` 鎺ㄨ崘锛岄粯璁ゆ斁鍒?`res://assets/rocks` 鍚庝細琚?`Main.rock_asset_dir` 鎵弿 |
| `profile_path` | `AutoVoxelProfile` | 杈撳嚭鍙€夊叡浜?profile `.tres` |
| `mesh` | `AutoRock.mesh` | 澶栭儴 mesh 鎴栧彲鍔犺浇鍦烘櫙閲岀殑 mesh |
| `height_texture` | `AutoRock.mesh_height_texture` | height texture锛沗.raw` 浼氭寜 `raw_width` / `raw_height` 璇诲彇 |
| `mesh_size` | `AutoRock.mesh_size` | GPU fitting 浣跨敤鐨勫崰鍦板昂瀵?|
| `color` / `complexity` | `AutoRock` object fields | 璧勪骇骞冲潎浣撶礌棰滆壊鍜屽崰鐢ㄥ己搴?|
| `affected_bands` | `AutoRock.affected_bands` | 榛樿鍙啓 `ground`銆乣understory`銆乣midstory`銆乣canopy` |
| `collision_voxels` | `AutoRock.collision_voxels` | 鍙€夌矖鍒氫綋浜掓枼锛涢潪鍒氫綋鍙负绌?|
| `random_rotate` / `random_scale` / `random_height_offset` | `AutoRock` | 宀╃煶 fitting 闅忔満鍙傛暟 |
| `sync_legacy_fields` | `AutoRock` | 鍚屾瀵硅薄浣撶礌瀛楁锛屽吋瀹规棫璋冪敤鍏ュ彛 |

```json
{
  "type": "rock",
  "asset_path": "res://assets/rocks/cliff_03_asset.tscn",
  "profile_path": "res://assets/rocks/cliff_03_profile.tres",
  "mesh": "res://geo/cliff_03.FBX",
  "height_texture": "res://geo/cliff_03_height.raw",
  "mesh_size": 4.2,
  "color": [0.55, 0.5, 0.45, 1.0],
  "complexity": 1.0,
  "affected_bands": ["ground", "understory", "midstory", "canopy"],
  "random_rotate": [0.0, 1.0],
  "random_scale": [0.8, 1.2],
  "random_height_offset": [-0.5, 0.5],
  "sync_legacy_fields": true
}
```

鐢熸垚鍣ㄧ洿鎺ヨ鍙?`AutoCliffRock` 鎴栨柊鐨?`AutoRock` 瀛愮被鍘熷瀷锛涚敓鎴愮粨鏋滆惤鍦版椂澶嶅埗瀵瑰簲瀛愮被锛屽苟鐢?`AutoAssetFactory.make_rock_scene_voxel_record()` 鎸?`AutoRock` 鐨勫璞′綋绱犲瓧娈垫淳鐢熷満鏅?`voxel_record`銆?
鏂板妞嶈鐨勮剼鏈寲杈撳叆锛?
| 瀛楁 | 鍐欏叆浣嶇疆 | 璇存槑 |
|---|---|---|
| `subtype` / `class_name` | 瀛愮被鑴氭湰 | 渚嬪 `flower` / `AutoFlower` |
| `script_path` | `AutoVegetation` 瀛愮被 | 鐢熸垚鍏蜂綋瀛愮被鑴氭湰 |
| `asset_path` | `AutoVegetationAsset` | 杈撳嚭 `.tres`锛岄粯璁ゆ斁鍒?`res://assets/vegetation` 鍚庝細琚壂鎻?|
| `profile_path` | `AutoVoxelProfile` | 杈撳嚭鍙€夊崟 band 鎴栬嚜瀹氫箟鍏变韩 profile |
| `band` / `radius` | `AutoVegetationAsset.affected_bands` | 渚嬪 `ground` + `0.25` |
| `color` / `complexity` | `AutoVegetationAsset` object fields | 璧勪骇骞冲潎浣撶礌棰滆壊鍜屽崰鐢ㄥ己搴?|
| `collision_voxels` | `AutoVegetationAsset.collision_voxels` | 鑽夈€佹爲鍙躲€佺粏鏋濅负绌猴紱绮楁爲骞叉墠璁剧疆 |
| `scatter_min_distance` / `scatter_max_count` / `scatter_max_scale` | `AutoVegetationAsset` | 鑷姩鏁ｅ竷鍙傛暟 |
| `visual_layer` / `group` | `AutoVegetationAsset` | 娓叉煋灞傚拰鍦烘櫙鍒嗙粍 |
| `mesh` 鎴?`mesh_create_method` | `AutoVegetationAsset` | 澶栭儴 mesh 鎴栫▼搴忓寲 mesh 鍑芥暟 |

```json
{
  "type": "vegetation",
  "subtype": "flower",
  "class_name": "AutoFlower",
  "script_path": "res://scripts/auto_flower.gd",
  "asset_path": "res://assets/vegetation/flower_asset.tres",
  "profile_path": "res://assets/vegetation/flower_profile.tres",
  "band": "ground",
  "radius": 0.25,
  "color": [0.9, 0.35, 0.5, 0.7],
  "complexity": 0.7,
  "collision_voxels": [],
  "scatter_min_distance": 0.35,
  "scatter_max_count": 800,
  "scatter_max_scale": 0.7,
  "visual_layer": 14,
  "group": "placed_flowers",
  "mesh_create_method": "create_flower_mesh"
}
```

鎽嗘斁闃舵浼氳皟鐢?`AutoVegetationAsset.instantiate_vegetation()` 鍒涘缓鍏蜂綋瀛愮被锛屽啀鐢ㄦ寔涔呭寲瀵硅薄浣撶礌瀛楁娲剧敓鍦烘櫙 `voxel_record`銆傝繖鏍疯嚜鍔ㄦ暎甯冨拰绗斿埛娉ㄥ唽閮借兘淇濈暀鐩稿悓鐨?object-field-derived 鏁版嵁璺緞銆?
## 10. 鐩稿叧鏂囦欢

| 鏂囦欢 | 璐熻矗鍐呭 |
|---|---|
| `scripts/auto_object.gd` | 鑷姩鐢熸垚鐗╀綋鍏叡灞炴€у拰涓诲璞′綋绱犲瓧娈?|
| `scripts/auto_object_manager.gd` | AutoObject 杩愯鏃舵暟鎹鐞嗗櫒锛屾寜 id 鍜?instance id 绠＄悊璁板綍 |
| `scripts/auto_voxel_profile.gd` | 鍙€夊叡浜綋绱?profile 鍜岀矖纰版挒浣撶礌棰勮 |
| `scripts/auto_asset_factory.gd` | 鑴氭湰鍖栧垱寤哄彲閫?profile銆乣AutoRock` 鍦烘櫙璧勪骇銆乣AutoVegetationAsset`銆佸瓙绫昏剼鏈拰 object-field-derived record |
| `scripts/auto_rock.gd` | 宀╃煶鍏叡灞炴€?|
| `scripts/auto_cliff_rock.gd` | 褰撳墠鎮礀宀╃煶鍏蜂綋绫?|
| `scripts/auto_vegetation.gd` | 妞嶈鍏叡灞炴€?|
| `scripts/auto_vegetation_asset.gd` | 妞嶈鎸佷箙鍖栬祫浜ц祫婧愶紝淇濆瓨瀵硅薄浣撶礌瀛楁銆佸彲閫?profile銆乵esh銆乻catter銆乴ayer銆乬roup |
| `scripts/auto_canopy_tree.gd` | 鍐犲眰鏍戠被 |
| `scripts/auto_midstory_tree.gd` | 涓眰鏍戠被 |
| `scripts/auto_bush.gd` | 鐏屾湪绫?|
| `scripts/auto_grass.gd` | 鑽夌被 |
| `scripts/mesh_data_asset.gd` | 宀╃煶 mesh 鏁版嵁璧勪骇 |
| `scripts/vegetation_scatter.gd` | 绋嬪簭鍖栨琚?mesh 鍒涘缓鍜屾棫 scatter helper锛涘寘鍚?`create_flower_mesh()` |
| `scripts/vegetation_exclusion.gd` | 妞嶈 band銆乻catter銆乷ccupancy銆乧ollision occupancy銆乿oxel volume |
| `scripts/main.gd` | 鐢熸垚娴佺▼缂栨帓銆佽剼鏈寲宀╃煶/妞嶈璧勪骇鎵弿鍜屽璞″疄渚嬪寲 |
| `tools/scaffold_auto_asset.gd` | Godot headless JSON 鑴氭墜鏋讹紝鐢熸垚宀╃煶鎴栨琚祫婧?|
| `scene-voxel-field-system.md` | UE 椋庢牸鐨勫眬閮ㄥ満銆佸叏灞€鍦哄拰鎻愪氦娴佺▼璁捐 |
| `auto-asset-scripting.md` | 鏂板宀╃煶/妞嶈鐨?JSON 绀轰緥鍜岃繍琛屽懡浠?|

