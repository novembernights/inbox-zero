#!/bin/sh
set -eu
# Run from the repository root. No accounts, network, or mail services are used.
# Keep temporary outputs for inspection; the printed directory is disposable.
qa_dir=$(mktemp -d "${TMPDIR:-/tmp}/inbox-smoke.XXXXXX")
mkdir -p "$qa_dir/ranking" "$qa_dir/attachments" "$qa_dir/modules"
xcrun swiftc -module-cache-path "$qa_dir/modules" \
  inbox.Zer0iOS/MailSearchRanking.swift scripts/SearchSmokeTests.swift -o "$qa_dir/search"
"$qa_dir/search"
cp scripts/SearchRankingSmoke.swift "$qa_dir/ranking/main.swift"
xcrun swiftc -module-cache-path "$qa_dir/modules" \
  inbox.Zer0iOS/MailSearchRanking.swift "$qa_dir/ranking/main.swift" -o "$qa_dir/ranking-check"
"$qa_dir/ranking-check"
cp scripts/MIMEAttachmentPolicySmoke.swift "$qa_dir/attachments/main.swift"
xcrun swiftc -module-cache-path "$qa_dir/modules" \
  inbox.Zer0iOS/MIMEAttachmentPolicy.swift "$qa_dir/attachments/main.swift" -o "$qa_dir/attachment-check"
"$qa_dir/attachment-check"
echo "Smoke checks passed. Temporary outputs: $qa_dir"
