#!/bin/bash
# GH secrets設定 (WIF + BQ)
# 1回だけ実行: bash scripts/setup-gh-secrets.sh

set -e

REPO="bonsai/stock-bqml"

WIF_PROVIDER="projects/826943922547/locations/global/workloadIdentityPools/stock-bqml-pool/providers/gh-oidc"
SA_EMAIL="stock-bqml-sa@gen-lang-client-0315818888.iam.gserviceaccount.com"

echo "=== Setting GH secrets for $REPO ==="

gh secret set GCP_WIF_PROVIDER --repo $REPO --body "$WIF_PROVIDER"
echo "  GCP_WIF_PROVIDER ✓"

gh secret set GCP_SERVICE_ACCOUNT --repo $REPO --body "$SA_EMAIL"
echo "  GCP_SERVICE_ACCOUNT ✓"

gh secret set BQ_PROJECT --repo $REPO --body "gen-lang-client-0315818888"
echo "  BQ_PROJECT ✓"

echo ""
echo "=== Done ==="
echo "Next: push && workflow_dispatch でパイプライン実行確認"
