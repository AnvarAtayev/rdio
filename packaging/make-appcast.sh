#!/usr/bin/env bash
# Emits a single-item Sparkle appcast for the current release to stdout.
# Sparkle only needs the newest item to offer an update, so each release
# rewrites the feed rather than accumulating history.
#
# Required env:
#   REPO     owner/name (e.g. AnvarAtayev/rdio)
#   TAG      release tag (e.g. v0.1.2)
#   VERSION  version without the leading v (e.g. 0.1.2)
#   URL      download URL of the .zip
#   SIG      EdDSA signature from `sign_update -p`
#   LEN      size of the .zip in bytes
set -euo pipefail

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Release notes for Sparkle's update dialog, shown before the user installs.
#
# Source is commit subjects between the previous tag and this one. GitHub's
# generated notes are the obvious alternative but format each entry as
# "Title by @user in <PR URL>", which is right for a release page and noise in
# a small dialog. main squash-merges pull requests, so a subject here is a PR
# title someone wrote deliberately.
#
# Two filters keep infrastructure out of it:
#   - commits touching only .github/ can't be user-facing, so they're dropped by
#     path. This needs no discipline, and catches the CI and release-plumbing
#     work that predates the prefix convention below.
#   - subjects prefixed ci:/chore:/build:/docs:/test:, for internal changes that
#     do touch app code. Forgetting a prefix leaks the entry into the notes
#     rather than breaking anything, so the failure is visible and cosmetic.
# The workflow's own appcast commits are dropped by subject; they touch only a
# root-level file, so no path rule would catch them.
PREV_TAG=$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)
RANGE="${TAG}"
[ -n "$PREV_TAG" ] && RANGE="${PREV_TAG}..${TAG}"
SUBJECTS=$(git log --no-merges --pretty=%s "$RANGE" -- . ':(exclude).github' \
  | grep -Ev '^Update appcast for |^(ci|chore|build|docs|test)(\(.+\))?: ' || true)

# Escaping `>` also guarantees no `]]>` can close the CDATA block early.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

NOTES=""
if [ -n "$SUBJECTS" ]; then
  ITEMS=""
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    ITEMS="${ITEMS}  <li>$(html_escape "$subject")</li>"$'\n'
  done <<< "$SUBJECTS"
  # `color-scheme` lets the web view follow the system appearance, so the notes
  # aren't black-on-white inside a dark update dialog.
  #
  # printf rather than a heredoc: macOS ships bash 3.2, which mis-parses a
  # heredoc inside $( ) as soon as the body contains a quote character.
  NOTES=$(printf '%s\n' \
    '      <description><![CDATA[' \
    '<style>' \
    '  :root { color-scheme: light dark; }' \
    '  body { font: 13px/1.45 -apple-system, system-ui, sans-serif; margin: 8px 12px; }' \
    '  h2 { font-size: 14px; margin: 0 0 6px; }' \
    '  ul { margin: 0; padding-left: 20px; }' \
    '  li { margin-bottom: 4px; }' \
    '</style>' \
    "<h2>What's new in ${VERSION}</h2>" \
    '<ul>' \
    "${ITEMS}</ul>" \
    ']]></description>')
fi

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Rdio</title>
    <link>https://raw.githubusercontent.com/${REPO}/main/appcast.xml</link>
    <description>Rdio update feed</description>
    <item>
      <title>Version ${VERSION}</title>
${NOTES}
      <link>https://github.com/${REPO}/releases/tag/${TAG}</link>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
      <enclosure url="${URL}" type="application/octet-stream" sparkle:edSignature="${SIG}" length="${LEN}" />
    </item>
  </channel>
</rss>
EOF
