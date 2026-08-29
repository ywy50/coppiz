#!/usr/bin/env python3
"""Portable project operations, configured through .local/project-kit.toml."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    print("ERROR: project-kit requires Python 3.11 or newer (tomllib).", file=sys.stderr)
    raise SystemExit(2)


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def root_from(value: str | None) -> Path:
    if value:
        root = Path(value).expanduser().resolve()
    else:
        installed = Path(__file__).resolve()
        if installed.parent.name == "scripts" and installed.parent.parent.name == ".local":
            root = installed.parent.parent.parent
        else:
            result = subprocess.run(["git", "rev-parse", "--show-toplevel"], text=True, capture_output=True)
            if result.returncode:
                raise ValueError("run inside a Git repository or pass --root")
            root = Path(result.stdout.strip()).resolve()
    # A .local/project-kit.toml marks a non-git or workspace root installed
    # with install.sh --no-git / --workspace.
    if not (root / ".git").exists() and not (root / ".local" / "project-kit.toml").exists():
        raise ValueError(f"not a Git repository and no .local/project-kit.toml: {root}")
    return root


def config(root: Path) -> dict:
    path = root / ".local" / "project-kit.toml"
    if not path.exists():
        return {}
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"invalid {path}: {error}") from error


def get(cfg: dict, section: str, key: str, default=""):
    table = cfg.get(section, {})
    return table.get(key, default) if isinstance(table, dict) else default


def local_script(root: Path, name: str) -> Path:
    return root / ".local" / "scripts" / name


def default_branch(root: Path, cfg: dict) -> str:
    configured = str(get(cfg, "project", "default_branch", "")).strip()
    if configured:
        return configured
    remote_head = shell(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], root).stdout.strip()
    if remote_head.startswith("origin/"):
        return remote_head[len("origin/"):]
    local_head = shell(["git", "symbolic-ref", "--short", "HEAD"], root).stdout.strip()
    if local_head:
        return local_head
    raise ValueError("cannot determine the default branch; set [project].default_branch in .local/project-kit.toml")


def layout(cfg: dict) -> str:
    value = str(get(cfg, "project", "layout", "standard")).strip() or "standard"
    if value not in ("standard", "local"):
        raise ValueError('project.layout must be "standard" or "local"')
    return value


def vcs(cfg: dict) -> str:
    value = str(get(cfg, "project", "vcs", "git")).strip() or "git"
    if value not in ("git", "none"):
        raise ValueError('project.vcs must be "git" or "none"')
    return value


def mode(cfg: dict) -> str:
    value = str(get(cfg, "project", "mode", "repo")).strip() or "repo"
    if value not in ("repo", "workspace"):
        raise ValueError('project.mode must be "repo" or "workspace"')
    return value


def workspace_repos(root: Path) -> list[Path]:
    repos = root / "repos"
    return sorted(path for path in repos.iterdir() if path.is_dir()) if repos.is_dir() else []


def docs_root(base: Path, cfg: dict) -> Path:
    return base / ".local/docs" if layout(cfg) == "local" else base / "docs"


def indexer_path(base: Path, cfg: dict) -> Path:
    return base / ".local/scripts/docs-index.sh" if layout(cfg) == "local" else base / "scripts/docs-index.sh"


def shell(argv: list[str], root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=root, text=True, capture_output=True)


def check(name: str, condition: bool, detail="") -> bool:
    print(f"{'ok' if condition else 'FAIL':4} {name}{': ' + detail if detail else ''}")
    return condition


def index_current(root: Path, cfg: dict) -> tuple[bool, str]:
    indexer = indexer_path(root, cfg)
    if not indexer.is_file():
        return False, f"{indexer.relative_to(root)} is missing"
    result = shell([str(indexer), "--check"], root)
    return result.returncode == 0, (result.stdout + result.stderr).strip()


def command_doctor(root: Path, cfg: dict, _args: argparse.Namespace) -> int:
    success = True
    if vcs(cfg) == "git" or mode(cfg) == "workspace":
        success &= check("Git", shutil.which("git") is not None)
    else:
        print('skip Git: project.vcs is "none"')
    success &= check("Python", sys.version_info >= (3, 11), f"{sys.version_info.major}.{sys.version_info.minor}")
    if vcs(cfg) == "git":
        success &= check(".local ignored", shell(["git", "check-ignore", "-q", ".local/project-kit-probe"], root).returncode == 0, "add /.local/ to .gitignore")
    else:
        print('skip .local ignored: project.vcs is "none"')
    if mode(cfg) == "workspace":
        success &= check("repos directory", (root / "repos").is_dir(), "repos/")
        for repo in workspace_repos(root):
            success &= check(f"repository {repo.name}", (repo / ".git").exists(), f"repos/{repo.name}")
    for name in (
        "project-kit.py",
        "new-session-id.sh",
        "lease-lock.py",
        "agent-runner.sh",
        "agent-loop.sh",
        "review-loop.sh",
        "agent-worktree-task.sh",
        "agent-automerge-git.sh",
        "report-time",
    ):
        path = local_script(root, name)
        success &= check(f"script {name}", path.is_file() and os.access(path, os.X_OK))
    indexer = indexer_path(root, cfg)
    success &= check("docs indexer", indexer.is_file(), str(indexer.relative_to(root)))
    success &= check("GitHub CLI", shutil.which("gh") is not None)
    agent = get(cfg, "project", "agent_cli", "")
    if agent:
        success &= check("configured agent", shutil.which(str(agent)) is not None, str(agent))
    else:
        print("skip configured agent: project.agent_cli is empty")
    current, detail = index_current(root, cfg)
    success &= check("docs index", current, detail or "current")
    probe = str(get(cfg, "lease", "probe", "")).strip()
    if probe:
        result = subprocess.run(probe, shell=True, cwd=root)
        success &= check("resource probe", result.returncode in (0, 1), f"exit {result.returncode}; 0=live, 1=stopped")
    else:
        print("skip resource probe: lease.probe is empty")
    destination = str(get(cfg, "backup", "destination", "")).strip()
    if destination:
        success &= check("rsync for backup", shutil.which("rsync") is not None)
    else:
        print("skip backup: backup.destination is empty")
    return 0 if success else 1


def slug(title: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    if not result:
        raise ValueError("title needs at least one letter or number")
    return result[:72]


def next_number(directory: Path) -> int:
    return max((int(path.name[:4]) for path in directory.glob("[0-9][0-9][0-9][0-9]-*.md")), default=0) + 1


def next_phase(directory: Path, series: str) -> int:
    pattern = re.compile(rf"\d{{4}}-\d{{2}}-\d{{2}}-{re.escape(series)}-phase-(\d{{2}})-[a-z0-9-]+\.md")
    return max((int(match.group(1)) for path in directory.glob("*.md") if (match := pattern.fullmatch(path.name))), default=0) + 1


def render_template(kind: str, text: str, title: str, number: int | None = None) -> str:
    headings = {"prd": "# PRD - ", "plan": "# Plan - ", "review": "# Review - ", "handover": "# Handover - ", "bug": "# Bug - ", "investigation": "# Investigation - ", "postmortem": "# Postmortem - "}
    if kind == "adr":
        if number is None:
            raise ValueError("ADR template rendering requires a number")
        headings["adr"] = f"# ADR {number:04d} - "
    text = re.sub(r"^# .*$", headings[kind] + title, text, count=1, flags=re.M)
    return text.replace("YYYY-MM-DD", datetime.now(timezone.utc).strftime("%Y-%m-%d"))


def command_new_doc(root: Path, cfg: dict, args: argparse.Namespace) -> int:
    title = " ".join(args.title)
    entries = {"prd": ("prds", "TEMPLATE.md"), "adr": ("adrs", "TEMPLATE.md"), "plan": ("plans", "TEMPLATE.md"), "review": ("reviews", "TEMPLATE.md"), "handover": ("handovers", "TEMPLATE.md"), "bug": ("reports/bugs", "TEMPLATE.md"), "investigation": ("reports/investigations", "TEMPLATE.md"), "postmortem": ("reports/postmortems", "TEMPLATE.md")}
    directory_name, template_name = entries[args.kind]
    directory = docs_root(root, cfg) / directory_name
    template = directory / template_name
    if not template.is_file():
        raise ValueError(f"missing {template}; run project-kit/install.sh first")
    directory.mkdir(parents=True, exist_ok=True)
    series = getattr(args, "series", None)
    if series and args.kind != "plan":
        raise ValueError("--series is only valid for plans")
    if args.kind in ("prd", "adr"):
        number = next_number(directory)
        output = directory / f"{number:04d}-{slug(title)}.md"
    elif series:
        # Phase plans of one parent plan: deterministic name and number so
        # they sort and count mechanically - <date>-<series>-phase-NN-<topic>.
        series = slug(series)
        number = None
        phase = next_phase(directory, series)
        date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        output = directory / f"{date}-{series}-phase-{phase:02d}-{slug(title)}.md"
        title = f"{series.replace('-', ' ').capitalize()} phase {phase:02d}: {title}"
    else:
        number = None
        date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        output = directory / f"{date}-{slug(title)}.md"
        suffix = 2
        while output.exists():
            output = directory / f"{date}-{slug(title)}-{suffix}.md"
            suffix += 1
    output.write_text(render_template(args.kind, template.read_text(encoding="utf-8"), title, number), encoding="utf-8")
    subprocess.run([str(indexer_path(root, cfg))], cwd=root, check=True)
    print(output.relative_to(root))
    return 0


def anchor(text: str) -> str:
    return re.sub(r"[ _]+", "-", re.sub(r"[^a-z0-9 _-]", "", text.lower()).strip()).strip("-")


def link_is_valid(source: Path, target: str) -> bool:
    if target.startswith(("http://", "https://", "mailto:", "tel:")):
        return True
    target = target.strip().strip("<>")
    file_name, _, fragment = target.partition("#")
    destination = source if not file_name else (source.parent / file_name).resolve()
    if not destination.exists():
        return False
    if not fragment or destination.suffix != ".md":
        return True
    anchors = {anchor(line.lstrip("#").strip()) for line in destination.read_text(encoding="utf-8").splitlines() if line.startswith("#")}
    return fragment in anchors


def command_docs_check(root: Path, cfg: dict, _args: argparse.Namespace) -> int:
    failures: list[str] = []
    docs = docs_root(root, cfg)
    # Documentation also lives at the repository root: the README and the
    # records kept beside it. The readability rules (links, paragraph
    # length, em dashes) apply to them like to docs/.
    root_docs = ("README.md", "CHANGELOG.md", "RELEASES.md", "AGENTS.md")
    readable = sorted(list(docs.rglob("*.md")) + [root / name for name in root_docs if (root / name).is_file()])
    required = {"prds": ["Status", "Problem", "Goals", "Non-goals", "Design", "Failure modes", "Acceptance criteria", "Open questions / future work"], "adrs": ["Status", "Context", "Decision", "Consequences"]}
    for group, headings in required.items():
        seen: set[int] = set()
        for path in sorted((docs / group).glob("*.md")):
            if path.name in ("TEMPLATE.md", "README.md"):
                continue
            match = re.fullmatch(r"(\d{4})-[a-z0-9][a-z0-9-]*\.md", path.name)
            if not match:
                failures.append(f"{path.relative_to(root)}: expected NNNN-kebab-name.md")
                continue
            number = int(match.group(1))
            if number in seen:
                failures.append(f"{(docs / group).relative_to(root)}: duplicate number {number:04d}")
            seen.add(number)
            body = path.read_text(encoding="utf-8")
            missing = [heading for heading in headings if f"## {heading}" not in body]
            if missing:
                failures.append(f"{path.relative_to(root)}: missing headings: {', '.join(missing)}")
    # Phase plans are numbered deterministically per series (new-doc --series):
    # within one series the numbers must be unique and contiguous from 01, so
    # name-sorted order is execution order with no gaps to second-guess.
    phase_series: dict[str, dict[int, list[Path]]] = {}
    for path in sorted((docs / "plans").glob("*.md")):
        match = re.fullmatch(r"\d{4}-\d{2}-\d{2}-([a-z0-9-]+)-phase-(\d{2})-[a-z0-9-]+\.md", path.name)
        if match:
            phase_series.setdefault(match.group(1), {}).setdefault(int(match.group(2)), []).append(path)
    for series_name, phases in phase_series.items():
        for phase_number, paths in phases.items():
            if len(paths) > 1:
                failures.append(f"{(docs / 'plans').relative_to(root)}: series {series_name} has duplicate phase {phase_number:02d}: {', '.join(p.name for p in paths)}")
        missing_phases = sorted(set(range(1, max(phases) + 1)) - set(phases))
        if missing_phases:
            failures.append(f"{(docs / 'plans').relative_to(root)}: series {series_name} has gaps: missing phase {', '.join(f'{n:02d}' for n in missing_phases)}")
    for path in readable:
        # A link pattern inside a fence or inline code span is quoted syntax,
        # not a navigable link.
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"^ {0,3}```.*?^ {0,3}```[^\n]*$", "", text, flags=re.S | re.M)
        text = re.sub(r"`[^`\n]+`", "", text)
        for target in re.findall(r"(?<!!)\[[^]]*\]\(([^)]+)\)", text):
            if not link_is_valid(path, target):
                failures.append(f"{path.relative_to(root)}: broken local link {target}")
    # Every doc is written to be scanned, not studied: flag wall-of-text
    # paragraphs (prose blocks, not code/lists/tables) that should be split,
    # and em dashes in prose (the general rule forbids them; use a regular
    # dash, comma, colon, parentheses, or a new sentence).
    for path in readable:
        in_fence = False
        block: list[str] = []
        block_start = 0
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines() + [""], start=1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if not in_fence and "\u2014" in re.sub(r"`[^`\n]+`", "", line):
                failures.append(f"{path.relative_to(root)}:{line_number}: em dash in prose; use a regular dash, comma, colon, parentheses, or a new sentence")
            prose = line.strip() and not in_fence and not re.match(r"^\s*(#|[-*+]\s|\d+\.\s|\||>)", line)
            if prose:
                if not block:
                    block_start = line_number
                block.append(line.strip())
                continue
            if len(" ".join(block)) > 700:
                failures.append(f"{path.relative_to(root)}:{block_start}: paragraph over 700 characters; split it into shorter paragraphs or a list")
            block = []
    # Report timelines are read under pressure: every data row must carry
    # an hh:mm time (date-prefixed when it changes, ~ when approximate).
    for path in sorted((docs / "reports").rglob("*.md")):
        if path.name in ("TEMPLATE.md", "README.md"):
            continue
        in_timeline = False
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.startswith("## "):
                in_timeline = line.strip() == "## Timeline"
                continue
            if not in_timeline or not line.lstrip().startswith("|"):
                continue
            first = line.strip().strip("|").split("|")[0].strip()
            if not first or set(first) <= {"-", ":", " "} or "time" in first.lower():
                continue
            if not re.search(r"\d{1,2}:\d{2}", first):
                failures.append(f"{path.relative_to(root)}:{line_number}: timeline row without an hh:mm time; stamp events with `date -u` or report-time when logging them")
    # Postmortems are blameless and shared broadly: no email addresses.
    # Individual attribution belongs in the linked internal investigation.
    for path in sorted((docs / "reports" / "postmortems").glob("*.md")):
        if path.name in ("TEMPLATE.md", "README.md"):
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if re.search(r"[\w.+-]+@[\w-]+(\.[\w-]+)*\.[A-Za-z]{2,}\b", line):
                failures.append(f"{path.relative_to(root)}:{line_number}: email address in a postmortem; refer to a role or team and keep attribution in the investigation")
    current, detail = index_current(root, cfg)
    if not current:
        failures.append(f"{(docs / 'INDEX.md').relative_to(root)} is stale ({detail})")
    if failures:
        print("Documentation check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("Documentation check passed.")
    return 0


def verification_log(root: Path) -> Path:
    return root / ".local/project-kit/verification.jsonl"


def command_verify(root: Path, cfg: dict, args: argparse.Namespace) -> int:
    commands = cfg.get("commands", {})
    if not isinstance(commands, dict):
        raise ValueError("[commands] must be a table")
    names = args.names or [name for name in ("build", "test", "lint", "release") if commands.get(name)]
    if not names:
        raise ValueError("no verification commands are configured")
    log = verification_log(root)
    log.parent.mkdir(parents=True, exist_ok=True)
    exit_code = 0
    for name in names:
        command = commands.get(name, "")
        if not isinstance(command, str) or not command.strip():
            print(f"ERROR: command {name!r} is not configured", file=sys.stderr)
            exit_code = 1
            continue
        result = subprocess.run(command, shell=True, cwd=root)
        with log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"time": now(), "name": name, "command": command, "exit": result.returncode}, separators=(",", ":")) + "\n")
        print(f"{'ok' if result.returncode == 0 else 'FAIL'} {name}: exit {result.returncode}")
        exit_code |= result.returncode != 0
    return int(exit_code)


def git_summary(repo: Path) -> tuple[str, list[str]]:
    branch = shell(["git", "rev-parse", "--abbrev-ref", "HEAD"], repo).stdout.strip()
    if not branch or branch == "HEAD":
        branch = "detached HEAD"
    changed = shell(["git", "status", "--short"], repo).stdout.splitlines()
    return f"{branch}; {len(changed)} changed path(s)", changed


def command_status(root: Path, cfg: dict, _args: argparse.Namespace) -> int:
    if mode(cfg) == "workspace":
        repos = workspace_repos(root)
        print(f"Workspace: {len(repos)} repositor{'y' if len(repos) == 1 else 'ies'} in repos/")
        for repo in repos:
            print(f"  {repo.name}: {git_summary(repo)[0] if (repo / '.git').exists() else 'not a Git repository'}")
    elif vcs(cfg) == "none":
        print('Git: none (project.vcs = "none")')
    else:
        summary, changed = git_summary(root)
        print(f"Git: {summary}")
        for line in changed[:20]: print(f"  {line}")
    todo = root / ".local/TODO.md"
    active = [line for line in todo.read_text(encoding="utf-8").splitlines() if line.startswith("[-]")] if todo.is_file() else []
    print(f"Active TODO claims: {len(active)}")
    for line in active: print(f"  {line}")
    raw_lock = str(get(cfg, "lease", "path", ".local/exclusive_resource.lock"))
    lock = Path(raw_lock).expanduser() if Path(raw_lock).is_absolute() else root / raw_lock
    lease = shell([str(local_script(root, "lease-lock.py")), "--lock", str(lock), "status"], root)
    print("Lease:\n  " + "\n  ".join(lease.stdout.strip().splitlines()))
    handovers = sorted(
        (item for item in (docs_root(root, cfg) / "handovers").glob("*.md") if item.name != "TEMPLATE.md"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    print("Recent handovers:")
    for path in handovers[:3]: print(f"  {path.relative_to(root)}")
    if not handovers: print("  none")
    last = None
    log = verification_log(root)
    if log.is_file():
        for line in reversed(log.read_text(encoding="utf-8").splitlines()):
            try:
                last = json.loads(line); break
            except json.JSONDecodeError: pass
    print(f"Last verification: {last['time']} {last['name']} exit {last['exit']}" if last else "Last verification: none recorded")
    return 0


def command_worktree(root: Path, cfg: dict, args: argparse.Namespace) -> int:
    in_workspace = mode(cfg) == "workspace"
    if in_workspace:
        if not args.repo:
            raise ValueError("workspace mode: pass --repo <name> (a directory under repos/)")
        repo_root = root / "repos" / args.repo
        if not (repo_root / ".git").exists():
            raise ValueError(f"not a Git repository: {repo_root}")
    elif vcs(cfg) == "none":
        raise ValueError('worktree requires a Git repository (project.vcs = "none")')
    else:
        if args.repo:
            raise ValueError("--repo only applies to workspace mode")
        repo_root = root
    session = subprocess.run([str(local_script(root, "new-session-id.sh")), args.agent], text=True, capture_output=True, check=True).stdout.strip()
    name = slug(args.name)
    label = f"{args.repo}/{name}" if in_workspace else name
    base = args.base or default_branch(repo_root, cfg)
    branch = args.branch or f"agent/{session}/{name}"
    directory = f"{args.repo}-{name}" if in_workspace else name
    path = Path(args.path).expanduser().resolve() if args.path else root / ".local/worktrees" / f"{directory}-{session.rsplit('-', 1)[-1]}"
    if path.exists():
        raise ValueError(f"worktree path already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "worktree", "add", "-b", branch, str(path), base], cwd=repo_root, check=True)
    if not in_workspace:
        # In workspace mode the shared .local stays at the workspace root; the
        # member repository does not ignore /.local/, so no symlink there.
        child_local = path / ".local"
        if not child_local.exists() and not child_local.is_symlink(): child_local.symlink_to(root / ".local", target_is_directory=True)
    todo = root / ".local/TODO.md"
    existing = todo.read_text(encoding="utf-8") if todo.is_file() else ""
    prefix = "" if not existing or existing.endswith("\n") else "\n"
    with todo.open("a", encoding="utf-8") as handle:
        handle.write(f"{prefix}[-] Worktree {label} - in progress - {args.agent}, {datetime.now(timezone.utc):%Y-%m-%d}; session: {session}\n")
    # Workspace worktrees contain only the member repository, so their
    # handover lives in the shared docs tree at the workspace root.
    docs_base = root if in_workspace else path
    handover = docs_root(docs_base, cfg) / "handovers" / f"{datetime.now(timezone.utc):%Y-%m-%d}-{directory}-worktree.md"
    template = docs_root(docs_base, cfg) / "handovers" / "TEMPLATE.md"
    if template.is_file():
        handover.write_text(render_template("handover", template.read_text(encoding="utf-8"), f"{label} worktree").replace("<agent-session-id>", session).replace("<agent or person>", args.agent).replace("<TODO, plan, PRD, ADR, review, branch, or PR>", branch), encoding="utf-8")
        subprocess.run([str(indexer_path(docs_base, cfg))], cwd=docs_base, check=True)
    print(f"session={session}\nbase={base}\nbranch={branch}\nworktree={path}\nhandover={handover}")
    return 0


def command_backup(root: Path, cfg: dict, _args: argparse.Namespace) -> int:
    raw = str(get(cfg, "backup", "destination", "")).strip()
    if not raw: raise ValueError("backup is disabled; configure [backup].destination")
    if not shutil.which("rsync"): raise ValueError("rsync is required for backup")
    destination_path = Path(raw).expanduser()
    if not destination_path.is_absolute():
        raise ValueError("backup destination must be an absolute external path")
    destination = destination_path.resolve()
    if destination == root or root in destination.parents: raise ValueError("backup destination must be outside the repository")
    includes = get(cfg, "backup", "includes", [".local"])
    if not isinstance(includes, list) or not all(isinstance(item, str) for item in includes): raise ValueError("backup.includes must be an array of relative paths")
    base = destination / root.name
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    snapshot = base / stamp
    latest = base / "latest"
    previous = latest.resolve() if latest.is_symlink() else None
    for item in includes:
        source = (root / item).resolve()
        if root not in source.parents or not source.exists(): raise ValueError(f"backup include must exist inside repository: {item}")
        target = snapshot / item
        target.parent.mkdir(parents=True, exist_ok=True)
        argv = ["rsync", "-a"]
        if previous and (previous / item).exists(): argv += ["--link-dest", str(previous / item)]
        subprocess.run(argv + [str(source) + "/", str(target) + "/"], check=True)
    base.mkdir(parents=True, exist_ok=True)
    temporary = base / f".latest.{os.getpid()}"
    temporary.symlink_to(stamp)
    os.replace(temporary, latest)
    print(snapshot)
    return 0


def parser() -> argparse.ArgumentParser:
    output = argparse.ArgumentParser(description="Portable project-kit operations; config: .local/project-kit.toml")
    output.add_argument("--root", help="repository root; defaults to the current Git repository")
    sub = output.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    doc = sub.add_parser("new-doc"); doc.add_argument("kind", choices=("prd", "adr", "plan", "review", "handover", "bug", "investigation", "postmortem")); doc.add_argument("--series", help="plans only: phase series slug; names the doc <date>-<series>-phase-NN-<title>.md with NN auto-numbered"); doc.add_argument("title", nargs="+")
    sub.add_parser("docs-check")
    verify = sub.add_parser("verify"); verify.add_argument("names", nargs="*")
    sub.add_parser("status")
    worktree = sub.add_parser("worktree"); worktree.add_argument("name"); worktree.add_argument("--agent", default="codex"); worktree.add_argument("--base"); worktree.add_argument("--branch"); worktree.add_argument("--path"); worktree.add_argument("--repo", help="workspace mode: the repository under repos/ to branch")
    sub.add_parser("backup")
    return output


def main() -> int:
    aliases = {"new-doc": "new-doc", "docs-check": "docs-check", "project-status": "status", "project-worktree": "worktree", "project-backup": "backup"}
    argv = sys.argv[1:]
    alias = Path(sys.argv[0]).name
    if alias in aliases: argv.insert(0, aliases[alias])
    args = parser().parse_args(argv)
    try:
        root = root_from(args.root); cfg = config(root)
        return {"doctor": command_doctor, "new-doc": command_new_doc, "docs-check": command_docs_check, "verify": command_verify, "status": command_status, "worktree": command_worktree, "backup": command_backup}[args.command](root, cfg, args)
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr); return 1


if __name__ == "__main__":
    raise SystemExit(main())
