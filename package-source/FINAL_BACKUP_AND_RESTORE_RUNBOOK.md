# Nipe Report Card Enterprise v6.7.0 Final Build

## Backup and Recovery Runbook

### Protection model

The system creates an encrypted full-system export containing:

- Every public application table
- Supabase Auth user identity and profile metadata
- Student photographs
- Generated report PDFs
- Principal signature files
- Uploaded report-card templates
- An encrypted manifest with checksums and object metadata

Database JSON is compressed with gzip. The database, manifest and each Storage object are encrypted separately using AES-256-GCM and the `NISB2` payload format.

Supabase Auth password hashes are not available through the supported Auth administration API. A disaster recovery into a new project requires users to set or reset passwords.

### Secret custody

`NIS_BACKUP_ENCRYPTION_KEY` is required for every backup and recovery operation.

- Store it in a protected password manager or institutional secrets vault.
- Keep at least two controlled recovery copies held by authorized officers.
- Never store the key inside the backup ZIP.
- Never place it in GitHub, `config.js`, email, screenshots or the database.
- Losing the key makes encrypted backups unrecoverable.

### Normal operating schedule

- Full encrypted backup: every day at 02:15 UTC
- Full integrity verification: every Sunday at 03:15 UTC
- Default retention: 30 days
- Default minimum copies: 7

The System Administrator can change retention between 7 and 365 days and minimum copies between 2 and 90.

### Monthly continuity procedure

1. Sign in as System Administrator and complete MFA.
2. Open **Settings > Backup and Recovery**.
3. Confirm the latest full backup is completed.
4. Confirm the latest verification status is Passed.
5. Download one current encrypted package.
6. Store it in a separate protected location, such as an encrypted external drive or an approved cloud archive.
7. Only after the separate copy is secured, select **Confirm off-site copy** and enter a non-secret reference note.
8. Check that failed backups in the last 30 days are zero.

### Offline integrity and extraction test

1. Copy `tools/backup-decryptor.html` and `tools/vendor/jszip-3.10.1.min.js` to an offline recovery computer.
2. Open `backup-decryptor.html` in a modern browser.
3. Select the encrypted backup ZIP.
4. Enter `NIS_BACKUP_ENCRYPTION_KEY`.
5. Run decryption and verification.
6. Confirm that database JSON is decrypted, decompressed and parsed.
7. Confirm every Storage object passes its SHA-256 checksum.
8. Save the generated recovery ZIP in a temporary protected test location.
9. Delete temporary decrypted data after the test unless it is needed for an authorized recovery.

The built-in Verify action and offline extraction are non-destructive integrity rehearsals. They do not overwrite production.

## Full disaster recovery to a new Supabase project

### Phase 1: establish a clean target

1. Declare the incident and restrict write access to the damaged environment.
2. Preserve the damaged project and all available logs. Do not delete it.
3. Create a new Supabase project in the approved organization and region.
4. Record the new Project URL and Publishable key.
5. Generate a new `NIS_CRON_SECRET`.
6. Reuse the original `NIS_BACKUP_ENCRYPTION_KEY` only to decrypt the selected backup. After recovery is complete, rotate it for future backups.

### Phase 2: install the application schema

Run the seven permanent SQL files in order:

1. `01_schema_foundation.sql`
2. `02_schema_operations.sql`
3. `03A_schema_hardening_persistence_and_jobs.sql`
4. `03B1_schema_staff_academics_and_signatures.sql`
5. `03B2_schema_governance_workflow_and_upgrades.sql`
6. `04_schema.sql`
7. `05_schema.sql`

Deploy all three Edge Functions and configure secrets and Vault exactly as described in the complete fresh setup guide.

### Phase 3: decrypt the selected backup

Use the offline backup decryptor to produce:

- `database.json`
- Original files grouped by their Storage bucket and path
- Restore notes and manifest information

Verify all checksums before restoring any record.

### Phase 4: restore authentication

The backup contains Auth user identifiers, emails, metadata and identity information, but not password hashes.

1. Recreate users through an authorized administrative recovery process.
2. Preserve original UUIDs where the chosen Supabase administration method safely supports it. Otherwise, prepare a controlled identity-remapping plan before restoring public profile references.
3. Require every user to set or reset a password.
4. Re-enroll MFA where required.
5. Do not activate users until their role and staff or guardian linkage is verified.

Authentication recovery should be performed by a qualified Supabase administrator in a staging project first.

### Phase 5: restore public table data

Restore into staging before production. Use service-role or direct database administration under change control. Preserve UUIDs and timestamps.

Recommended dependency order:

1. `school_settings`
2. `academic_years`, `terms`, `classes`, `subjects`
3. `grading_scales`, `assessment_schemes`, `assessment_components`
4. `profiles`, `teachers`, `headteachers`
5. `class_subjects`, `user_class_access`
6. `students`, `student_guardians`, `guardian_links`
7. `enrollments`
8. `student_reports`
9. `subject_scores`, `subject_results`, `assessment_score_entries`
10. `report_workflow_events`, `report_revisions`, `report_publications`
11. `report_card_templates`
12. `notifications`, `notification_outbox`
13. `import_batches`, `import_errors`
14. `audit_log`, `client_error_events`, `system_maintenance_log`
15. Prior `backup_exports` and `backup_storage_objects`, if historical continuity records are required

Disable or carefully manage audit and synchronization triggers during bulk restoration only under qualified database supervision. Re-enable and validate every control before acceptance.

### Phase 6: restore Storage objects

Upload each extracted file to its original private bucket and path:

- `student-photos`
- `report-pdfs`
- `headteacher-signatures`
- `report-card-templates`

Do not make any bucket public. Confirm file counts and sample checksums against the manifest.

### Phase 7: acceptance

1. Compare restored row counts with the backup manifest.
2. Compare Storage object counts and bytes by bucket.
3. Verify System Administrator, Principal, teacher and guardian access using test accounts.
4. Open student photographs and uploaded templates.
5. Regenerate and download sample report PDFs.
6. Verify sample published-report QR codes.
7. Confirm report revisions, workflow history and audit entries.
8. Confirm Term 3 eligibility and approval-gated promotion behavior.
9. Create and verify a new encrypted backup from the recovered project.
10. Obtain formal acceptance before changing the production URL.

### Testing frequency

- Built-in encrypted-backup verification: weekly
- Off-site package export: at least monthly
- Offline decryption and checksum test: quarterly
- Full staging restoration exercise: at least annually and after major schema changes

Record every exercise date, backup identifier, operator, result and corrective action.
