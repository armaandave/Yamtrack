"""Regression tests for the self-hosted desk Mac deploy workflow."""

from pathlib import Path

from django.test import SimpleTestCase

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "deploy-backend-desk-mac.yml"
DEPLOY_SCRIPT = REPO_ROOT / "scripts" / "codex-mobile-deploy-backend.sh"


class DeskMacDeployWorkflowTests(SimpleTestCase):
    """Ensure backend deploys cannot mutate the source branch."""

    def test_workflow_cannot_write_to_repository(self):
        workflow = WORKFLOW.read_text()

        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("contents: write", workflow)

    def test_deploy_script_never_updates_github_branch(self):
        script = DEPLOY_SCRIPT.read_text()

        forbidden_commands = [
            "git push",
            "git pull",
            "push origin",
            "git merge",
            "git rebase",
        ]
        for command in forbidden_commands:
            with self.subTest(command=command):
                self.assertNotIn(command, script)

    def test_deploy_script_uses_isolated_checkout(self):
        script = DEPLOY_SCRIPT.read_text()

        self.assertIn('repo_dir="${SPINE_DEPLOY_DIR:-$HOME/projects/spine-deploy}"', script)
        self.assertIn('source_repo_dir="${SPINE_SOURCE_REPO_DIR:-$HOME/projects/spine}"', script)
        self.assertIn("Deploy directory must be separate from source repo", script)
        self.assertIn('git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"', script)
        self.assertIn('git reset --hard "origin/$branch"', script)
