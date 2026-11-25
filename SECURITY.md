# Security notes

1. Never commit `.env` or expose a Supabase `service_role` / `sb_secret_` key.
2. Use the Supabase publishable/anon key in the browser and rely on RLS for data isolation.
3. Keep beneficiary and case data fictional during development and demonstration.
4. NIK is currently stored as plaintext in the database. Do not enter real NIK values until an approved encryption/key-management design and privacy review are in place.
5. Uploaded reports are stored in a private Supabase Storage bucket with a 10 MB limit.
6. Back up the existing database before running the V2 migration.
7. This prototype needs an institutional security and privacy review before any operational use.
