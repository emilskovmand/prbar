# PRBar

A macOS menu bar app that shows your open GitHub PRs together with the Claude Code agents working on them, local and cloud, live.

```
⎇ ◐1 ●2 ✗1 ✎2          ← menu bar: same icons as the panel (hover it for a legend)
─────────────────────────────────────────────
READY FOR REVIEW                            2
✗  Fix flaky sync job                    #101
   1 failing · conflicts
✓  Rollover handling                ◐    #103
   ✎ changes requested
DRAFTS                                      1
✓  Add merchant logos               ●    #102
AGENTS                                      3
◐  Rollover handling     needs you · #103 · Cloud · 3m
●  Merchant logos          working · #102 · CLI · 12s
○  Explain Prisma SQL output          Codex · 1h
```

PRs are split into **Ready for review** and **Drafts**. Within each section they're sorted by what needs attention: agents waiting on you, then failing CI or conflicts, then review feedback, then in-progress work, then quiet PRs. 

PR rows only list what needs attention (failing or running checks, review state, unresolved threads, conflicts). A dot next to the PR number shows when an agent on it is working (●) or needs you (◐).

The **Agents** section lists every running agent (Claude Code CLI, Claude Desktop, IDE, Codex, and recent cloud sessions), with the PR it's on. Hover one to see its last prompt or recap. The menu bar counts exactly what the panel shows, with the same icons.

Clicking the icon opens a panel. Clicking a PR opens it on GitHub in the background, so the panel stays open and you can open several in a row. Clicking a cloud agent opens it on claude.ai; clicking a local agent copies a `claude --resume` command for it. The panel closes on Esc or a click outside.

## Data sources

| What | Where it comes from | Refresh |
| --- | --- | --- |
| Open PRs, CI checks, review state, unresolved threads | `gh api graphql` (`viewer.pullRequests`, all repos) | 45s, and right after any local agent finishes a turn |
| Local Claude Code sessions (CLI, Desktop, IDE) | `~/.claude/sessions/<pid>.json` (live status) plus incremental tail of each session's transcript (`pr-link`, `ai-title`, `last-prompt`, recaps) | 3s |
| Codex threads (CLI and desktop app) | `~/.codex/state_*.sqlite` `threads` table, plus the task events at the end of each rollout log. Claude Code sessions Codex mirrors and Codex sub-agents are skipped. Idle threads are shown only while Codex is running. | 5s |
| Cloud Claude Code sessions | `api.anthropic.com/v1/code/sessions`, using the `claude` CLI's login from the keychain (read only; never refreshed here) | 30s |

Agents are linked to PRs in this order: the PR the session itself linked (`pr-link` / "PR #123" in a cloud summary), then the git branch of the session's working directory or the cloud session's branch, then the ticket id (`bli-1637`) in the worktree name or branch.

The cloud sessions endpoint is internal to Claude Code, not a public API, so it may change between versions. If it breaks, the panel shows a `Cloud:` warning and everything else keeps working.

## Build & install

Requires macOS 15+, Xcode command line tools, and an authenticated `gh` CLI.

```sh
./scripts/build-app.sh            # builds build/PRBar.app
./scripts/build-app.sh --install  # copies to ~/Applications and launches it
```

Enable **Open at Login** from the gear menu in the panel to start it automatically.

## Debugging

```sh
swift build -c release && .build/release/PRBar --dump
```

This polls every source once and prints what the panel would show. `PRBar --snapshot out.png` renders the panel to an image.
