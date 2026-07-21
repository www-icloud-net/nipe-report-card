REPORT CARD ENTERPRISE v6.8.1 REUSABLE SCHOOLS EDITION
GITHUB PAGES FRONTEND

1. For an existing v6.8.0 system, run 07_schema.sql before deploying this frontend.
2. Preserve the production Supabase Project URL and Publishable key in config.js.
3. Upload the CONTENTS of this folder to the GitHub repository root.
4. Enable GitHub Pages from main / root.
5. Add the final GitHub Pages URL to Supabase Authentication Site URL and Redirect URLs.
6. Close old application tabs and perform a hard refresh after deployment.
7. Confirm Students and staff lists remain alphabetical.
8. Sign in as a subject teacher and confirm scores can be entered but reports cannot be submitted or published.
9. Sign in as a class teacher and verify individual and bulk submission only for the assigned home class.
10. Sign in as the Principal and verify individual and bulk class approval.
11. Sign in as a class teacher and System Administrator and verify approved reports can be published individually and in bulk.
12. Confirm bulk publication stores official PDFs and attendance totals still update reports automatically.

The System Administrator GitHub Navigator can generate a complete separately branded package for another school. The package-source folder is required by that generator and must remain in the deployment.

Never place Supabase Secret keys, service-role keys, database passwords, cron secrets, backup encryption keys, or email-service secrets in config.js or GitHub.
