import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from personal_release import (
    ArchiveIdentity,
    PersonalReleaseError,
    ReleaseBaseline,
    RequiredCommit,
    evaluate_release,
    load_baseline,
    read_archive_identity,
    validate_personal_target,
    verify_archive_identity,
)


def sha(character: str) -> str:
    return character * 40


class PersonalReleaseBaselineTests(unittest.TestCase):
    def test_loads_valid_baseline(self) -> None:
        baseline = load_baseline(
            json.dumps(
                {
                    "schema_version": 1,
                    "required_commits": [
                        {
                            "id": "pr-1",
                            "sha": sha("a"),
                            "description": "Keep a personal behavior",
                        }
                    ],
                }
            )
        )

        self.assertEqual(baseline.schema_version, 1)
        self.assertEqual(
            baseline.required_commits,
            (RequiredCommit("pr-1", sha("a"), "Keep a personal behavior"),),
        )

    def test_rejects_duplicate_baseline_ids(self) -> None:
        with self.assertRaisesRegex(PersonalReleaseError, "Duplicate personal baseline id"):
            load_baseline(
                json.dumps(
                    {
                        "schema_version": 1,
                        "required_commits": [
                            {
                                "id": "duplicate",
                                "sha": sha("a"),
                                "description": "First",
                            },
                            {
                                "id": "duplicate",
                                "sha": sha("b"),
                                "description": "Second",
                            },
                        ],
                    }
                )
            )

    def test_rejects_abbreviated_sha(self) -> None:
        with self.assertRaisesRegex(PersonalReleaseError, "40-character Git SHA"):
            load_baseline(
                json.dumps(
                    {
                        "schema_version": 1,
                        "required_commits": [
                            {
                                "id": "pr-1",
                                "sha": "abc123",
                                "description": "First",
                            }
                        ],
                    }
                )
            )


class PersonalReleaseEvaluationTests(unittest.TestCase):
    baseline = ReleaseBaseline(
        schema_version=1,
        required_commits=(
            RequiredCommit("pr-1", sha("a"), "First behavior"),
            RequiredCommit("pr-2", sha("b"), "Second behavior"),
        ),
    )

    def test_ready_when_upstream_and_personal_baseline_are_contained(self) -> None:
        release = sha("c")
        upstream = sha("d")
        ancestors = {
            (sha("a"), release),
            (sha("b"), release),
            (upstream, release),
            (upstream, upstream),
        }

        inspection = evaluate_release(
            release_sha=release,
            upstream_sha=upstream,
            tested_upstream_sha=upstream,
            triaged_upstream_sha=upstream,
            baseline=self.baseline,
            is_ancestor=lambda ancestor, descendant: (ancestor, descendant) in ancestors,
            commit_count=lambda base, target: 0 if base == target else None,
            commit_summaries=lambda _base, _target: (),
        )

        self.assertTrue(inspection.is_releasable)
        self.assertEqual(inspection.errors, ())
        self.assertEqual(inspection.missing_required_commits, ())

    def test_blocks_missing_personal_baseline_commit(self) -> None:
        release = sha("c")
        upstream = sha("d")
        ancestors = {
            (sha("a"), release),
            (upstream, release),
            (upstream, upstream),
        }

        inspection = evaluate_release(
            release_sha=release,
            upstream_sha=upstream,
            tested_upstream_sha=upstream,
            triaged_upstream_sha=upstream,
            baseline=self.baseline,
            is_ancestor=lambda ancestor, descendant: (ancestor, descendant) in ancestors,
            commit_count=lambda base, target: 0 if base == target else None,
            commit_summaries=lambda _base, _target: (),
        )

        self.assertFalse(inspection.is_releasable)
        self.assertEqual(
            inspection.missing_required_commits,
            (RequiredCommit("pr-2", sha("b"), "Second behavior"),),
        )
        self.assertTrue(any("pr-2" in error for error in inspection.errors))

    def test_blocks_unvalidated_and_unmerged_upstream_commits(self) -> None:
        release = sha("c")
        tested = sha("d")
        upstream = sha("e")
        ancestors = {
            (sha("a"), release),
            (sha("b"), release),
            (tested, release),
            (tested, upstream),
        }

        inspection = evaluate_release(
            release_sha=release,
            upstream_sha=upstream,
            tested_upstream_sha=tested,
            triaged_upstream_sha=tested,
            baseline=self.baseline,
            is_ancestor=lambda ancestor, descendant: (ancestor, descendant) in ancestors,
            commit_count=lambda base, target: 3 if (base, target) == (tested, upstream) else None,
            commit_summaries=lambda _base, _target: (
                f"{upstream}\tNew upstream feature",
            ),
        )

        self.assertFalse(inspection.is_releasable)
        self.assertEqual(inspection.upstream_commits_behind, 3)
        self.assertEqual(
            inspection.new_upstream_commits,
            (f"{upstream}\tNew upstream feature",),
        )
        self.assertTrue(
            any("has not been validated" in error for error in inspection.errors)
        )
        self.assertTrue(
            any("does not contain upstream" in error for error in inspection.errors)
        )

    def test_stale_upstream_is_advisory_for_archiving(self) -> None:
        release = sha("c")
        tested = sha("d")
        upstream = sha("e")
        ancestors = {
            (sha("a"), release),
            (sha("b"), release),
            (tested, release),
            (tested, upstream),
        }

        inspection = evaluate_release(
            release_sha=release,
            upstream_sha=upstream,
            tested_upstream_sha=tested,
            triaged_upstream_sha=tested,
            baseline=self.baseline,
            is_ancestor=lambda ancestor, descendant: (ancestor, descendant) in ancestors,
            commit_count=lambda base, target: 3 if (base, target) == (tested, upstream) else None,
            commit_summaries=lambda _base, _target: (),
        )

        self.assertFalse(inspection.is_releasable)
        self.assertTrue(inspection.is_archivable)
        self.assertEqual(inspection.lineage_errors, ())
        self.assertTrue(inspection.freshness_errors)

    def test_missing_baseline_commit_blocks_archiving(self) -> None:
        release = sha("c")
        upstream = sha("d")
        ancestors = {
            (sha("a"), release),
            (upstream, release),
            (upstream, upstream),
        }

        inspection = evaluate_release(
            release_sha=release,
            upstream_sha=upstream,
            tested_upstream_sha=upstream,
            triaged_upstream_sha=upstream,
            baseline=self.baseline,
            is_ancestor=lambda ancestor, descendant: (ancestor, descendant) in ancestors,
            commit_count=lambda base, target: 0 if base == target else None,
            commit_summaries=lambda _base, _target: (),
        )

        self.assertFalse(inspection.is_archivable)
        self.assertTrue(inspection.lineage_errors)


class PersonalReleaseArchiveIdentityTests(unittest.TestCase):
    identity = ArchiveIdentity(
        bundle_identifier="com.example.personal",
        team_identifier="TEAM123",
        build_number="202607241900",
        source_sha=sha("a"),
        source_branch="personal/main",
        upstream_sha=sha("b"),
        source_dirty="NO",
    )

    def test_accepts_exact_archive_identity(self) -> None:
        verify_archive_identity(
            self.identity,
            expected_bundle_identifier="com.example.personal",
            expected_team_identifier="TEAM123",
            expected_build_number="202607241900",
            expected_source_sha=sha("a"),
            expected_upstream_sha=sha("b"),
        )

    def test_rejects_wrong_bundle_and_source(self) -> None:
        with self.assertRaisesRegex(
            PersonalReleaseError,
            "(?s)bundle identifier.*source SHA",
        ):
            verify_archive_identity(
                self.identity,
                expected_bundle_identifier="com.example.production",
                expected_team_identifier="TEAM123",
                expected_build_number="202607241900",
                expected_source_sha=sha("c"),
                expected_upstream_sha=sha("b"),
            )

    def test_reads_identity_from_archive_plists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "Hermex.xcarchive"
            app_info = (
                archive
                / "Products"
                / "Applications"
                / "HermesMobile.app"
                / "Info.plist"
            )
            app_info.parent.mkdir(parents=True)

            with (archive / "Info.plist").open("wb") as handle:
                plistlib.dump(
                    {
                        "ApplicationProperties": {
                            "ApplicationPath": "Applications/HermesMobile.app",
                            "CFBundleIdentifier": self.identity.bundle_identifier,
                            "CFBundleVersion": self.identity.build_number,
                            "Team": self.identity.team_identifier,
                        }
                    },
                    handle,
                )
            with app_info.open("wb") as handle:
                plistlib.dump(
                    {
                        "HermexBuildSourceSHA": self.identity.source_sha,
                        "HermexBuildSourceBranch": self.identity.source_branch,
                        "HermexBuildUpstreamSHA": self.identity.upstream_sha,
                        "HermexBuildSourceDirty": self.identity.source_dirty,
                    },
                    handle,
                )

            self.assertEqual(read_archive_identity(archive), self.identity)

    def test_refuses_production_and_branch_testflight_targets(self) -> None:
        with self.assertRaisesRegex(PersonalReleaseError, "production or branch"):
            validate_personal_target(
                "com.uzairansar.hermesmobile.branch",
                "PERSONALTEAM",
            )
        with self.assertRaisesRegex(PersonalReleaseError, "production TestFlight team"):
            validate_personal_target(
                "com.example.personal",
                "6GYD9C9N6R",
            )


if __name__ == "__main__":
    unittest.main()
