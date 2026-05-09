---
description: Extract useful code from UE material generated HLSL, filtering engine boilerplate (Substrate, normal transforms, depth offset). Supports both UE 5.7+ inline format (#line directives) and legacy // section_name format. Use when user provides UE material HLSL, mentions "refine HLSL", "extract material code", "material shader analysis", "MFNode", "CalcPixelMaterialInputs", "Custom Node code", "HLSL extract", "material HLSL", "简化材质", "材质HLSL", "提取材质代码". Trigger: HLSL, material shader, MFNode, Custom Node, CalcPixelMaterialInputs, 材质HLSL, 简化HLSL.
---

# UE Material HLSL Extractor (v2)

Extract real user logic from UE material editor exported HLSL (typically thousands of lines),
filtering out 99% engine boilerplate. Supports UE 5.7+ inline format and legacy section format.

## Quick Start

```bash
python scripts/extract_ue_hlsl.py <input.hlsl>
python scripts/extract_ue_hlsl.py <input.hlsl> --out result.hlsl
python scripts/extract_ue_hlsl.py <input.hlsl> --json
```

Script path: `~/.cursor/skills/ue-hlsl-extract/scripts/extract_ue_hlsl.py`

## What Gets Extracted

| Section | Description |
|---------|-------------|
| Parameter Mapping | PreshaderBuffer to Material Parameter correspondence |
| Custom Expression | User-written Custom Node function bodies (with signatures) |
| Core Material Logic | Local variables in CalcPixelMaterialInputs (excluding Substrate boilerplate) |
| Non-default Pins | PixelMaterialInputs assignments that differ from defaults |
| All Pins | Complete pin listing with [默认] tags |
| Substrate BSDF | SubstrateConvertLegacyMaterialStatic parameter key-value pairs |
| WPO | Non-zero World Position Offset |

## What Gets Filtered

- `_Pragma("dxc diagnostic ...")` noise lines
- `#line N "/Engine/..."` directives
- Substrate FullySimplified duplicate blocks
- PromoteParameterBlendedBSDFToOperator calls
- SharedLocalBases normal/tangent setup
- All expanded engine includes (95%+ of file)
- Default pin values (Metallic=0, Roughness=0.5, AO=1, etc.)
- SelectionColor editor highlight boilerplate (lerp with PreshaderBuffer)

## UE HLSL File Structure

### UE 5.7+ (inline format)
- No `// section_name` markers
- `#line N "/Engine/Generated/Material.ush"` separates regions
- `CustomExpressionN()` functions defined before `CalcPixelMaterialInputs`
- All Local variables and PixelMaterialInputs inside `CalcPixelMaterialInputs()`

### Legacy format (pre-5.7)
- `// section_name` comment markers separate regions
- `calc_pixel_material_inputs_other_inputs` contains core logic

The script auto-detects the format.

## Workflow

1. User provides UE HLSL file (from ShaderDebugInfo, desktop, etc.)
2. Run extraction script to get core logic
3. Based on results, help user:
   - Convert to Custom Node code
   - Analyze material functionality
   - Locate performance bottlenecks
   - Debug shader issues