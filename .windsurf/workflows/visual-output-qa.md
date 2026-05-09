---
description: Build, edit, or review visual outputs with required rendered screenshot verification. Use when creating or modifying UI, frontend pages, dashboards, HTML/CSS layouts, SVG diagrams, architecture graphs, flowcharts, charts, canvas/WebGL scenes, or other visual artifacts, including Chinese-language requests about drawing diagrams, charts, UI, screenshots, overlap, layout, responsive behavior, or text overflow.
---

# Visual Output QA

## Core Rule

After creating or editing any UI, web page, SVG, flowchart, chart, canvas, WebGL scene, or other visual artifact, render it and verify it with a screenshot. Do not rely only on code review, XML validation, or static file inspection.

If the environment cannot capture a screenshot, state the blocker, the render methods attempted, and the remaining visual risks.

## Workflow

1. Identify the render target:
   - Web UI: run the app or open the built HTML.
   - SVG, diagram, or chart: open the SVG/HTML/chart page in a browser or through the project renderer.
   - Canvas, WebGL, or game UI: run the dev server and capture the live canvas.
   - Native or editor output: use the project or engine screenshot/export tool.

2. Design with layout budgets:
   - Give each node, card, label, and control a text budget before drawing.
   - Prefer short labels and move detail into nearby docs or tooltips.
   - Set stable width, height, padding, line height, and gaps.
   - For SVG text, use explicit multi-line `<text>` / `<tspan>` layout; SVG does not auto-wrap text reliably.
   - Keep long identifiers such as `AutoVegetationAsset` away from narrow boxes unless the box is sized for them.

3. Build or edit the artifact.

4. Screenshot verify:
   - Capture at least one screenshot after the final visual change.
   - For responsive UI, capture desktop and mobile/narrow viewport screenshots.
   - For SVG diagrams, capture the whole diagram and inspect it at normal zoom.
   - For charts, verify axis labels, legends, titles, and dense data labels.
   - For canvas/WebGL, verify the canvas is nonblank and correctly framed.

5. Fix and re-check:
   - If text overflows, wraps badly, overlaps, clips, or crosses important edges, adjust layout and screenshot again.
   - If colors, icons, legends, grouping, or hierarchy are ambiguous, revise and screenshot again.
   - Do not mark the work complete while known visual defects remain unless the user explicitly accepts them.

## Screenshot Checklist

Before final response, inspect the rendered screenshot for:

- Text stays inside its box and does not collide with other text.
- Lines, arrows, legends, and labels do not obscure key content.
- Important content is visible without accidental cropping.
- Spacing is consistent across repeated nodes or UI controls.
- Long labels have enough width or deliberate line breaks.
- Mobile or narrow layouts do not overlap or hide controls.
- The screenshot shows the final edited file or running app.

## Final Response

Include a short verification note:

```text
Verified with screenshot: [what was rendered], [viewport or file], [result].
```

If screenshot verification failed or was unavailable, say that plainly and name the residual visual risks.
