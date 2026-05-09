---
description: Normalize and edit Markdown documents (.md) for consistent structure, concise technical writing, and standardized code/dictionary examples. Use when the user asks to 规范化MD编写, 统一Markdown风格, 整理文档, 改写字段说明, convert field tables into inline comments, or clean up technical documentation while preserving meaning.
---

# Normalize MD Writing

## Goal

Standardize Markdown without changing technical meaning. Make documents easier to scan, keep examples copy-friendly, and avoid duplicating the same field explanation in both a code block and a table.

## Workflow

1. Read the surrounding section before editing so examples, tables, and prose stay consistent.
2. Identify whether each table is a structural field table or an overview table.
3. Convert structural field tables into inline comments on the matching code/dictionary example.
4. Keep overview tables when they compare classes, assets, thresholds, files, matrices, or workflows.
5. Preserve project terms, identifiers, code names, headings, and existing language unless clarity requires a small wording fix.
6. Re-scan the edited sections for stale duplicated explanations, broken heading flow, and code blocks with missing comments.

## Field Example Style

For concrete dictionary/config examples, put the type and explanation as a comment on the same line as the field.

Prefer:

```gdscript
{
	"band": "canopy",                         # String, band name
	"channel": 3,                             # int, RGBA channel index
	"radius": 3.0,                            # float, world-space radius
	"color": Color(0.8, 0.2, 0.2, 0.2),       # Color, debug color
	"complexity": 0.2,                        # float, value written to occupancy
}
```

Avoid:

```gdscript
# Fields: band(String)=band name; channel(int)=RGBA channel index; ...
{
	"band": "canopy",
	"channel": 3,
}
```

Also avoid a separate `| Field | Type | Description |` table when it only repeats the same dictionary fields.

## Comment Rules

- Match the code block language. Use `#` in `gdscript`, `python`, and shell-like examples. Use `//` in JavaScript/TypeScript/C-like examples.
- Do not add comments to strict `json` blocks. If comments are important and the block is illustrative, change the fence to `jsonc` or another appropriate non-strict language.
- Keep each inline comment short: `Type, purpose` is enough.
- Align comments lightly when it improves readability, but do not chase perfect columns at the cost of noisy edits.
- If a value has aliases, document the preferred key and mention aliases in the comment only when useful.
- For Chinese docs, write comments in Chinese unless the surrounding section is already English.

## Table Rules

Keep tables for:

- Class/type hierarchies
- Asset matrices
- Comparison or decision tables
- File lists
- Validation thresholds
- Workflow stage summaries

Replace tables with inline comments when:

- The table only explains keys already shown in a dictionary/config example.
- A code block and table must be kept in sync manually.
- The user asks for "注释写在参数同一行" or similar wording.

## Structure Rules

- Keep headings short and stable.
- Prefer a short paragraph before a code example that explains why the example exists.
- Remove duplicated prose after converting a field table into inline comments.
- Preserve existing examples unless a field name, type, or documented behavior is stale.
- When normalizing multiple Markdown files, make the style consistent across them rather than fixing only the active selection.

## Final Check

Before finishing:

- Search for remaining stale field tables near edited examples.
- Confirm every field in the edited dictionary example has an inline comment.
- Confirm overview tables were not unnecessarily flattened.
- Confirm technical terms and identifiers are unchanged.
