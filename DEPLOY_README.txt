REPORT CARD ENTERPRISE v6.9.2 REUSABLE SCHOOLS EDITION
GITHUB PAGES DEPLOYMENT

EXISTING v6.9.1 INSTALLATION
1. Preserve the confirmed v6.9.1 package and create a verified encrypted backup.
2. Run only the appended v6.9.2 continuation in 07_schema.sql.
3. Confirm: 07 SCHEMA v6.9.2 EMERGENCY ACADEMIC DELEGATION: PASS.
4. Redeploy scheduled-backup and platform-package-manager.
5. Preserve the live Supabase URL and publishable key in config.js.
6. Upload only the contents of this GITHUB_PAGES_FRONTEND directory.
7. Hard-refresh or clear the previous application cache.
8. Complete UPGRADE_FROM_V6_9_1_TO_V6_9_2.txt acceptance tests.

FRESH INSTALLATION
Follow COMPLETE_FRESH_SETUP_SUPABASE_TO_GITHUB.md and run all nine schema files in order, ending with 07_schema.sql.

SECURITY
Never publish service-role keys, Edge Function secrets, backup keys, RCE_PACKAGE_SIGNING_SECRET, PLATFORM_PACKAGE_TEMPLATE files, generated licensed packages, or any package-source directory.
