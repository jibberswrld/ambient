---
name: delegate-coding-task
description: Brief and supervise a headless Codex or Claude Code agent to finish a concrete coding task, verify the result, and report briefly.
---

Use when a request needs repository work that would interrupt the conversation: implementing a feature, fixing a bug, investigating a failure, or reviewing a change.

## Establish the job

1. Identify the exact repository and working directory from the request, memory or a small read-only shell inspection. Never guess between similar checkouts. Read that directory's AGENTS.md/CLAUDE.md and relevant project guidance. If another agent owns a checkout, use a separately authorized worktree; do not change its branch or discard its work.
2. Inspect just enough code and current git status to give the worker a useful starting point. Include relevant paths, observed failure, reproduction steps and existing constraints. If important context only exists in the conversation or on screen, put it in the brief: the worker cannot see it.
3. State an observable goal and definition of done. Specify scope, files it owns, what must remain compatible, how to run the app or reproduce the behavior, required tests, and whether to commit or open a PR. Do not invent permission to push, deploy, merge, spend money, change production, or send messages.

## Pick and launch an agent

- Follow the person's explicit engine preference first. Otherwise use Codex for bounded repository edits, bug fixes and verification with a clear finish line. Use Claude Code when the task is primarily open-ended investigation, reconciling substantial prose/context, or a project workflow already relies on Claude Code. Both can code; neither choice grants broader permissions. Check available engines rather than claiming one is unavailable.
- Call spawn_agent with the goal, engine, exact working directory and a complete brief. Use this structure:

  Goal: what the user should observe after the change.
  Directory and ownership: exact repo/worktree, branch if known, permitted paths; other agents may be working nearby.
  Evidence and context: reproduction, relevant code, decisions, constraints and guidance files.
  Work: smallest necessary implementation; preserve other people's edits.
  Done: concrete behavior, tests/build commands, runtime verification, and authorized git actions.
  Return: changed paths, commands and observed results, commit/PR if authorized, remaining blockers. Do not claim success from a passing build alone.

- Keep the task ID. Tell the person in one sentence what is running and what result you are waiting for. Continue the conversation without blocking on a shell sleep or repeatedly querying status.

## Follow through

Use get_task_result to collect the task's actual outcome. Use continue_agent with that task ID to supply missing context, respond to a blocker or request a specific correction; do not create duplicate workers for the same job. Relay important changes of scope and concrete blockers briefly. If a result lacks verification, have the agent run the missing check or explain the genuine limitation. Do not turn a worker's request for an unapproved destructive action into permission.

Finish with the observed result, one useful verification fact and any unresolved limitation. Link an authorized PR on its own line. Never say it is fixed if only a hypothesis or untested patch exists. Save a stable repository/workflow preference with remember when appropriate; do not memorize temporary task IDs or build output.
