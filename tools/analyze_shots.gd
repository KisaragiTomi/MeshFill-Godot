extends SceneTree

const SHOTS := [
	"res://tools/_shots/01_default.png",
	"res://tools/_shots/02_after_contract.png",
]
const BG := Color(0.07, 0.085, 0.095, 1.0)


func _initialize() -> void:
	for p in SHOTS:
		_analyze(p)
	quit(0)


func _analyze(path: String) -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null or img.is_empty():
		print("[PIX] ", path, " -> empty/missing")
		return
	var w := img.get_width()
	var h := img.get_height()
	var total := w * h
	var bg_like := 0
	var step := 3
	var sampled := 0
	for y in range(0, h, step):
		for x in range(0, w, step):
			sampled += 1
			var c := img.get_pixel(x, y)
			if absf(c.r - BG.r) < 0.04 and absf(c.g - BG.g) < 0.04 and absf(c.b - BG.b) < 0.04:
				bg_like += 1
	var non_bg_ratio := 1.0 - float(bg_like) / float(maxi(sampled, 1))
	print("[PIX] ", path, " size=", w, "x", h,
		" non_bg_ratio=", "%.3f" % non_bg_ratio,
		(" -> HAS_CONTENT" if non_bg_ratio > 0.05 else " -> NEARLY_EMPTY"))