#!/bin/bash

echo "🔍 n8n Worker Distribution Monitor"
echo "=================================="
echo ""

# Check current executions
echo "📊 Recent Executions (last 10):"
docker exec n8ndocker-in-scale-postgres-1 psql -U n8n -d n8n -c "
SELECT 
    id,
    CASE 
        WHEN finished = true THEN '✅'
        ELSE '❌'
    END as status,
    \"startedAt\",
    CASE 
        WHEN finished = true THEN 'SUCCESS'
        ELSE status
    END as result
FROM execution_entity 
WHERE \"workflowId\" = (SELECT id FROM workflow_entity WHERE name = 'Email Test' LIMIT 1)
ORDER BY \"startedAt\" DESC 
LIMIT 10;
"

echo ""
echo "🏃‍♂️ Active Workers:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep n8n-worker

echo ""
echo "📦 Redis Queue Status:"
docker exec n8ndocker-in-scale-redis-1 redis-cli info keyspace

echo ""
echo "💡 To test worker distribution:"
echo "   1. Execute workflow manually in n8n UI multiple times"
echo "   2. Check emails at parasu@joggle.supply"
echo "   3. Each successful execution will send an email"
echo "   4. Run this script again to see execution count increase"