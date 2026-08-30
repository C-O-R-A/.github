#!/usr/bin/env bash

set -euo pipefail

: "${ORGANIZATION:?ORGANIZATION is required}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER is required}"
: "${CHILD_ISSUE_REPOSITORY:?CHILD_ISSUE_REPOSITORY is required}"

echo "Looking up $ORGANIZATION Project #$PROJECT_NUMBER..."

PROJECT_QUERY='
query($org: String!, $number: Int!) {
organization(login: $org) {
projectV2(number: $number) {
id
title
fields(first: 100) {
nodes {
__typename
... on ProjectV2IterationField {
id
name
configuration {
iterations {
id
title
startDate
duration
}
}
}
}
}
}
}
}'

PROJECT_JSON="$(
gh api graphql 
-f query="$PROJECT_QUERY" 
-f org="$ORGANIZATION" 
-F number="$PROJECT_NUMBER"
)"

PROJECT_ID="$(jq -r '.data.organization.projectV2.id' <<< "$PROJECT_JSON")"
PROJECT_TITLE="$(jq -r '.data.organization.projectV2.title' <<< "$PROJECT_JSON")"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
echo "::error::Could not find Project #$PROJECT_NUMBER."
exit 1
fi

echo "Project: $PROJECT_TITLE"
echo "Project ID: $PROJECT_ID"

ITERATION_FIELD_ID="$(
jq -r '
.data.organization.projectV2.fields.nodes[]
| select(.__typename == "ProjectV2IterationField")
| .id
' <<< "$PROJECT_JSON" | head -n1
)"

if [[ -z "$ITERATION_FIELD_ID" || "$ITERATION_FIELD_ID" == "null" ]]; then
echo "::error::No Iteration field found."
exit 1
fi

echo "Iteration field: $ITERATION_FIELD_ID"

# Find current iteration

TODAY_EPOCH="$(date -u +%s)"
CURRENT_ITERATION=""

while IFS= read -r ITERATION; do
[[ -z "$ITERATION" ]] && continue

START_DATE="$(jq -r '.startDate' <<< "$ITERATION")"
DURATION="$(jq -r '.duration' <<< "$ITERATION")"

START_EPOCH="$(date -u -d "$START_DATE" +%s)"
END_EPOCH=$((START_EPOCH + DURATION * 86400))

if (( TODAY_EPOCH >= START_EPOCH && TODAY_EPOCH < END_EPOCH )); then
CURRENT_ITERATION="$ITERATION"
break
fi
done < <(
jq -c '
.data.organization.projectV2.fields.nodes[]
| select(.__typename == "ProjectV2IterationField")
| .configuration.iterations[]
' <<< "$PROJECT_JSON"
)

if [[ -z "$CURRENT_ITERATION" ]]; then
echo "::error::Could not determine current iteration."
exit 1
fi

ITERATION_ID="$(jq -r '.id' <<< "$CURRENT_ITERATION")"
ITERATION_TITLE="$(jq -r '.title' <<< "$CURRENT_ITERATION")"

echo "Current iteration: $ITERATION_TITLE"
echo "Iteration ID: $ITERATION_ID"

# Fetch Project items

ITEMS_QUERY='
query($project: ID!, $after: String) {
node(id: $project) {
... on ProjectV2 {
items(first: 100, after: $after) {
pageInfo {
hasNextPage
endCursor
}
nodes {
id
type
content {
__typename
... on DraftIssue {
id
title
body
}
}
fieldValues(first: 100) {
nodes {
__typename
... on ProjectV2ItemFieldIterationValue {
iterationId
title
}
}
}
}
}
}
}
}'

ALL_ITEMS='[]'
AFTER="null"

while true; do
if [[ "$AFTER" == "null" ]]; then
RESPONSE="$(
gh api graphql 
-f query="$ITEMS_QUERY" 
-f project="$PROJECT_ID"
)"
else
RESPONSE="$(
gh api graphql 
-f query="$ITEMS_QUERY" 
-f project="$PROJECT_ID" 
-f after="$AFTER"
)"
fi

PAGE_ITEMS="$(jq -c '.data.node.items.nodes' <<< "$RESPONSE")"

ALL_ITEMS="$(
jq -c --argjson page "$PAGE_ITEMS" '. + $page' <<< "$ALL_ITEMS"
)"

HAS_NEXT="$(jq -r '.data.node.items.pageInfo.hasNextPage' <<< "$RESPONSE")"
AFTER="$(jq -r '.data.node.items.pageInfo.endCursor' <<< "$RESPONSE")"

[[ "$HAS_NEXT" != "true" ]] && break

echo "Fetching next Project page..."
done

echo "Total Project items: $(jq 'length' <<< "$ALL_ITEMS")"

# Find draft items in current iteration

CURRENT_ITEMS="$(
jq -c 
--arg iteration "$ITERATION_ID" '
[
.[]
| select(.content.__typename == "DraftIssue")
| select(
any(
.fieldValues.nodes[];
.__typename == "ProjectV2ItemFieldIterationValue"
and .iterationId == $iteration
)
)
]
' <<< "$ALL_ITEMS"
)"

ITEM_COUNT="$(jq 'length' <<< "$CURRENT_ITEMS")"

echo "Draft items in current iteration: $ITEM_COUNT"

if [[ "$ITEM_COUNT" == "0" ]]; then
echo "Nothing to process."
exit 0
fi

# Mutations

ADD_ITEM_MUTATION='
mutation($project: ID!, $content: ID!) {
addProjectV2ItemById(
input: {
projectId: $project
contentId: $content
}
) {
item {
id
}
}
}'

UPDATE_ITERATION_MUTATION='
mutation(
$project: ID!,
$item: ID!,
$field: ID!,
$iteration: String!
) {
updateProjectV2ItemFieldValue(
input: {
projectId: $project
itemId: $item
fieldId: $field
value: {
iterationId: $iteration
}
}
) {
projectV2Item {
id
}
}
}'

# Process draft items

while IFS= read -r ITEM; do

DRAFT_TITLE="$(jq -r '.content.title' <<< "$ITEM")"
DRAFT_BODY="$(jq -r '.content.body // ""' <<< "$ITEM")"

echo ""
echo "=================================================="
echo "Draft item: $DRAFT_TITLE"
echo "=================================================="

CHECKLIST="$(
printf '%s\n' "$DRAFT_BODY" |
grep -E '^[[:space:]]*[-*+] \([ xX]\)[[:space:]]+.+$' ||
true
)"

if [[ -z "$CHECKLIST" ]]; then
echo "No checklist items."
continue
fi

echo "Checklist items found:"
echo "$CHECKLIST"

while IFS= read -r LINE; do

```
[[ -z "$LINE" ]] && continue

TITLE="$(
  sed -E \
    's/^[[:space:]]*[-*+] \[[ xX]\][[:space:]]+//' \
    <<< "$LINE"
)"

TITLE="$(sed 's/[[:space:]]*$//' <<< "$TITLE")"

[[ -z "$TITLE" ]] && continue

COMPLETED=false
if grep -qE '\[[xX]\]' <<< "$LINE"; then
  COMPLETED=true
fi

echo ""
echo "Checklist item: $TITLE"

# Check for an existing issue with exactly this title
EXISTING_NUMBER="$(
  gh issue list \
    --repo "$CHILD_ISSUE_REPOSITORY" \
    --state all \
    --search "$TITLE in:title" \
    --limit 100 \
    --json number,title 2>/dev/null |
  jq -r \
    --arg title "$TITLE" \
    '.[] | select(.title == $title) | .number' |
  head -n1 ||
  true
)"

if [[ -n "$EXISTING_NUMBER" ]]; then
  echo "Already exists: #$EXISTING_NUMBER"
  continue
fi

CHILD_BODY="Created automatically from a checklist item in the Planner Board.
```

Source draft item: $DRAFT_TITLE

Checklist item:

$LINE"

```
echo "Creating issue..."

CHILD_URL="$(
  gh issue create \
    --repo "$CHILD_ISSUE_REPOSITORY" \
    --title "$TITLE" \
    --body "$CHILD_BODY"
)"

CHILD_URL="$(printf '%s' "$CHILD_URL" | tail -n1)"
CHILD_NUMBER="${CHILD_URL##*/}"

if [[ ! "$CHILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "::error::Could not determine issue number from: $CHILD_URL"
  exit 1
fi

echo "Created: $CHILD_URL"

CHILD_JSON="$(
  gh api \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "/repos/$CHILD_ISSUE_REPOSITORY/issues/$CHILD_NUMBER"
)"

CHILD_NODE_ID="$(jq -r '.node_id' <<< "$CHILD_JSON")"

# Add issue to Project
ADD_RESULT="$(
  gh api graphql \
    -f query="$ADD_ITEM_MUTATION" \
    -f project="$PROJECT_ID" \
    -f content="$CHILD_NODE_ID"
)"

CHILD_PROJECT_ITEM_ID="$(
  jq -r '.data.addProjectV2ItemById.item.id' <<< "$ADD_RESULT"
)"

if [[ -z "$CHILD_PROJECT_ITEM_ID" ||
      "$CHILD_PROJECT_ITEM_ID" == "null" ]]; then
  echo "::error::Failed to add #$CHILD_NUMBER to Project."
  exit 1
fi

echo "Added #$CHILD_NUMBER to Planner Board."

# Set iteration
gh api graphql \
  -f query="$UPDATE_ITERATION_MUTATION" \
  -f project="$PROJECT_ID" \
  -f item="$CHILD_PROJECT_ITEM_ID" \
  -f field="$ITERATION_FIELD_ID" \
  -f iteration="$ITERATION_ID" \
  >/dev/null

echo "Set iteration: $ITERATION_TITLE"

# Close if checklist item was already checked
if [[ "$COMPLETED" == "true" ]]; then
  gh issue close \
    "$CHILD_NUMBER" \
    --repo "$CHILD_ISSUE_REPOSITORY"

  echo "Closed #$CHILD_NUMBER because checklist item was checked."
fi

sleep 1
```

done <<< "$CHECKLIST"

done < <(jq -c '.[]' <<< "$CURRENT_ITEMS")

echo ""
echo "=================================================="
echo "Finished."
echo "=================================================="
