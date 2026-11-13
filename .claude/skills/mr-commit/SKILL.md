---
name: mr-commit
description: Stage and commit pending changes with a conventional commit message. Use when the user asks to commit.
---

# Commit Skill

1. Run `git status` to see ALL pending changes.
2. Show the user a summary of all changed files.
3. Stage ALL changes with `git add -A` unless the user explicitly specifies a subset.
4. Write a conventional commit message: `type(scope): description`
5. After committing, run `git status` to confirm clean working tree.
6. Ask if the user wants to push.
