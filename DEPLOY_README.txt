REPORT CARD ENTERPRISE v7.2.6 FINAL REUSABLE SCHOOLS EDITION

Deploy only the contents of this GITHUB_PAGES_FRONTEND directory to the school GitHub Pages repository.
Preserve the production config.js values. Never publish service-role keys, secret keys, package-signing secrets, or reusable package source files.

Upgrade from v7.2.4 Final:
1. Run only the appended v7.2.6 section of 09_schema.sql.
2. Deploy this complete frontend directory while preserving config.js.
3. Redeploy platform-package-manager and scheduled-backup.
4. Upload PLATFORM_PACKAGE_TEMPLATE_v7_2_6_FINAL.zip through the Platform Super Administrator portal.
5. Hard-refresh all browsers or clear the previous service-worker cache.
