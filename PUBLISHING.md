# Publishing this source snapshot

Publish only the contents of the sanitized `inbox-zero` archive. Do not push the original working repository or copy its `.git` directory: previous commits, reflogs, remotes, author emails, user state, and ignored files were deliberately not carried into this snapshot.

1. Extract the archive into a new directory outside any existing Git repository.
2. Read `RELEASE_REVIEW.md` and `THIRD_PARTY_NOTICES.md`; resolve the release gates.
3. Run `python3 scripts/check_public_export.py --require-history-free` before initializing Git.
4. Create a fresh repository. Choose the author identity yourself; use a GitHub-provided no-reply commit email if you do not want to disclose a personal email. Check local and global Git identity configuration before making a commit.
5. Stage only the reviewed files, inspect `git diff --cached`, and run the privacy check again.
6. Create a new GitHub repository using your chosen account and visibility, then publish only that fresh history.
7. Enable secret scanning/push protection and private vulnerability reporting where supported.

Publishing account, Git commit metadata, repository ownership, issues, screenshots, and later contributions can identify a maintainer even when source content is sanitized. This archive does not change or conceal your GitHub account or external metadata.

No GitHub repository, remote, commit, tag, or release has been created as part of preparing this copy.
