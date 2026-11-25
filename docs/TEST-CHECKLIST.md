# SIP-BH V2 — Acceptance test checklist

Use fictional/demo data while testing.

## Setup
- [ ] Existing Supabase project backed up.
- [ ] `migration_v2.sql` executed without errors.
- [ ] Existing Admin can still log in.
- [ ] `.env` contains the Project URL and publishable/anon key only.
- [ ] Local app opens at the Vite URL.

## Admin tests
- [ ] Dashboard loads and refreshes.
- [ ] Admin can add/edit an OBH.
- [ ] Admin can approve and reject an OBH account.
- [ ] Admin can create a beneficiary for a selected OBH.
- [ ] Admin can create a litigation service (Perdata, Pidana or PTUN).
- [ ] Admin can create a non-litigation service.
- [ ] Admin can add progress history.
- [ ] Admin can verify, request revision and reject a service.
- [ ] Admin can upload/review a periodic report.
- [ ] Admin can enter evaluation scores.
- [ ] CSV exports open correctly in Excel.

## OBH tests
- [ ] OBH can register using a valid email and active OBH directory entry.
- [ ] Pending account cannot access the dashboard before Admin approval.
- [ ] After approval, OBH can see only its own data.
- [ ] OBH can update its contact/profile details and manage personnel.
- [ ] OBH can register a beneficiary.
- [ ] OBH can create litigation and non-litigation services.
- [ ] OBH can add progress history.
- [ ] OBH can upload a periodic report.
- [ ] OBH cannot mark its own service verified or change accreditation status.
- [ ] OBH cannot read another OBH's beneficiary, service, progress or report data.

## Deployment tests
- [ ] GitHub Actions build succeeds.
- [ ] GitHub Pages URL loads over HTTPS.
- [ ] Supabase Auth redirect URLs include the deployed site.
- [ ] Login and data access work on the deployed URL.
- [ ] Private report files require authentication and signed URLs.
