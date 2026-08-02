#!/usr/bin/env bash
# Renders README.md from the GitHub API.
#
# Counts only PUBLIC pull requests and issues in repositories the user does not
# own, so day-job work in private company repos never appears. In CI the
# GITHUB_TOKEN cannot see private repos anyway; the isPrivate filter keeps a
# local run with a personal token producing identical output.
set -euo pipefail

OSS_USER="${OSS_USER:?OSS_USER is required}"
WINDOW_DAYS="${WINDOW_DAYS:-365}"

if date -u -v-1d +%F >/dev/null 2>&1; then
  FROM_DATE=$(date -u -v-"${WINDOW_DAYS}"d +%F)   # BSD date (macOS)
else
  FROM_DATE=$(date -u -d "${WINDOW_DAYS} days ago" +%F)  # GNU date (CI)
fi
TODAY=$(date -u +%F)

pr_query='
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title url state createdAt mergedAt additions deletions
        repository { nameWithOwner url stargazerCount isPrivate owner { login } }
      }
    }
  }
}'

issue_query='
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on Issue {
        number title url state createdAt
        repository { nameWithOwner isPrivate owner { login } }
      }
    }
  }
}'

# Pages through the search API; search caps at 1000 results per query.
fetch_all() {
  local query="$1" search="$2" out="$3" cursor="null" page
  : > "$out"
  while :; do
    if [ "$cursor" = "null" ]; then
      page=$(gh api graphql -F q="$search" -f query="$query")
    else
      page=$(gh api graphql -F q="$search" -F cursor="$cursor" -f query="$query")
    fi
    echo "$page" | jq -c '.data.search.nodes[]' >> "$out"
    [ "$(echo "$page" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(echo "$page" | jq -r '.data.search.pageInfo.endCursor')
  done
}

fetch_all "$pr_query"    "author:$OSS_USER is:pr created:>=$FROM_DATE"    prs.ndjson
fetch_all "$issue_query" "author:$OSS_USER is:issue created:>=$FROM_DATE" issues.ndjson

# Community-only: drop private repos and anything the user owns.
jq -s --arg user "$OSS_USER" '
  map(select(.repository.isPrivate == false and .repository.owner.login != $user))
' prs.ndjson > prs.json
jq -s --arg user "$OSS_USER" '
  map(select(.repository.isPrivate == false and .repository.owner.login != $user))
' issues.ndjson > issues.json

jq -n \
  --slurpfile prs prs.json \
  --slurpfile issues issues.json \
  --arg user "$OSS_USER" \
  --arg from "$FROM_DATE" \
  --arg today "$TODAY" \
  -r '
  ($prs[0]) as $p
  | ($issues[0]) as $i
  | ($p | map(select(.state == "MERGED"))) as $merged

  # Monthly activity, PRs and issues combined, keyed by YYYY-MM.
  | (($p + $i) | group_by(.createdAt[0:7])
      | map({month: .[0].createdAt[0:7], n: length})
      | sort_by(.month)) as $months
  | (($months | map(.n) | max) // 1) as $peak

  # Repositories, ranked by merged PRs then stars.
  | ($p | group_by(.repository.nameWithOwner)
      | map({
          repo:  .[0].repository.nameWithOwner,
          url:   .[0].repository.url,
          stars: .[0].repository.stargazerCount,
          merged: (map(select(.state == "MERGED")) | length),
          open:   (map(select(.state == "OPEN"))   | length),
          closed: (map(select(.state == "CLOSED")) | length),
          prs: (sort_by(.createdAt) | reverse)
        })
      | sort_by(-.merged, -.stars)) as $repos

  | "# open source contributions",
    "",
    "<sub>public pull requests and issues in repositories i do not own. personal repos and company work are excluded. regenerated daily from the github api.</sub>",
    "",
    "## overview",
    "",
    "| metric | count |",
    "| --- | ---: |",
    "| merged pull requests | \($merged | length) |",
    "| pull requests opened | \($p | length) |",
    "| issues filed | \($i | length) |",
    "| repositories touched | \($repos | length) |",
    "",
    "<sub>window: \($from) to \($today)</sub>",
    "",
    "## monthly activity",
    "",
    "```",
    ($months[] | "\(.month)  \(.n | tostring | (" " * (3 - length)) + .)  \("█" * ((.n * 28 / $peak) | ceil))"),
    "```",
    "",
    "## repositories",
    "",
    ($repos[] |
      "### [\(.repo)](\(.url)) · \(.stars) stars",
      "",
      "\(.merged) merged · \(.open) open · \(.closed) closed",
      "",
      "| date | state | diff | title |",
      "| --- | --- | ---: | --- |",
      (.prs[] |
        "| \(.createdAt[0:10]) | \(.state | ascii_downcase) | +\(.additions)/-\(.deletions) | [\(.title | gsub("\\|"; "\\\\|"))](\(.url)) |"),
      ""),
    "<sub>last updated \($today)</sub>"
' > README.md

rm -f prs.ndjson issues.ndjson prs.json issues.json
echo "wrote README.md"
