#!/usr/bin/env python3
"""Update selected third-party lock files from their declared Git refs."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
LOCK_GROUPS = {
    "aurora": PROJECT_ROOT / "configs/aurora-sources.lock",
    "arwi": PROJECT_ROOT / "configs/arwi-source.lock",
    "bandix": PROJECT_ROOT / "configs/bandix-sources.lock",
    "adguardhome": PROJECT_ROOT / "configs/adguardhome-source.lock",
}
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
TAG_PATTERN = re.compile(r"^(v?)([0-9]+(?:\.[0-9]+){1,3})(.*)$")


def git_ls_remote(*args: str) -> list[str]:
    result = subprocess.run(
        ["git", "ls-remote", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.splitlines()


def version_key(value: str) -> tuple[int, int, int, int]:
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0, 0, 0])[:4])  # type: ignore[return-value]


def remote_branch_commit(url: str, ref: str) -> str:
    branch_ref = f"refs/heads/{ref}"
    rows = git_ls_remote("--heads", url, branch_ref)
    if len(rows) != 1:
        raise RuntimeError(f"Unable to resolve branch {ref} from {url}")
    commit, remote_ref = rows[0].split()
    if remote_ref != branch_ref or not SHA_PATTERN.fullmatch(commit):
        raise RuntimeError(f"Invalid branch response for {url} {ref}")
    return commit


def latest_tag(url: str, current_ref: str, locked_commit: str) -> tuple[str, str]:
    match = TAG_PATTERN.fullmatch(current_ref)
    if not match:
        raise RuntimeError(f"Unsupported version tag format: {current_ref}")
    prefix, current_version, suffix = match.groups()
    expected = re.compile(
        rf"^{re.escape(prefix)}(?P<version>[0-9]+(?:\.[0-9]+){{1,3}}){re.escape(suffix)}$"
    )

    tag_commits: dict[str, str] = {}
    peeled_commits: dict[str, str] = {}
    for row in git_ls_remote("--tags", url):
        fields = row.split()
        if len(fields) != 2 or not SHA_PATTERN.fullmatch(fields[0]):
            continue
        remote_ref = fields[1]
        if not remote_ref.startswith("refs/tags/"):
            continue
        tag_name = remote_ref.removeprefix("refs/tags/")
        if tag_name.endswith("^{}"):
            peeled_commits[tag_name[:-3]] = fields[0]
        else:
            tag_commits[tag_name] = fields[0]

    remote_current = peeled_commits.get(current_ref, tag_commits.get(current_ref))
    if remote_current is None:
        raise RuntimeError(f"Current tag was removed: {current_ref} ({url})")
    if remote_current != locked_commit:
        raise RuntimeError(f"Current tag was rewritten: {current_ref} ({url})")

    candidates: list[tuple[tuple[int, int, int, int], str, str]] = []
    for tag_name, tag_commit in tag_commits.items():
        candidate = expected.fullmatch(tag_name)
        if not candidate:
            continue
        commit = peeled_commits.get(tag_name, tag_commit)
        candidates.append((version_key(candidate.group("version")), tag_name, commit))
    if not candidates:
        raise RuntimeError(f"No matching version tags found for {current_ref} ({url})")

    latest_version, latest_ref, latest_commit = max(candidates, key=lambda item: item[0])
    if latest_version <= version_key(current_version):
        return current_ref, locked_commit
    return latest_ref, latest_commit


def update_lock(
    path: Path, check_only: bool, resolved_entries: list[str] | None = None
) -> int:
    lines = path.read_text(encoding="utf-8").splitlines()
    changes = 0
    for index, raw_line in enumerate(lines):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) != 4:
            raise RuntimeError(f"Invalid lock entry: {path}:{index + 1}")
        name, url, ref, commit = fields
        if not SHA_PATTERN.fullmatch(commit):
            raise RuntimeError(f"Invalid commit: {path}:{index + 1}")

        if ref in {"main", "master"}:
            new_ref, new_commit = ref, remote_branch_commit(url, ref)
        else:
            new_ref, new_commit = latest_tag(url, ref, commit)

        if (new_ref, new_commit) == (ref, commit):
            print(f"{name}: up to date ({ref} {commit[:12]})")
        else:
            print(f"{name}: {ref} {commit[:12]} -> {new_ref} {new_commit[:12]}")
            lines[index] = f"{name} {url} {new_ref} {new_commit}"
            changes += 1
        if resolved_entries is not None:
            resolved_entries.append(f"{name} {url} {new_ref} {new_commit}")

    if changes and not check_only:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return changes


def selected_groups() -> list[str]:
    selected: list[str] = []
    for group in LOCK_GROUPS:
        value = os.environ.get(f"UPDATE_{group.upper()}", "true").lower()
        if value not in {"true", "false"}:
            raise RuntimeError(f"UPDATE_{group.upper()} must be true or false")
        if value == "true":
            selected.append(group)
    if not selected:
        raise RuntimeError("Select at least one third-party plugin group")
    return selected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="report updates without writing locks")
    parser.add_argument(
        "--resolve-output",
        type=Path,
        help="write latest resolved entries without modifying the lock files",
    )
    args = parser.parse_args()

    total = 0
    resolved_entries: list[str] | None = [] if args.resolve_output else None
    for group in selected_groups():
        total += update_lock(
            LOCK_GROUPS[group], args.check or bool(args.resolve_output), resolved_entries
        )
    if args.resolve_output:
        assert resolved_entries is not None
        args.resolve_output.parent.mkdir(parents=True, exist_ok=True)
        args.resolve_output.write_text(
            "\n".join(resolved_entries) + "\n", encoding="utf-8", newline="\n"
        )
    print(f"Updates found: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
