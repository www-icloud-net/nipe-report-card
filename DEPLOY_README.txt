REPORT CARD ENTERPRISE v7.3.8 FINAL BACKUP RUNTIME RELIABILITY AND PRODUCT STABILIZATION

DEPLOYMENT
1. No SQL migration is required when upgrading from the confirmed working v7.3.7 system.
2. Deploy every file in GITHUB_PAGES_FRONTEND together. Preserve the production config.js values and confirm generatedSchoolPackage is correct for the installation.
3. Redeploy supabase/functions/scheduled-backup/index.ts. Use Verify JWT disabled for the cron-compatible function; browser requests are authorised inside the function.
4. Confirm RCE_BACKUP_ENCRYPTION_KEY and RCE_CRON_SECRET are configured. Legacy NIS_* aliases remain temporarily supported.
5. On the master edition, redeploy platform-package-manager and install PLATFORM_PACKAGE_TEMPLATE_v7_3_8_FINAL.zip.
6. Unregister the prior service worker, clear site data, and confirm cache v7-3-8-final-r1.
7. Sign in as System Administrator. Create a full backup, verify it, download it, confirm an off-site copy, and test restoration only in a staging clone first.

SECURITY
Manual backup creation and verification follow the account MFA policy. Full school restoration always requires an AAL2 authenticator session. Do not place service-role keys, backup encryption keys, cron secrets, or package signing private keys in config.js or a public repository.
