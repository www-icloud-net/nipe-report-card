REPORT CARD ENTERPRISE v6.7.1 REUSABLE SCHOOLS EDITION
FRESH COMPLETE PACKAGE

CURRENT STATUS
- Built from the confirmed working v6.7.0 Final Build.
- Adds a System Administrator GitHub Navigator immediately after Settings.
- Generates a separate complete fresh package for another school using that school's name, logo, report prefix, email domain, and GitHub repository identity.
- Package generation does not alter the current school's data or configuration.
- Database upgrades continue in 05_schema.sql. No 06_schema.sql is required.

THIS PACKAGE INCLUDES
- Complete frontend and GitHub Pages deployment folder.
- Seven ordered permanent database SQL files.
- Three Supabase Edge Functions.
- Reusable school package-source files for browser-based generation.
- Exact locally hosted browser libraries.
- Complete encrypted backup, retention, verification, and off-site export controls.
- Offline backup decryptor and recovery runbook.
- Approval-gated Term 3 promotion governance.

FRESH DATABASE ORDER
1. 01_schema_foundation.sql
2. 02_schema_operations.sql
3. 03A_schema_hardening_persistence_and_jobs.sql
4. 03B1_schema_staff_academics_and_signatures.sql
5. 03B2_schema_governance_workflow_and_upgrades.sql
6. 04_schema.sql
7. 05_schema.sql

IMPORTANT
- Run each SQL file separately and wait for success before continuing.
- Deploy the three Edge Functions after files 01 and 02, before file 03A.
- Configure NIS_CRON_SECRET and NIS_BACKUP_ENCRYPTION_KEY before deploying scheduled-backup.
- Configure nis_project_url and nis_cron_secret through Supabase Vault SQL before file 03A.
- Fresh installations must not run historical SQL_HOTFIX files.
- Only upload the CONTENTS of GITHUB_PAGES_FRONTEND to GitHub Pages.
- Preserve the real Project URL and Publishable key in config.js during upgrades.
- For another school, use GitHub Navigator to generate a separate package and run its SCHOOL_IDENTITY_SETUP.sql.

START HERE
Read COMPLETE_FRESH_SETUP_SUPABASE_TO_GITHUB.md.
For an existing v6.7.0 installation, read UPGRADE_FROM_V6_7_0_TO_V6_7_1_REUSABLE.txt.
For package generation, read REUSABLE_SCHOOL_PACKAGE_GENERATOR_GUIDE.md.
For continuity and recovery, read FINAL_BACKUP_AND_RESTORE_RUNBOOK.md.
