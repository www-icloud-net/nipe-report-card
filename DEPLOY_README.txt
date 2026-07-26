REPORT CARD ENTERPRISE v7.2.3 FINAL REUSABLE SCHOOLS EDITION

Deploy every file in this directory to the approved GitHub Pages branch.
Preserve the production Supabase values in config.js.
Do not publish service-role keys, package-signing secrets, backup encryption keys, or GitHub credentials.

For an upgrade from v7.2.2 Final:
1. Run the appended v7.2.3 section of 09_schema.sql in Supabase.
2. Deploy this complete frontend directory.
3. Redeploy platform-package-manager and scheduled-backup.
4. Upload PLATFORM_PACKAGE_TEMPLATE_v7_2_3_FINAL.zip through the Platform Super Administrator portal.
5. Hard-refresh all school devices.

The official report generator now redraws the grading guide from the configured academic scale and preserves the frozen guide on submitted, approved, and published reports.
