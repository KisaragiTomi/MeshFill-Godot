---
description: Decompile .NET/C# assemblies (DLL files) to readable source code using ilspycmd. Use when the user asks to decompile, reverse-engineer, read source of, or inspect a .NET DLL, or when you need to understand the internal logic of a compiled C# assembly. Commonly used for RimWorld modding, Unity game analysis, and Harmony patch writing.
---

# .NET Decompilation

Decompile .NET assemblies to readable C# source using `ilspycmd`.

## Setup

Check if `ilspycmd` is installed:

```bash
dotnet tool list -g | findstr ilspycmd
```

If not found, install it:

```bash
dotnet tool install -g ilspycmd
```

After installation, verify:

```bash
ilspycmd --version
```

## Common Targets

For RimWorld projects, the primary assembly is:

```
<game_root>/RimWorldWin64_Data/Managed/Assembly-CSharp.dll
```

Other useful assemblies:
- `Assembly-CSharp-firstpass.dll` — early-load game code
- `UnityEngine.CoreModule.dll` — Unity core API
- Mod DLLs typically at `<game_root>/Mods/<ModName>/Assemblies/*.dll`

## Decompilation Commands

### Decompile a single type (class/struct/enum)

```bash
ilspycmd -t <FullTypeName> <path_to_dll>
```

Example:

```bash
ilspycmd -t Verse.Pawn "d:\SteamLibrary\steamapps\common\RimWorld\RimWorldWin64_Data\Managed\Assembly-CSharp.dll"
```

### List all types in an assembly

```bash
ilspycmd -l <path_to_dll>
```

Use this to discover type names before decompiling. Pipe through `findstr` to filter:

```bash
ilspycmd -l <path_to_dll> | findstr <keyword>
```

### Decompile entire assembly to a project

```bash
ilspycmd -p -o <output_dir> <path_to_dll>
```

This generates a `.csproj` and `.cs` files. Use sparingly — large assemblies produce thousands of files.

### Output to a specific file

```bash
ilspycmd -t <FullTypeName> <path_to_dll> > output.cs
```

## Workflow

1. **Identify the target** — determine which DLL contains the code of interest.
2. **List types** — run `-l` and filter to find the exact fully-qualified type name.
3. **Decompile the type** — run `-t` with the type name.
4. **Read and analyze** — read the output to understand the logic.
5. **Iterate** — follow references to related types as needed.

## RimWorld Namespace Guide

| Namespace | Contains |
|-----------|----------|
| `Verse` | Core engine — Thing, Pawn, Map, Def, GenStep, etc. |
| `RimWorld` | Gameplay — Jobs, WorkGivers, Needs, ThoughtDefs, etc. |
| `RimWorld.Planet` | World map — WorldObject, Caravan, Tile, etc. |
| `RimWorld.QuestGen` | Quest generation system |
| `RimWorld.BaseGen` | Structure/settlement generation |

## Tips

- Type names are fully qualified: `Verse.Pawn`, not just `Pawn`.
- If a type is nested, use `+` syntax: `Verse.ThingDef+NamedArgument`.
- For generic types, use backtick notation: ``Verse.GenCollection`1``.
- The `-il` flag outputs raw IL instead of C# — useful for low-level analysis.
- If ilspycmd output is too long for the terminal, redirect to a file and read it.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ilspycmd` not found | Run `dotnet tool install -g ilspycmd` |
| PATH not updated after install | Restart terminal or run from `%USERPROFILE%\.dotnet\tools\ilspycmd` |
| Type not found | Run `-l` to verify the exact fully-qualified name |
| Output garbled | Ensure terminal encoding is UTF-8: `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` |