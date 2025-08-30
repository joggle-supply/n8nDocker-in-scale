#!/bin/bash
set -e

# Configuration
WORKFLOW_FILE="../workflows/email-workflow.json"
WORKFLOW_NAME="Email Test"
POSTGRES_CONTAINER="n8ndocker-in-scale-postgres-1"

echo "🔄 Inserting n8n workflow into database..."

# Check if workflow file exists
if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Error: Workflow file $WORKFLOW_FILE not found!"
    exit 1
fi

# Check if PostgreSQL container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    echo "❌ Error: PostgreSQL container $POSTGRES_CONTAINER is not running!"
    exit 1
fi

# Check if workflow already exists
EXISTING_WORKFLOW_ID=$(docker exec "$POSTGRES_CONTAINER" psql -U n8n -d n8n -t -c "
SELECT id FROM workflow_entity WHERE name = '$WORKFLOW_NAME' LIMIT 1;
" | tr -d ' ')

if [ -n "$EXISTING_WORKFLOW_ID" ]; then
    WORKFLOW_ID="$EXISTING_WORKFLOW_ID"
    echo "🔄 Found existing workflow ID: $WORKFLOW_ID"
    OPERATION="UPDATE"
else
    # Generate UUID for new workflow
    WORKFLOW_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    echo "📝 Generated new workflow ID: $WORKFLOW_ID"
    OPERATION="INSERT"
fi

# Get current timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Read and prepare JSON content for PostgreSQL
WORKFLOW_JSON=$(cat "$WORKFLOW_FILE")

# Create temporary SQL file to handle complex JSON escaping
TEMP_SQL="/tmp/insert_workflow_${WORKFLOW_ID}.sql"

echo "🔧 Operation: $OPERATION"

# Create SQL for upsert operation
if [ "$OPERATION" = "UPDATE" ]; then
cat > "$TEMP_SQL" << EOF
UPDATE workflow_entity SET
    nodes = '$(echo "$WORKFLOW_JSON" | jq -c '.nodes')'::json,
    connections = '$(echo "$WORKFLOW_JSON" | jq -c '.connections')'::json,
    "updatedAt" = '$TIMESTAMP'::timestamp with time zone,
    settings = '$(echo "$WORKFLOW_JSON" | jq -c '.settings // {}')'::json,
    "staticData" = '$(echo "$WORKFLOW_JSON" | jq -c '.staticData // {}')'::json,
    "pinData" = '$(echo "$WORKFLOW_JSON" | jq -c '.pinData // {}')'::json,
    meta = '$(echo "$WORKFLOW_JSON" | jq -c '.meta // {}')'::json
WHERE id = '$WORKFLOW_ID';
EOF
else
cat > "$TEMP_SQL" << EOF
INSERT INTO workflow_entity (
    id,
    name,
    active,
    nodes,
    connections,
    "createdAt",
    "updatedAt",
    settings,
    "staticData",
    "pinData",
    "versionId",
    "triggerCount",
    meta,
    "parentFolderId",
    "isArchived"
) VALUES (
    '$WORKFLOW_ID',
    '$WORKFLOW_NAME',
    false,
    '$(echo "$WORKFLOW_JSON" | jq -c '.nodes')'::json,
    '$(echo "$WORKFLOW_JSON" | jq -c '.connections')'::json,
    '$TIMESTAMP'::timestamp with time zone,
    '$TIMESTAMP'::timestamp with time zone,
    '$(echo "$WORKFLOW_JSON" | jq -c '.settings // {}')'::json,
    '$(echo "$WORKFLOW_JSON" | jq -c '.staticData // {}')'::json,
    '$(echo "$WORKFLOW_JSON" | jq -c '.pinData // {}')'::json,
    '$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")',
    0,
    '$(echo "$WORKFLOW_JSON" | jq -c '.meta // {}')'::json,
    null,
    false
);

-- Associate workflow with user's project (required for UI visibility)
INSERT INTO shared_workflow ("workflowId", "projectId", role, "createdAt", "updatedAt")
SELECT '$WORKFLOW_ID', p.id, 'workflow:owner', '$TIMESTAMP'::timestamp with time zone, '$TIMESTAMP'::timestamp with time zone
FROM project p
WHERE p.type = 'personal'
LIMIT 1;
EOF
fi

echo "📥 Executing SQL via temporary file..."
docker exec -i "$POSTGRES_CONTAINER" psql -U n8n -d n8n < "$TEMP_SQL" > /dev/null

echo "🧹 Cleaning up temporary files..."
rm -f "$TEMP_SQL"

if [ "$OPERATION" = "UPDATE" ]; then
    echo "✅ Workflow updated successfully!"
    echo "📊 Workflow Details:"
    echo "   - ID: $WORKFLOW_ID (existing)"
    echo "   - Name: $WORKFLOW_NAME"
    echo "   - Status: Active"
    echo "   - Updated: $TIMESTAMP"
    echo "   - Operation: UPSERT (updated existing)"
else
    echo "✅ Workflow inserted successfully!"
    echo "📊 Workflow Details:"
    echo "   - ID: $WORKFLOW_ID (new)"
    echo "   - Name: $WORKFLOW_NAME" 
    echo "   - Status: Active"
    echo "   - Created: $TIMESTAMP"
    echo "   - Operation: INSERT (new workflow)"
fi

# Verify insertion
echo "🔍 Verifying workflow in database..."
RESULT=$(docker exec "$POSTGRES_CONTAINER" psql -U n8n -d n8n -t -c "
SELECT COUNT(*) FROM workflow_entity WHERE name = '$WORKFLOW_NAME';
")

if [ "$(echo $RESULT | tr -d ' ')" = "1" ]; then
    echo "✅ Verification successful - workflow exists in database"
    echo "🎯 You can now execute this workflow from the n8n UI or REST API"
    echo "📧 Each execution will send an email showing which worker processed it"
    echo ""
    echo "To execute via API:"
    echo "curl -X POST http://localhost:5678/rest/workflows/$WORKFLOW_ID/execute \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{}'"
else
    echo "❌ Verification failed - workflow not found in database"
    exit 1
fi