Run the full pre-deploy verification and tag a new version for deployment.

## Steps

1. Run `scripts/pre-deploy` to execute the full verification checklist (tests, formatting, credo, dialyzer, YAML validation, Docker build, release boot).
2. If any step fails, stop and report the failure. Do not proceed to tagging.
3. Check the latest version tag: `git tag --sort=-creatordate | head -5`
4. Determine the next version by incrementing the patch number (e.g., v0.5.19 -> v0.5.20). If the user provided a specific version, use that instead.
5. Show the user: what changed since last tag (`git log --oneline <last-tag>..HEAD`), the proposed version number, and ask for confirmation before tagging.
6. Create the tag: `git tag <version>`
7. Push commit and tag: `git push && git push --tags`
8. Report the deploy URL and remind the user to monitor the GitHub Actions workflow.

## Important

- Never skip the pre-deploy verification.
- Never create a tag that is numerically lower than the latest existing tag.
- If `git push` requires confirmation (e.g., force push), stop and ask the user.
