---
name: github-release
description: Prepare or publish one MarkItDown UI GitHub release. Use for release notes, a requested version tag, the CI build and publish run, or the four published download files.
---

# GitHub Release (MarkItDown UI)

Use the release procedure in [Operations](../../../docs/operations.md#release).
A release uses one commit on `origin/main` and the version in that commit's
`app/pubspec.yaml`. CI builds the Windows EXE installer, Android APK and both macOS
DMGs, then publishes them together. A request to prepare notes or inspect
CI authorizes that work. Creating a tag requires authorization to publish.

1. Fetch `origin/main`. Use its tip unless the user identifies another
   commit on `origin/main`. Read `app/pubspec.yaml` at that exact SHA with
   `git show`. For `X.Y.Z+N`, use `vX.Y.Z` as the tag. Check that the
   requested version matches. Version changes, commits and pushes to
   `main` follow the current request.
2. Look up the tag and release on GitHub. If the release already has the
   four downloads, report it. For an existing tag with no release, verify
   its commit and resume its CI run. Treat connection or authorization
   errors separately from a missing tag or release. Never move a tag to
   a different commit or overwrite a published release to retry.
3. Compare with the previous published release and the intervening
   changes. Write English `What's new` bullets about the changes users
   get. Keep installation instructions in `.github/release-notes.md`
   and the version's bullets in `CHANGELOG.md`. If edits are needed,
   preview them and resolve the exact committed SHA before tagging.
   Render the notes for the confirmed SHA from its files:
   ```bash
   notes_tree="$(mktemp -d)"
   git archive "$release_commit" CHANGELOG.md .github/release-notes.md tool/release_notes.sh |
     tar -x -C "$notes_tree"
   "$notes_tree/tool/release_notes.sh" "$version"
   ```
4. Show the rendered notes before publishing if the user has not already
   approved that exact text and release. Then create the tag at the
   confirmed SHA and push only that tag with `git push origin "refs/tags/$tag"`.
   The tag runs `ci.yml` once, including publication. A separate manual
   run is useful only for a requested dry run or a specific diagnosis.
5. Find the CI run for the tag push and the confirmed SHA. Watch it
   through completion with `gh run watch RUN_ID --exit-status --interval 60`.
   On a failed run, inspect the failed jobs. Retry transient failures
   on the same run and commit with `gh run rerun RUN_ID --failed`.
   Check for an existing draft or release before retrying publish.
   If a fix requires a different commit or changing a release, report
   the blocker and get authorization for the next mutation.
6. Use `gh release view "$tag" --json url,isDraft,assets,body` to verify the
   public release, its notes, and the four uploads:
   - `markitdown_ui-X.Y.Z-windows-x64-setup.exe`
   - `markitdown_ui-X.Y.Z-android-arm64.apk`
   - `markitdown_ui-X.Y.Z-macos-x64.dmg`
   - `markitdown_ui-X.Y.Z-macos-arm64.dmg`

Report the release URL and the result of CI. For a dry run, report the
CI URL and the artifacts it produced.
