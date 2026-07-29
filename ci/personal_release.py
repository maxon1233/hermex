#!/usr/bin/env python3
"""Guard and build owner-only personal releases from an immutable Git snapshot."""

from __future__ import annotations

import argparse
import io
import json
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Sequence


DEFAULT_RELEASE_REF = "refs/remotes/origin/personal/main"
DEFAULT_UPSTREAM_REF = "refs/remotes/upstream/master"
DEFAULT_RELEASE_BRANCH = "personal/main"
DEFAULT_BASELINE_PATH = "Config/PersonalReleaseBaseline.json"
DEFAULT_TESTED_SHA_PATH = "HERMEX_APP_UPSTREAM_TESTED_SHA"
DEFAULT_TRIAGED_SHA_PATH = "HERMEX_APP_UPSTREAM_TRIAGED_SHA"
EXPECTED_UPSTREAM_REPOSITORY = "uzairansaruzi/hermex"
FORBIDDEN_PERSONAL_BUNDLE_IDENTIFIERS = {
    "com.uzairansar.hermesmobile",
    "com.uzairansar.hermesmobile.branch",
}
FORBIDDEN_PERSONAL_TEAM_IDENTIFIERS = {"6GYD9C9N6R"}
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class PersonalReleaseError(RuntimeError):
    """A release invariant was not satisfied."""


@dataclass(frozen=True)
class RequiredCommit:
    id: str
    sha: str
    description: str


@dataclass(frozen=True)
class ReleaseBaseline:
    schema_version: int
    required_commits: tuple[RequiredCommit, ...]


@dataclass(frozen=True)
class ReleaseInspection:
    release_sha: str
    upstream_sha: str
    tested_upstream_sha: str
    triaged_upstream_sha: str
    upstream_commits_behind: int | None
    triage_commits_behind: int | None
    missing_required_commits: tuple[RequiredCommit, ...]
    new_upstream_commits: tuple[str, ...]
    # Lineage errors mean the release snapshot itself is wrong (a required
    # personal commit is missing) and always block archiving. Freshness
    # errors mean the app upstream has moved past the validated pins; the
    # owner treats upstream syncs as free-time housekeeping, so they are
    # advisory for archives and only affect the strict readiness report.
    lineage_errors: tuple[str, ...]
    freshness_errors: tuple[str, ...]

    @property
    def errors(self) -> tuple[str, ...]:
        return self.lineage_errors + self.freshness_errors

    @property
    def is_releasable(self) -> bool:
        return not self.errors

    @property
    def is_archivable(self) -> bool:
        return not self.lineage_errors

    def to_json(self) -> dict[str, object]:
        return {
            "release_sha": self.release_sha,
            "upstream_sha": self.upstream_sha,
            "tested_upstream_sha": self.tested_upstream_sha,
            "triaged_upstream_sha": self.triaged_upstream_sha,
            "upstream_commits_behind": self.upstream_commits_behind,
            "triage_commits_behind": self.triage_commits_behind,
            "missing_required_commits": [
                asdict(commit) for commit in self.missing_required_commits
            ],
            "new_upstream_commits": list(self.new_upstream_commits),
            "errors": list(self.errors),
            "is_releasable": self.is_releasable,
            "is_archivable": self.is_archivable,
        }


@dataclass(frozen=True)
class ArchiveIdentity:
    bundle_identifier: str
    team_identifier: str
    build_number: str
    source_sha: str
    source_branch: str
    upstream_sha: str
    source_dirty: str


class GitRepository:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def run(
        self,
        arguments: Sequence[str],
        *,
        capture_output: bool = True,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        command = ["git", *arguments]
        return subprocess.run(
            command,
            cwd=self.root,
            check=check,
            text=True,
            capture_output=capture_output,
        )

    def resolve(self, ref: str) -> str:
        value = self.run(["rev-parse", "--verify", f"{ref}^{{commit}}"]).stdout.strip()
        return parse_sha(value, f"Git ref {ref}")

    def show_text(self, ref: str, path: str) -> str:
        return self.run(["show", f"{ref}:{path}"]).stdout

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        result = self.run(
            ["merge-base", "--is-ancestor", ancestor, descendant],
            check=False,
        )
        return result.returncode == 0

    def commit_count(self, base: str, target: str) -> int | None:
        if not self.is_ancestor(base, target):
            return None
        value = self.run(["rev-list", "--count", f"{base}..{target}"]).stdout.strip()
        return int(value)

    def commit_summaries(self, base: str, target: str, limit: int = 40) -> tuple[str, ...]:
        if not self.is_ancestor(base, target):
            return ()
        output = self.run(
            [
                "log",
                f"--max-count={limit}",
                "--format=%H%x09%s",
                f"{base}..{target}",
            ]
        ).stdout
        return tuple(line for line in output.splitlines() if line)

    def fetch_release_refs(self) -> None:
        self.run(["fetch", "origin", "personal/main"], capture_output=False)
        self.run(["fetch", "upstream", "master"], capture_output=False)

    def verify_upstream_remote(self) -> None:
        remote_url = self.run(["remote", "get-url", "upstream"]).stdout.strip()
        normalized = remote_url.removesuffix(".git").lower()
        if EXPECTED_UPSTREAM_REPOSITORY not in normalized:
            raise PersonalReleaseError(
                "The upstream remote does not point to the official Hermex repository: "
                f"{remote_url}"
            )


def parse_sha(value: str, label: str) -> str:
    normalized = value.strip().lower()
    if not SHA_PATTERN.fullmatch(normalized):
        raise PersonalReleaseError(f"{label} must be one full 40-character Git SHA.")
    return normalized


def load_baseline(text: str) -> ReleaseBaseline:
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as error:
        raise PersonalReleaseError(f"Invalid personal release baseline JSON: {error}") from error

    if payload.get("schema_version") != 1:
        raise PersonalReleaseError("Unsupported personal release baseline schema.")

    raw_commits = payload.get("required_commits")
    if not isinstance(raw_commits, list) or not raw_commits:
        raise PersonalReleaseError("Personal release baseline must require at least one commit.")

    commits: list[RequiredCommit] = []
    seen_ids: set[str] = set()
    seen_shas: set[str] = set()
    for raw_commit in raw_commits:
        if not isinstance(raw_commit, dict):
            raise PersonalReleaseError("Every personal baseline entry must be an object.")
        identifier = str(raw_commit.get("id", "")).strip()
        description = str(raw_commit.get("description", "")).strip()
        sha = parse_sha(str(raw_commit.get("sha", "")), f"Baseline commit {identifier or '<unknown>'}")
        if not identifier or not description:
            raise PersonalReleaseError("Every personal baseline entry needs an id and description.")
        if identifier in seen_ids:
            raise PersonalReleaseError(f"Duplicate personal baseline id: {identifier}")
        if sha in seen_shas:
            raise PersonalReleaseError(f"Duplicate personal baseline SHA: {sha}")
        seen_ids.add(identifier)
        seen_shas.add(sha)
        commits.append(RequiredCommit(identifier, sha, description))

    return ReleaseBaseline(schema_version=1, required_commits=tuple(commits))


def evaluate_release(
    *,
    release_sha: str,
    upstream_sha: str,
    tested_upstream_sha: str,
    triaged_upstream_sha: str,
    baseline: ReleaseBaseline,
    is_ancestor: Callable[[str, str], bool],
    commit_count: Callable[[str, str], int | None],
    commit_summaries: Callable[[str, str], tuple[str, ...]],
) -> ReleaseInspection:
    lineage_errors: list[str] = []
    freshness_errors: list[str] = []

    missing_required_commits = tuple(
        commit
        for commit in baseline.required_commits
        if not is_ancestor(commit.sha, release_sha)
    )
    for commit in missing_required_commits:
        lineage_errors.append(
            f"Personal baseline {commit.id} is missing: {commit.description} ({commit.sha[:12]})."
        )

    tested_lag = commit_count(tested_upstream_sha, upstream_sha)
    triage_lag = commit_count(triaged_upstream_sha, upstream_sha)

    if tested_upstream_sha != upstream_sha:
        lag_description = (
            f"{tested_lag} commit(s) behind"
            if tested_lag is not None
            else "not an ancestor of the current upstream tip"
        )
        freshness_errors.append(
            "Hermex app upstream has not been validated: "
            f"{tested_upstream_sha[:12]} is {lag_description}; "
            f"current upstream is {upstream_sha[:12]}."
        )

    if triaged_upstream_sha != upstream_sha:
        lag_description = (
            f"{triage_lag} commit(s) behind"
            if triage_lag is not None
            else "not an ancestor of the current upstream tip"
        )
        freshness_errors.append(
            "Hermex app upstream has not been triaged: "
            f"{triaged_upstream_sha[:12]} is {lag_description}; "
            f"current upstream is {upstream_sha[:12]}."
        )

    if not is_ancestor(upstream_sha, release_sha):
        freshness_errors.append(
            f"Release {release_sha[:12]} does not contain upstream {upstream_sha[:12]}."
        )

    return ReleaseInspection(
        release_sha=release_sha,
        upstream_sha=upstream_sha,
        tested_upstream_sha=tested_upstream_sha,
        triaged_upstream_sha=triaged_upstream_sha,
        upstream_commits_behind=tested_lag,
        triage_commits_behind=triage_lag,
        missing_required_commits=missing_required_commits,
        new_upstream_commits=commit_summaries(tested_upstream_sha, upstream_sha),
        lineage_errors=tuple(lineage_errors),
        freshness_errors=tuple(freshness_errors),
    )


def inspect_repository(
    repository: GitRepository,
    *,
    release_ref: str,
    upstream_ref: str,
) -> ReleaseInspection:
    release_sha = repository.resolve(release_ref)
    upstream_sha = repository.resolve(upstream_ref)
    baseline = load_baseline(repository.show_text(release_ref, DEFAULT_BASELINE_PATH))
    tested_upstream_sha = parse_sha(
        repository.show_text(release_ref, DEFAULT_TESTED_SHA_PATH),
        DEFAULT_TESTED_SHA_PATH,
    )
    triaged_upstream_sha = parse_sha(
        repository.show_text(release_ref, DEFAULT_TRIAGED_SHA_PATH),
        DEFAULT_TRIAGED_SHA_PATH,
    )

    return evaluate_release(
        release_sha=release_sha,
        upstream_sha=upstream_sha,
        tested_upstream_sha=tested_upstream_sha,
        triaged_upstream_sha=triaged_upstream_sha,
        baseline=baseline,
        is_ancestor=repository.is_ancestor,
        commit_count=repository.commit_count,
        commit_summaries=repository.commit_summaries,
    )


def validate_working_tree_baseline(repository: GitRepository, release_ref: str) -> None:
    release_sha = repository.resolve(release_ref)
    baseline_path = repository.root / DEFAULT_BASELINE_PATH
    baseline = load_baseline(baseline_path.read_text(encoding="utf-8"))
    marker_paths = (DEFAULT_TESTED_SHA_PATH, DEFAULT_TRIAGED_SHA_PATH)

    errors = [
        f"{commit.id} ({commit.sha[:12]}) is not an ancestor of {release_sha[:12]}."
        for commit in baseline.required_commits
        if not repository.is_ancestor(commit.sha, release_sha)
    ]
    for marker_path in marker_paths:
        marker = parse_sha(
            (repository.root / marker_path).read_text(encoding="utf-8"),
            marker_path,
        )
        if not repository.is_ancestor(marker, release_sha):
            errors.append(
                f"{marker_path} ({marker[:12]}) is not contained in {release_sha[:12]}."
            )

    if errors:
        raise PersonalReleaseError("\n".join(errors))


def format_markdown(inspection: ReleaseInspection) -> str:
    status = "READY" if inspection.is_releasable else "BLOCKED"
    lines = [
        "# Hermex Personal Release Status",
        "",
        f"**Result:** {status}",
        "",
        f"- Personal release: `{inspection.release_sha}`",
        f"- Hermex app upstream: `{inspection.upstream_sha}`",
        f"- Tested app upstream: `{inspection.tested_upstream_sha}`",
        f"- Triaged app upstream: `{inspection.triaged_upstream_sha}`",
        f"- Upstream commits awaiting validation: "
        f"`{inspection.upstream_commits_behind if inspection.upstream_commits_behind is not None else 'diverged'}`",
        f"- Missing personal baseline commits: `{len(inspection.missing_required_commits)}`",
    ]

    if inspection.errors:
        lines.extend(["", "## Blocking findings", ""])
        lines.extend(f"- {error}" for error in inspection.errors)

    if inspection.new_upstream_commits:
        lines.extend(["", "## New upstream app commits", ""])
        for summary in inspection.new_upstream_commits:
            sha, _, subject = summary.partition("\t")
            lines.append(f"- `{sha[:12]}` {subject}")

    return "\n".join(lines) + "\n"


def extract_source_snapshot(
    repository: GitRepository,
    release_sha: str,
    destination: Path,
) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    archive = subprocess.run(
        ["git", "archive", "--format=tar", release_sha],
        cwd=repository.root,
        check=True,
        capture_output=True,
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        tar.extractall(destination)


def read_archive_identity(archive_path: Path) -> ArchiveIdentity:
    archive_info_path = archive_path / "Info.plist"
    if not archive_info_path.is_file():
        raise PersonalReleaseError(f"Archive Info.plist is missing: {archive_info_path}")

    with archive_info_path.open("rb") as handle:
        archive_info = plistlib.load(handle)
    properties = archive_info.get("ApplicationProperties", {})
    application_path = properties.get("ApplicationPath")
    if not isinstance(application_path, str) or not application_path:
        raise PersonalReleaseError("Archive does not identify its application path.")

    app_info_path = archive_path / "Products" / application_path / "Info.plist"
    if not app_info_path.is_file():
        raise PersonalReleaseError(f"Application Info.plist is missing: {app_info_path}")
    with app_info_path.open("rb") as handle:
        app_info = plistlib.load(handle)

    return ArchiveIdentity(
        bundle_identifier=str(properties.get("CFBundleIdentifier", "")),
        team_identifier=str(properties.get("Team", "")),
        build_number=str(properties.get("CFBundleVersion", "")),
        source_sha=str(app_info.get("HermexBuildSourceSHA", "")),
        source_branch=str(app_info.get("HermexBuildSourceBranch", "")),
        upstream_sha=str(app_info.get("HermexBuildUpstreamSHA", "")),
        source_dirty=str(app_info.get("HermexBuildSourceDirty", "")),
    )


def verify_archive_identity(
    identity: ArchiveIdentity,
    *,
    expected_bundle_identifier: str,
    expected_team_identifier: str,
    expected_build_number: str,
    expected_source_sha: str,
    expected_upstream_sha: str,
) -> None:
    expected = {
        "bundle identifier": expected_bundle_identifier,
        "team identifier": expected_team_identifier,
        "build number": expected_build_number,
        "source SHA": expected_source_sha,
        "source branch": DEFAULT_RELEASE_BRANCH,
        "upstream SHA": expected_upstream_sha,
        "source dirty state": "NO",
    }
    actual = {
        "bundle identifier": identity.bundle_identifier,
        "team identifier": identity.team_identifier,
        "build number": identity.build_number,
        "source SHA": identity.source_sha,
        "source branch": identity.source_branch,
        "upstream SHA": identity.upstream_sha,
        "source dirty state": identity.source_dirty,
    }
    mismatches = [
        f"{label}: expected {expected[label]!r}, found {actual[label]!r}"
        for label in expected
        if actual[label] != expected[label]
    ]
    if mismatches:
        raise PersonalReleaseError(
            "Archive identity verification failed:\n" + "\n".join(mismatches)
        )


def validate_personal_target(bundle_identifier: str, team_identifier: str) -> None:
    if bundle_identifier in FORBIDDEN_PERSONAL_BUNDLE_IDENTIFIERS:
        raise PersonalReleaseError(
            "The personal release tool refuses the production or branch TestFlight "
            f"bundle identifier: {bundle_identifier}"
        )
    if team_identifier in FORBIDDEN_PERSONAL_TEAM_IDENTIFIERS:
        raise PersonalReleaseError(
            "The personal release tool refuses the production TestFlight team: "
            f"{team_identifier}"
        )
    if not bundle_identifier.strip() or not team_identifier.strip():
        raise PersonalReleaseError(
            "Expected personal bundle and team identifiers must both be provided."
        )


def run_xcodebuild(arguments: Sequence[str], *, cwd: Path) -> None:
    subprocess.run(["xcodebuild", *arguments], cwd=cwd, check=True)


def archive_personal_release(args: argparse.Namespace, repository: GitRepository) -> None:
    validate_personal_target(args.expected_bundle_id, args.expected_team_id)
    repository.verify_upstream_remote()
    repository.fetch_release_refs()
    inspection = inspect_repository(
        repository,
        release_ref=DEFAULT_RELEASE_REF,
        upstream_ref=DEFAULT_UPSTREAM_REF,
    )
    if not inspection.is_archivable:
        print(format_markdown(inspection), file=sys.stderr)
        raise PersonalReleaseError("Personal release preflight is blocked.")
    if not inspection.is_releasable:
        # Upstream freshness is advisory for personal archives: TestFlight is
        # the owner's fast iteration channel, and upstream syncs happen in
        # free time. personal/main is already CI-gated, so the snapshot being
        # archived has passed the full suite on merge.
        print(format_markdown(inspection), file=sys.stderr)
        print(
            "WARNING: archiving despite upstream freshness findings; "
            "sync upstream in free time.",
            file=sys.stderr,
        )

    build_number = args.build_number.strip()
    if not build_number.isdigit():
        raise PersonalReleaseError("Build number must contain only decimal digits.")

    xcconfig = Path(args.xcconfig).expanduser().resolve()
    if not xcconfig.is_file():
        raise PersonalReleaseError(f"Personal xcconfig does not exist: {xcconfig}")

    archive_path = Path(args.archive_path).expanduser().resolve()
    if archive_path.exists():
        raise PersonalReleaseError(
            f"Archive path already exists; choose a new build-specific path: {archive_path}"
        )
    archive_path.parent.mkdir(parents=True, exist_ok=True)

    result_bundle_path: Path | None = None
    if args.run_tests:
        result_bundle_path = (
            Path(args.result_bundle_path).expanduser().resolve()
            if args.result_bundle_path
            else archive_path.with_suffix(".tests.xcresult")
        )
        if result_bundle_path.exists():
            raise PersonalReleaseError(
                f"Test result path already exists: {result_bundle_path}"
            )

    with tempfile.TemporaryDirectory(prefix="hermex-personal-release-") as temporary:
        temporary_root = Path(temporary)
        source_root = temporary_root / "source"
        derived_data = temporary_root / "DerivedData"
        extract_source_snapshot(repository, inspection.release_sha, source_root)

        common_identity_settings = [
            f"CURRENT_PROJECT_VERSION={build_number}",
            f"HERMEX_BUILD_SOURCE_SHA={inspection.release_sha}",
            f"HERMEX_BUILD_SOURCE_BRANCH={DEFAULT_RELEASE_BRANCH}",
            f"HERMEX_BUILD_UPSTREAM_SHA={inspection.upstream_sha}",
            "HERMEX_BUILD_SOURCE_DIRTY=NO",
        ]

        # The suite rerun is opt-in: personal/main only advances through the
        # required CI Gate, so the exported snapshot already passed the full
        # suite on merge. Pass --run-tests to revalidate anyway.
        if args.run_tests and result_bundle_path is not None:
            run_xcodebuild(
                [
                    "test",
                    "-project",
                    "HermesMobile.xcodeproj",
                    "-scheme",
                    "HermesMobile",
                    "-destination",
                    args.test_destination,
                    "-derivedDataPath",
                    str(derived_data),
                    "-resultBundlePath",
                    str(result_bundle_path),
                    "-parallel-testing-enabled",
                    "YES",
                    "-parallel-testing-worker-count",
                    "1",
                    "-xcconfig",
                    str(xcconfig),
                    "CODE_SIGNING_ALLOWED=NO",
                    *common_identity_settings,
                ],
                cwd=source_root,
            )

        run_xcodebuild(
            [
                "-project",
                "HermesMobile.xcodeproj",
                "-scheme",
                "HermesMobile",
                "-configuration",
                "Release",
                "-destination",
                "generic/platform=iOS",
                "-archivePath",
                str(archive_path),
                "-derivedDataPath",
                str(derived_data),
                "-xcconfig",
                str(xcconfig),
                *common_identity_settings,
                "archive",
                "-allowProvisioningUpdates",
            ],
            cwd=source_root,
        )

    identity = read_archive_identity(archive_path)
    verify_archive_identity(
        identity,
        expected_bundle_identifier=args.expected_bundle_id,
        expected_team_identifier=args.expected_team_id,
        expected_build_number=build_number,
        expected_source_sha=inspection.release_sha,
        expected_upstream_sha=inspection.upstream_sha,
    )

    manifest_path = archive_path.with_suffix(f"{archive_path.suffix}.source.json")
    manifest = {
        "schema_version": 1,
        "build_number": build_number,
        "bundle_identifier": identity.bundle_identifier,
        "team_identifier": identity.team_identifier,
        "source_branch": identity.source_branch,
        "source_sha": identity.source_sha,
        "upstream_sha": identity.upstream_sha,
        "source_dirty": identity.source_dirty,
        "archive_path": str(archive_path),
        "test_result_path": (
            str(result_bundle_path)
            if result_bundle_path is not None
            else "skipped (personal/main is CI-gated; pass --run-tests to revalidate)"
        ),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Verified personal archive: {archive_path}")
    print(f"Source manifest: {manifest_path}")


def add_common_inspection_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repo", default=".", help="Hermex repository worktree.")
    parser.add_argument("--release-ref", default=DEFAULT_RELEASE_REF)
    parser.add_argument("--upstream-ref", default=DEFAULT_UPSTREAM_REF)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Guard personal releases and Hermex app-upstream freshness."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status", help="Report release and upstream status.")
    add_common_inspection_arguments(status)
    status.add_argument("--fetch", action="store_true")
    status.add_argument("--format", choices=("markdown", "json"), default="markdown")

    check = subparsers.add_parser("check", help="Fail unless a personal release is safe.")
    add_common_inspection_arguments(check)
    check.add_argument(
        "--offline",
        action="store_true",
        help="Do not fetch. Never use this option for an actual release.",
    )

    baseline = subparsers.add_parser(
        "validate-baseline",
        help="Validate working-tree baseline files against a release ref.",
    )
    baseline.add_argument("--repo", default=".")
    baseline.add_argument("--release-ref", default="HEAD")

    archive = subparsers.add_parser(
        "archive",
        help="Archive the exact remote personal/main snapshot (fast by default).",
    )
    archive.add_argument("--repo", default=".")
    archive.add_argument("--build-number", required=True)
    archive.add_argument("--xcconfig", required=True)
    archive.add_argument("--archive-path", required=True)
    archive.add_argument("--expected-bundle-id", required=True)
    archive.add_argument("--expected-team-id", required=True)
    archive.add_argument("--result-bundle-path")
    archive.add_argument(
        "--run-tests",
        action="store_true",
        help=(
            "Rerun the full XCTest suite before archiving. Off by default: "
            "personal/main is CI-gated, so merged snapshots already passed."
        ),
    )
    archive.add_argument(
        "--test-destination",
        default="platform=iOS Simulator,name=iPhone 17",
    )

    verify = subparsers.add_parser(
        "verify-archive",
        help="Verify source and signing identity embedded in an archive.",
    )
    verify.add_argument("--archive-path", required=True)
    verify.add_argument("--expected-bundle-id", required=True)
    verify.add_argument("--expected-team-id", required=True)
    verify.add_argument("--expected-build-number", required=True)
    verify.add_argument("--expected-source-sha", required=True)
    verify.add_argument("--expected-upstream-sha", required=True)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        if args.command == "verify-archive":
            validate_personal_target(args.expected_bundle_id, args.expected_team_id)
            identity = read_archive_identity(Path(args.archive_path).expanduser().resolve())
            verify_archive_identity(
                identity,
                expected_bundle_identifier=args.expected_bundle_id,
                expected_team_identifier=args.expected_team_id,
                expected_build_number=args.expected_build_number,
                expected_source_sha=parse_sha(
                    args.expected_source_sha, "Expected source SHA"
                ),
                expected_upstream_sha=parse_sha(
                    args.expected_upstream_sha, "Expected upstream SHA"
                ),
            )
            print("Archive identity verified.")
            return 0

        repository = GitRepository(Path(args.repo))
        if args.command == "validate-baseline":
            validate_working_tree_baseline(repository, args.release_ref)
            print("Personal release baseline is contained in the release ref.")
            return 0

        if args.command == "archive":
            archive_personal_release(args, repository)
            return 0

        if args.command == "status" and args.fetch:
            repository.verify_upstream_remote()
            repository.fetch_release_refs()
        if args.command == "check" and not args.offline:
            repository.verify_upstream_remote()
            repository.fetch_release_refs()

        inspection = inspect_repository(
            repository,
            release_ref=args.release_ref,
            upstream_ref=args.upstream_ref,
        )
        if args.command == "status" and args.format == "json":
            print(json.dumps(inspection.to_json(), indent=2))
        else:
            print(format_markdown(inspection), end="")

        if args.command == "check" and not inspection.is_releasable:
            return 1
        return 0
    except (OSError, subprocess.CalledProcessError, PersonalReleaseError) as error:
        print(f"personal-release: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
