---
description: Use when writing, editing, or reviewing general project Markdown (.md) documentation, including architecture notes, pipeline docs, asset/property docs, API notes, setup guides, and code-adjacent specifications. Enforce concise structure, source-grounded content, stable headings, language consistency, table-first schema summaries, labeled code fences, and concise same-line comments for short examples.
---

# Project Markdown Style

## Overview

Write project Markdown as practical engineering documentation: concise, searchable, easy to diff, and close to the code or data it describes.

Preserve the existing document language and tone. For Chinese project docs, keep prose and comments in Chinese while leaving code identifiers, file paths, method names, keys, and enum values unchanged.

## Workflow

1. Read the target `.md` file and nearby project docs before making structural changes.
2. Preserve existing headings and anchors unless renaming clearly improves clarity.
3. Update related examples, field lists, and cross-references together.
4. Mark unknown or inferred behavior explicitly; do not invent implementation details.
5. Prefer small, focused edits over broad rewrites when maintaining an existing doc.

## Document Structure

- Start with one `#` title that matches the file purpose.
- Add a short purpose paragraph when the file is longer than a quick note.
- Use `##` sections for stable topics such as Overview, Data Flow, Fields, Rules, Examples, Risks, and Open Questions.
- Use `###` only when a section has multiple meaningful subtopics.
- Keep paragraphs short. Prefer bullets for facts, constraints, and step lists.
- Keep terminology consistent with code and existing docs.
- Put file paths, symbols, keys, commands, and literal values in backticks.
- Avoid decorative prose, marketing language, and unexplained abbreviations.

## Code And Parameters

- Always label fenced code blocks with a language such as `gdscript`, `json`, `yaml`, `bash`, `text`, or the closest accurate option.
- Use code blocks for runnable snippets, short access examples, and compact config examples. Use tables for long record schemas, source-type responsibility lists, field inventories, and dictionaries that would need many commented lines.
- When documenting short parameters, properties, metadata keys, config entries, record fields, or return values inside a code block, put the value or explanation on the same line as the item.
- Align same-line comments into a readable column when the block has repeated fields.
- Prefer a concise same-line `#` comment over a separate explanatory bullet when the field can fit on one line.
- Keep examples realistic and source-grounded. If an example is hypothetical, label it as an example.
- If a code line would become too long or wrap badly, shorten the comment first. If several lines still need long comments, replace the block with a table.

Use this style for short metadata access examples:

```gdscript
node.get_meta("auto_id")              # "Cliff_s1_0_m0"
node.get_meta("auto_source")          # "meshfill"
node.get_meta("auto_object_type")     # "rock"
node.get_meta("bound_min_length")     # scaled bound minimum axis length
node.get_meta("min_spacing")          # default bound_min_length * 0.5

var record: Dictionary = node.get_meta("asset_voxel_record")
record.color                          # Color(0.55, 0.50, 0.45, 1.0)
record.complexity                     # 1.0
record.auto_object_id                 # "Cliff_s1_0_m0"
record.instance_mesh_id               # actual MeshInstance3D instance id
```

Use this style for config-like examples:

```yaml
asset_type: "rock"                    # primary asset type
asset_subtype: "cliff"                # asset subtype
min_spacing: 0.5                      # default spacing multiplier
collision_voxels: []                  # optional collision footprint samples
```

Use this style for source/type responsibility descriptions:

| Source Voxel | Producer | Purpose |
| --- | --- | --- |
| `AutoSceneVoxel` | automatic generation such as meshfill, scatter, or procedural placement | derived occupancy, blockers, surfaces, or vegetation |
| `BrushSceneVoxel` | brush and active edits such as paint, erase, lock, or manual override | user/tool-authored scene intent |
| `SceneVoxel` | blend stage | final result read by occupancy, voxel volume, and validation |

## Tables

Use tables when comparing multiple items, documenting schemas, or replacing commented pseudo-objects:

| Field | Type | Meaning |
| --- | --- | --- |
| `auto_id` | `String` | generated object id |
| `asset_voxel_record` | `Dictionary` | record written to voxel/band data |

Keep table cells short. Move long explanations to a following paragraph only when necessary.

## Maintenance Rules

- Update examples when field names, default values, or behavior change.
- Keep outdated behavior only if it is explicitly marked as legacy.
- Do not duplicate the same field list in multiple sections unless each section serves a different reader task.
- Preserve existing TODO/Open Questions sections and add unresolved points there.
- Keep Markdown lint-friendly spacing: blank line before headings, lists, tables, and fenced code blocks.
- Do not add generated timestamps, author signatures, or change logs unless the existing file already uses them.

## Review Checklist

- The title and headings describe the actual content.
- Code fences have language labels.
- Schemas and long field lists use tables; short parameter/property examples use same-line comments where practical.
- Comments explain meaning, default, source, or runtime effect.
- Claims are supported by code, existing docs, or an explicit inference note.
- The document can be scanned without reading every paragraph.