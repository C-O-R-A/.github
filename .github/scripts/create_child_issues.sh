#!/usr/bin/env bash

set -euo pipefail

: "${ORGANIZATION:?ORGANIZATION is required}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER is required}"

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
  gh api graphql \
    -f query="$PROJECT_QUERY" \
    -f org="$ORGANIZATION" \
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
          content {
            __typename
            ... on Issue {
              id
              number
              title
              body
              repository {
                nameWithOwner
              }
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
AFTER=""

while true; do
  if [[ -z "$AFTER" ]]; then
    RESPONSE="$(
      gh api graphql \
        -f query="$ITEMS_QUERY" \
        -f project="$PROJECT_ID"
    )"
  else
    RESPONSE="$(
      gh api graphql \
        -f query="$ITEMS_QUERY" \
        -f project="$PROJECT_ID" \
        -f after="$AFTER"
    )"
  fi

  PAGE_ITEMS="$(jq -c '.data.node.items.nodes' <<< "$RESPONSE")"

  ALL_ITEMS="$(
    jq -c \
      --argjson page "$PAGE_ITEMS" \
      '. + $page' \
      <<< "$ALL_ITEMS"
  )"

  HAS_NEXT="$(jq -r '.data.node.items.pageInfo.hasNextPage' <<< "$RESPONSE")"
  AFTER="$(jq -r '.data.node.items.pageInfo.endCursor' <<< "$RESPONSE")"

  [[ "$HAS_NEXT" != "true" ]] && break

  echo "Fetching next Project page..."
done

echo "Total Project items: $(jq 'length' <<< "$ALL_ITEMS")"

CURRENT_ITEMS="$(
  jq -c \
    --arg iteration "$ITERATION_ID" '
    [
      .[]
      | select(.content.__typename == "Issue")
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

ISSUE_COUNT="$(jq 'length' <<< "$CURRENT_ITEMS")"

echo "Issues in current iteration: $ISSUE_COUNT"

if [[ "$ISSUE_COUNT" == "0" ]]; then
  echo "Nothing to process."
  exit 0
fi

while IFS= read -r ITEM; do
  PARENT_NUMBER="$(jq -r '.content.number' <<< "$ITEM")"
  PARENT_TITLE="$(jq -r '.content.title' <<< "$ITEM")"
  PARENT_BODY="$(jq -r '.content.body // ""' <<< "$ITEM")"
  PARENT_REPO="$(jq -r '.content.repository.nameWithOwner' <<< "$ITEM")"

  echo ""
  echo "=================================================="
  echo "$PARENT_REPO#$PARENT_NUMBER"
  echo "$PARENT_TITLE"
  echo "=================================================="

  CHECKLIST="$(
    printf '%s\n' "$PARENT_BODY" |
    grep -E '^[[:space:]]*[-*+] \[[ xX]\][[:space:]]+.+$' ||
    true
  )"

  if [[ -z "$CHECKLIST" ]]; then
    echo "No checklist items."
    continue
  fi

  echo "Checklist items found:"
  echo "$CHECKLIST"

  while IFS= read -r LINE; do
    [[ -z "$LINE" ]] && continue

    TITLE="$(
      sed -E \
        's/^[[:space:]]*[-*+] \[[ xX]\][[:space:]]+//' \
        <<< "$LINE"
    )"

    TITLE="$(sed 's/[[:space:]]*$//' <<< "$TITLE")"

    [[ -z "$TITLE" ]] && continue

    if grep -qE '\[[xX]\]' <<< "$LINE"; then
      COMPLETED=true
    else
      COMPLETED=false
    fi

    echo ""
    echo "Checklist item: $TITLE"

    EXISTING_NUMBER="$(
      gh issue list \
        --repo "$PARENT_REPO" \
        --state all \
        --search "$TITLE in:title" \
        --limit 100 \
        --json number,title |
      jq -r \
        --arg title "$TITLE" \
        '.[] | select(.title == $title) | .number' |
      head -n1 ||
      true
    )"

    if [[ -n "$EXISTING_NUMBER" ]]; then
      echo "Already exists: $PARENT_REPO#$EXISTING_NUMBER"
      continue
    fi

    CHILD_BODY="Created automatically from a checklist item.

Parent issue: #$PARENT_NUMBER
Parent title: $PARENT_TITLE

Source checklist item:

$LINE"

    echo "Creating child issue in $PARENT_REPO..."

    CHILD_URL="$(
      gh issue create \
        --repo "$PARENT_REPO" \
        --title "$TITLE" \
        --body "$CHILD_BODY"
    )"

    CHILD_URL="$(printf '%s\n' "$CHILD_URL" | tail -n1)"
    CHILD_NUMBER="${CHILD_URL##*/}"

    if [[ ! "$CHILD_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "::error::Could not determine issue number from: $CHILD_URL"
      exit 1
    fi

    echo "Created: $CHILD_URL"

    CHILD_NODE_ID="$(
      gh api \
        "/repos/$PARENT_REPO/issues/$CHILD_NUMBER" |
      jq -r '.node_id'
    )"

    OWNER="${PARENT_REPO%%/*}"
    REPO="${PARENT_REPO#*/}"

    PARENT_GRAPHQL_ID="$(
      gh api graphql \
        -f query='
          query($owner: String!, $repo: String!, $number: Int!) {
            repository(owner: $owner, name: $repo) {
              issue(number: $number) {
                id
              }
            }
          }' \
        -f owner="$OWNER" \
        -f repo="$REPO" \
        -F number="$PARENT_NUMBER" |
      jq -r '.data.repository.issue.id'
    )"

    CHILD_GRAPHQL_ID="$(
      gh api graphql \
        -f query='
          query($owner: String!, $repo: String!, $number: Int!) {
            repository(owner: $owner, name: $repo) {
              issue(number: $number) {
                id
              }
            }
          }' \
        -f owner="$OWNER" \
        -f repo="$REPO" \
        -F number="$CHILD_NUMBER" |
      jq -r '.data.repository.issue.id'
    )"

    ADD_SUB_ISSUE_MUTATION='
      mutation($parent: ID!, $child: ID!) {
        addSubIssue(
          input: {
            issueId: $parent
            subIssueId: $child
          }
        ) {
          issue {
            id
          }
          subIssue {
            id
          }
        }
      }'

    gh api graphql \
      -f query="$ADD_SUB_ISSUE_MUTATION" \
      -f parent="$PARENT_GRAPHQL_ID" \
      -f child="$CHILD_GRAPHQL_ID" \
      >/dev/null

    echo "Attached as child of #$PARENT_NUMBER."

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
      echo "::error::Failed to add child to Project."
      exit 1
    fi

    echo "Added child to Planner Board."

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

    gh api graphql \
      -f query="$UPDATE_ITERATION_MUTATION" \
      -f project="$PROJECT_ID" \
      -f item="$CHILD_PROJECT_ITEM_ID" \
      -f field="$ITERATION_FIELD_ID" \
      -f iteration="$ITERATION_ID" \
      >/dev/null

    echo "Set iteration: $ITERATION_TITLE"

    if [[ "$COMPLETED" == "true" ]]; then
      gh issue close \
        "$CHILD_NUMBER" \
        --repo "$PARENT_REPO"

      echo "Closed child because checklist item was checked."
    fi

    sleep 1

  done <<< "$CHECKLIST"

done < <(jq -c '.[]' <<< "$CURRENT_ITEMS")

echo ""
echo "Done."
