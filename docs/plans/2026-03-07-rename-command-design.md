# Design: `chatscan rename`

Rename a project directory and update all LLM conversation logs to point to the new path.

## Command

```
chatscan rename <old-path> <new-path>
```

Both paths can be absolute or relative to cwd. Resolved to absolute before proceeding.

## Flags

- `--force` — skip the y/N confirmation prompt (for scripting)

## Execution Flow

### 1. Validate

- Old path exists and is a directory
- New path does not already exist
- Check for Claude lock files in `~/.claude/projects/<old-slug>/`
- If cwd is inside old path, note it for post-rename message

### 2. Discover affected resources

- **Claude**: `~/.claude/projects/<old-slug>/` → `<new-slug>/` (slug = path with `/` → `-`)
- **Codex**: scan `~/.codex/sessions/` JSONL files for `session_meta` records with `cwd` matching old path; collect file list
- **Gemini**: scan `~/.gemini/tmp/*/` for `.project_root` files containing old path; collect matches
- **chatscan index**: count rows in `messages` where `file_path` or `project_dir` matches old slug

### 3. Print plan

```
chatscan rename: the following changes will be made:

  Project directory:
    mv /Users/pmarreck/Documents-CloudManaged/old-name
    → /Users/pmarreck/Documents-CloudManaged/new-name

  Claude conversations:
    rename ~/.claude/projects/-Users-pmarreck-Documents-CloudManaged-old-name/
         → ~/.claude/projects/-Users-pmarreck-Documents-CloudManaged-new-name/
    (47 conversation files)

  Codex sessions:
    update cwd in 12 session files

  Gemini:
    update .project_root in 2 project dirs

  chatscan index:
    update 834 indexed messages

  WARNING: You are inside the directory being renamed.
  After completion, run: cd /Users/pmarreck/Documents-CloudManaged/new-name

Proceed? [y/N]
```

### 4. Execute (in order)

1. Move the project directory (`rename` syscall, atomic on same filesystem)
2. Rename Claude conversation directory
3. Rewrite Codex JSONL `session_meta` lines (only `cwd` field changes)
4. Rewrite Gemini `.project_root` files
5. Update chatscan SQLite index (`UPDATE messages SET file_path=..., project_dir=...`)
6. Print success + `cd` hint if cwd was inside old path

## Error handling

- If step 1 (mv) fails, abort entirely — nothing else was touched
- If a later step fails, print what succeeded and what failed so the user can recover
- Steps are ordered so the most critical (directory move) happens first

## Path resolution

- Starts with `/` → absolute
- Contains `/` but doesn't start with `/` → relative to cwd, resolved to absolute
- No `/` → treated as basename in same parent as old path (for the new-path argument)

## cwd handling

- `mv` of the cwd directory works fine on macOS and Linux (shell holds stale fd)
- chatscan prints a warning and the `cd` command to run afterward
- chatscan cannot change the parent shell's cwd (it's a subprocess)

## Agent safety

- Check for Claude lock files before proceeding
- Print a warning about stopping running agents
- Require y/N confirmation (or `--force`)
