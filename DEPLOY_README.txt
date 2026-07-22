REPORT CARD ENTERPRISE v6.8.2 REUSABLE SCHOOLS EDITION

DEPLOYMENT

1. Preserve the confirmed working v6.8.1 package and create a verified backup.
2. In Supabase SQL Editor, run the v6.8.2 continuation appended to 07_schema.sql. Rerunning the complete updated 07_schema.sql is also safe.
3. Confirm the final SQL result reads: 07 SCHEMA v6.8.2 PDF/TEMPLATE STORAGE FIX: PASS.
4. Replace the GitHub Pages frontend files while preserving the installation-specific config.js values.
5. Hard refresh the browser or allow the v6.8.2 service worker to activate.
6. As an assigned class teacher, create an official PDF for a published report and download it.
7. As the System Administrator, upload or replace one report-card template and preview it.
8. Confirm a subject teacher still cannot publish reports or create official PDFs.
9. Complete every acceptance test in UPGRADE_FROM_V6_8_1_TO_V6_8_2.txt before declaring production acceptance.

The System Administrator GitHub Navigator can generate a complete separately branded package for another school. The package-source folder is required by that generator and must remain in the deployment.
