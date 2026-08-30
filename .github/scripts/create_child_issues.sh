#!/usr/bin/env bash

set -euo pipefail

echo "Looking up $ORGANIZATION Project #$PROJECT_NUMBER..."

# ================================================================
# Find Project and Iteration field
# ================================================================

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
  gh api graphql \
    -f query="$PROJECT_QUERY" \
    -f org="$ORGANIZATION" \
    -F number="$PROJECT_NUMBER"
)"

PROJECT_ID="$(
  jq -r '.data.organization.projectV2.id' <<< "$PROJECT_JSON"
)"

PROJECT_TITLE="$(
  jq -r '.data.organization.projectV2.title' <<< "$PROJECT_JSON"
)"

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

# ================================================================
# Find current iteration
# ================================================================

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
  echo "::error::Could not determine the current iteration."
  exit 1
fi

ITERATION_ID="$(jq -r '.id' <<< "$CURRENT_ITERATION")"
ITERATION_TITLE="$(jq -r '.title' <<< "$CURRENT_ITERATION")"

echo "Current iteration: $ITERATION_TITLE"
echo "Iteration ID: $ITERATION_ID"

# ================================================================
# Fetch Project items
# ================================================================

ITEMS_QUERY_FIRST='
query($project: ID!) {
  node(id: $project) {
    ... on ProjectV2 {
      items(first: 100) {
        pageInfo {
          hasNextPage
          endCursor
        }

        nodes {
          id
          type

          content {
            __typename

            ... on Issue {
              id
              databaseId
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

ITEMS_QUERY_NEXT='
query($project: ID!, $after: String!) {
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

            ... on Issue {
              id
              databaseId
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

# First page
RESPONSE="$(
  gh api graphql \
    -f query="$ITEMS_QUERY_FIRST" \
    -f project="$PROJECT_ID"
)"

PAGE_ITEMS="$(
  jq -c '.data.node.items.nodes' <<< "$RESPONSE"
)"

ALL_ITEMS="$(
  jq -c --argjson page "$PAGE_ITEMS" '. + $page' <<< "$ALL_ITEMS"
)"

HAS_NEXT="$(
  jq -r '.data.node.items.pageInfo.hasNextPage' <<< "$RESPONSE"
)"

AFTER="$(
  jq -r '.data.node.items.pageInfo.endCursor' <<< "$RESPONSE"
)"

# Additional pages
while [[ "$HAS_NEXT" == "true" ]]; do

  echo "Fetching next Project page..."

  RESPONSE="$(
    gh api graphql \
      -f query="$ITEMS_QUERY_NEXT" \
      -f project="$PROJECT_ID" \
      -f after="$AFTER"
  )"

  PAGE_ITEMS="$(
    jq -c '.data.node.items.nodes' <<< "$RESPONSE"
  )"

  ALL_ITEMS="$(
    jq -c --argjson page "$PAGE_ITEMS" '. + $page' <<< "$ALL_ITEMS"
  )"

  HAS_NEXT="$(
    jq -r '.data.node.items.pageInfo.hasNextPage' <<< "$RESPONSE"
  )"

  AFTER="$(
    jq -r '.data.node.items.pageInfo.endCursor' <<< "$RESPONSE"
  )"

done

echo "Total Project items: $(jq 'length' <<< "$ALL_ITEMS")"

# ================================================================
# Find issues in current iteration
# ================================================================

CURRENT_ITEMS="$(
  jq -c \
    --arg iteration "$ITERATION_ID" '
    [
      .[]
      | select(.type == "ISSUE")
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

# ================================================================
# Process issues
# ================================================================

while IFS= read -r ITEM; do

  ISSUE_NUMBER="$(jq -r '.content.number' <<< "$ITEM")"
  ISSUE_TITLE="$(jq -r '.content.title' <<< "$ITEM")"
  ISSUE_BODY="$(jq -r '.content.body // ""' <<< "$ITEM")"
  ISSUE_REPO="$(jq -r '.content.repository.nameWithOwner' <<< "$ITEM")"

  echo ""
  echo "=================================================="
  echo "$ISSUE_REPO#$ISSUE_NUMBER"
  echo "$ISSUE_TITLE"
  echo "=================================================="

  # --------------------------------------------------------------
  # Find Markdown checklist items
  # --------------------------------------------------------------

  CHECKLIST="$(
    printf '%s\n' "$ISSUE_BODY" |
    grep -E '^[[:space:]]*[-*+] \[[ xX]\][[:space:]]+.+$' ||
    true
  )"

  if [[ -z "$CHECKLIST" ]]; then
    echo "No checklist items."
    continue
  fi

  echo "Checklist items found:"
  echo "$CHECKLIST"

  # --------------------------------------------------------------
  # Existing child issues
  # --------------------------------------------------------------

  EXISTING_CHILDREN="$(
    gh api \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2026-03-10' \
      "/repos/$ISSUE_REPO/issues/$ISSUE_NUMBER/sub_issues?per_page=100" |
    jq -r '.[].title'
  )"

  # --------------------------------------------------------------
  # Create child issue for each checklist item
  # --------------------------------------------------------------

  while IFS= read -r LINE; do

    [[ -z "$LINE" ]] && continue

    TITLE="$(
      sed -E \
        's/^[[:space:]]*[-*+] \[[ xX]\][[:space:]]+//' \
        <<< "$LINE"
    )"

    TITLE="$(sed 's/[[:space:]]*$//' <<< "$TITLE")"

    [[ -z "$TITLE" ]] && continue

    # Avoid duplicates
    if grep -Fxq "$TITLE" <<< "$EXISTING_CHILDREN"; then
      echo "Already exists: $TITLE"
      continue
    fi

    if grep -qE '\[[xX]\]' <<< "$LINE"; then
      COMPLETED=true
    else
      COMPLETED=false
    fi

    echo "Creating child issue: $TITLE"

    CHILD_BODY="Automatically created from checklist item in #$ISSUE_NUMBER.

Parent issue: #$ISSUE_NUMBER
Source checklist item: $TITLE"

    CHILD_NUMBER="$(
      gh issue create \
        --repo "$ISSUE_REPO" \
        --title "$TITLE" \
        --body "$CHILD_BODY" \
        --json number \
        --jq '.number'
    )"

    echo "Created $ISSUE_REPO#$CHILD_NUMBER"

    CHILD_JSON="$(
      gh api \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2026-03-10' \
        "/repos/$ISSUE_REPO/issues/$CHILD_NUMBER"
    )"

    CHILD_DATABASE_ID="$(jq -r '.id' <<< "$CHILD_JSON")"
    CHILD_NODE_ID="$(jq -r '.node_id' <<< "$CHILD_JSON")"

    # ------------------------------------------------------------
    # Attach child issue to parent
    # ------------------------------------------------------------

    gh api \
      --method POST \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2026-03-10' \
      "/repos/$ISSUE_REPO/issues/$ISSUE_NUMBER/sub_issues" \
      -f sub_issue_id="$CHILD_DATABASE_ID" \
      >/dev/null

    echo "Attached as child issue."

    # ------------------------------------------------------------
    # Add child to Project
    # ------------------------------------------------------------

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

    echo "Added child to Project."

    # ------------------------------------------------------------
    # Set child iteration
    # ------------------------------------------------------------

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

    # ------------------------------------------------------------
    # Preserve checked state
    # ------------------------------------------------------------

    if [[ "$COMPLETED" == "true" ]]; then

      gh issue close \
        "$CHILD_NUMBER" \
        --repo "$ISSUE_REPO"

      echo "Closed child because checklist item was checked."

    fi

    sleep 1

  done <<< "$CHECKLIST"

done < <(jq -c '.[]' <<< "$CURRENT_ITEMS")

echo ""
echo "Done."
