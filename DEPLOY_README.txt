REPORT CARD ENTERPRISE v7.2.9 FINAL REUSABLE SCHOOLS EDITION

Deploy only the contents of this GITHUB_PAGES_FRONTEND directory to the school GitHub Pages repository.
Preserve the production config.js values. Never publish service-role keys, secret keys, package-signing secrets, or reusable package source files.

Upgrade from v7.2.7 Final:
1. Confirm the offline synchronisation queue shows 0 pending and 0 conflicts before replacing the frontend.
2. No SQL file is required for this upgrade.
3. Deploy this complete frontend directory while preserving config.js.
4. Redeploy platform-package-manager and scheduled-backup.
5. Upload PLATFORM_PACKAGE_TEMPLATE_v7_2_9_FINAL.zip through the Platform Super Administrator portal.
6. Hard-refresh all browsers or clear the previous service-worker cache.
7. Test two school editions hosted under different repository paths and confirm their offline queues and caches remain isolated.
