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

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Rdio</title>
    <link>https://raw.githubusercontent.com/${REPO}/main/appcast.xml</link>
    <description>Rdio update feed</description>
    <item>
      <title>Version ${VERSION}</title>
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
