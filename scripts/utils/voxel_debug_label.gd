@tool
extends RefCounted

## 体素 debug 悬浮文字（Label3D）统一样式工厂。
##
## 之前这些文字散落在各 demo 里各写各的、且有重复：
##   - spa_interactive_demo：选中标签 _make_selection_label（24 / 0.16 / 6，billboard 悬浮）、
##     AutoObject 总览标题（28 / 0.45 / 8，非 billboard）
##   - volume_score_demo:654：锚点评分标签（24 / 0.16 / 6，和选中标签完全重复）
##   - asset_overview：资产 / probe / 体素通道标签（18~28 / 0.01 / 3~5，非 billboard）
## 现在所有 Label3D 文字都从这里出，样式集中一处。
##
## 前 4 个参数是常用控制项（文字、颜色、字号、宽度）；后 3 个可选参数（世界缩放 pixel_size、
## 描边 outline_size、是否 billboard 面朝相机）用来在**不改各站点原有观感**的前提下，把
## 缩放/描边不同的站点也统一收敛进同一个函数——默认值就是体素悬浮字的标准样式。

## 体素悬浮字标准样式默认值（选中 / 锚点标签用）。
const DEFAULT_FONT_SIZE := 24
const DEFAULT_PIXEL_SIZE := 0.16   ## 世界缩放；资产贴标用 0.01、总览标题用 0.45
const DEFAULT_OUTLINE_SIZE := 6


## 新建并返回一个按统一样式配置好的 Label3D。
## text        显示的文字（可含 \n 多行）
## color       文字颜色（写入 modulate）
## font_size   字号
## width       换行宽度：>0 时按词换行到该宽度，<=0 不换行
## pixel_size  世界缩放（每像素对应的世界单位）
## outline_size 描边粗细
## billboard   是否始终整体面朝相机（体素悬浮字用 true，贴在网格上的静态标签用 false）
static func make(
		text: String,
		color: Color = Color.WHITE,
		font_size: int = DEFAULT_FONT_SIZE,
		width: float = 0.0,
		pixel_size: float = DEFAULT_PIXEL_SIZE,
		outline_size: int = DEFAULT_OUTLINE_SIZE,
		billboard: bool = true
) -> Label3D:
	var label := Label3D.new()
	apply(label, text, color, font_size, width, pixel_size, outline_size, billboard)
	return label


## 把统一样式套用到一个已有的 Label3D（供场景里已存在的节点复用同一套样式）。
static func apply(
		label: Label3D,
		text: String,
		color: Color = Color.WHITE,
		font_size: int = DEFAULT_FONT_SIZE,
		width: float = 0.0,
		pixel_size: float = DEFAULT_PIXEL_SIZE,
		outline_size: int = DEFAULT_OUTLINE_SIZE,
		billboard: bool = true
) -> void:
	if label == null:
		return
	label.text = text
	label.modulate = color
	label.font_size = font_size
	label.pixel_size = pixel_size
	label.outline_size = outline_size
	if billboard:
		# 悬浮字：整体面朝相机；底边对齐→origin 落在体素/锚点头顶、文字向上生长，不盖住本体
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	else:
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	# 宽度控制换行
	if width > 0.0:
		label.width = width
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
