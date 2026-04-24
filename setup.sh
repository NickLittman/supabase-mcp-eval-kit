#!/usr/bin/env bash
set -euo pipefail

# Supabase MCP Eval Sandbox — one-command setup
#
# Usage:
#   ./setup.sh                          # interactive (prompts for org + region)
#   ./setup.sh --org-id <id>            # non-interactive with defaults
#   ./setup.sh --org-id <id> --region us-west-1 --name my-sandbox
#
# Prerequisites:
#   - supabase CLI installed: brew install supabase/tap/supabase
#   - logged in: supabase login

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
PROJECT_NAME="mcp-eval-sandbox"
REGION="us-east-1"
ORG_ID=""
DB_PASSWORD=""

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --org-id)   ORG_ID="$2"; shift 2 ;;
    --region)   REGION="$2"; shift 2 ;;
    --name)     PROJECT_NAME="$2"; shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./setup.sh [--org-id <id>] [--region <region>] [--name <name>] [--db-password <pw>]"
      echo ""
      echo "Creates a Supabase project, applies the sandbox migration, and deploys the Edge Function."
      echo ""
      echo "Options:"
      echo "  --org-id       Organization ID (required, or will prompt)"
      echo "  --region       Region (default: us-east-1)"
      echo "  --name         Project name (default: mcp-eval-sandbox)"
      echo "  --db-password  Database password (default: auto-generated)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Check prerequisites
if ! command -v supabase &> /dev/null; then
  echo "Error: supabase CLI not found. Install: brew install supabase/tap/supabase"
  exit 1
fi

# Get org ID if not provided
if [[ -z "$ORG_ID" ]]; then
  echo "Available organizations:"
  supabase orgs list
  echo ""
  read -rp "Enter organization ID: " ORG_ID
fi

# Generate a DB password if not provided
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
fi

echo ""
echo "Creating project '$PROJECT_NAME' in org '$ORG_ID' (region: $REGION)..."
echo ""

# 1. Create project
PROJECT_REF=$(supabase projects create "$PROJECT_NAME" \
  --org-id "$ORG_ID" \
  --region "$REGION" \
  --db-password "$DB_PASSWORD" \
  --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "Project created: $PROJECT_REF"
echo "Waiting for project to be ready..."

# Poll until project is healthy
for i in $(seq 1 60); do
  STATUS=$(supabase projects list --output json 2>/dev/null | \
    python3 -c "import sys,json; projects=json.load(sys.stdin); print(next((p['status'] for p in projects if p['id']=='$PROJECT_REF'), 'unknown'))" 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "ACTIVE_HEALTHY" ]]; then
    echo "Project is ready. Waiting 10s for database to fully initialize..."
    sleep 10
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "Timeout waiting for project. Check dashboard: https://supabase.com/dashboard/project/$PROJECT_REF"
    exit 1
  fi
  sleep 5
done

# 2. Link project
echo ""
echo "Linking project..."
supabase link --project-ref "$PROJECT_REF" --workdir "$SCRIPT_DIR"

# 3. Push migrations (retry up to 3 times — DB may still be starting TLS after creation)
echo ""
echo "Applying migration..."
for attempt in 1 2 3; do
  if SUPABASE_DB_PASSWORD="$DB_PASSWORD" supabase db push --workdir "$SCRIPT_DIR" 2>&1; then
    break
  fi
  if [[ $attempt -eq 3 ]]; then
    echo "Migration failed after 3 attempts. Try manually:"
    echo "  SUPABASE_DB_PASSWORD='$DB_PASSWORD' supabase db push"
    exit 1
  fi
  echo "Connection failed (attempt $attempt/3). Retrying in 10s..."
  sleep 10
done

# 4. Deploy Edge Function
echo ""
echo "Deploying Edge Function..."
supabase functions deploy team-stats --project-ref "$PROJECT_REF" --workdir "$SCRIPT_DIR"

# 5. Upload placeholder files to storage
echo ""
echo "Uploading placeholder files to storage..."

API_URL="https://$PROJECT_REF.supabase.co"
SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null | \
  python3 -c "import sys,json; keys=json.load(sys.stdin); print(next((k['api_key'] for k in keys if k['name']=='service_role'), ''))" 2>/dev/null || echo "")

if [[ -n "$SERVICE_ROLE_KEY" ]]; then
  # Get the file_path values from the documents table (these are the paths we need to create)
  DOC_PATHS=$(curl -s "$API_URL/rest/v1/documents?select=file_path" \
    -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" | \
    python3 -c "import sys,json; [print(d['file_path']) for d in json.load(sys.stdin)]" 2>/dev/null || true)

  if [[ -n "$DOC_PATHS" ]]; then
    while IFS= read -r filepath; do
      # Create a small placeholder file with metadata
      FILENAME=$(basename "$filepath")
      PLACEHOLDER="This is a placeholder for: $FILENAME\nUploaded by the MCP eval sandbox setup script."

      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$API_URL/storage/v1/object/documents/$filepath" \
        -H "apikey: $SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
        -H "Content-Type: text/plain" \
        --data-binary "$PLACEHOLDER")

      if [[ "$HTTP_CODE" == "200" ]]; then
        echo "  Uploaded: documents/$filepath"
      else
        echo "  Warning: failed to upload documents/$filepath (HTTP $HTTP_CODE)"
      fi
    done <<< "$DOC_PATHS"
  else
    echo "  Warning: could not query document paths. Skipping storage uploads."
  fi
else
  echo "  Warning: could not get service role key. Skipping storage uploads."
fi

# 6. Print summary
ANON_KEY=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null | \
  python3 -c "import sys,json; keys=json.load(sys.stdin); print(next((k['api_key'] for k in keys if k['name']=='anon'), 'unknown'))" 2>/dev/null || echo "(check dashboard)")

echo ""
echo "============================================"
echo "  Sandbox ready!"
echo "============================================"
echo ""
echo "  Project ref:  $PROJECT_REF"
echo "  API URL:      $API_URL"
echo "  Anon key:     $ANON_KEY"
echo "  DB password:  $DB_PASSWORD"
echo ""
echo "  Dashboard:    https://supabase.com/dashboard/project/$PROJECT_REF"
echo "  Edge Function: $API_URL/functions/v1/team-stats"
echo ""
echo "  Test users:   alice@example.com through ivan@example.com"
echo "  Password:     password123"
echo ""
